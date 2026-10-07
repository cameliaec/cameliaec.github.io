-- ════════════════════════════════════════════════════════════════
-- CAMELIA · Joyería y Accesorios — esquema Supabase
-- Todo vive en el esquema "camelia" y en el bucket "camelia-fotos",
-- así no se mezcla con las tablas ni archivos de los otros locales.
-- Ejecutar completo en: Supabase → SQL Editor → New query → Run.
-- Después: Settings → API → "Exposed schemas" → agregar  camelia
-- ════════════════════════════════════════════════════════════════

create schema if not exists camelia;
grant usage on schema camelia to anon, authenticated;

-- ── Administradoras (la dueña) ───────────────────────────────────
create table if not exists camelia.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email   text not null,
  created_at timestamptz not null default now()
);

create or replace function camelia.is_admin()
returns boolean language sql stable security definer set search_path = camelia, public as $$
  select exists (select 1 from camelia.admins where user_id = auth.uid());
$$;
grant execute on function camelia.is_admin() to anon, authenticated;

-- ── Productos (costo y stock exacto son internos) ────────────────
create table if not exists camelia.products (
  id          text primary key default ('p' || floor(extract(epoch from now()) * 1000)::bigint),
  name        text not null,
  cat         text not null check (cat in ('Anillos','Aretes','Collares','Pulseras')),
  material    text not null default '',
  price       numeric(10,2) not null default 0 check (price >= 0),
  cost        numeric(10,2) not null default 0 check (cost >= 0),
  stock       integer not null default 0 check (stock >= 0),
  visible     boolean not null default false,
  featured    boolean not null default false,
  photo_path  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ── Promoción (una sola fila) ────────────────────────────────────
create table if not exists camelia.promo (
  id      smallint primary key default 1 check (id = 1),
  active  boolean not null default false,
  title   text not null default 'Semana Camelia',
  pct     integer not null default 15 check (pct between 1 and 90),
  scope   text not null default 'Todas' check (scope in ('Todas','Anillos','Aretes','Collares','Pulseras')),
  updated_at timestamptz not null default now()
);
insert into camelia.promo (id) values (1) on conflict do nothing;

-- ── Pedidos ──────────────────────────────────────────────────────
create table if not exists camelia.orders (
  id         uuid primary key default gen_random_uuid(),
  client     text not null check (length(client) between 1 and 120),
  phone      text not null default '',
  note       text not null default '',
  summary    text not null default '',
  total      numeric(10,2) not null default 0,
  status     text not null default 'Nuevo' check (status in ('Nuevo','Confirmado','Entregado','Cancelado')),
  created_at timestamptz not null default now()
);

create table if not exists camelia.order_lines (
  id         bigint generated always as identity primary key,
  order_id   uuid not null references camelia.orders(id) on delete cascade,
  product_id text references camelia.products(id) on delete set null,
  name       text not null,
  qty        integer not null check (qty > 0),
  unit       numeric(10,2) not null,
  cost       numeric(10,2) not null default 0
);
create index if not exists order_lines_order_idx on camelia.order_lines(order_id);

-- updated_at automático
create or replace function camelia.touch() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
drop trigger if exists products_touch on camelia.products;
create trigger products_touch before update on camelia.products for each row execute function camelia.touch();
drop trigger if exists promo_touch on camelia.promo;
create trigger promo_touch before update on camelia.promo for each row execute function camelia.touch();

-- ── Seguridad (RLS) ──────────────────────────────────────────────
alter table camelia.admins      enable row level security;
alter table camelia.products    enable row level security;
alter table camelia.promo       enable row level security;
alter table camelia.orders      enable row level security;
alter table camelia.order_lines enable row level security;

revoke all on all tables in schema camelia from anon, authenticated;
grant select, insert, update, delete on camelia.products, camelia.orders, camelia.order_lines to authenticated;
grant select, update on camelia.promo to anon, authenticated;
grant select on camelia.admins to authenticated;

drop policy if exists admins_self on camelia.admins;
create policy admins_self on camelia.admins for select to authenticated using (user_id = auth.uid());

drop policy if exists products_admin on camelia.products;
create policy products_admin on camelia.products for all to authenticated using (camelia.is_admin()) with check (camelia.is_admin());

drop policy if exists promo_read on camelia.promo;
create policy promo_read on camelia.promo for select to anon, authenticated using (true);
drop policy if exists promo_admin on camelia.promo;
create policy promo_admin on camelia.promo for update to authenticated using (camelia.is_admin()) with check (camelia.is_admin());

drop policy if exists orders_admin on camelia.orders;
create policy orders_admin on camelia.orders for all to authenticated using (camelia.is_admin()) with check (camelia.is_admin());
drop policy if exists lines_admin on camelia.order_lines;
create policy lines_admin on camelia.order_lines for all to authenticated using (camelia.is_admin()) with check (camelia.is_admin());

-- ── Catálogo público (sin costo ni stock exacto) ─────────────────
create or replace view camelia.catalogo as
  select id, name, cat, material, price, featured, photo_path, (stock <= 0) as agotado, stock as disponible
  from camelia.products where visible;
grant select on camelia.catalogo to anon, authenticated;

-- ── Crear pedido (las clientas no escriben tablas directo) ───────
-- Recibe: {"client":"Ana","phone":"...","note":"...","items":[{"id":"p1","qty":2}]}
-- Calcula precios con la promo vigente y guarda el costo para finanzas.
create or replace function camelia.crear_pedido(payload jsonb)
returns jsonb language plpgsql security definer set search_path = camelia, public as $$
declare
  pr camelia.promo; o_id uuid; it jsonb; p camelia.products;
  q int; u numeric; tot numeric := 0; resumen text := '';
begin
  if coalesce(trim(payload->>'client'), '') = '' then raise exception 'Falta el nombre'; end if;
  select * into pr from camelia.promo where id = 1;
  insert into camelia.orders (client, phone, note)
    values (left(trim(payload->>'client'),120), left(coalesce(payload->>'phone',''),40), left(coalesce(payload->>'note',''),500))
    returning id into o_id;
  for it in select * from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) loop
    select * into p from camelia.products where id = it->>'id' and visible;
    continue when not found;
    q := least(greatest(coalesce((it->>'qty')::int,1),1), p.stock);
    continue when q <= 0;
    u := case when pr.active and (pr.scope = 'Todas' or pr.scope = p.cat)
              then round(p.price * (100 - pr.pct) / 100.0, 2) else p.price end;
    insert into camelia.order_lines (order_id, product_id, name, qty, unit, cost) values (o_id, p.id, p.name, q, u, p.cost);
    tot := tot + u * q;
    resumen := resumen || case when resumen = '' then '' else ', ' end || p.name || case when q > 1 then ' ×' || q else '' end;
  end loop;
  update camelia.orders set total = tot, summary = coalesce(nullif(resumen,''),'Consulta general') where id = o_id;
  return jsonb_build_object('id', o_id, 'total', tot, 'summary', resumen);
