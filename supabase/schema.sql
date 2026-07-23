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
  peso                 text,
  color                text,
  genero               text,
  talla                text,
  estado_reproductivo  text,
  animal_servicio      boolean not null default false,
  fallecido            boolean not null default false,
  alimentacion         text,
  frecuencia_bano      text,
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
