-- ONE PIXEL v2: accounts, themes-compatible canvas, cooldown, and leaderboard.
-- Run this entire file in Supabase SQL Editor as the project owner.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null,
  created_at timestamptz not null default now(),
  constraint username_format check (username ~ '^[A-Za-z0-9_]{3,20}$')
);
create unique index if not exists profiles_username_lower_unique on public.profiles (lower(username));

create table if not exists public.pixels (
  x integer not null check (x >= 0 and x < 10000),
  y integer not null check (y >= 0 and y < 10000),
  color text not null check (color ~ '^#[0-9A-Fa-f]{6}$'),
  user_id uuid not null references public.profiles(id) on delete restrict,
  updated_at timestamptz not null default now(),
  primary key (x,y)
);
create index if not exists pixels_user_id_idx on public.pixels(user_id);

-- Append-only contribution history. This is what the leaderboard counts.
create table if not exists public.pixel_placements (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete restrict,
  x integer not null,
  y integer not null,
  color text not null,
  placed_at timestamptz not null default now()
);
create index if not exists pixel_placements_user_id_idx on public.pixel_placements(user_id);

create table if not exists public.pixel_cooldowns (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  last_placed_at timestamptz not null
);

-- Create a profile automatically when a username/password account is created.
-- The browser maps usernames to synthetic addresses at users.onepixel.invalid for Supabase Auth.
-- Email confirmation must be disabled in the Supabase Dashboard.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  requested_name text;
begin
  requested_name := coalesce(new.raw_user_meta_data ->> 'username', '');
  if requested_name !~ '^[A-Za-z0-9_]{3,20}$' then
    requested_name := 'pixel_' || substr(replace(new.id::text, '-', ''), 1, 12);
  end if;
  insert into public.profiles (id, username)
  values (new.id, requested_name);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile
after insert on auth.users
for each row execute procedure public.handle_new_user();

alter table public.profiles enable row level security;
alter table public.pixels enable row level security;
alter table public.pixel_placements enable row level security;
alter table public.pixel_cooldowns enable row level security;

drop policy if exists "Profiles are publicly readable" on public.profiles;
create policy "Profiles are publicly readable" on public.profiles for select using (true);
drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile" on public.profiles for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);
-- No client insert/delete policy: profile creation is handled by the trusted auth trigger.

drop policy if exists "Pixels are publicly readable" on public.pixels;
create policy "Pixels are publicly readable" on public.pixels for select using (true);
-- Pixel writes happen only through the server-side place_pixel RPC.

-- Contribution history and cooldowns are intentionally not directly readable/writable by clients.
revoke all on public.pixel_placements from anon, authenticated;
revoke all on public.pixel_cooldowns from anon, authenticated;
revoke insert, update, delete on public.pixels from anon, authenticated;
grant select on public.profiles, public.pixels to anon, authenticated;
grant update (username) on public.profiles to authenticated;

create or replace function public.place_pixel(p_x integer, p_y integer, p_color text)
returns table(x integer, y integer, color text, updated_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  previous_time timestamptz;
  placed_time timestamptz := clock_timestamp();
begin
  if current_user_id is null then
    raise exception 'You must be logged in to place a pixel.' using errcode = '28000';
  end if;
  if p_x is null or p_y is null or p_x < 0 or p_y < 0 or p_x >= 10000 or p_y >= 10000 then
    raise exception 'Pixel coordinates are outside the canvas.' using errcode = '22023';
  end if;
  if p_color is null or p_color !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception 'Color must be a six-digit HEX value.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where id = current_user_id) then
    raise exception 'Your account profile is still being created. Please try again.';
  end if;

  insert into public.pixel_cooldowns(user_id,last_placed_at)
  values(current_user_id, '-infinity'::timestamptz)
  on conflict(user_id) do nothing;

  select last_placed_at into previous_time
  from public.pixel_cooldowns
  where user_id = current_user_id
  for update;

  if previous_time > placed_time - interval '10 seconds' then
    raise exception 'Cooldown active. Wait 10 seconds between pixels.' using errcode = 'P0001';
  end if;

  update public.pixel_cooldowns set last_placed_at = placed_time where user_id = current_user_id;
  insert into public.pixels(x,y,color,user_id,updated_at)
  values(p_x,p_y,upper(p_color),current_user_id,placed_time)
  on conflict(x,y) do update set color=excluded.color,user_id=excluded.user_id,updated_at=excluded.updated_at;
  insert into public.pixel_placements(user_id,x,y,color,placed_at)
  values(current_user_id,p_x,p_y,upper(p_color),placed_time);

  return query select p.x,p.y,p.color,p.updated_at from public.pixels p where p.x=p_x and p.y=p_y;
end;
$$;

create or replace function public.get_pixels_in_bounds(
  p_min_x integer, p_min_y integer, p_max_x integer, p_max_y integer, p_limit integer default 50000
)
returns table(x integer,y integer,color text)
language sql
stable
security definer
set search_path = ''
as $$
  select p.x,p.y,p.color from public.pixels p
  where p.x between greatest(0,p_min_x) and least(9999,p_max_x)
    and p.y between greatest(0,p_min_y) and least(9999,p_max_y)
  order by p.y,p.x
  limit least(greatest(coalesce(p_limit,50000),1),50000);
$$;

create or replace function public.get_pixel_count()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$ select count(*) from public.pixels; $$;

create or replace function public.get_leaderboard(p_limit integer default 10)
returns table(username text, placements bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select pr.username, count(pp.id)::bigint as placements
  from public.profiles pr
  join public.pixel_placements pp on pp.user_id=pr.id
  group by pr.id,pr.username
  order by count(pp.id) desc, lower(pr.username) asc
  limit least(greatest(coalesce(p_limit,10),1),50);
$$;

revoke all on function public.place_pixel(integer,integer,text) from public;
revoke all on function public.get_pixels_in_bounds(integer,integer,integer,integer,integer) from public;
revoke all on function public.get_pixel_count() from public;
revoke all on function public.get_leaderboard(integer) from public;
grant execute on function public.place_pixel(integer,integer,text) to authenticated;
grant execute on function public.get_pixels_in_bounds(integer,integer,integer,integer,integer) to anon, authenticated;
grant execute on function public.get_pixel_count() to anon, authenticated;
grant execute on function public.get_leaderboard(integer) to anon, authenticated;

-- Enable realtime updates for the shared canvas.
do $$
begin
  alter publication supabase_realtime add table public.pixels;
exception when duplicate_object then null;
when undefined_object then raise notice 'supabase_realtime publication not found; enable Realtime for public.pixels in the dashboard.';
end $$;
