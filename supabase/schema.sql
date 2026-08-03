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
-- matricula/firma_url: datos profesionales del médico (Mi perfil), usados
-- por Consultorio > Fórmulas médicas para mostrar la firma electrónica y
-- el número de matrícula bajo el nombre del médico en la fórmula generada.
alter table public.profiles add column if not exists matricula text;
alter table public.profiles add column if not exists firma_url text;
-- tema_color: preferencia de tema de color de la cuenta (Mi perfil >
-- Tema), una de las claves de CLINIC_THEMES en index.html
-- ('teal'/'indigo'/'esmeralda'/'violeta'/'rosa'). null = Teal (defecto).
alter table public.profiles add column if not exists tema_color text;

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
-- `email` ata el enlace a una persona concreta: accept_invite() exige
-- que coincida con el correo de la sesión que acepta, para que nunca
-- pueda pisar la membership de quien lo abra (ver nota en
-- accept_invite más abajo — bug real ya sufrido en producción).
create table if not exists public.invites (
  id                 uuid primary key default gen_random_uuid(),
  establecimiento_id uuid not null references public.establecimientos (id) on delete cascade,
  rol                text not null check (rol in ('admin','medico','auxiliar','ventas')),
  email              text,
  created_by         uuid references auth.users (id) on delete set null,
  expires_at         timestamptz not null default (now() + interval '7 days'),
  used_by            uuid references auth.users (id) on delete set null,
  used_at            timestamptz,
  created_at         timestamptz not null default now()
);
alter table public.invites add column if not exists email text;

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
-- insertando directo en memberships. Exige además que el correo de
-- quien acepta coincida con invites.email: sin esto, el ON CONFLICT
-- de más abajo (necesario para poder re-invitar a alguien con otro
-- rol) sobreescribe silenciosamente CUALQUIER membership preexistente
-- del usuario que acepte en ese establecimiento — incluida la del
-- propio admin que generó el enlace, si lo abre en el mismo navegador
-- donde ya tiene sesión (pasó en producción: el creador de la clínica
-- terminó con rol 'medico' sin ninguna vía de vuelta a 'admin', dos
-- veces, porque used_by resultó igual a created_by ambas veces).
create or replace function public.accept_invite(p_token uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite record;
  v_user_email text;
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
  if v_invite.email is null then
    raise exception 'Este enlace de invitación es antiguo y ya no incluye un correo válido. Pide que te generen uno nuevo.';
  end if;

  select email into v_user_email from auth.users where id = auth.uid();
  if v_user_email is null or lower(trim(v_user_email)) <> lower(trim(v_invite.email)) then
    raise exception 'Esta invitación fue generada para %. Inicia sesión o crea una cuenta con ese correo para aceptarla.', v_invite.email;
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

-- ── FUNCIÓN: get_invite_preview ──────────────────────────────────
-- Lectura anónima (pre-login) de un enlace de invitación válido, solo
-- para que la pantalla de login pueda pre-llenar el correo y explicar
-- para qué rol/clínica es ANTES de que la persona inicie sesión o cree
-- cuenta — así nunca se le pide "aceptar" con la sesión equivocada.
create or replace function public.get_invite_preview(p_token uuid)
returns table (email text, rol text, establecimiento_nombre text)
language sql
stable
security definer
set search_path = public
as $$
  select i.email, i.rol, e.nombre
  from public.invites i
  join public.establecimientos e on e.id = i.establecimiento_id
  where i.id = p_token
    and i.used_at is null
    and i.expires_at > now();
$$;

grant execute on function public.get_invite_preview(uuid) to anon, authenticated;

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

-- ============================================================
-- NÚCLEO DE DATOS CLÍNICOS (fase 1) — propietarios, mascotas
-- (solo ficha, no las 17 sub-secciones de Historia todavía) y
-- documentos. Antes vivían solo en arrays JS en memoria
-- (`propietarios`/`patientData` en index.html), por eso se
-- perdían en cada login. Acceso por CLÍNICA (establecimiento_id),
-- no por usuario individual: cualquier membership activa en el
-- establecimiento puede ver/editar — a diferencia de la tabla
-- `formularios` (arriba), que queda intacta pero deja de recibir
-- escrituras nuevas de este flujo.
-- ============================================================

-- ── FUNCIÓN: user_is_member_of ──────────────────────────────
-- Igual a user_is_admin_of pero sin filtrar por rol — cualquier
-- membership 'activo' del establecimiento. security definer por
-- el mismo motivo (evitar policies RLS recursivas sobre memberships).
create or replace function public.user_is_member_of(estab uuid)
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
      and estado = 'activo'
  );
$$;

grant execute on function public.user_is_member_of(uuid) to authenticated;

