
-- ONE PIXEL: ANONYMOUS CANVAS RESET
-- WARNING: This deletes all existing pixels and old account data.
-- Run this in Supabase SQL Editor.

create extension if not exists pgcrypto;

-- Remove old account-based tables
drop table if exists public.pixel_placements cascade;
drop table if exists public.pixel_cooldowns cascade;
drop table if exists public.pixels cascade;
drop table if exists public.profiles cascade;

-- Create the shared pixel canvas
create table public.pixels (
    x integer not null check (x >= 0 and x < 10000),
    y integer not null check (y >= 0 and y < 10000),
    color text not null check (color ~ '^#[0-9A-Fa-f]{6}$'),
    visitor_id uuid not null,
    updated_at timestamptz not null default now(),
    primary key (x, y)
);

create index pixels_updated_at_idx
on public.pixels(updated_at);

-- Store cooldowns per browser visitor
create table public.pixel_cooldowns (
    visitor_id uuid primary key,
    last_placed_at timestamptz not null
);

-- Enable row-level security
alter table public.pixels enable row level security;
alter table public.pixel_cooldowns enable row level security;

-- Allow everyone to view pixels
drop policy if exists "Pixels are publicly readable"
on public.pixels;

create policy "Pixels are publicly readable"
on public.pixels
for select
to anon, authenticated
using (true);

revoke all on public.pixels from anon, authenticated;
grant select on public.pixels to anon, authenticated;

revoke all on public.pixel_cooldowns from anon, authenticated;

-- Place pixel with server-enforced 5-second cooldown
create or replace function public.place_pixel(
    p_x integer,
    p_y integer,
    p_color text,
    p_visitor_id uuid
)
returns table (
    x integer,
    y integer,
    color text,
    updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
    previous_time timestamptz;
    placed_time timestamptz := clock_timestamp();
begin
    if p_visitor_id is null then
        raise exception 'Visitor ID is required.';
    end if;

    if p_x < 0 or p_y < 0 or p_x >= 10000 or p_y >= 10000 then
        raise exception 'Invalid pixel coordinates.';
    end if;

    if p_color is null or p_color !~ '^#[0-9A-Fa-f]{6}$' then
        raise exception 'Invalid HEX color.';
    end if;

    insert into public.pixel_cooldowns (
        visitor_id,
        last_placed_at
    )
    values (
        p_visitor_id,
        '-infinity'::timestamptz
    )
    on conflict (visitor_id) do nothing;

    select last_placed_at
    into previous_time
    from public.pixel_cooldowns
    where visitor_id = p_visitor_id
    for update;

    if previous_time > placed_time - interval '5 seconds' then
        raise exception 'Cooldown active. Wait 5 seconds.';
    end if;

    update public.pixel_cooldowns
    set last_placed_at = placed_time
    where visitor_id = p_visitor_id;

    insert into public.pixels (
        x, y, color, visitor_id, updated_at
    )
    values (
        p_x, p_y, upper(p_color), p_visitor_id, placed_time
    )
    on conflict (x, y)
    do update set
        color = excluded.color,
        visitor_id = excluded.visitor_id,
        updated_at = excluded.updated_at;

    return query
    select p.x, p.y, p.color, p.updated_at
    from public.pixels p
    where p.x = p_x and p.y = p_y;
end;
$$;

-- Load visible canvas area
create or replace function public.get_pixels_in_bounds(
    p_min_x integer,
    p_min_y integer,
    p_max_x integer,
    p_max_y integer,
    p_limit integer default 50000
)
returns table (
    x integer,
    y integer,
    color text
)
language sql
stable
security definer
set search_path = ''
as $$
    select p.x, p.y, p.color
    from public.pixels p
    where p.x between greatest(0, p_min_x) and least(9999, p_max_x)
      and p.y between greatest(0, p_min_y) and least(9999, p_max_y)
    order by p.y, p.x
    limit least(greatest(coalesce(p_limit, 50000), 1), 50000);
$$;

-- Count all placed pixels
create or replace function public.get_pixel_count()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
    select count(*) from public.pixels;
$$;

-- Function permissions
revoke all on function public.place_pixel(integer, integer, text, uuid) from public;
revoke all on function public.get_pixels_in_bounds(integer, integer, integer, integer, integer) from public;
revoke all on function public.get_pixel_count() from public;

grant execute on function public.place_pixel(integer, integer, text, uuid) to anon, authenticated;
grant execute on function public.get_pixels_in_bounds(integer, integer, integer, integer, integer) to anon, authenticated;
grant execute on function public.get_pixel_count() to anon, authenticated;

-- Enable realtime updates
do $$
begin
    alter publication supabase_realtime add table public.pixels;
exception
    when duplicate_object then null;
    when undefined_object then
        raise notice 'Enable Realtime for public.pixels in Supabase Dashboard.';
end;
$$;
