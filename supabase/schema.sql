-- ============================================================
-- IRIS · Esquema de base de datos (Supabase)
-- Ejecutar completo en el SQL Editor de Supabase (proyecto → SQL Editor).
-- Es idempotente: puede volver a ejecutarse sin duplicar objetos.
-- ============================================================

-- ── EXTENSIONES ────────────────────────────────────────────────
create extension if not exists "pgcrypto";

-- ── TABLA: profiles ──────────────────────────────────────────
-- Un perfil por usuario de auth.users. Se crea automáticamente vía
-- trigger al registrarse (ver más abajo), tomando el rol y el nombre
-- de clínica que el frontend manda en options.data de supabase.auth.signUp.
create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  email       text,
  role        text,
  clinic_name text,
  created_at  timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own"
  on public.profiles for select
  using (auth.uid() = id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- Crea el perfil automáticamente cuando se registra un usuario nuevo.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, role, clinic_name)
  values (
    new.id,
    new.email,
    new.raw_user_meta_data ->> 'role',
    coalesce(new.raw_user_meta_data ->> 'clinic_name', new.raw_user_meta_data ->> 'requested_clinic')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ── TABLA: formularios ───────────────────────────────────────
-- Registros capturados desde formularios del frontend (ej. "Registrar
-- propietario"). user_id referencia al usuario autenticado que lo creó;
-- pdf_url guarda la RUTA dentro del bucket privado `pdfs` (no una URL
-- pública), porque los datos son personales — se firma una URL temporal
-- desde el frontend cuando hace falta compartir el documento.
create table if not exists public.formularios (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users (id) on delete cascade,
  tipo                  text not null default 'propietario',
  doc_tipo              text,
  doc_numero            text,
  movil                 text,
  email                 text,
  nombre                text,
  direccion             text,
  ciudad                text,
  contacto_autorizado   text,
  telefono_alterno      text,
  telefono_opcional     text,
  expedicion_documento  text,
  como_nos_encontro     text,
  pdf_url               text,
  created_at            timestamptz not null default now()
);

create index if not exists formularios_user_id_idx on public.formularios (user_id);

alter table public.formularios enable row level security;

drop policy if exists "formularios_insert_own" on public.formularios;
create policy "formularios_insert_own"
  on public.formularios for insert
  with check (auth.uid() = user_id);

drop policy if exists "formularios_select_own" on public.formularios;
create policy "formularios_select_own"
  on public.formularios for select
  using (auth.uid() = user_id);

drop policy if exists "formularios_update_own" on public.formularios;
create policy "formularios_update_own"
  on public.formularios for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "formularios_delete_own" on public.formularios;
create policy "formularios_delete_own"
  on public.formularios for delete
  using (auth.uid() = user_id);

-- ── STORAGE: bucket `pdfs` ───────────────────────────────────
-- Privado (los PDF contienen datos personales de propietarios). Cada
-- usuario solo puede leer/escribir dentro de su propia carpeta
-- "<user_id>/...", validado con storage.foldername(name).
insert into storage.buckets (id, name, public)
values ('pdfs', 'pdfs', false)
on conflict (id) do nothing;

drop policy if exists "pdfs_insert_own_folder" on storage.objects;
create policy "pdfs_insert_own_folder"
  on storage.objects for insert
  with check (
    bucket_id = 'pdfs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "pdfs_select_own_folder" on storage.objects;
create policy "pdfs_select_own_folder"
  on storage.objects for select
  using (
    bucket_id = 'pdfs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "pdfs_update_own_folder" on storage.objects;
create policy "pdfs_update_own_folder"
  on storage.objects for update
  using (
    bucket_id = 'pdfs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "pdfs_delete_own_folder" on storage.objects;
create policy "pdfs_delete_own_folder"
  on storage.objects for delete
  using (
    bucket_id = 'pdfs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ============================================================
-- MULTI-TENANCY — clínicas, membresías, solicitudes de
-- vinculación, invitaciones y verificación de email por código.
-- Añadido para soportar múltiples clínicas/usuarios reales; ver
-- CLAUDE.md para el modelo híbrido (identidad/tenencia real,
-- datos clínicos mock en index.html).
-- ============================================================

-- ── PROFILES: columnas adicionales para identidad real ────────
alter table public.profiles add column if not exists nombre text;
alter table public.profiles add column if not exists telefono text;
alter table public.profiles add column if not exists foto_url text;

-- ── TABLA: establecimientos (clínicas) ─────────────────────────
create table if not exists public.establecimientos (
  id                 uuid primary key default gen_random_uuid(),
  nombre             text not null,
  razon_social       text,
  nit                text,
  ciudad             text,
  telefono           text,
  correo_contacto    text,
  whatsapp_conectado boolean not null default false,
  created_by         uuid references auth.users (id) on delete set null,
  created_at         timestamptz not null default now()
);

alter table public.establecimientos enable row level security;

-- Select abierto a cualquier usuario autenticado: hace falta poder
-- buscar/listar establecimientos existentes para solicitar
-- vinculación (pantalla "Busca tu establecimiento").
drop policy if exists "establecimientos_select_authenticated" on public.establecimientos;
create policy "establecimientos_select_authenticated"
  on public.establecimientos for select
  to authenticated
  using (true);

drop policy if exists "establecimientos_insert_authenticated" on public.establecimientos;
create policy "establecimientos_insert_authenticated"
  on public.establecimientos for insert
  to authenticated
  with check (auth.uid() = created_by);

-- ── TABLA: memberships (usuario ↔ establecimiento ↔ rol) ───────
create table if not exists public.memberships (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users (id) on delete cascade,
  establecimiento_id uuid not null references public.establecimientos (id) on delete cascade,
  rol                text not null check (rol in ('admin','medico','auxiliar','ventas')),
  estado             text not null default 'activo' check (estado in ('activo','inactivo')),
  created_at         timestamptz not null default now(),
  unique (user_id, establecimiento_id)
);

create index if not exists memberships_user_id_idx on public.memberships (user_id);
create index if not exists memberships_establecimiento_id_idx on public.memberships (establecimiento_id);

alter table public.memberships enable row level security;

-- ── FUNCIÓN: user_is_admin_of ──────────────────────────────────
-- security definer para evitar el problema clásico de policies RLS
-- recursivas (una policy sobre memberships que a su vez consulta
-- memberships). Definida antes de las policies que la usan.
create or replace function public.user_is_admin_of(estab uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.memberships
    where establecimiento_id = estab
      and user_id = auth.uid()
      and rol = 'admin'
      and estado = 'activo'
  );
$$;

grant execute on function public.user_is_admin_of(uuid) to authenticated;

drop policy if exists "establecimientos_update_admin" on public.establecimientos;
create policy "establecimientos_update_admin"
  on public.establecimientos for update
  using (public.user_is_admin_of(id))
  with check (public.user_is_admin_of(id));

drop policy if exists "memberships_select_own_or_admin" on public.memberships;
create policy "memberships_select_own_or_admin"
  on public.memberships for select
  using (auth.uid() = user_id or public.user_is_admin_of(establecimiento_id));

drop policy if exists "memberships_insert_own_or_admin" on public.memberships;
create policy "memberships_insert_own_or_admin"
  on public.memberships for insert
  with check (auth.uid() = user_id or public.user_is_admin_of(establecimiento_id));

drop policy if exists "memberships_update_admin" on public.memberships;
create policy "memberships_update_admin"
  on public.memberships for update
  using (public.user_is_admin_of(establecimiento_id))
  with check (public.user_is_admin_of(establecimiento_id));

drop policy if exists "memberships_delete_admin" on public.memberships;
create policy "memberships_delete_admin"
  on public.memberships for delete
  using (public.user_is_admin_of(establecimiento_id));

-- ── TABLA: link_requests (solicitudes de vinculación) ──────────
create table if not exists public.link_requests (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users (id) on delete cascade,
  establecimiento_id uuid not null references public.establecimientos (id) on delete cascade,
  rol_solicitado     text not null check (rol_solicitado in ('admin','medico','auxiliar','ventas')),
  estado             text not null default 'pendiente' check (estado in ('pendiente','aprobada','rechazada')),
  created_at         timestamptz not null default now(),
  decided_at         timestamptz,
  decided_by         uuid references auth.users (id) on delete set null
);

create index if not exists link_requests_establecimiento_id_idx on public.link_requests (establecimiento_id);
create index if not exists link_requests_user_id_idx on public.link_requests (user_id);

alter table public.link_requests enable row level security;

drop policy if exists "link_requests_select_own_or_admin" on public.link_requests;
create policy "link_requests_select_own_or_admin"
  on public.link_requests for select
  using (auth.uid() = user_id or public.user_is_admin_of(establecimiento_id));

drop policy if exists "link_requests_insert_own" on public.link_requests;
create policy "link_requests_insert_own"
  on public.link_requests for insert
  with check (auth.uid() = user_id);

-- Sin policy de update para el cliente: decidir (aprobar/rechazar)
-- pasa EXCLUSIVAMENTE por las funciones approve_link_request /
-- reject_link_request de abajo, para que el cambio de estado y la
-- creación de membership ocurran en una sola transacción atómica.

-- ── FUNCIONES: aprobar / rechazar solicitud de vinculación ─────
create or replace function public.approve_link_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request record;
begin
  select * into v_request from public.link_requests where id = p_request_id;
  if not found then
    raise exception 'Solicitud no encontrada';
  end if;
  if not public.user_is_admin_of(v_request.establecimiento_id) then
    raise exception 'No autorizado';
  end if;
  if v_request.estado <> 'pendiente' then
    raise exception 'La solicitud ya fue decidida';
  end if;

  insert into public.memberships (user_id, establecimiento_id, rol, estado)
  values (v_request.user_id, v_request.establecimiento_id, v_request.rol_solicitado, 'activo')
  on conflict (user_id, establecimiento_id)
  do update set rol = excluded.rol, estado = 'activo';

  update public.link_requests
  set estado = 'aprobada', decided_at = now(), decided_by = auth.uid()
  where id = p_request_id;
end;
$$;

create or replace function public.reject_link_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request record;
begin
  select * into v_request from public.link_requests where id = p_request_id;
  if not found then
    raise exception 'Solicitud no encontrada';
  end if;
  if not public.user_is_admin_of(v_request.establecimiento_id) then
    raise exception 'No autorizado';
  end if;
  if v_request.estado <> 'pendiente' then
    raise exception 'La solicitud ya fue decidida';
  end if;

  update public.link_requests
  set estado = 'rechazada', decided_at = now(), decided_by = auth.uid()
  where id = p_request_id;
end;
$$;

grant execute on function public.approve_link_request(uuid) to authenticated;
grant execute on function public.reject_link_request(uuid) to authenticated;

-- ── TABLA: invites (enlaces de invitación generados por un admin) ──
create table if not exists public.invites (
  id                 uuid primary key default gen_random_uuid(),
  establecimiento_id uuid not null references public.establecimientos (id) on delete cascade,
  rol                text not null check (rol in ('admin','medico','auxiliar','ventas')),
  created_by         uuid references auth.users (id) on delete set null,
  expires_at         timestamptz not null default (now() + interval '7 days'),
  used_by            uuid references auth.users (id) on delete set null,
  used_at            timestamptz,
  created_at         timestamptz not null default now()
);

create index if not exists invites_establecimiento_id_idx on public.invites (establecimiento_id);

alter table public.invites enable row level security;

-- Select abierto a cualquier autenticado: el token (uuid aleatorio)
-- es el secreto real que protege la invitación, igual que cualquier
-- enlace de invitación — quien no tiene el token no puede adivinarlo.
drop policy if exists "invites_select_authenticated" on public.invites;
create policy "invites_select_authenticated"
  on public.invites for select
  to authenticated
  using (true);

drop policy if exists "invites_insert_admin" on public.invites;
create policy "invites_insert_admin"
  on public.invites for insert
  with check (public.user_is_admin_of(establecimiento_id));

drop policy if exists "invites_delete_admin" on public.invites;
create policy "invites_delete_admin"
  on public.invites for delete
  using (public.user_is_admin_of(establecimiento_id));

-- ── FUNCIÓN: accept_invite ──────────────────────────────────────
-- Única vía por la que un cliente puede crear su propia membership
-- con un rol específico — evita que alguien se auto-asigne 'admin'
-- insertando directo en memberships.
create or replace function public.accept_invite(p_token uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite record;
begin
  select * into v_invite from public.invites where id = p_token;
  if not found then
    raise exception 'Invitación no encontrada';
  end if;
  if v_invite.used_at is not null then
    raise exception 'Esta invitación ya fue utilizada';
  end if;
  if v_invite.expires_at < now() then
    raise exception 'Esta invitación expiró';
  end if;

  insert into public.memberships (user_id, establecimiento_id, rol, estado)
  values (auth.uid(), v_invite.establecimiento_id, v_invite.rol, 'activo')
  on conflict (user_id, establecimiento_id)
  do update set rol = excluded.rol, estado = 'activo';

  update public.invites
  set used_by = auth.uid(), used_at = now()
  where id = p_token;
end;
$$;

grant execute on function public.accept_invite(uuid) to authenticated;

-- ── TABLA: verification_codes (verificación de email por código) ──
-- RLS habilitado SIN policies: inalcanzable desde el cliente por
-- diseño. Solo las funciones serverless (api/send-verification-code.js,
-- api/verify-code.js), usando SUPABASE_SERVICE_ROLE_KEY, la tocan —
-- la service role ignora RLS.
create table if not exists public.verification_codes (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  target      text not null,
  code_hash   text not null,
  expires_at  timestamptz not null,
  verified_at timestamptz,
  attempts    integer not null default 0,
  created_at  timestamptz not null default now()
);

create index if not exists verification_codes_user_id_idx on public.verification_codes (user_id);

alter table public.verification_codes enable row level security;