-- ── FUNCIÓN: list_establecimiento_members ────────────────────────
-- Roster real de un establecimiento (memberships + su profiles) para
-- Admin > Usuarios. profiles solo se puede leer con auth.uid() = id
-- vía RLS normal (ver policy "profiles_select_own"), por eso hace
-- falta security definer aquí, igual que en user_is_admin_of/
-- user_is_member_of — sin esto, un admin solo vería su propia fila en
-- la tabla de usuarios reales, nunca al resto del equipo.
create or replace function public.list_establecimiento_members(p_establecimiento_id uuid)
returns table (
  membership_id uuid,
  user_id uuid,
  rol text,
  estado text,
  email text,
  nombre text,
  telefono text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select m.id, m.user_id, m.rol, m.estado, p.email, p.nombre, p.telefono, m.created_at
  from public.memberships m
  join public.profiles p on p.id = m.user_id
  where m.establecimiento_id = p_establecimiento_id
    and public.user_is_member_of(p_establecimiento_id)
  order by m.created_at;
$$;

grant execute on function public.list_establecimiento_members(uuid) to authenticated;

-- ── TABLA: propietarios ─────────────────────────────────────
create table if not exists public.propietarios (
  id                    uuid primary key default gen_random_uuid(),
  establecimiento_id    uuid not null references public.establecimientos (id) on delete cascade,
  doc_tipo              text,
  doc_numero            text,
  movil                 text,
  email                 text,
  nombre                text not null,
  direccion             text,
  ciudad                text,
  contacto_autorizado   text,
  telefono_alterno      text,
  telefono_opcional     text,
  expedicion_documento  text,
  como_nos_encontro     text,
  ultima_gestion_time   timestamptz,
  ultima_gestion_detail text,
  pdf_path              text,
  created_by            uuid references auth.users (id) on delete set null,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create index if not exists propietarios_establecimiento_id_idx on public.propietarios (establecimiento_id);

alter table public.propietarios enable row level security;

drop policy if exists "propietarios_select_member" on public.propietarios;
create policy "propietarios_select_member"
  on public.propietarios for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "propietarios_insert_member" on public.propietarios;
create policy "propietarios_insert_member"
  on public.propietarios for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "propietarios_update_member" on public.propietarios;
create policy "propietarios_update_member"
  on public.propietarios for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "propietarios_delete_member" on public.propietarios;
create policy "propietarios_delete_member"
  on public.propietarios for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── TABLA: mascotas (ficha, no historia clínica todavía) ────
create table if not exists public.mascotas (
  id                   uuid primary key default gen_random_uuid(),
  establecimiento_id   uuid not null references public.establecimientos (id) on delete cascade,
  propietario_id       uuid not null references public.propietarios (id) on delete cascade,
  pet_key              text not null,
  nombre               text not null,
  chip                 text,
  especie              text,
  raza                 text,
  edad                 text,
  fecha_nacimiento     date,
  peso                 text,
  color                text,
  genero               text,
  talla                text,
  estado_reproductivo  text,
  animal_servicio      boolean not null default false,
  fallecido            boolean not null default false,
  alimentacion         text,
  frecuencia_bano      text,
  temperamento         text,
  antecedentes         text,
  alergias             text,
  peso_historico       jsonb not null default '[]'::jsonb,
  foto_path            text,
  created_by           uuid references auth.users (id) on delete set null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (establecimiento_id, pet_key)
);

create index if not exists mascotas_establecimiento_id_idx on public.mascotas (establecimiento_id);
create index if not exists mascotas_propietario_id_idx on public.mascotas (propietario_id);

alter table public.mascotas enable row level security;

drop policy if exists "mascotas_select_member" on public.mascotas;
create policy "mascotas_select_member"
  on public.mascotas for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "mascotas_insert_member" on public.mascotas;
create policy "mascotas_insert_member"
  on public.mascotas for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "mascotas_update_member" on public.mascotas;
create policy "mascotas_update_member"
  on public.mascotas for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "mascotas_delete_member" on public.mascotas;
create policy "mascotas_delete_member"
  on public.mascotas for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── TABLA: documentos (módulo Documentos de Consultorio) ────
create table if not exists public.documentos (
  id                 uuid primary key default gen_random_uuid(),
  establecimiento_id uuid not null references public.establecimientos (id) on delete cascade,
  mascota_id         uuid not null references public.mascotas (id) on delete cascade,
  tipo               text,
  titulo             text,
  contenido_html     text,
  estado             text not null default 'borrador' check (estado in ('borrador','pendiente','firmado')),
  requiere_firma     boolean not null default true,
  notificar_propietario boolean not null default true,
  usuario            text,
  firma_nombre       text,
  firma_fecha        text,
  firma_hora         text,
  pdf_path           text,
  created_by         uuid references auth.users (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index if not exists documentos_establecimiento_id_idx on public.documentos (establecimiento_id);
create index if not exists documentos_mascota_id_idx on public.documentos (mascota_id);

alter table public.documentos enable row level security;

drop policy if exists "documentos_select_member" on public.documentos;
create policy "documentos_select_member"
  on public.documentos for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "documentos_insert_member" on public.documentos;
create policy "documentos_insert_member"
  on public.documentos for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "documentos_update_member" on public.documentos;
create policy "documentos_update_member"
  on public.documentos for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "documentos_delete_member" on public.documentos;
create policy "documentos_delete_member"
  on public.documentos for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── STORAGE: bucket `fotos-mascotas` ────────────────────────
-- Público (a diferencia de `pdfs`) — una foto de mascota no es un
-- documento de identidad, y así los <img src> del front no
-- necesitan firmar una URL temporal en cada render. Path:
-- "<establecimiento_id>/<mascota_id>.<ext>".
insert into storage.buckets (id, name, public)
values ('fotos-mascotas', 'fotos-mascotas', true)
on conflict (id) do nothing;

-- Sin policy de select: el bucket ya es público, así que Supabase permite
-- GET directo por URL sin pasar por RLS. Una policy "select ... to public"
-- aquí habilitaría además LISTAR todo el contenido del bucket vía API
-- (todas las clínicas) — detectado por el advisor de seguridad
-- (public_bucket_allows_listing) y removido a propósito.

drop policy if exists "fotos_mascotas_insert_member" on storage.objects;
create policy "fotos_mascotas_insert_member"
  on storage.objects for insert
  with check (
    bucket_id = 'fotos-mascotas'
    and public.user_is_member_of(((storage.foldername(name))[1])::uuid)
  );

drop policy if exists "fotos_mascotas_update_member" on storage.objects;
create policy "fotos_mascotas_update_member"
  on storage.objects for update
  using (
    bucket_id = 'fotos-mascotas'
    and public.user_is_member_of(((storage.foldername(name))[1])::uuid)
  );

drop policy if exists "fotos_mascotas_delete_member" on storage.objects;
create policy "fotos_mascotas_delete_member"
  on storage.objects for delete
  using (
    bucket_id = 'fotos-mascotas'
    and public.user_is_member_of(((storage.foldername(name))[1])::uuid)
  );

-- ── STORAGE: bucket `pdfs` — nuevo prefijo "clinica/<estab>/" ──
-- El bucket ya existe (ver arriba) con policies por carpeta
-- "<user_id>/..." para el flujo viejo de `formularios`, que
-- quedan intactas. Estas 4 policies nuevas cubren el prefijo
-- "clinica/<establecimiento_id>/..." que usan los PDFs de
-- propietarios/documentos del núcleo clínico (visibles para toda
-- la clínica, no solo para quien los subió).
drop policy if exists "pdfs_insert_clinica_member" on storage.objects;
create policy "pdfs_insert_clinica_member"
  on storage.objects for insert
  with check (
    bucket_id = 'pdfs'
    and (storage.foldername(name))[1] = 'clinica'
    and public.user_is_member_of(((storage.foldername(name))[2])::uuid)
  );

drop policy if exists "pdfs_select_clinica_member" on storage.objects;
create policy "pdfs_select_clinica_member"
  on storage.objects for select
  using (
    bucket_id = 'pdfs'
    and (storage.foldername(name))[1] = 'clinica'
    and public.user_is_member_of(((storage.foldername(name))[2])::uuid)
  );

drop policy if exists "pdfs_update_clinica_member" on storage.objects;
create policy "pdfs_update_clinica_member"
  on storage.objects for update
  using (
    bucket_id = 'pdfs'
    and (storage.foldername(name))[1] = 'clinica'
    and public.user_is_member_of(((storage.foldername(name))[2])::uuid)
  );

drop policy if exists "pdfs_delete_clinica_member" on storage.objects;
create policy "pdfs_delete_clinica_member"
  on storage.objects for delete
  using (
    bucket_id = 'pdfs'
    and (storage.foldername(name))[1] = 'clinica'
    and public.user_is_member_of(((storage.foldername(name))[2])::uuid)
  );

-- ── TABLA: examenes (Exámenes de laboratorio / Imágenes diagnósticas) ──
-- Un registro por "orden" del flujo propio de Laboratorio/Imágenes
-- (independiente de la tabla mock `ordenes` de index.html, que sigue
-- existiendo aparte para Inventario/otros tipos). tipo distingue
-- 'laboratorio' de 'imagen' -- misma tabla, dos subtabs de Consultorio.
-- pruebas es jsonb (mismo criterio que mascotas.peso_historico) en vez
-- de una tabla hija: cada elemento es un bloque repetible del modal
-- { profesional, prueba, cantidad, resultadoPath, resultadoNombre }.
create table if not exists public.examenes (
  id                      uuid primary key default gen_random_uuid(),
  establecimiento_id      uuid not null references public.establecimientos (id) on delete cascade,
  mascota_id              uuid not null references public.mascotas (id) on delete cascade,
  tipo                    text not null check (tipo in ('laboratorio','imagen')),
  fecha                   date not null,
  diagnostico_presuntivo  text,
  pruebas                 jsonb not null default '[]'::jsonb,
  usuario                 text,
  created_by              uuid references auth.users (id) on delete set null,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

create index if not exists examenes_establecimiento_id_idx on public.examenes (establecimiento_id);
create index if not exists examenes_mascota_id_idx on public.examenes (mascota_id);

alter table public.examenes enable row level security;

drop policy if exists "examenes_select_member" on public.examenes;
create policy "examenes_select_member"
  on public.examenes for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "examenes_insert_member" on public.examenes;
create policy "examenes_insert_member"
  on public.examenes for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "examenes_update_member" on public.examenes;
create policy "examenes_update_member"
  on public.examenes for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "examenes_delete_member" on public.examenes;
create policy "examenes_delete_member"
  on public.examenes for delete
  using (public.user_is_member_of(establecimiento_id));

-- Reutiliza el bucket privado `pdfs` ya existente (prefijo "clinica/<estab>/...",
-- policies ya cubren cualquier archivo bajo ese prefijo para miembros de la
-- clínica) -- sin bucket nuevo. Los resultados de examenes van en
-- "clinica/<establecimiento_id>/examenes/<examen_id>/<n>-<nombre>".

-- ── TABLA: consultas (Consultas Clínicas, formato SOIP) ───────────────
-- guardarConsulta()/abrirEditarConsultaModal() en index.html leen y
-- escriben esta tabla directamente (no pasó por el patrón "SÍ persiste
-- en Supabase" documentado en CLAUDE.md para módulos más nuevos, porque
-- ya estaba wireada desde antes de que ese patrón se documentara).
-- interpretacion reemplaza a la columna original `assessment` -- se
-- renombró junto con el cambio de nomenclatura SOAP -> SOIP (S/O/I/P,
-- "I" de Interpretación en vez de "A" de Assessment); un rename de
-- columna conserva los datos existentes, así que las consultas ya
-- registradas no se perdieron. Los signos vitales (vital_*) solo se
-- diligencian desde el Tablero de trabajo -- el modal clásico los deja
-- en null al editar para no pisarlos.
create table if not exists public.consultas (
  id                  uuid primary key default gen_random_uuid(),
  establecimiento_id  uuid not null references public.establecimientos (id) on delete cascade,
  mascota_id          uuid not null references public.mascotas (id) on delete cascade,
  fecha_hora          timestamptz not null,
  motivo              text,
  subjetivo           text,
  objetivo            text,
  interpretacion      text,
  plan                text,
  vital_temp          numeric,
  vital_fc            integer,
  vital_fr            integer,
  vital_crt           text,
  vital_pas           integer,
  vital_pad           integer,
  vital_pam           integer,
  examen_fisico       jsonb not null default '[]'::jsonb,
  usuario             text,
  created_by          uuid references auth.users (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index if not exists consultas_establecimiento_id_idx on public.consultas (establecimiento_id);
create index if not exists consultas_mascota_id_idx on public.consultas (mascota_id);

alter table public.consultas enable row level security;

drop policy if exists "consultas_select_member" on public.consultas;
create policy "consultas_select_member"
  on public.consultas for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "consultas_insert_member" on public.consultas;
create policy "consultas_insert_member"
  on public.consultas for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "consultas_update_member" on public.consultas;
create policy "consultas_update_member"
  on public.consultas for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "consultas_delete_member" on public.consultas;
create policy "consultas_delete_member"
  on public.consultas for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── TABLA: hospitalizaciones (Hospitalizaciones/ambulatorios + Kardex) ──
-- Un registro por ingreso. `dias` es jsonb (mismo criterio que
-- examenes.pruebas/mascotas.peso_historico) y guarda el árbol completo del
-- Kardex de trazabilidad -- acordeón por día, cada uno con tratamientos[]
-- (grilla horaria de 24h) y signos{} (8 filas x 24h) -- en vez de tablas
-- hijas, porque index.html ya trata esa estructura como un solo blob que se
-- relee/reescribe entero (nunca se consulta por campo interno). seguimientos[]
-- sigue siendo 100% mock (no persiste todavía) y enlaza a esta tabla por el
-- `id` real (uuid), no por el hospId sintético que usaba el mock en memoria.
create table if not exists public.hospitalizaciones (
  id                 uuid primary key default gen_random_uuid(),
  establecimiento_id uuid not null references public.establecimientos (id) on delete cascade,
  mascota_id         uuid not null references public.mascotas (id) on delete cascade,
  tipo               text not null,
  fecha_ingreso      date not null,
  fecha_salida       date,
  motivo_salida      text,
  razon              text not null,
  observaciones      text,
  estado             text not null default 'activa' check (estado in ('activa','finalizada')),
  dias               jsonb not null default '[]'::jsonb,
  usuario            text,
  created_by         uuid references auth.users (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index if not exists hospitalizaciones_establecimiento_id_idx on public.hospitalizaciones (establecimiento_id);
create index if not exists hospitalizaciones_mascota_id_idx on public.hospitalizaciones (mascota_id);

alter table public.hospitalizaciones enable row level security;

drop policy if exists "hospitalizaciones_select_member" on public.hospitalizaciones;
create policy "hospitalizaciones_select_member"
  on public.hospitalizaciones for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "hospitalizaciones_insert_member" on public.hospitalizaciones;
create policy "hospitalizaciones_insert_member"
  on public.hospitalizaciones for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "hospitalizaciones_update_member" on public.hospitalizaciones;
create policy "hospitalizaciones_update_member"
  on public.hospitalizaciones for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "hospitalizaciones_delete_member" on public.hospitalizaciones;
create policy "hospitalizaciones_delete_member"
  on public.hospitalizaciones for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── TABLA: vacunaciones ──────────────────────────────────────────
-- Un registro por vacuna aplicada. Antes vivía solo en memoria
-- (patientData[petKey].vacunaciones, mock) y se perdía al refrescar —
-- mismo criterio de columnas planas que examenes/hospitalizaciones
-- (sin jsonb acá porque no hay sub-estructura repetida).
create table if not exists public.vacunaciones (
  id                   uuid primary key default gen_random_uuid(),
  establecimiento_id   uuid not null references public.establecimientos (id) on delete cascade,
  mascota_id           uuid not null references public.mascotas (id) on delete cascade,
  fecha                date not null,
  vacuna               text not null,
  laboratorio          text,
  lote                 text,
  vencimiento          date,
  observaciones        text,
  proxima_vacunacion   date,
  usuario              text,
  created_by           uuid references auth.users (id) on delete set null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create index if not exists vacunaciones_establecimiento_id_idx on public.vacunaciones (establecimiento_id);
create index if not exists vacunaciones_mascota_id_idx on public.vacunaciones (mascota_id);

alter table public.vacunaciones enable row level security;

drop policy if exists "vacunaciones_select_member" on public.vacunaciones;
create policy "vacunaciones_select_member"
  on public.vacunaciones for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "vacunaciones_insert_member" on public.vacunaciones;
create policy "vacunaciones_insert_member"
  on public.vacunaciones for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "vacunaciones_update_member" on public.vacunaciones;
create policy "vacunaciones_update_member"
  on public.vacunaciones for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "vacunaciones_delete_member" on public.vacunaciones;
create policy "vacunaciones_delete_member"
  on public.vacunaciones for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── TABLA: desparasitaciones ─────────────────────────────────────
-- Mismo criterio que vacunaciones. `archivo_adjunto_nombre` solo
-- guarda el nombre de archivo mostrado en el formulario (el adjunto en
-- sí nunca se subió a Storage, tampoco antes de esta tabla — el modal
-- solo lo usaba como texto decorativo junto al input file).
create table if not exists public.desparasitaciones (
  id                        uuid primary key default gen_random_uuid(),
  establecimiento_id        uuid not null references public.establecimientos (id) on delete cascade,
  mascota_id                uuid not null references public.mascotas (id) on delete cascade,
  fecha                     date not null,
  ultima_desparasitacion    date,
  tipo                      text not null,
  producto                  text,
  dosis                     text,
  lote                      text,
  vencimiento               date,
  proximo_control           date,
  archivo_adjunto_nombre    text,
  observaciones             text,
  usuario                   text,
  created_by                uuid references auth.users (id) on delete set null,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);

create index if not exists desparasitaciones_establecimiento_id_idx on public.desparasitaciones (establecimiento_id);
create index if not exists desparasitaciones_mascota_id_idx on public.desparasitaciones (mascota_id);

alter table public.desparasitaciones enable row level security;

drop policy if exists "desparasitaciones_select_member" on public.desparasitaciones;
create policy "desparasitaciones_select_member"
  on public.desparasitaciones for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "desparasitaciones_insert_member" on public.desparasitaciones;
create policy "desparasitaciones_insert_member"
  on public.desparasitaciones for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "desparasitaciones_update_member" on public.desparasitaciones;
create policy "desparasitaciones_update_member"
  on public.desparasitaciones for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "desparasitaciones_delete_member" on public.desparasitaciones;
create policy "desparasitaciones_delete_member"
  on public.desparasitaciones for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── TABLA: mensajes (Mensajes al propietario) ────────────────────
-- Sin patrón de edición (un mensaje ya enviado no se edita, solo se ve o
-- se elimina) — por eso no hay `updated_at` ni política de update, a
-- diferencia de vacunaciones/desparasitaciones. `fecha` es `timestamp`
-- sin zona horaria a propósito, mismo criterio que `agenda_eventos.start_iso`
-- (ver CLAUDE.md): el valor se genera y se lee siempre como cadena
-- ingenua, nunca se parsea con offset.
create table if not exists public.mensajes (
  id                   uuid primary key default gen_random_uuid(),
  establecimiento_id   uuid not null references public.establecimientos (id) on delete cascade,
  mascota_id           uuid not null references public.mascotas (id) on delete cascade,
  fecha                timestamp not null,
  texto                text not null,
  metodos              text[] not null default '{}',
  usuario              text,
  created_by           uuid references auth.users (id) on delete set null,
  created_at           timestamptz not null default now()
);

create index if not exists mensajes_establecimiento_id_idx on public.mensajes (establecimiento_id);
create index if not exists mensajes_mascota_id_idx on public.mensajes (mascota_id);

alter table public.mensajes enable row level security;

drop policy if exists "mensajes_select_member" on public.mensajes;
create policy "mensajes_select_member"
  on public.mensajes for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "mensajes_insert_member" on public.mensajes;
create policy "mensajes_insert_member"
  on public.mensajes for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "mensajes_delete_member" on public.mensajes;
create policy "mensajes_delete_member"
  on public.mensajes for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── STORAGE: bucket `avatars` (foto de perfil de usuario) ───────
-- Público (igual que `fotos-mascotas`) — a diferencia de ese bucket, que
-- es por establecimiento ("clinica/<estab>/..."), este es por usuario
-- individual: path "<user_id>/avatar.<ext>", mismo patrón "own folder" ya
-- probado en producción con `pdfs_insert_own_folder` (auth.uid() =
-- foldername[1]).
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

-- Policy de select SÍ hace falta pese a ser bucket público: el upload de
-- storage-api hace un INSERT ... RETURNING, y el RETURNING evalúa la
-- policy de SELECT de RLS (que "bucket público" NO reemplaza — eso solo
-- habilita la ruta anónima /object/public/... para leer, no la respuesta
-- del propio insert). Sin esto, el insert falla con "new row violates
-- row-level security policy" aunque el WITH CHECK de insert sea correcto
-- (bug real sufrido en `firmas`, mismo patrón exacto — ver ahí).
drop policy if exists "avatars_select_own_folder" on storage.objects;
create policy "avatars_select_own_folder"
  on storage.objects for select
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "avatars_insert_own_folder" on storage.objects;
create policy "avatars_insert_own_folder"
  on storage.objects for insert
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "avatars_update_own_folder" on storage.objects;
create policy "avatars_update_own_folder"
  on storage.objects for update
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "avatars_delete_own_folder" on storage.objects;
create policy "avatars_delete_own_folder"
  on storage.objects for delete
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ── establecimientos.logo_path — logo de la clínica (Configuración de
-- la veterinaria > Información general). Mismo criterio que
-- mascotas.foto_path: se guarda el path, la URL pública se deriva en
-- el cliente vía getPublicUrl() cuando hace falta.
alter table public.establecimientos add column if not exists logo_path text;

-- ── STORAGE: bucket `logos-clinica` (logo del establecimiento) ──
-- Público (igual que `fotos-mascotas`) — por establecimiento, path
-- "<establecimiento_id>/logo.<ext>", mismo patrón "own folder" que
-- `fotos-mascotas`/`avatars` pero con el establecimiento_id como
-- carpeta raíz (un solo logo por clínica, no uno por registro).
insert into storage.buckets (id, name, public)
values ('logos-clinica', 'logos-clinica', true)
on conflict (id) do nothing;

-- Policy de select SÍ hace falta pese a ser bucket público (ver nota en
-- `avatars` arriba — el RETURNING del insert de storage-api la exige).
drop policy if exists "logos_clinica_select_member" on storage.objects;
create policy "logos_clinica_select_member"
  on storage.objects for select
  using (
    bucket_id = 'logos-clinica'
    and public.user_is_member_of(((storage.foldername(name))[1])::uuid)
  );

drop policy if exists "logos_clinica_insert_member" on storage.objects;
create policy "logos_clinica_insert_member"
  on storage.objects for insert
  with check (
    bucket_id = 'logos-clinica'
    and public.user_is_member_of(((storage.foldername(name))[1])::uuid)
  );

drop policy if exists "logos_clinica_update_member" on storage.objects;
create policy "logos_clinica_update_member"
  on storage.objects for update
  using (
    bucket_id = 'logos-clinica'
    and public.user_is_member_of(((storage.foldername(name))[1])::uuid)
  );

drop policy if exists "logos_clinica_delete_member" on storage.objects;
create policy "logos_clinica_delete_member"
  on storage.objects for delete
  using (
    bucket_id = 'logos-clinica'
    and public.user_is_member_of(((storage.foldername(name))[1])::uuid)
  );

-- ── STORAGE: bucket `firmas` (firma electrónica del médico) ────
-- Público (igual que `avatars`) — por usuario individual, path
-- "<user_id>/firma.<ext>", mismo patrón "own folder" que `avatars`.
-- Se pinta sobre el nombre del médico en la fórmula médica generada
-- (ver profiles.firma_url y formulaViewContentHTML en index.html).
insert into storage.buckets (id, name, public)
values ('firmas', 'firmas', true)
on conflict (id) do nothing;

-- Policy de select SÍ hace falta pese a ser bucket público — bug real
-- sufrido en producción: el upload de storage-api hace un
-- INSERT ... RETURNING, y ese RETURNING evalúa la policy de SELECT de
-- RLS ("bucket público" solo habilita la ruta anónima
-- /object/public/... para lectura externa, no reemplaza la policy de
-- select que necesita el propio insert). Sin esto, el insert falla con
-- "new row violates row-level security policy" pese a que el WITH CHECK
-- de insert sea correcto — mismo fix aplicado también en `avatars` y
-- `logos-clinica` (arriba), que tenían el mismo hueco sin haber sido
-- probados todavía.
drop policy if exists "firmas_select_own_folder" on storage.objects;
create policy "firmas_select_own_folder"
  on storage.objects for select
  using (
    bucket_id = 'firmas'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "firmas_insert_own_folder" on storage.objects;
create policy "firmas_insert_own_folder"
  on storage.objects for insert
  with check (
    bucket_id = 'firmas'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "firmas_update_own_folder" on storage.objects;
create policy "firmas_update_own_folder"
  on storage.objects for update
  using (
    bucket_id = 'firmas'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "firmas_delete_own_folder" on storage.objects;
create policy "firmas_delete_own_folder"
  on storage.objects for delete
  using (
    bucket_id = 'firmas'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ── TABLA: productos (Inventario > Productos y servicios) ────
-- Antes vivía solo en VENTAS_CATALOGO (array JS en memoria en index.html),
-- por eso se perdía al refrescar la página tanto para altas manuales
-- ("+Registrar") como para lo importado desde Excel. Acceso por CLÍNICA
-- (establecimiento_id), mismo patrón que mascotas/examenes/hospitalizaciones.
-- proveedor_id NO es una FK real: VENTAS_PROVEEDORES sigue siendo mock en
-- memoria (fuera de alcance de este cambio), así que solo se guarda su id
-- de texto, igual que ventas_facturas.cliente_id referencia VENTAS_CLIENTES.
create table if not exists public.productos (
  id                     uuid primary key default gen_random_uuid(),
  establecimiento_id     uuid not null references public.establecimientos (id) on delete cascade,
  tipo                   text not null check (tipo in ('producto','servicio','otro')),
  nombre                 text not null,
  categoria              text,
  sku                    text,
  barcode                text,
  descripcion            text,
  cuantificable          boolean not null default false,
  excluido_lista_precio  boolean not null default false,
  precio                 numeric not null default 0,
  valor_base             numeric not null default 0,
  costo                  numeric not null default 0,
  impuesto               text,
  estado                 text not null default 'activo' check (estado in ('activo','inactivo')),
  unidad_medida          text,
  stock                  numeric not null default 0,
  stock_minimo           numeric not null default 0,
  proveedor_id           text,
  lote                   text,
  vencimiento            date,
  unidades_dia           numeric not null default 0,
  duracion_minutos       integer,
  created_by             uuid references auth.users (id) on delete set null,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

create index if not exists productos_establecimiento_id_idx on public.productos (establecimiento_id);

alter table public.productos enable row level security;

drop policy if exists "productos_select_member" on public.productos;
create policy "productos_select_member"
  on public.productos for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "productos_insert_member" on public.productos;
create policy "productos_insert_member"
  on public.productos for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "productos_update_member" on public.productos;
create policy "productos_update_member"
  on public.productos for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "productos_delete_member" on public.productos;
create policy "productos_delete_member"
  on public.productos for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── TABLA: movimientos (Ventas > Ingresos y Egresos) ────────────
-- NOTA: la FK factura_id -> ventas_facturas asume que esa tabla ya
-- existe en la base de datos real (creada directamente ahí, fuera de
-- este archivo — ventas_facturas/ventas_cotizaciones todavía no están
-- documentadas en este schema.sql). Si corres este archivo contra una
-- base nueva desde cero, crea antes esa tabla o quita la FK.
create table if not exists public.movimientos (
  id                 uuid primary key default gen_random_uuid(),
  establecimiento_id uuid not null references public.establecimientos (id) on delete cascade,
  fecha              date not null,
  tipo               text not null check (tipo in ('Ingreso','Egreso')),
  categoria          text not null,
  concepto           text not null,
  monto              numeric not null default 0,
  metodo_pago        text not null,
  factura_id         uuid references public.ventas_facturas (id) on delete set null,
  factura_numero     text,
  created_by         uuid references auth.users (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index if not exists movimientos_establecimiento_id_idx on public.movimientos (establecimiento_id);

alter table public.movimientos enable row level security;

drop policy if exists "movimientos_select_member" on public.movimientos;
create policy "movimientos_select_member"
  on public.movimientos for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "movimientos_insert_member" on public.movimientos;
create policy "movimientos_insert_member"
  on public.movimientos for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "movimientos_update_member" on public.movimientos;
create policy "movimientos_update_member"
  on public.movimientos for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "movimientos_delete_member" on public.movimientos;
create policy "movimientos_delete_member"
  on public.movimientos for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── TABLA: arqueos (Ventas > Ingresos y Egresos > Cierre de caja) ─
-- Un registro por fecha (unique establecimiento_id+fecha) — ver
-- cierreBloqueado()/CIERRE_VENTANA_MODIFICACION_MS en index.html para
-- la ventana de 24h de modificación tras cerrar. `filas` guarda el
-- desglose Tipo+Forma de pago en JSON opaco (camelCase), igual que
-- `items` de ventas_facturas/ventas_cotizaciones.
-- `contado_por_metodo` es lo que el usuario cuenta al cerrar: un valor por
-- método de pago ({"Efectivo": 470000, "Transferencia": -2500000}), puede
-- ser negativo cuando ese método tuvo más egresos que ingresos. Antes el
-- contado se digitaba por fila y vivía dentro de `filas`; los arqueos de
-- esa época tienen estas tres columnas en null y el front los reconstruye
-- (ver contadoPorMetodoDeArqueo en index.html) — por eso son nullable y no
-- se hizo backfill.
-- `base_efectivo` es la plata con la que se abrió el cajón, heredada del
-- `saldo_final_efectivo` del arqueo anterior (solo efectivo: los demás
-- métodos no se guardan en la caja). El front la re-deriva al abrir la
-- pantalla; acá se guarda como foto del día para la colilla impresa.
-- contado_ingresos/contado_egresos quedaron como legado: desde que el
-- contado es por método ya no hay split Ingreso/Egreso, así que
-- contado_ingresos guarda el TOTAL contado del día y contado_egresos 0.
create table if not exists public.arqueos (
  id                   uuid primary key default gen_random_uuid(),
  establecimiento_id   uuid not null references public.establecimientos (id) on delete cascade,
  fecha                date not null,
  estado               text not null check (estado in ('Cerrado','Pendiente')),
  filas                jsonb not null default '[]'::jsonb,
  contado_por_metodo   jsonb,
  base_efectivo        numeric,
  saldo_final_efectivo numeric,
  sistema_ingresos     numeric not null default 0,
  sistema_egresos      numeric not null default 0,
  contado_ingresos     numeric not null default 0,
  contado_egresos      numeric not null default 0,
  cerrado_por          text,
  cerrado_en           timestamptz,
  created_by           uuid references auth.users (id) on delete set null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (establecimiento_id, fecha)
);

-- Para las bases que ya existían antes de la base de caja (ver
-- supabase/migrations/20260727_arqueos_base_caja.sql).
alter table public.arqueos add column if not exists contado_por_metodo   jsonb;
alter table public.arqueos add column if not exists base_efectivo        numeric;
alter table public.arqueos add column if not exists saldo_final_efectivo numeric;

create index if not exists arqueos_establecimiento_id_idx on public.arqueos (establecimiento_id);

alter table public.arqueos enable row level security;

drop policy if exists "arqueos_select_member" on public.arqueos;
create policy "arqueos_select_member"
  on public.arqueos for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "arqueos_insert_member" on public.arqueos;
create policy "arqueos_insert_member"
  on public.arqueos for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "arqueos_update_member" on public.arqueos;
create policy "arqueos_update_member"
  on public.arqueos for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "arqueos_delete_member" on public.arqueos;
create policy "arqueos_delete_member"
  on public.arqueos for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── TABLA: agenda_eventos (Agenda > eventos/citas del calendario) ─
-- start_iso/end_iso/recordatorio_24h son `timestamp` SIN zona horaria a
-- propósito: el frontend trabaja con cadenas locales ingenuas
-- ('2026-07-06T09:00:00', ver AGENDA_EVENTOS en index.html) y PostgREST
-- las devuelve tal cual con este tipo — con timestamptz volverían
-- convertidas a UTC con offset y romperían FullCalendar y todos los
-- .split('T') del módulo.
-- pet_key (no mascota_id) porque el evento referencia la clave con la que
-- patientData indexa a la mascota, y puede ser null cuando el evento es
-- "solo reservar espacio" o el propietario aún no tiene mascota registrada.
-- encargado_id es el id LOCAL numérico de USUARIOS_SISTEMA (1..N en el
-- orden de list_establecimiento_members), no un uuid de auth.users.
create table if not exists public.agenda_eventos (
  id                 uuid primary key default gen_random_uuid(),
  establecimiento_id uuid not null references public.establecimientos (id) on delete cascade,
  tipo               text not null,
  estado             text not null,
  titulo             text not null,
  start_iso          timestamp not null,
  end_iso            timestamp not null,
  sin_hora           boolean not null default false,
  solo_espacio       boolean not null default false,
  propietario        text,
  pet_key            text,
  encargado_id       integer,
  lugar              text,
  descripcion        text,
  recordatorio_24h   timestamp,
  created_by         uuid references auth.users (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index if not exists agenda_eventos_establecimiento_id_idx on public.agenda_eventos (establecimiento_id);

alter table public.agenda_eventos enable row level security;

drop policy if exists "agenda_eventos_select_member" on public.agenda_eventos;
create policy "agenda_eventos_select_member"
  on public.agenda_eventos for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "agenda_eventos_insert_member" on public.agenda_eventos;
create policy "agenda_eventos_insert_member"
  on public.agenda_eventos for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "agenda_eventos_update_member" on public.agenda_eventos;
create policy "agenda_eventos_update_member"
  on public.agenda_eventos for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "agenda_eventos_delete_member" on public.agenda_eventos;
create policy "agenda_eventos_delete_member"
  on public.agenda_eventos for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── TABLA: cirugias (Cirugías/procedimientos) ────────────────────
-- Antes vivía solo en memoria (patientData[petKey].cirugias, mock) y se
-- perdía al refrescar — mismo criterio de columnas planas que
-- vacunaciones/desparasitaciones. medico_responsable/auxiliar_asignado
-- se guardan como texto (nombre), no como id: el modal ya los llena así
-- (renderCirugiaMedicoOptions/renderCirugiaAuxiliarOptions usan
-- u.nombre como value), mismo criterio que usuario.
create table if not exists public.cirugias (
  id                       uuid primary key default gen_random_uuid(),
  establecimiento_id       uuid not null references public.establecimientos (id) on delete cascade,
  mascota_id               uuid not null references public.mascotas (id) on delete cascade,
  grupo                    text not null,
  tipo                     text not null,
  fecha                    date not null,
  hora                     text not null,
  medico_responsable       text,
  auxiliar_asignado        text,
  anestesia                text,
  estado                   text not null default 'programado',
  notas_preop              text,
  notas_postop             text,
  consentimiento_firmado   boolean not null default false,
  consentimiento_fecha     date,
  usuario                  text,
  created_by               uuid references auth.users (id) on delete set null,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

create index if not exists cirugias_establecimiento_id_idx on public.cirugias (establecimiento_id);
create index if not exists cirugias_mascota_id_idx on public.cirugias (mascota_id);

alter table public.cirugias enable row level security;

drop policy if exists "cirugias_select_member" on public.cirugias;
create policy "cirugias_select_member"
  on public.cirugias for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "cirugias_insert_member" on public.cirugias;
create policy "cirugias_insert_member"
  on public.cirugias for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "cirugias_update_member" on public.cirugias;
create policy "cirugias_update_member"
  on public.cirugias for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "cirugias_delete_member" on public.cirugias;
create policy "cirugias_delete_member"
  on public.cirugias for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── TABLA: tareas_pendientes ──────────────────────────────────────
-- Antes vivía solo en memoria (patientData[petKey].tareasPendientes,
-- mock) y se perdía al refrescar. responsable_id es el id LOCAL
-- numérico de USUARIOS_SISTEMA (mismo criterio, y misma limitación,
-- que agenda_eventos.encargado_id — no es un uuid de auth.users);
-- responsable_nombre se guarda aparte para no depender de que ese id
-- siga apuntando al mismo usuario tras recargar.
create table if not exists public.tareas_pendientes (
  id                  uuid primary key default gen_random_uuid(),
  establecimiento_id  uuid not null references public.establecimientos (id) on delete cascade,
  mascota_id          uuid not null references public.mascotas (id) on delete cascade,
  descripcion         text not null,
  responsable_id      integer,
  responsable_nombre  text,
  prioridad           text not null default 'media',
  fecha_limite        date,
  notas               text,
  estado              text not null default 'pendiente' check (estado in ('pendiente','completada')),
  usuario             text,
  created_by          uuid references auth.users (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index if not exists tareas_pendientes_establecimiento_id_idx on public.tareas_pendientes (establecimiento_id);
create index if not exists tareas_pendientes_mascota_id_idx on public.tareas_pendientes (mascota_id);

alter table public.tareas_pendientes enable row level security;

drop policy if exists "tareas_pendientes_select_member" on public.tareas_pendientes;
create policy "tareas_pendientes_select_member"
  on public.tareas_pendientes for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "tareas_pendientes_insert_member" on public.tareas_pendientes;
create policy "tareas_pendientes_insert_member"
  on public.tareas_pendientes for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "tareas_pendientes_update_member" on public.tareas_pendientes;
create policy "tareas_pendientes_update_member"
  on public.tareas_pendientes for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "tareas_pendientes_delete_member" on public.tareas_pendientes;
create policy "tareas_pendientes_delete_member"
  on public.tareas_pendientes for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── TABLA: seguimientos ──────────────────────────────────────────
-- Antes vivía solo en memoria (patientData[petKey].seguimientos, mock) y
-- se perdía al refrescar/reiniciar sesión. `fecha` es `timestamp` SIN
-- zona horaria a propósito, mismo criterio que agenda_eventos.start_iso
-- (el campo del formulario es un <input type="datetime-local"> y el
-- frontend trabaja con esa cadena local ingenua tal cual). `adjuntos`
-- es jsonb con solo {nombre} por elemento -- el archivo en sí nunca se
-- sube a Storage (mismo criterio que desparasitaciones.archivo_adjunto_nombre),
-- así que la URL de blob local no sobrevive al refresco y no se guarda.
-- `origen_modulo`/`origen_referencia_id` reemplazan al objeto `origen`
-- en memoria ({modulo, referenciaId}) -- referenciaId sigue siendo
-- `${hospId}:${diaIndex}` y hospId ya es el uuid real de
-- hospitalizaciones.id, así que el enlace sigue siendo válido tras
-- recargar. `registrado_por` tiene la misma limitación que
-- tareas_pendientes.responsable_id (id LOCAL numérico de
-- USUARIOS_SISTEMA, no un uuid) -- por eso también se guarda
-- `registrado_por_nombre` aparte.
create table if not exists public.seguimientos (
  id                    uuid primary key default gen_random_uuid(),
  establecimiento_id    uuid not null references public.establecimientos (id) on delete cascade,
  mascota_id            uuid not null references public.mascotas (id) on delete cascade,
  fecha                 timestamp not null,
  tipo                  text not null,
  motivo                text,
  detalles              text,
  adjuntos              jsonb not null default '[]'::jsonb,
  proximo_control       date,
  examen_fisico         text,
  mensaje_enviar        boolean not null default false,
  mensaje_texto         text,
  origen_modulo         text not null,
  origen_referencia_id  text,
  registrado_por        integer,
  registrado_por_nombre text,
  created_by            uuid references auth.users (id) on delete set null,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create index if not exists seguimientos_establecimiento_id_idx on public.seguimientos (establecimiento_id);
create index if not exists seguimientos_mascota_id_idx on public.seguimientos (mascota_id);

alter table public.seguimientos enable row level security;

drop policy if exists "seguimientos_select_member" on public.seguimientos;
create policy "seguimientos_select_member"
  on public.seguimientos for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "seguimientos_insert_member" on public.seguimientos;
create policy "seguimientos_insert_member"
  on public.seguimientos for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "seguimientos_update_member" on public.seguimientos;
create policy "seguimientos_update_member"
  on public.seguimientos for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "seguimientos_delete_member" on public.seguimientos;
create policy "seguimientos_delete_member"
  on public.seguimientos for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── TABLA: remisiones ─────────────────────────────────────────────
-- Antes vivía solo en memoria (patientData[petKey].remisiones, mock) y
-- se perdía al refrescar/reiniciar sesión. Mismo criterio de columnas
-- planas que cirugias -- `fecha` es `timestamp` sin zona horaria (mismo
-- motivo que seguimientos.fecha: viene de un <input type="datetime-local">).
-- `profesional` se guarda como texto (nombre), no como id -- el modal ya
-- lo llena así (renderRemisionProfesionalOptions usa u.nombre como value).
create table if not exists public.remisiones (
  id                  uuid primary key default gen_random_uuid(),
  establecimiento_id  uuid not null references public.establecimientos (id) on delete cascade,
  mascota_id          uuid not null references public.mascotas (id) on delete cascade,
  fecha               timestamp not null,
  profesional         text not null,
  centro_destino      text not null,
  procedimiento       text,
  observaciones       text,
  usuario             text,
  created_by          uuid references auth.users (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index if not exists remisiones_establecimiento_id_idx on public.remisiones (establecimiento_id);
create index if not exists remisiones_mascota_id_idx on public.remisiones (mascota_id);

alter table public.remisiones enable row level security;

drop policy if exists "remisiones_select_member" on public.remisiones;
create policy "remisiones_select_member"
  on public.remisiones for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "remisiones_insert_member" on public.remisiones;
create policy "remisiones_insert_member"
  on public.remisiones for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "remisiones_update_member" on public.remisiones;
create policy "remisiones_update_member"
  on public.remisiones for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "remisiones_delete_member" on public.remisiones;
create policy "remisiones_delete_member"
  on public.remisiones for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── TABLA: peluquerias (Peluquería y spa) ────────────────────────
-- Antes vivía solo en memoria (patientData[petKey].peluquerias, mock) y
-- se perdía al refrescar/reiniciar sesión. `fecha` es `timestamp` sin
-- zona horaria a propósito, mismo criterio que remisiones/seguimientos
-- (viene de un <input type="datetime-local">). `servicios` es jsonb
-- (mismo criterio que mascotas.peso_historico) porque el modal permite
-- varios bloques repetibles de {tipoServicio, encargado, motivo,
-- detalles}. `fotos_antes`/`fotos_despues` son jsonb con solo {nombre}
-- por elemento -- el archivo en sí nunca se sube a Storage (mismo
-- criterio que seguimientos.adjuntos/desparasitaciones.archivo_adjunto_nombre),
-- así que la URL de blob local no sobrevive al refresco y no se guarda.
create table if not exists public.peluquerias (
  id                        uuid primary key default gen_random_uuid(),
  establecimiento_id        uuid not null references public.establecimientos (id) on delete cascade,
  mascota_id                uuid not null references public.mascotas (id) on delete cascade,
  fecha                     timestamp not null,
  servicios                 jsonb not null default '[]'::jsonb,
  observaciones             text,
  fotos_antes               jsonb not null default '[]'::jsonb,
  fotos_despues             jsonb not null default '[]'::jsonb,
  proxima_cita              date,
  vacunacion_antirrabica    text,
  usuario                   text,
  created_by                uuid references auth.users (id) on delete set null,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);

create index if not exists peluquerias_establecimiento_id_idx on public.peluquerias (establecimiento_id);
create index if not exists peluquerias_mascota_id_idx on public.peluquerias (mascota_id);

alter table public.peluquerias enable row level security;

drop policy if exists "peluquerias_select_member" on public.peluquerias;
create policy "peluquerias_select_member"
  on public.peluquerias for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "peluquerias_insert_member" on public.peluquerias;
create policy "peluquerias_insert_member"
  on public.peluquerias for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "peluquerias_update_member" on public.peluquerias;
create policy "peluquerias_update_member"
  on public.peluquerias for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "peluquerias_delete_member" on public.peluquerias;
create policy "peluquerias_delete_member"
  on public.peluquerias for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── TABLA: guarderias (Guardería) ─────────────────────────────────
-- Antes vivía solo en memoria (patientData[petKey].guarderias, mock) y
-- se perdía al refrescar/reiniciar sesión. `fecha_ingreso`/`fecha_salida`
-- son `timestamp` sin zona horaria, mismo criterio que peluquerias.fecha
-- -- `fecha_salida` null significa "En curso" (ver enCurso en
-- renderGuarderiaTable/guarderiaViewContentHTML).
create table if not exists public.guarderias (
  id                  uuid primary key default gen_random_uuid(),
  establecimiento_id  uuid not null references public.establecimientos (id) on delete cascade,
  mascota_id          uuid not null references public.mascotas (id) on delete cascade,
  fecha_ingreso       timestamp not null,
  fecha_salida        timestamp,
  tipo                text not null,
  tipo_comida         text,
  cantidad_comida     text,
  objetos             text,
  observaciones       text,
  usuario             text,
  created_by          uuid references auth.users (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index if not exists guarderias_establecimiento_id_idx on public.guarderias (establecimiento_id);
create index if not exists guarderias_mascota_id_idx on public.guarderias (mascota_id);

alter table public.guarderias enable row level security;

drop policy if exists "guarderias_select_member" on public.guarderias;
create policy "guarderias_select_member"
  on public.guarderias for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "guarderias_insert_member" on public.guarderias;
create policy "guarderias_insert_member"
  on public.guarderias for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "guarderias_update_member" on public.guarderias;
create policy "guarderias_update_member"
  on public.guarderias for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "guarderias_delete_member" on public.guarderias;
create policy "guarderias_delete_member"
  on public.guarderias for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── vacunaciones.vencimiento / desparasitaciones.lote,vencimiento ──
-- Recuadro de Lote + Fecha de vencimiento en el formulario, mismo
-- criterio en ambos módulos (desparasitaciones no tenía Lote todavía).
alter table public.vacunaciones add column if not exists vencimiento date;
alter table public.desparasitaciones add column if not exists lote text;
alter table public.desparasitaciones add column if not exists vencimiento date;

-- ── TABLA: catalogos_custom (entradas "+Registrar X" de Vacunas/
-- Desparasitaciones/Hospitalizaciones) ────────────────────────────
-- Antes vivían solo en memoria (vacunasCatalogoCustom/
-- desparasitacionTiposCustom/hospitalizacionTiposCustom, mock) y se
-- perdían al refrescar/reiniciar sesión — el usuario tenía que volver
-- a registrar la misma vacuna o tipo cada vez. Una sola tabla genérica
-- para los 3 catálogos (en vez de 3 tablas casi idénticas) porque cada
-- entrada es solo un string plano sin sub-estructura propia; `categoria`
-- distingue a cuál de los 3 selects alimenta. El unique constraint
-- evita duplicados si dos sesiones agregan el mismo valor a la vez —
-- el frontend trata esa violación como "ya existe" en vez de error.
create table if not exists public.catalogos_custom (
  id                  uuid primary key default gen_random_uuid(),
  establecimiento_id  uuid not null references public.establecimientos (id) on delete cascade,
  categoria           text not null check (categoria in ('vacuna', 'desparasitacion', 'hospitalizacion')),
  valor               text not null,
  created_by          uuid references auth.users (id) on delete set null,
  created_at          timestamptz not null default now(),
  unique (establecimiento_id, categoria, valor)
);

create index if not exists catalogos_custom_establecimiento_id_idx on public.catalogos_custom (establecimiento_id);

alter table public.catalogos_custom enable row level security;

drop policy if exists "catalogos_custom_select_member" on public.catalogos_custom;
create policy "catalogos_custom_select_member"
  on public.catalogos_custom for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "catalogos_custom_insert_member" on public.catalogos_custom;
create policy "catalogos_custom_insert_member"
  on public.catalogos_custom for insert
  with check (public.user_is_member_of(establecimiento_id));

-- ============================================================
-- RED IRIS — identidad compartida de propietarios/mascotas entre
-- establecimientos + solicitudes de información clínica entre
-- clínicas.
--
-- Problema que resuelve: `propietarios`/`mascotas` están aisladas
-- por `establecimiento_id` (ver policies arriba). Si Pedro con su
-- gato Pacco ya existe en la Clínica A y llega a la Clínica B, hoy
-- hay que volver a escribir todo a mano y no hay forma de saber
-- que es la misma persona/mascota.
--
-- Modelo:
--   red_personas        → identidad canónica de un tutor en la red,
--                         llaveada por el número de documento
--                         normalizado. NO tiene establecimiento_id:
--                         es global.
--   red_persona_moviles → todos los celulares conocidos de esa
--                         persona (segundo factor de verificación).
--                         Se AGREGAN, nunca se sobreescriben: si la
--                         Clínica B corrige el celular, el de la
--                         Clínica A sigue siendo válido para
--                         verificar (la gente cambia de número) y
--                         ninguna clínica puede "secuestrar" la
--                         verificación de otra pisando el dato.
--   red_mascotas        → ficha canónica de la mascota (especie,
--                         raza, fecha de nacimiento, chip...).
--                         SIN historia clínica: nada de consultas,
--                         documentos ni registros — eso solo viaja
--                         vía red_solicitudes, con aprobación
--                         explícita de la clínica origen.
--
-- Aislamiento: red_personas / red_persona_moviles / red_mascotas
-- tienen RLS habilitada y CERO policies a propósito → ningún
-- cliente puede leerlas ni escribirlas por PostgREST. El único
-- acceso es a través de las funciones `security definer` de abajo,
-- que aplican verificación de identidad, rate limiting y auditoría.
-- No agregues una policy de select "para debuggear": eso convierte
-- el directorio en una lista de cédulas y teléfonos legible por
-- cualquier clínica de la red.
--
-- Publicación al directorio: automática vía triggers sobre
-- propietarios/mascotas, condicionada a `propietarios.consentimiento_red`
-- (default true, viene de los términos y condiciones que se aceptan
-- al registrar). Poner ese flag en false saca a la persona del
-- directorio para búsquedas futuras.
-- ============================================================

-- ── NORMALIZADORES ──────────────────────────────────────────
-- Toda comparación de la red pasa por estas tres funciones. No
-- compares nunca doc/celular "en crudo": la misma cédula se escribe
-- con puntos en una clínica y sin puntos en otra, y el móvil se
-- guarda como "+57 3001234567" pero se digita de mil formas.
create or replace function public.red_norm_doc(p text)
returns text language sql immutable set search_path = public as $$
  select nullif(upper(regexp_replace(coalesce(p, ''), '[^a-zA-Z0-9]', '', 'g')), '');
$$;

-- Se queda con los últimos 10 dígitos: así "+57 3001234567",
-- "3001234567" y "57 300 123 4567" normalizan al mismo valor sin
-- tener que adivinar el indicativo. Heurística pensada para
-- Colombia (10 dígitos); números de otros países con longitud
-- distinta igual funcionan mientras la misma persona se digite
-- consistentemente.
create or replace function public.red_norm_movil(p text)
returns text language sql immutable set search_path = public as $$
  select nullif(right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10), '');
$$;

create or replace function public.red_norm_txt(p text)
returns text language sql immutable set search_path = public as $$
  select nullif(lower(regexp_replace(
    translate(coalesce(p, ''), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN'),
    '[^a-zA-Z0-9]', '', 'g')), '');
$$;

-- Enmascara un nombre para el "hint" de coincidencia: "Pedro Gómez"
-- → "Pe*** Gó***". Suficiente para que el recepcionista reconozca
-- al tutor que tiene enfrente, insuficiente para armar una base de
-- datos de nombres a punta de consultas.
create or replace function public.red_mask_nombre(p text)
returns text language sql immutable set search_path = public as $$
  select coalesce(nullif(trim(string_agg(
    case when length(w) <= 2 then w || '*'
         else left(w, 2) || repeat('*', least(length(w) - 2, 5)) end, ' ')), ''), '-')
  from unnest(string_to_array(trim(coalesce(p, '')), ' ')) as w
  where w <> '';
$$;

grant execute on function public.red_norm_doc(text) to authenticated;
grant execute on function public.red_norm_movil(text) to authenticated;
grant execute on function public.red_norm_txt(text) to authenticated;

-- ── TABLA: red_personas (directorio global de tutores) ──────
create table if not exists public.red_personas (
  id                   uuid primary key default gen_random_uuid(),
  doc_tipo             text,
  doc_numero_norm      text not null unique,
  doc_numero           text,
  movil_norm           text,
  movil                text,
  nombre               text,
  email                text,
  direccion            text,
  ciudad               text,
  contacto_autorizado  text,
  telefono_alterno     text,
  telefono_opcional    text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

alter table public.red_personas enable row level security;
-- Sin policies: ver nota de aislamiento arriba.

create table if not exists public.red_persona_moviles (
  persona_id  uuid not null references public.red_personas (id) on delete cascade,
  movil_norm  text not null,
  movil       text,
  created_at  timestamptz not null default now(),
  primary key (persona_id, movil_norm)
);

alter table public.red_persona_moviles enable row level security;

create index if not exists red_persona_moviles_movil_idx on public.red_persona_moviles (movil_norm);

-- ── TABLA: red_mascotas (ficha canónica, SIN historia clínica) ──
create table if not exists public.red_mascotas (
  id                   uuid primary key default gen_random_uuid(),
  persona_id           uuid not null references public.red_personas (id) on delete cascade,
  nombre               text not null,
  nombre_norm          text not null,
  especie              text,
  especie_norm         text not null default '',
  raza                 text,
  chip                 text,
  fecha_nacimiento     date,
  peso                 text,
  color                text,
  genero               text,
  talla                text,
  estado_reproductivo  text,
  animal_servicio      boolean not null default false,
  fallecido            boolean not null default false,
  foto_path            text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (persona_id, nombre_norm, especie_norm)
);

alter table public.red_mascotas enable row level security;

-- ── COLUMNAS DE ENLACE en las tablas por clínica ────────────
alter table public.propietarios add column if not exists red_persona_id uuid references public.red_personas (id) on delete set null;
alter table public.propietarios add column if not exists consentimiento_red boolean not null default true;
alter table public.mascotas     add column if not exists red_mascota_id uuid references public.red_mascotas (id) on delete set null;

create index if not exists propietarios_red_persona_id_idx on public.propietarios (red_persona_id);
create index if not exists mascotas_red_mascota_id_idx on public.mascotas (red_mascota_id);

-- ── PUBLICACIÓN AL DIRECTORIO ───────────────────────────────
-- Funciones reutilizadas por los triggers Y por el backfill del
-- final del archivo (por eso no viven dentro del trigger).
create or replace function public.red_upsert_persona(
  p_doc_tipo text, p_doc_numero text, p_movil text, p_nombre text, p_email text,
  p_direccion text, p_ciudad text, p_contacto_autorizado text,
  p_telefono_alterno text, p_telefono_opcional text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_doc  text := public.red_norm_doc(p_doc_numero);
  v_mov  text := public.red_norm_movil(p_movil);
  v_id   uuid;
begin
  -- Sin documento no hay identidad canónica posible: el celular solo
  -- sirve de segundo factor, nunca de llave primaria (se reasigna
  -- entre personas con el tiempo).
  if v_doc is null then return null; end if;

  insert into public.red_personas as rp (
    doc_tipo, doc_numero_norm, doc_numero, movil_norm, movil, nombre, email,
    direccion, ciudad, contacto_autorizado, telefono_alterno, telefono_opcional
  ) values (
    p_doc_tipo, v_doc, p_doc_numero, v_mov, p_movil, p_nombre, nullif(p_email, ''),
    nullif(p_direccion, ''), nullif(p_ciudad, ''), nullif(p_contacto_autorizado, ''),
    nullif(p_telefono_alterno, ''), nullif(p_telefono_opcional, '')
  )
  on conflict (doc_numero_norm) do update set
    doc_tipo            = coalesce(excluded.doc_tipo, rp.doc_tipo),
    doc_numero          = coalesce(excluded.doc_numero, rp.doc_numero),
    movil_norm          = coalesce(excluded.movil_norm, rp.movil_norm),
    movil               = coalesce(excluded.movil, rp.movil),
    nombre              = coalesce(excluded.nombre, rp.nombre),
    email               = coalesce(excluded.email, rp.email),
    direccion           = coalesce(excluded.direccion, rp.direccion),
    ciudad              = coalesce(excluded.ciudad, rp.ciudad),
    contacto_autorizado = coalesce(excluded.contacto_autorizado, rp.contacto_autorizado),
    telefono_alterno    = coalesce(excluded.telefono_alterno, rp.telefono_alterno),
    telefono_opcional   = coalesce(excluded.telefono_opcional, rp.telefono_opcional),
    updated_at          = now()
  returning rp.id into v_id;

  -- El móvil se ACUMULA (ver nota del modelo arriba).
  if v_mov is not null then
    insert into public.red_persona_moviles (persona_id, movil_norm, movil)
    values (v_id, v_mov, p_movil)
    on conflict (persona_id, movil_norm) do nothing;
  end if;

  return v_id;
end;
$$;

create or replace function public.red_upsert_mascota(
  p_persona_id uuid, p_nombre text, p_especie text, p_raza text, p_chip text,
  p_fecha_nacimiento date, p_peso text, p_color text, p_genero text, p_talla text,
  p_estado_reproductivo text, p_animal_servicio boolean, p_fallecido boolean, p_foto_path text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_nom text := public.red_norm_txt(p_nombre);
  v_esp text := coalesce(public.red_norm_txt(p_especie), '');
  v_id  uuid;
begin
  if p_persona_id is null or v_nom is null then return null; end if;

  insert into public.red_mascotas as rm (
    persona_id, nombre, nombre_norm, especie, especie_norm, raza, chip, fecha_nacimiento,
    peso, color, genero, talla, estado_reproductivo, animal_servicio, fallecido, foto_path
  ) values (
    p_persona_id, p_nombre, v_nom, nullif(p_especie, ''), v_esp, nullif(p_raza, ''),
    nullif(p_chip, ''), p_fecha_nacimiento, nullif(p_peso, ''), nullif(p_color, ''),
    nullif(p_genero, ''), nullif(p_talla, ''), nullif(p_estado_reproductivo, ''),
    coalesce(p_animal_servicio, false), coalesce(p_fallecido, false), p_foto_path
  )
  on conflict (persona_id, nombre_norm, especie_norm) do update set
    raza                = coalesce(excluded.raza, rm.raza),
    chip                = coalesce(excluded.chip, rm.chip),
    fecha_nacimiento    = coalesce(excluded.fecha_nacimiento, rm.fecha_nacimiento),
    peso                = coalesce(excluded.peso, rm.peso),
    color               = coalesce(excluded.color, rm.color),
    genero              = coalesce(excluded.genero, rm.genero),
    talla               = coalesce(excluded.talla, rm.talla),
    estado_reproductivo = coalesce(excluded.estado_reproductivo, rm.estado_reproductivo),
    animal_servicio     = rm.animal_servicio or excluded.animal_servicio,
    fallecido           = rm.fallecido or excluded.fallecido,
    foto_path           = coalesce(rm.foto_path, excluded.foto_path),
    updated_at          = now()
  returning rm.id into v_id;

  return v_id;
end;
$$;

create or replace function public.red_trg_publicar_propietario()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if coalesce(new.consentimiento_red, true) then
    v_id := public.red_upsert_persona(
      new.doc_tipo, new.doc_numero, new.movil, new.nombre, new.email,
      new.direccion, new.ciudad, new.contacto_autorizado,
      new.telefono_alterno, new.telefono_opcional
    );
    if v_id is not null then new.red_persona_id := v_id; end if;
  end if;

  -- Estado de vinculación (ver el bloque siguiente). Se decide solo al
  -- CREAR la ficha, y solo si quien inserta no lo fijó explícitamente
  -- (red_vincular_con_token sí lo hace, porque ahí la verificación de
  -- identidad ya ocurrió). Vive en el trigger y no en index.html para
  -- que quede cubierta TODA vía de inserción — "Registrar propietario",
  -- la importación de clientes por CSV, la siembra de demo y cualquier
  -- camino futuro — sin tener que replicar la regla en cada una.
  if TG_OP = 'INSERT' and new.red_vinculado is null then
    new.red_vinculado := not (
      new.red_persona_id is not null and exists (
        select 1 from public.propietarios p
         where p.red_persona_id = new.red_persona_id
           and p.establecimiento_id <> new.establecimiento_id
      )
    );
  end if;

  return new;
end;
$$;

drop trigger if exists propietarios_red_publicar on public.propietarios;
create trigger propietarios_red_publicar
  before insert or update of doc_tipo, doc_numero, movil, nombre, email, direccion, ciudad, consentimiento_red
  on public.propietarios
  for each row execute function public.red_trg_publicar_propietario();

create or replace function public.red_trg_publicar_mascota()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_persona uuid;
  v_id uuid;
begin
  select p.red_persona_id into v_persona from public.propietarios p where p.id = new.propietario_id;
  if v_persona is null then return new; end if;

  v_id := public.red_upsert_mascota(
    v_persona, new.nombre, new.especie, new.raza, new.chip, new.fecha_nacimiento,
    new.peso, new.color, new.genero, new.talla, new.estado_reproductivo,
    new.animal_servicio, new.fallecido, new.foto_path
  );
  if v_id is not null then new.red_mascota_id := v_id; end if;
  return new;
end;
$$;

drop trigger if exists mascotas_red_publicar on public.mascotas;
create trigger mascotas_red_publicar
  before insert or update of nombre, especie, raza, chip, fecha_nacimiento, peso, color, genero, talla, estado_reproductivo, animal_servicio, fallecido, foto_path
  on public.mascotas
  for each row execute function public.red_trg_publicar_mascota();

-- ── ESTADO DE VINCULACIÓN POR ESTABLECIMIENTO ───────────────
-- Tener la ficha NO es lo mismo que tener derecho a abrirla. Sin esto,
-- una clínica podía quedarse con el tutor de otra ("Registrar como
-- nuevo de todas formas", o una importación CSV, que ni consultaba la
-- red) y usarlo con acceso completo sin haber pasado nunca por la
-- verificación de identidad: la vinculación existía pero era opcional.
--
--   red_vinculado = true  → la clínica abre y edita la ficha.
--   red_vinculado = false → la ficha se ve en el buscador (hay que
--                           poder reclamarla) pero no da acceso a nada
--                           hasta red_verificar_identidad +
--                           red_vincular_con_token.
--
-- Nace en false SOLO si esa identidad ya vivía en otro establecimiento.
-- Si la persona es nueva en la red, o no tiene cédula (sin identidad
-- canónica no hay a quién reclamarle), esta clínica es el origen y la
-- ficha nace utilizable.
alter table public.propietarios add column if not exists red_vinculado boolean;

create index if not exists propietarios_red_vinculado_idx
  on public.propietarios (establecimiento_id, red_vinculado);

-- Backfill deliberadamente permisivo: todo lo preexistente queda
-- vinculado y la regla aplica solo hacia adelante. No es pereza — en
-- producción 80 de los 95 tutores de la clínica real comparten
-- red_persona_id con la clínica de pruebas (ambas importaron la misma
-- lista de clientes por CSV antes de que la red existiera), así que
-- cualquier regla retroactiva basada en "identidad compartida" dejaría
-- a esa clínica sin acceso a la mayoría de sus propios pacientes.
update public.propietarios set red_vinculado = true where red_vinculado is null;

-- El bloqueo no puede vivir solo en index.html: con la anon key se le
-- habla a PostgREST directo. Se cubren las dos tablas de identidad; la
-- historia clínica cuelga de `mascotas`, así que sin poder crear
-- mascota tampoco se le puede colgar nada.
--
-- Ojo: esta función se evalúa DENTRO de una policy, así que la ejecuta
-- el rol que consulta (`authenticated`). No le quites el EXECUTE por
-- higiene como sí se hace con red_upsert_persona más abajo — acá
-- revocarlo rompe las policies de `mascotas` con "permission denied".
create or replace function public.propietario_vinculado(p_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select red_vinculado from public.propietarios where id = p_id), true);
$$;

-- Estas tres policies reemplazan a las del núcleo clínico (más arriba
-- en este archivo). Se re-crean acá y no allá porque dependen de
-- propietario_vinculado()/red_vinculado, que no existen todavía a esa
-- altura del schema.
drop policy if exists "propietarios_update_member" on public.propietarios;
create policy "propietarios_update_member"
  on public.propietarios for update
  using (public.user_is_member_of(establecimiento_id) and coalesce(red_vinculado, true))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "mascotas_insert_member" on public.mascotas;
create policy "mascotas_insert_member"
  on public.mascotas for insert
  with check (
    public.user_is_member_of(establecimiento_id)
    and public.propietario_vinculado(propietario_id)
  );

drop policy if exists "mascotas_update_member" on public.mascotas;
create policy "mascotas_update_member"
  on public.mascotas for update
  using (
    public.user_is_member_of(establecimiento_id)
    and public.propietario_vinculado(propietario_id)
  )
  with check (public.user_is_member_of(establecimiento_id));

-- ── AUDITORÍA Y RATE LIMITING ───────────────────────────────
-- Una búsqueda por cédula es un oráculo de enumeración ("¿existe
-- esta cédula en la red?") y la verificación lo es de credenciales
-- (cédula + celular). Ambas quedan registradas acá y ambas tienen
-- tope por usuario y ventana de tiempo — sin esto, cualquier
-- clínica de la red puede barrer el directorio con un script.
create table if not exists public.red_intentos (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid references auth.users (id) on delete set null,
  establecimiento_id uuid references public.establecimientos (id) on delete set null,
  tipo               text not null check (tipo in ('busqueda', 'verificacion')),
  doc_numero_norm    text,
  exito              boolean not null default false,
  created_at         timestamptz not null default now()
);

create index if not exists red_intentos_user_idx on public.red_intentos (user_id, tipo, created_at desc);

alter table public.red_intentos enable row level security;
-- Sin policies (solo lo escriben/leen las funciones definer).

-- Topes. Si una clínica real los alcanza, súbelos acá — pero no
-- los quites: son la única defensa contra el barrido del directorio.
create or replace function public.red_limite_busquedas() returns int language sql immutable set search_path = public as $$ select 60 $$;   -- por hora
create or replace function public.red_limite_verificaciones() returns int language sql immutable set search_path = public as $$ select 5 $$; -- fallidas por 15 min

-- Token de corta vida que emite red_verificar_identidad() y consume
-- red_vincular_con_token(): así la cédula y el celular viajan UNA
-- vez (en la verificación) y no se vuelven a mandar al confirmar
-- cuáles mascotas copiar.
create table if not exists public.red_verificaciones (
  id                 uuid primary key default gen_random_uuid(),
  persona_id         uuid not null references public.red_personas (id) on delete cascade,
  user_id            uuid not null references auth.users (id) on delete cascade,
  establecimiento_id uuid not null references public.establecimientos (id) on delete cascade,
  usada              boolean not null default false,
  expira_at          timestamptz not null default (now() + interval '10 minutes'),
  created_at         timestamptz not null default now()
);

alter table public.red_verificaciones enable row level security;

create table if not exists public.red_vinculaciones (
  id                 uuid primary key default gen_random_uuid(),
  persona_id         uuid not null references public.red_personas (id) on delete cascade,
  establecimiento_id uuid not null references public.establecimientos (id) on delete cascade,
  propietario_id     uuid references public.propietarios (id) on delete set null,
  mascotas_copiadas  int not null default 0,
  user_id            uuid references auth.users (id) on delete set null,
  created_at         timestamptz not null default now()
);

alter table public.red_vinculaciones enable row level security;

-- ── RPC 1: red_buscar_persona — detección (hint, sin PII) ────
-- Se llama al guardar un propietario nuevo. Responde "esta cédula
-- o este celular ya existen en la red" con el nombre enmascarado y
-- unos contadores; nunca devuelve datos utilizables sin pasar por
-- la verificación de abajo.
create or replace function public.red_buscar_persona(
  p_establecimiento_id uuid, p_doc_numero text, p_movil text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_doc     text := public.red_norm_doc(p_doc_numero);
  v_mov     text := public.red_norm_movil(p_movil);
  v_persona public.red_personas%rowtype;
  v_por_doc boolean := false;
  v_usos    int;
begin
  if auth.uid() is null or not public.user_is_member_of(p_establecimiento_id) then
    raise exception 'No autorizado';
  end if;

  select count(*) into v_usos from public.red_intentos
   where user_id = auth.uid() and tipo = 'busqueda' and created_at > now() - interval '1 hour';
  if v_usos >= public.red_limite_busquedas() then
    return jsonb_build_object('ok', false, 'motivo', 'rate_limited');
  end if;

  if v_doc is not null then
    select * into v_persona from public.red_personas where doc_numero_norm = v_doc;
    v_por_doc := found;
  end if;

  if not v_por_doc and v_mov is not null then
    select rp.* into v_persona from public.red_personas rp
      join public.red_persona_moviles m on m.persona_id = rp.id
     where m.movil_norm = v_mov
     limit 1;
  end if;

  insert into public.red_intentos (user_id, establecimiento_id, tipo, doc_numero_norm, exito)
  values (auth.uid(), p_establecimiento_id, 'busqueda', v_doc, v_persona.id is not null);

  if v_persona.id is null then
    return jsonb_build_object('ok', true, 'existe', false);
  end if;

  return jsonb_build_object(
    'ok', true,
    'existe', true,
    'coincide_doc', v_por_doc,
    'coincide_movil', v_mov is not null and exists (
      select 1 from public.red_persona_moviles m where m.persona_id = v_persona.id and m.movil_norm = v_mov),
    'nombre_masked', public.red_mask_nombre(v_persona.nombre),
    'mascotas', (select count(*) from public.red_mascotas where persona_id = v_persona.id),
    'clinicas', (select count(distinct establecimiento_id) from public.propietarios where red_persona_id = v_persona.id),
    -- Ya registrado en MI clínica: el front avisa "ya existe acá" en
    -- vez de ofrecer vincular (vincular sería un duplicado).
    'ya_en_clinica', exists (
      select 1 from public.propietarios
       where red_persona_id = v_persona.id and establecimiento_id = p_establecimiento_id)
  );
end;
$$;

grant execute on function public.red_buscar_persona(uuid, text, text) to authenticated;

-- ── RPC 2: red_verificar_identidad — cédula + celular ────────
-- El formulario de seguridad. AMBOS datos tienen que coincidir con
-- la misma persona; el mensaje de error es siempre el mismo
-- ('no_coincide') sin decir cuál de los dos falló, para no
-- convertirlo en un oráculo de "esta cédula existe, adivina el
-- teléfono". Tras 5 fallos en 15 minutos el usuario queda
-- bloqueado para verificar.
create or replace function public.red_verificar_identidad(
  p_establecimiento_id uuid, p_doc_numero text, p_movil text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_doc     text := public.red_norm_doc(p_doc_numero);
  v_mov     text := public.red_norm_movil(p_movil);
  v_persona public.red_personas%rowtype;
  v_fallos  int;
  v_token   uuid;
  v_mascotas jsonb;
begin
  if auth.uid() is null or not public.user_is_member_of(p_establecimiento_id) then
    raise exception 'No autorizado';
  end if;

  select count(*) into v_fallos from public.red_intentos
   where user_id = auth.uid() and tipo = 'verificacion' and not exito
     and created_at > now() - interval '15 minutes';
  if v_fallos >= public.red_limite_verificaciones() then
    return jsonb_build_object('ok', false, 'motivo', 'bloqueado');
  end if;

  if v_doc is not null and v_mov is not null then
    select rp.* into v_persona from public.red_personas rp
     where rp.doc_numero_norm = v_doc
       and exists (select 1 from public.red_persona_moviles m
                    where m.persona_id = rp.id and m.movil_norm = v_mov);
  end if;

  if v_persona.id is null then
    insert into public.red_intentos (user_id, establecimiento_id, tipo, doc_numero_norm, exito)
    values (auth.uid(), p_establecimiento_id, 'verificacion', v_doc, false);
    return jsonb_build_object(
      'ok', false, 'motivo', 'no_coincide',
      'intentos_restantes', greatest(public.red_limite_verificaciones() - v_fallos - 1, 0));
  end if;

  insert into public.red_intentos (user_id, establecimiento_id, tipo, doc_numero_norm, exito)
  values (auth.uid(), p_establecimiento_id, 'verificacion', v_doc, true);

  insert into public.red_verificaciones (persona_id, user_id, establecimiento_id)
  values (v_persona.id, auth.uid(), p_establecimiento_id)
  returning id into v_token;

  -- Fichas de mascota (sin historia clínica). `ya_existe` marca las
  -- que esta clínica ya tiene: el front las muestra deshabilitadas
  -- para no crear duplicados.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', rm.id, 'nombre', rm.nombre, 'especie', rm.especie, 'raza', rm.raza,
           'chip', rm.chip, 'fecha_nacimiento', rm.fecha_nacimiento, 'peso', rm.peso,
           'color', rm.color, 'genero', rm.genero, 'talla', rm.talla,
           'estado_reproductivo', rm.estado_reproductivo,
           'animal_servicio', rm.animal_servicio, 'fallecido', rm.fallecido,
           'clinicas', (select count(distinct m2.establecimiento_id) from public.mascotas m2 where m2.red_mascota_id = rm.id),
           'ya_existe', exists (select 1 from public.mascotas m3
                                 where m3.red_mascota_id = rm.id
                                   and m3.establecimiento_id = p_establecimiento_id)
         ) order by rm.nombre), '[]'::jsonb)
    into v_mascotas
    from public.red_mascotas rm where rm.persona_id = v_persona.id;

  return jsonb_build_object(
    'ok', true,
    'token', v_token,
    'ya_vinculado', exists (select 1 from public.propietarios
                             where red_persona_id = v_persona.id
                               and establecimiento_id = p_establecimiento_id),
    'persona', jsonb_build_object(
      'doc_tipo', v_persona.doc_tipo, 'doc_numero', v_persona.doc_numero,
      'movil', v_persona.movil, 'nombre', v_persona.nombre, 'email', v_persona.email,
      'direccion', v_persona.direccion, 'ciudad', v_persona.ciudad,
      'contacto_autorizado', v_persona.contacto_autorizado,
      'telefono_alterno', v_persona.telefono_alterno,
      'telefono_opcional', v_persona.telefono_opcional),
    'mascotas', v_mascotas
  );
end;
$$;

grant execute on function public.red_verificar_identidad(uuid, text, text) to authenticated;

-- ── RPC 3: red_vincular_con_token — copia las fichas ─────────
-- Crea el propietario en la clínica solicitante y una fila de
-- `mascotas` por cada ficha seleccionada. Copia SOLO ficha: ni una
-- consulta, ni un documento, ni un registro clínico (eso es
-- red_solicitudes, más abajo). Devuelve las filas insertadas para
-- que el front arme su estado local sin releer todo.
create or replace function public.red_vincular_con_token(
  p_token uuid, p_red_mascota_ids uuid[]
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_ver     public.red_verificaciones%rowtype;
  v_persona public.red_personas%rowtype;
  v_prop    public.propietarios%rowtype;
  v_rm      public.red_mascotas%rowtype;
  v_key     text;
  v_base    text;
  v_i       int;
  v_nueva   public.mascotas%rowtype;
  v_mascotas jsonb := '[]'::jsonb;
  v_copiadas int := 0;
begin
  select * into v_ver from public.red_verificaciones
   where id = p_token and user_id = auth.uid() and not usada and expira_at > now();
  if v_ver.id is null then
    return jsonb_build_object('ok', false, 'motivo', 'token_invalido');
  end if;
  if not public.user_is_member_of(v_ver.establecimiento_id) then
    raise exception 'No autorizado';
  end if;

  update public.red_verificaciones set usada = true where id = v_ver.id;

  select * into v_persona from public.red_personas where id = v_ver.persona_id;

  -- Si la clínica ya tenía a esta persona (p. ej. dos vinculaciones
  -- seguidas, o una ficha que quedó creada SIN vincular) se reutiliza su
  -- propietario en vez de duplicarlo, y se desbloquea. Este es el único
  -- camino que pone red_vinculado en true después de creada la fila: la
  -- policy de update de `propietarios` impide hacerlo por PostgREST.
  select * into v_prop from public.propietarios
   where red_persona_id = v_persona.id and establecimiento_id = v_ver.establecimiento_id
   limit 1;

  if v_prop.id is null then
    insert into public.propietarios (
      establecimiento_id, doc_tipo, doc_numero, movil, email, nombre, direccion, ciudad,
      contacto_autorizado, telefono_alterno, telefono_opcional, created_by, red_persona_id,
      red_vinculado
    ) values (
      v_ver.establecimiento_id, v_persona.doc_tipo, v_persona.doc_numero, v_persona.movil,
      v_persona.email, coalesce(v_persona.nombre, 'Sin nombre'), v_persona.direccion, v_persona.ciudad,
      v_persona.contacto_autorizado, v_persona.telefono_alterno, v_persona.telefono_opcional,
      auth.uid(), v_persona.id, true
    ) returning * into v_prop;
  elsif not coalesce(v_prop.red_vinculado, true) then
    update public.propietarios
       set red_vinculado = true, updated_at = now()
     where id = v_prop.id
     returning * into v_prop;
  end if;

  for v_rm in
    select rm.* from public.red_mascotas rm
     where rm.persona_id = v_persona.id
       and rm.id = any(coalesce(p_red_mascota_ids, array[]::uuid[]))
       and not exists (select 1 from public.mascotas m
                        where m.red_mascota_id = rm.id
                          and m.establecimiento_id = v_ver.establecimiento_id)
  loop
    -- pet_key: mismo criterio que crearMascotaKey() en index.html
    -- (slug del nombre, sufijo numérico ante colisión) porque es la
    -- llave con la que el front indexa patientData.
    v_base := coalesce(public.red_norm_txt(v_rm.nombre), 'mascota');
    v_key := v_base;
    v_i := 2;
    while exists (select 1 from public.mascotas
                   where establecimiento_id = v_ver.establecimiento_id and pet_key = v_key) loop
      v_key := v_base || v_i::text;
      v_i := v_i + 1;
    end loop;

    insert into public.mascotas (
      establecimiento_id, propietario_id, pet_key, nombre, chip, especie, raza,
      fecha_nacimiento, peso, color, genero, talla, estado_reproductivo,
      animal_servicio, fallecido, foto_path, created_by, red_mascota_id
    ) values (
      v_ver.establecimiento_id, v_prop.id, v_key, v_rm.nombre, v_rm.chip, v_rm.especie, v_rm.raza,
      v_rm.fecha_nacimiento, v_rm.peso, v_rm.color, v_rm.genero, v_rm.talla, v_rm.estado_reproductivo,
      v_rm.animal_servicio, v_rm.fallecido, v_rm.foto_path, auth.uid(), v_rm.id
    ) returning * into v_nueva;

    v_mascotas := v_mascotas || to_jsonb(v_nueva);
    v_copiadas := v_copiadas + 1;
  end loop;

  insert into public.red_vinculaciones (persona_id, establecimiento_id, propietario_id, mascotas_copiadas, user_id)
  values (v_persona.id, v_ver.establecimiento_id, v_prop.id, v_copiadas, auth.uid());

  return jsonb_build_object('ok', true, 'propietario', to_jsonb(v_prop), 'mascotas', v_mascotas);
end;
$$;

grant execute on function public.red_vincular_con_token(uuid, uuid[]) to authenticated;

-- ============================================================
-- SOLICITUDES DE INFORMACIÓN ENTRE ESTABLECIMIENTOS
--
-- La vinculación de arriba trae ficha, no historia. Para la
-- historia (documentos, consultas, vacunaciones, ...) la clínica
-- solicitante pide permiso y la clínica origen aprueba o rechaza.
--
-- Aprobar NO copia ni duplica nada: agrega una policy de lectura
-- (ver red_puede_ver_registro más abajo) sobre las filas que ya
-- existen en la clínica origen. Ventajas frente a copiar:
--   · no se duplica información clínica ni archivos en Storage —
--     el PDF se lee en su ubicación original, que es exactamente
--     el "no tener que descargar y volver a cargar cada documento";
--   · revocar el acceso lo revoca de verdad (estado 'revocada'),
--     en vez de dejar copias regadas;
--   · los cambios en la clínica origen se ven al día.
-- Contrapartida: los registros compartidos son SOLO LECTURA en la
-- clínica solicitante (las policies de update/delete siguen
-- exigiendo membresía del establecimiento dueño), y el front lo
-- refleja limitando el menú "..." a Ver/Imprimir.
-- ============================================================
create table if not exists public.red_solicitudes (
  id                             uuid primary key default gen_random_uuid(),
  red_mascota_id                 uuid not null references public.red_mascotas (id) on delete cascade,
  solicitante_establecimiento_id uuid not null references public.establecimientos (id) on delete cascade,
  destino_establecimiento_id     uuid not null references public.establecimientos (id) on delete cascade,
  mascota_solicitante_id         uuid references public.mascotas (id) on delete set null,
  mascota_destino_id             uuid references public.mascotas (id) on delete set null,
  tipos                          text[] not null,
  mensaje                        text,
  estado                         text not null default 'pendiente'
                                 check (estado in ('pendiente', 'aprobada', 'rechazada', 'cancelada', 'revocada')),
  respuesta_nota                 text,
  created_by                     uuid references auth.users (id) on delete set null,
  created_at                     timestamptz not null default now(),
  respondida_por                 uuid references auth.users (id) on delete set null,
  respondida_at                  timestamptz,
  constraint red_solicitudes_tipos_validos check (
    array_length(tipos, 1) >= 1
    and tipos <@ array['documentos','consultas','vacunaciones','desparasitaciones','examenes','formulas','cirugias']::text[]
  ),
  constraint red_solicitudes_distintos check (solicitante_establecimiento_id <> destino_establecimiento_id)
);

create index if not exists red_solicitudes_destino_idx on public.red_solicitudes (destino_establecimiento_id, estado);
create index if not exists red_solicitudes_solicitante_idx on public.red_solicitudes (solicitante_establecimiento_id, estado);
create index if not exists red_solicitudes_mascota_destino_idx on public.red_solicitudes (mascota_destino_id, estado);

alter table public.red_solicitudes enable row level security;

-- Select: las dos clínicas involucradas ven la solicitud. Sin
-- policies de insert/update/delete a propósito — crear, responder y
-- cancelar pasan por las funciones de abajo, que son las que
-- validan quién puede hacer qué (el solicitante no puede aprobarse
-- su propia solicitud escribiendo estado='aprobada' por PostgREST).
drop policy if exists "red_solicitudes_select_involucrados" on public.red_solicitudes;
create policy "red_solicitudes_select_involucrados"
  on public.red_solicitudes for select
  using (public.user_is_member_of(solicitante_establecimiento_id)
      or public.user_is_member_of(destino_establecimiento_id));

-- ── Regla de lectura compartida ─────────────────────────────
-- El corazón del permiso. stable + definer: lee red_solicitudes sin
-- RLS y se evalúa una vez por fila candidata.
create or replace function public.red_puede_ver_registro(
  p_establecimiento_id uuid, p_mascota_id uuid, p_tipo text
) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.red_solicitudes s
     where s.estado = 'aprobada'
       and s.destino_establecimiento_id = p_establecimiento_id
       and s.mascota_destino_id = p_mascota_id
       and p_tipo = any (s.tipos)
       and public.user_is_member_of(s.solicitante_establecimiento_id)
  );
$$;

grant execute on function public.red_puede_ver_registro(uuid, uuid, text) to authenticated;

-- Policies ADICIONALES de select (las permissive se combinan con OR,
-- así que la policy "..._select_member" original sigue mandando para
-- la clínica dueña; esta solo agrega el caso compartido).
drop policy if exists "documentos_select_red" on public.documentos;
create policy "documentos_select_red" on public.documentos for select
  using (public.red_puede_ver_registro(establecimiento_id, mascota_id, 'documentos'));

drop policy if exists "consultas_select_red" on public.consultas;
create policy "consultas_select_red" on public.consultas for select
  using (public.red_puede_ver_registro(establecimiento_id, mascota_id, 'consultas'));

drop policy if exists "vacunaciones_select_red" on public.vacunaciones;
create policy "vacunaciones_select_red" on public.vacunaciones for select
  using (public.red_puede_ver_registro(establecimiento_id, mascota_id, 'vacunaciones'));

drop policy if exists "desparasitaciones_select_red" on public.desparasitaciones;
create policy "desparasitaciones_select_red" on public.desparasitaciones for select
  using (public.red_puede_ver_registro(establecimiento_id, mascota_id, 'desparasitaciones'));

drop policy if exists "examenes_select_red" on public.examenes;
create policy "examenes_select_red" on public.examenes for select
  using (public.red_puede_ver_registro(establecimiento_id, mascota_id, 'examenes'));

drop policy if exists "formulas_medicas_select_red" on public.formulas_medicas;
create policy "formulas_medicas_select_red" on public.formulas_medicas for select
  using (public.red_puede_ver_registro(establecimiento_id, mascota_id, 'formulas'));

drop policy if exists "cirugias_select_red" on public.cirugias;
create policy "cirugias_select_red" on public.cirugias for select
  using (public.red_puede_ver_registro(establecimiento_id, mascota_id, 'cirugias'));

-- Storage: el PDF de un documento compartido y el archivo de
-- resultado de un examen compartido se leen en su ruta original
-- (bucket `pdfs`, prefijo "clinica/<estab_origen>/..."), sin copiar
-- el archivo. Definer porque tiene que mirar documentos/examenes
-- saltándose la RLS de esas tablas.
create or replace function public.red_puede_ver_pdf(p_path text)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.documentos d
     where d.pdf_path = p_path
       and public.red_puede_ver_registro(d.establecimiento_id, d.mascota_id, 'documentos')
  ) or exists (
    select 1 from public.examenes e, jsonb_array_elements(e.pruebas) pr
     where pr->>'resultadoPath' = p_path
       and public.red_puede_ver_registro(e.establecimiento_id, e.mascota_id, 'examenes')
  );
$$;

grant execute on function public.red_puede_ver_pdf(text) to authenticated;

drop policy if exists "pdfs_select_red_compartido" on storage.objects;
create policy "pdfs_select_red_compartido"
  on storage.objects for select
  using (bucket_id = 'pdfs' and public.red_puede_ver_pdf(name));

-- ── RPC: clínicas donde existe esta mascota ─────────────────
-- Alimenta el selector "¿a qué establecimiento le solicitas?".
-- Devuelve solo nombre/ciudad de la clínica y la fecha del último
-- registro — nunca contenido clínico.
create or replace function public.red_establecimientos_de_mascota(p_mascota_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_m public.mascotas%rowtype;
  v_out jsonb;
begin
  select * into v_m from public.mascotas where id = p_mascota_id;
  if v_m.id is null or not public.user_is_member_of(v_m.establecimiento_id) then
    raise exception 'No autorizado';
  end if;
  if v_m.red_mascota_id is null then
    return jsonb_build_object('ok', true, 'red_mascota_id', null, 'establecimientos', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'establecimiento_id', e.id, 'nombre', e.nombre, 'ciudad', e.ciudad,
           'mascota_id', m.id, 'desde', m.created_at,
           'solicitud_estado', (select s.estado from public.red_solicitudes s
                                 where s.mascota_destino_id = m.id
                                   and s.solicitante_establecimiento_id = v_m.establecimiento_id
                                 order by s.created_at desc limit 1)
         ) order by e.nombre), '[]'::jsonb)
    into v_out
    from public.mascotas m
    join public.establecimientos e on e.id = m.establecimiento_id
   where m.red_mascota_id = v_m.red_mascota_id
     and m.establecimiento_id <> v_m.establecimiento_id;

  return jsonb_build_object('ok', true, 'red_mascota_id', v_m.red_mascota_id, 'establecimientos', v_out);
end;
$$;

grant execute on function public.red_establecimientos_de_mascota(uuid) to authenticated;

-- ── RPC: crear solicitud ────────────────────────────────────
-- Va por función y no por insert directo porque el solicitante NO
-- puede leer `mascotas` de la clínica destino (RLS): la resolución
-- de mascota_destino_id la hace el servidor.
create or replace function public.red_crear_solicitud(
  p_mascota_id uuid, p_destino_establecimiento_id uuid, p_tipos text[], p_mensaje text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_m public.mascotas%rowtype;
  v_destino uuid;
  v_id uuid;
begin
  select * into v_m from public.mascotas where id = p_mascota_id;
  if v_m.id is null or not public.user_is_member_of(v_m.establecimiento_id) then
    raise exception 'No autorizado';
  end if;
  if v_m.red_mascota_id is null then
    return jsonb_build_object('ok', false, 'motivo', 'sin_identidad_red');
  end if;
  if p_destino_establecimiento_id = v_m.establecimiento_id then
    return jsonb_build_object('ok', false, 'motivo', 'mismo_establecimiento');
  end if;

  select id into v_destino from public.mascotas
   where red_mascota_id = v_m.red_mascota_id
     and establecimiento_id = p_destino_establecimiento_id
   limit 1;
  if v_destino is null then
    return jsonb_build_object('ok', false, 'motivo', 'no_existe_en_destino');
  end if;

  if exists (select 1 from public.red_solicitudes
              where mascota_destino_id = v_destino
                and solicitante_establecimiento_id = v_m.establecimiento_id
                and estado = 'pendiente') then
    return jsonb_build_object('ok', false, 'motivo', 'ya_pendiente');
  end if;

  insert into public.red_solicitudes (
    red_mascota_id, solicitante_establecimiento_id, destino_establecimiento_id,
    mascota_solicitante_id, mascota_destino_id, tipos, mensaje, created_by
  ) values (
    v_m.red_mascota_id, v_m.establecimiento_id, p_destino_establecimiento_id,
    v_m.id, v_destino, p_tipos, nullif(p_mensaje, ''), auth.uid()
  ) returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

grant execute on function public.red_crear_solicitud(uuid, uuid, text[], text) to authenticated;

-- ── RPC: responder / cancelar / revocar ─────────────────────
-- Aprobar y rechazar son del establecimiento DESTINO (el dueño de
-- los datos); cancelar es del solicitante mientras siga pendiente;
-- revocar es del destino sobre una solicitud ya aprobada y corta el
-- acceso de inmediato (las policies de arriba solo miran
-- estado='aprobada').
create or replace function public.red_responder_solicitud(
  p_id uuid, p_estado text, p_nota text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_s public.red_solicitudes%rowtype;
begin
  select * into v_s from public.red_solicitudes where id = p_id;
  if v_s.id is null then return jsonb_build_object('ok', false, 'motivo', 'no_existe'); end if;

  if p_estado in ('aprobada', 'rechazada') then
    if not public.user_is_member_of(v_s.destino_establecimiento_id) then raise exception 'No autorizado'; end if;
    if v_s.estado <> 'pendiente' then return jsonb_build_object('ok', false, 'motivo', 'ya_respondida'); end if;
  elsif p_estado = 'revocada' then
    if not public.user_is_member_of(v_s.destino_establecimiento_id) then raise exception 'No autorizado'; end if;
    if v_s.estado <> 'aprobada' then return jsonb_build_object('ok', false, 'motivo', 'no_aprobada'); end if;
  elsif p_estado = 'cancelada' then
    if not public.user_is_member_of(v_s.solicitante_establecimiento_id) then raise exception 'No autorizado'; end if;
    if v_s.estado <> 'pendiente' then return jsonb_build_object('ok', false, 'motivo', 'ya_respondida'); end if;
  else
    return jsonb_build_object('ok', false, 'motivo', 'estado_invalido');
  end if;

  update public.red_solicitudes
     set estado = p_estado, respuesta_nota = nullif(p_nota, ''),
         respondida_por = auth.uid(), respondida_at = now()
   where id = p_id;

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.red_responder_solicitud(uuid, text, text) to authenticated;

-- ── RPC: bandeja (recibidas + enviadas) ─────────────────────
-- Enriquecida en el servidor porque cada lado necesita datos que su
-- RLS no le deja leer directo (el destino no ve la mascota del
-- solicitante y viceversa).
create or replace function public.red_listar_solicitudes(p_establecimiento_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_out jsonb;
begin
  if not public.user_is_member_of(p_establecimiento_id) then raise exception 'No autorizado'; end if;

  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'id', s.id,
      'direccion', case when s.destino_establecimiento_id = p_establecimiento_id then 'recibida' else 'enviada' end,
      'estado', s.estado, 'tipos', s.tipos, 'mensaje', s.mensaje,
      'respuesta_nota', s.respuesta_nota,
      'created_at', s.created_at, 'respondida_at', s.respondida_at,
      'mascota_nombre', rm.nombre, 'mascota_especie', rm.especie,
      'propietario_nombre', rp.nombre,
      'solicitante_nombre', es.nombre, 'destino_nombre', ed.nombre,
      'creado_por_nombre', pr.nombre
    ) as x
    from public.red_solicitudes s
    join public.red_mascotas rm on rm.id = s.red_mascota_id
    join public.red_personas rp on rp.id = rm.persona_id
    join public.establecimientos es on es.id = s.solicitante_establecimiento_id
    join public.establecimientos ed on ed.id = s.destino_establecimiento_id
    left join public.profiles pr on pr.id = s.created_by
    where s.solicitante_establecimiento_id = p_establecimiento_id
       or s.destino_establecimiento_id = p_establecimiento_id
  ) t;

  return jsonb_build_object('ok', true, 'solicitudes', v_out);
end;
$$;

grant execute on function public.red_listar_solicitudes(uuid) to authenticated;

-- ── RPC: qué tengo compartido HACIA MÍ ──────────────────────
-- Lo llama cargarDatosClinicaDesdeSupabase() al iniciar sesión para
-- saber qué mascotas ajenas puede leer y en qué mascota local
-- mostrarlas. Los registros en sí se leen con selects normales
-- (las policies de arriba los habilitan), no por acá.
create or replace function public.red_mis_compartidos(p_establecimiento_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_out jsonb;
begin
  if not public.user_is_member_of(p_establecimiento_id) then raise exception 'No autorizado'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'solicitud_id', s.id,
           'mascota_local_id', s.mascota_solicitante_id,
           'mascota_origen_id', s.mascota_destino_id,
           'establecimiento_origen_id', s.destino_establecimiento_id,
           'establecimiento_origen_nombre', e.nombre,
           'tipos', s.tipos,
           'aprobada_at', s.respondida_at)), '[]'::jsonb)
    into v_out
    from public.red_solicitudes s
    join public.establecimientos e on e.id = s.destino_establecimiento_id
   where s.solicitante_establecimiento_id = p_establecimiento_id
     and s.estado = 'aprobada';

  return jsonb_build_object('ok', true, 'compartidos', v_out);
end;
$$;

grant execute on function public.red_mis_compartidos(uuid) to authenticated;

-- ── ENDURECIMIENTO DE PERMISOS (no es opcional) ─────────────
-- Supabase concede EXECUTE por default privileges a `anon` y
-- `authenticated` sobre TODA función nueva de `public`, y PostgREST
-- expone cualquier función con EXECUTE en /rest/v1/rpc/<nombre>. Sin
-- este bloque, `red_upsert_persona` — que es `security definer` y no
-- verifica nada porque solo la llaman los triggers — queda invocable
-- por un anónimo desde internet: bastaría un POST para agregarle un
-- celular propio a la persona de otra clínica en red_persona_moviles
-- y pasar después la verificación de identidad como si fuera el
-- tutor. Detectado por el advisor de seguridad
-- (anon_security_definer_function_executable).
-- Ojo: `revoke ... from public` NO alcanza, porque el grant a
-- anon/authenticated es directo, no heredado de PUBLIC — hay que
-- nombrarlos. Se revoca todo y se vuelve a conceder solo lo que el
-- front llama de verdad; los helpers internos (red_upsert_*, los dos
-- trigger functions, los límites y el enmascarador) quedan sin
-- EXECUTE para nadie: los triggers y las RPC los ejecutan como dueño
-- de la función, no como el usuario que llama.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'red\_%'
  loop
    execute format('revoke all on function %s from anon, authenticated, public', r.sig);
  end loop;
end $$;

grant execute on function public.red_norm_doc(text) to authenticated;
grant execute on function public.red_norm_movil(text) to authenticated;
grant execute on function public.red_norm_txt(text) to authenticated;
grant execute on function public.red_buscar_persona(uuid, text, text) to authenticated;
grant execute on function public.red_verificar_identidad(uuid, text, text) to authenticated;
grant execute on function public.red_vincular_con_token(uuid, uuid[]) to authenticated;
-- Estas dos las evalúan las policies con el rol del que consulta, no
-- con el dueño: sin EXECUTE, todo select sobre las 7 tablas
-- compartidas fallaría.
grant execute on function public.red_puede_ver_registro(uuid, uuid, text) to authenticated;
grant execute on function public.red_puede_ver_pdf(text) to authenticated;
grant execute on function public.red_establecimientos_de_mascota(uuid) to authenticated;
grant execute on function public.red_crear_solicitud(uuid, uuid, text[], text) to authenticated;
grant execute on function public.red_responder_solicitud(uuid, text, text) to authenticated;
grant execute on function public.red_listar_solicitudes(uuid) to authenticated;
grant execute on function public.red_mis_compartidos(uuid) to authenticated;

-- ── BACKFILL del directorio con lo ya existente ─────────────
-- Los propietarios/mascotas que ya estaban en la base cuando se
-- corrió esta migración no dispararon los triggers. Se publican una
-- vez acá; es idempotente (los upsert resuelven por llave natural),
-- así que volver a correr el archivo completo no duplica nada.
do $$
declare r record; v_id uuid;
begin
  for r in select * from public.propietarios where red_persona_id is null and coalesce(consentimiento_red, true) loop
    v_id := public.red_upsert_persona(r.doc_tipo, r.doc_numero, r.movil, r.nombre, r.email,
                                      r.direccion, r.ciudad, r.contacto_autorizado,
                                      r.telefono_alterno, r.telefono_opcional);
    if v_id is not null then
      update public.propietarios set red_persona_id = v_id where id = r.id;
    end if;
  end loop;

  for r in
    select m.*, p.red_persona_id as persona_id
      from public.mascotas m join public.propietarios p on p.id = m.propietario_id
     where m.red_mascota_id is null and p.red_persona_id is not null
  loop
    v_id := public.red_upsert_mascota(r.persona_id, r.nombre, r.especie, r.raza, r.chip,
                                      r.fecha_nacimiento, r.peso, r.color, r.genero, r.talla,
                                      r.estado_reproductivo, r.animal_servicio, r.fallecido, r.foto_path);
    if v_id is not null then
      update public.mascotas set red_mascota_id = v_id where id = r.id;
    end if;
  end loop;
end $$;
