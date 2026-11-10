-- ONE PIXEL database setup
-- Run this entire file in the Supabase SQL Editor.
create table if not exists public.pixels (
  x integer not null check (x >= 0 and x < 10000),
  y integer not null check (y >= 0 and y < 10000),
  color text not null check (color ~ '^#[0-9A-Fa-f]{6}$'),
  updated_at timestamptz not null default now(),
  primary key (x, y)
);

create table if not exists public.pixel_cooldowns (
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_placed_at timestamptz not null
);

alter table public.pixels enable row level security;
alter table public.pixel_cooldowns enable row level security;
drop policy if exists "Pixels are readable by everyone" on public.pixels;
create policy "Pixels are readable by everyone" on public.pixels for select to anon, authenticated using (true);
-- Writes happen only through the validated SECURITY DEFINER RPC below.
revoke insert, update, delete on public.pixels from anon, authenticated;
revoke all on public.pixel_cooldowns from anon, authenticated;

grant select on public.pixels to anon, authenticated;

create or replace function public.get_pixels_in_bounds(
  p_min_x integer, p_min_y integer, p_max_x integer, p_max_y integer, p_limit integer default 50000
) returns table(x integer, y integer, color text)
language sql stable security definer set search_path = public
as $$
  select px.x, px.y, px.color from public.pixels px
  where px.x between greatest(0,p_min_x) and least(9999,p_max_x)
    and px.y between greatest(0,p_min_y) and least(9999,p_max_y)
  order by px.y, px.x limit least(greatest(coalesce(p_limit,50000),1),50000);
$$;

create or replace function public.get_pixel_count()
returns bigint language sql stable security definer set search_path = public
as $$ select count(*) from public.pixels; $$;

create or replace function public.place_pixel(p_x integer, p_y integer, p_color text)
returns jsonb language plpgsql security definer set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_last timestamptz;
  v_now timestamptz := clock_timestamp();
begin
  if v_user is null then raise exception 'AUTH_REQUIRED: Sign in before placing a pixel'; end if;
  if p_x is null or p_y is null or p_x < 0 or p_x >= 10000 or p_y < 0 or p_y >= 10000 then
    raise exception 'INVALID_COORDINATES';
  end if;
  if p_color is null or p_color !~ '^#[0-9A-Fa-f]{6}$' then raise exception 'INVALID_COLOR'; end if;

  -- Serialize placements per visitor so parallel requests cannot bypass the cooldown.
  perform pg_advisory_xact_lock(hashtextextended(v_user::text, 0));
  select last_placed_at into v_last from public.pixel_cooldowns where user_id = v_user for update;
  if v_last is not null and v_now < v_last + interval '5 seconds' then
    raise exception 'COOLDOWN: Wait % seconds before placing another pixel',
      greatest(1, ceil(extract(epoch from (v_last + interval '5 seconds' - v_now)))::integer);
  end if;

  insert into public.pixel_cooldowns(user_id,last_placed_at) values(v_user,v_now)
    on conflict(user_id) do update set last_placed_at = excluded.last_placed_at;
  insert into public.pixels(x,y,color,updated_at) values(p_x,p_y,upper(p_color),v_now)
    on conflict(x,y) do update set color=excluded.color, updated_at=excluded.updated_at;
  return jsonb_build_object('x',p_x,'y',p_y,'color',upper(p_color));
end;
$$;

revoke all on function public.get_pixels_in_bounds(integer,integer,integer,integer,integer) from public;
revoke all on function public.get_pixel_count() from public;
revoke all on function public.place_pixel(integer,integer,text) from public;
grant execute on function public.get_pixels_in_bounds(integer,integer,integer,integer,integer) to anon, authenticated;
grant execute on function public.get_pixel_count() to anon, authenticated;
grant execute on function public.place_pixel(integer,integer,text) to authenticated;

-- Enable Postgres Changes for the canvas table (Realtime must also be enabled in project settings).
alter table public.pixels replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.pixels;
exception when duplicate_object then null;
when undefined_object then raise notice 'Create the supabase_realtime publication or enable Realtime in the dashboard.';
end $$;