end $$;
revoke all on function camelia.crear_pedido(jsonb) from public;
grant execute on function camelia.crear_pedido(jsonb) to anon, authenticated;

-- Descontar stock al confirmar un pedido (y devolverlo si se cancela)
create or replace function camelia.ajustar_stock() returns trigger language plpgsql security definer set search_path = camelia, public as $$
begin
  if new.status in ('Confirmado','Entregado') and old.status not in ('Confirmado','Entregado') then
    update camelia.products p set stock = greatest(p.stock - l.qty, 0) from camelia.order_lines l where l.order_id = new.id and l.product_id = p.id;
  elsif new.status in ('Nuevo','Cancelado') and old.status in ('Confirmado','Entregado') then
    update camelia.products p set stock = p.stock + l.qty from camelia.order_lines l where l.order_id = new.id and l.product_id = p.id;
  end if;
  return new;
end $$;
drop trigger if exists orders_stock on camelia.orders;
create trigger orders_stock after update of status on camelia.orders for each row execute function camelia.ajustar_stock();

-- ── Fotos: bucket propio, máx. 200 KB, solo WebP/JPEG ────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('camelia-fotos', 'camelia-fotos', true, 204800, array['image/webp','image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = 204800, allowed_mime_types = array['image/webp','image/jpeg'];

drop policy if exists camelia_fotos_read on storage.objects;
create policy camelia_fotos_read on storage.objects for select to anon, authenticated using (bucket_id = 'camelia-fotos');
drop policy if exists camelia_fotos_insert on storage.objects;
create policy camelia_fotos_insert on storage.objects for insert to authenticated with check (bucket_id = 'camelia-fotos' and camelia.is_admin());
drop policy if exists camelia_fotos_update on storage.objects;
create policy camelia_fotos_update on storage.objects for update to authenticated using (bucket_id = 'camelia-fotos' and camelia.is_admin());
drop policy if exists camelia_fotos_delete on storage.objects;
create policy camelia_fotos_delete on storage.objects for delete to authenticated using (bucket_id = 'camelia-fotos' and camelia.is_admin());

-- ── Productos iniciales ──────────────────────────────────────────
insert into camelia.products (id, name, cat, material, price, cost, stock, visible, featured) values
  ('p1','Anillo Camelia','Anillos','Plata 925 con baño de oro',48,20,6,true,true),
  ('p2','Aretes Perla Luna','Aretes','Perla de agua dulce y oro laminado',36,15,10,true,false),
  ('p3','Collar Rocío','Collares','Cadena fina con dije de gota',55,24,4,true,true),
  ('p4','Pulsera Seda','Pulseras','Eslabones delicados en baño de oro',42,18,0,true,false),
  ('p5','Solitario Alba','Anillos','Circón talla brillante en plata',62,27,3,true,false),
  ('p6','Aretes Gota Dorada','Aretes','Argollas con gota martillada',39,16,8,true,false),
  ('p7','Collar Inicial','Collares','Letra personalizada en oro laminado',45,19,12,true,false),
  ('p8','Pulsera Brisa','Pulseras','Cordón de seda y dije de camelia',29,11,9,true,false)
on conflict (id) do nothing;

-- ── Dar acceso a la dueña ────────────────────────────────────────
-- 1) Crea su usuario en Authentication → Users (correo + contraseña).
-- 2) Cambia el correo abajo y ejecuta esta línea:
-- insert into camelia.admins (user_id, email) select id, email from auth.users where email = 'duena@correo.com';
