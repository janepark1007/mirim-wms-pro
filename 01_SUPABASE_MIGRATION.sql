
-- MIRIM TECHNOLOGY WMS V1 - production-ready extension for the existing Supabase project
-- Run once in Supabase SQL Editor.
-- This migration keeps the existing items/item_locations/stock_movements data.

create extension if not exists pgcrypto;

-- 1) Existing items table extensions
alter table public.items
  add column if not exists specification text,
  add column if not exists updated_at timestamptz not null default now();

-- Allow administrator-defined categories.
alter table public.items drop constraint if exists items_category_check;

-- 2) Categories
create table if not exists public.material_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  is_active boolean not null default true,
  sort_order integer not null default 999,
  created_at timestamptz not null default now()
);

insert into public.material_categories(name, sort_order)
values
('하우징',1),('하팅',2),('커넥터',3),('터미널',4),('후드',5),
('전선',6),('PVC',7),('포장재',8),('나사',9),('타이',10),('기타',99)
on conflict (name) do nothing;

-- 3) Login accounts
create table if not exists public.app_users (
  id uuid primary key default gen_random_uuid(),
  username text not null unique,
  password_hash text not null,
  role text not null check (role in ('admin','production')),
  display_name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.app_users(username,password_hash,role,display_name)
values
('admin', crypt('5859', gen_salt('bf')), 'admin', '주관리자'),
('mirim', crypt('1234', gen_salt('bf')), 'production', '생산 PC')
on conflict (username) do update
set role=excluded.role, display_name=excluded.display_name, is_active=true;

-- 4) Outbound responsible people
create table if not exists public.material_handlers (
  id uuid primary key default gen_random_uuid(),
  display_name text not null unique,
  login_no_hash text not null,
  is_active boolean not null default true,
  sort_order integer not null default 999,
  created_at timestamptz not null default now()
);

insert into public.material_handlers(display_name,login_no_hash,sort_order)
values
('이혜정팀장님', crypt('0', gen_salt('bf')), 0),
('미림대표님', crypt('1', gen_salt('bf')), 1),
('정부장님', crypt('2', gen_salt('bf')), 2),
('박부장님', crypt('3', gen_salt('bf')), 3),
('이연주부장님', crypt('4', gen_salt('bf')), 4),
('김부장님', crypt('5', gen_salt('bf')), 5),
('최순정대리님', crypt('6', gen_salt('bf')), 6),
('엑셀-조영애', crypt('7', gen_salt('bf')), 7),
('김미화대리님', crypt('8', gen_salt('bf')), 8),
('신대리님', crypt('9', gen_salt('bf')), 9),
('유차장님', crypt('10', gen_salt('bf')), 10),
('이천희팀장님', crypt('11', gen_salt('bf')), 11),
('이과장님', crypt('12', gen_salt('bf')), 12),
('압착', crypt('13', gen_salt('bf')), 13),
('엑셀-수정', crypt('14', gen_salt('bf')), 14),
('엑셀-매화', crypt('15', gen_salt('bf')), 15)
on conflict (display_name) do nothing;

-- 5) Login verification
create or replace function public.verify_app_login(p_username text, p_password text)
returns table(role text, display_name text)
language sql
security definer
set search_path = public
as $$
  select u.role, u.display_name
  from public.app_users u
  where u.username = trim(p_username)
    and u.is_active = true
    and u.password_hash = crypt(p_password, u.password_hash);
$$;

-- 6) Read-only lookup helpers
create or replace function public.list_material_categories()
returns table(id uuid, name text, sort_order integer)
language sql
security definer
set search_path = public
as $$
  select c.id, c.name, c.sort_order
  from public.material_categories c
  where c.is_active = true
  order by c.sort_order, c.name;
$$;

create or replace function public.list_material_handlers()
returns table(id uuid, display_name text, sort_order integer)
language sql
security definer
set search_path = public
as $$
  select h.id, h.display_name, h.sort_order
  from public.material_handlers h
  where h.is_active = true
  order by h.sort_order, h.display_name;
$$;

