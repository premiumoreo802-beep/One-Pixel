-- ONE PIXEL: Supabase setup
-- Run the entire file in Supabase Dashboard > SQL Editor.
-- Enable Anonymous Sign-Ins in Authentication > Providers before testing.

create table if not exists public.pixels (
  x integer not null check (x >= 0 and x < 10000),
  y integer not null check (y >= 0 and y < 10000),
  color text not null check (color ~ '^#[0-9A-Fa-f]{6}$'),
  placed_by uuid not null,
  created_at timestamptz not null default now(),
  primary key (x, y)
);

create index if not exists pixels_created_at_idx on public.pixels (created_at desc);

create table if not exists public.pixel_cooldowns (
  user_id uuid primary key,
  last_placed_at timestamptz
);

alter table public.pixels enable row level security;
alter table public.pixel_cooldowns enable row level security;

-- Anyone can read the public artwork. Writes must go through the rate-limited RPC.
drop policy if exists "Pixels are publicly readable" on public.pixels;
create policy "Pixels are publicly readable" on public.pixels for select using (true);

revoke insert, update, delete on public.pixels from anon, authenticated;
revoke all on public.pixel_cooldowns from anon, authenticated;

create or replace function public.place_pixel(p_x integer, p_y integer, p_color text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_last timestamptz;
  v_pixel public.pixels%rowtype;
begin
  if v_uid is null then raise exception 'Sign in anonymously to place a pixel'; end if;
  if p_x is null or p_y is null or p_x < 0 or p_x >= 10000 or p_y < 0 or p_y >= 10000 then
    raise exception 'Pixel coordinates are outside the canvas';
  end if;
  if p_color is null or p_color !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception 'Invalid color';
  end if;

  insert into public.pixel_cooldowns(user_id, last_placed_at)
  values (v_uid, null)
  on conflict (user_id) do nothing;

  select last_placed_at into v_last
  from public.pixel_cooldowns
  where user_id = v_uid
  for update;

  if v_last is not null and v_last > now() - interval '10 seconds' then
    raise exception 'Cooldown active: one pixel every 10 seconds';
  end if;

  insert into public.pixels(x, y, color, placed_by, created_at)
  values (p_x, p_y, upper(p_color), v_uid, now())
  on conflict (x, y) do update
    set color = excluded.color,
        placed_by = excluded.placed_by,
        created_at = excluded.created_at
  returning * into v_pixel;

  update public.pixel_cooldowns
  set last_placed_at = now()
  where user_id = v_uid;

  return jsonb_build_object('x', v_pixel.x, 'y', v_pixel.y, 'color', v_pixel.color, 'created_at', v_pixel.created_at);
end;
$$;

create or replace function public.get_pixels_in_bounds(
  p_min_x integer, p_min_y integer, p_max_x integer, p_max_y integer,
  p_limit integer default 50000
)
returns table(x integer, y integer, color text)
language sql
stable
security definer
set search_path = public
as $$
  select px.x, px.y, px.color
  from public.pixels px
  where px.x between greatest(0, p_min_x) and least(9999, p_max_x)
    and px.y between greatest(0, p_min_y) and least(9999, p_max_y)
  order by px.created_at desc
  limit least(greatest(coalesce(p_limit, 50000), 1), 50000);
$$;

create or replace function public.get_pixel_count()
returns bigint
language sql
stable
security definer
set search_path = public
as $$ select count(*) from public.pixels; $$;

revoke all on function public.place_pixel(integer, integer, text) from public;
grant execute on function public.place_pixel(integer, integer, text) to authenticated;
revoke all on function public.get_pixels_in_bounds(integer, integer, integer, integer, integer) from public;
grant execute on function public.get_pixels_in_bounds(integer, integer, integer, integer, integer) to anon, authenticated;
revoke all on function public.get_pixel_count() from public;
grant execute on function public.get_pixel_count() to anon, authenticated;

-- Enable realtime for the pixels table. Ignore the duplicate-object error if already published.
do $$
begin
  alter publication supabase_realtime add table public.pixels;
exception when duplicate_object then null;
end $$;