-- 7) Administrator item/category/location operations
create or replace function public.admin_upsert_item(
  p_username text,
  p_password text,
  p_item_id uuid,
  p_part_no text,
  p_item_name text,
  p_category text,
  p_maker text,
  p_specification text,
  p_unit text,
  p_min_stock numeric,
  p_note text,
  p_photo_url text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not exists (
    select 1 from public.app_users
    where username=trim(p_username) and role='admin' and is_active=true
      and password_hash=crypt(p_password,password_hash)
  ) then raise exception 'ADMIN_AUTH_FAILED'; end if;

  if coalesce(trim(p_part_no),'')='' or coalesce(trim(p_item_name),'')='' then
    raise exception 'PART_AND_NAME_REQUIRED';
  end if;

  if p_item_id is null then
    insert into public.items(part_no,item_name,category,maker,specification,unit,min_stock,note,photo_url,is_active)
    values(trim(p_part_no),trim(p_item_name),coalesce(nullif(trim(p_category),''),'기타'),
           nullif(trim(p_maker),''),nullif(trim(p_specification),''),
           coalesce(nullif(trim(p_unit),''),'EA'),greatest(coalesce(p_min_stock,0),0),
           nullif(trim(p_note),''),nullif(p_photo_url,''),true)
    returning id into v_id;
  else
    update public.items
    set part_no=trim(p_part_no), item_name=trim(p_item_name),
        category=coalesce(nullif(trim(p_category),''),'기타'),
        maker=nullif(trim(p_maker),''), specification=nullif(trim(p_specification),''),
        unit=coalesce(nullif(trim(p_unit),''),'EA'),
        min_stock=greatest(coalesce(p_min_stock,0),0),
        note=nullif(trim(p_note),''),
        photo_url=case when p_photo_url is null then photo_url else nullif(p_photo_url,'') end,
        updated_at=now(), is_active=true
    where id=p_item_id
    returning id into v_id;
  end if;
  return v_id;
end;
$$;

create or replace function public.admin_add_category(
  p_username text,p_password text,p_name text
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare v_id uuid;
begin
  if not exists (select 1 from public.app_users where username=trim(p_username) and role='admin' and is_active=true and password_hash=crypt(p_password,password_hash))
  then raise exception 'ADMIN_AUTH_FAILED'; end if;
  insert into public.material_categories(name,is_active)
  values(trim(p_name),true)
  on conflict(name) do update set is_active=true
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.admin_add_location(
  p_username text,p_password text,p_item_id uuid,p_location_code text,p_location_display text,p_qty numeric
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare v_id uuid;
begin
  if not exists (select 1 from public.app_users where username=trim(p_username) and role='admin' and is_active=true and password_hash=crypt(p_password,password_hash))
  then raise exception 'ADMIN_AUTH_FAILED'; end if;
  if coalesce(trim(p_location_code),'')='' then raise exception 'LOCATION_REQUIRED'; end if;
  insert into public.item_locations(item_id,location_code,location_display,qty)
  values(p_item_id,trim(p_location_code),coalesce(nullif(trim(p_location_display),''),trim(p_location_code)),greatest(coalesce(p_qty,0),0))
  on conflict(item_id,location_code) do update
  set location_display=excluded.location_display, qty=excluded.qty
  returning id into v_id;
  return v_id;
end $$;

-- 8) Atomic administrator inbound/outbound
create or replace function public.admin_apply_movement(
  p_username text,p_password text,p_type text,p_item_id uuid,p_location_id uuid,
  p_qty numeric,p_actor_name text,p_note text
) returns public.stock_movements
language plpgsql security definer set search_path=public
as $$
declare v_loc public.item_locations; v_total numeric; v_signed numeric; v_row public.stock_movements;
begin
  if not exists (select 1 from public.app_users where username=trim(p_username) and role='admin' and is_active=true and password_hash=crypt(p_password,password_hash))
  then raise exception 'ADMIN_AUTH_FAILED'; end if;
  if p_type not in ('IN','OUT') then raise exception 'INVALID_MOVEMENT_TYPE'; end if;
  if p_qty is null or p_qty<=0 then raise exception 'INVALID_QTY'; end if;
  if coalesce(trim(p_actor_name),'')='' then raise exception 'ACTOR_REQUIRED'; end if;

  select * into v_loc from public.item_locations
  where id=p_location_id and item_id=p_item_id for update;
  if not found then raise exception 'LOCATION_NOT_FOUND'; end if;
  if p_type='OUT' and v_loc.qty<p_qty then raise exception 'INSUFFICIENT_STOCK'; end if;

  v_signed:=case when p_type='OUT' then -p_qty else p_qty end;
  update public.item_locations set qty=qty+v_signed where id=p_location_id returning * into v_loc;
  select coalesce(sum(qty),0) into v_total from public.item_locations where item_id=p_item_id;

  insert into public.stock_movements(movement_type,item_id,location_id,qty,signed_qty,actor_name,note,stock_after_location,stock_after_total)
  values(p_type,p_item_id,p_location_id,p_qty,v_signed,trim(p_actor_name),nullif(trim(p_note),''),v_loc.qty,v_total)
  returning * into v_row;
  return v_row;
end $$;

-- 9) Responsible person number verification for outbound
create or replace function public.verify_material_handler(p_handler_id uuid,p_login_no text)
returns table(id uuid, display_name text)
language sql security definer set search_path=public
as $$
  select h.id,h.display_name from public.material_handlers h
  where h.id=p_handler_id and h.is_active=true and h.login_no_hash=crypt(p_login_no,h.login_no_hash);
$$;

-- 10) RLS and grants
alter table public.material_categories enable row level security;
alter table public.app_users enable row level security;
alter table public.material_handlers enable row level security;

revoke all on public.app_users from anon, authenticated;
revoke all on public.material_handlers from anon, authenticated;
revoke all on public.material_categories from anon, authenticated;

revoke all on function public.verify_app_login(text,text) from public;
grant execute on function public.verify_app_login(text,text) to anon, authenticated;
revoke all on function public.list_material_categories() from public;
grant execute on function public.list_material_categories() to anon, authenticated;
revoke all on function public.list_material_handlers() from public;
grant execute on function public.list_material_handlers() to anon, authenticated;
revoke all on function public.admin_upsert_item(text,text,uuid,text,text,text,text,text,text,numeric,text,text) from public;
grant execute on function public.admin_upsert_item(text,text,uuid,text,text,text,text,text,text,numeric,text,text) to anon, authenticated;
revoke all on function public.admin_add_category(text,text,text) from public;
grant execute on function public.admin_add_category(text,text,text) to anon, authenticated;
revoke all on function public.admin_add_location(text,text,uuid,text,text,numeric) from public;
grant execute on function public.admin_add_location(text,text,uuid,text,text,numeric) to anon, authenticated;
revoke all on function public.admin_apply_movement(text,text,text,uuid,uuid,numeric,text,text) from public;
grant execute on function public.admin_apply_movement(text,text,text,uuid,uuid,numeric,text,text) to anon, authenticated;
revoke all on function public.verify_material_handler(uuid,text) from public;
grant execute on function public.verify_material_handler(uuid,text) to anon, authenticated;

-- Realtime, idempotent
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='items')
  then alter publication supabase_realtime add table public.items; end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='item_locations')
  then alter publication supabase_realtime add table public.item_locations; end if;
end $$;
