-- ═══════════════════════════════════════════════════════════════════
-- PQRS — Peticiones, Quejas, Reclamos y Sugerencias
-- ═══════════════════════════════════════════════════════════════════
-- Punto de contacto entre la clínica y el soporte de IRIS/MUVET. Se
-- envía desde el menú desplegable del perfil (header del app shell) y
-- cada envío dispara un correo a soporteiris@appmuvet.com (override:
-- PQRS_EMAIL_DESTINO en Vercel), por el mismo camino que el resto del
-- correo de la app (api/enviar-correo.js → bandeja `correos`).
--
-- Se guarda la fila ADEMÁS de mandar el correo a propósito: el
-- subsistema de correo falla en silencio (dominio sin verificar, API
-- key ausente — ver el bloque de "Envío de correos" en CLAUDE.md), y
-- una PQRS perdida por eso no dejaría ningún rastro. `correo_estado`
-- registra si el aviso llegó a salir.

create table if not exists public.pqrs (
  id                 uuid primary key default gen_random_uuid(),
  establecimiento_id uuid not null references public.establecimientos (id) on delete cascade,
  -- 'peticion' | 'queja' | 'reclamo' | 'sugerencia' | 'felicitacion'
  tipo               text not null
                       check (tipo in ('peticion','queja','reclamo','sugerencia','felicitacion')),
  asunto             text not null,
  descripcion        text not null,
  -- Quién la envía. Se precarga de la sesión pero es editable en el
  -- modal: el correo del remitente es a dónde soporte va a responder.
  remitente_nombre   text,
  remitente_email    text,
  remitente_rol      text,
  -- Estado de gestión — hoy no hay pantalla de listado/triage, existe
  -- para no tener que migrar la tabla cuando la haya.
  estado             text not null default 'enviada'
                       check (estado in ('enviada','en_revision','resuelta')),
  -- 'enviado' | 'fallido' | null (todavía sin resolver). Lo escribe el
  -- navegador tras llamar a /api/enviar-correo.
  correo_estado      text,
  created_by         uuid references auth.users (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index if not exists pqrs_establecimiento_id_idx
  on public.pqrs (establecimiento_id, created_at desc);

alter table public.pqrs enable row level security;

-- A diferencia de `correos` (que solo escribe el backend con la Service
-- Role key), una PQRS es contenido que genera el propio usuario para su
-- clínica: puede insertarla y leer las de su establecimiento. Update
-- para un futuro triage; sin delete a propósito (una PQRS enviada es
-- historia, igual que un mensaje al propietario).
drop policy if exists "pqrs_select_member" on public.pqrs;
create policy "pqrs_select_member"
  on public.pqrs for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "pqrs_insert_member" on public.pqrs;
create policy "pqrs_insert_member"
  on public.pqrs for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "pqrs_update_member" on public.pqrs;
create policy "pqrs_update_member"
  on public.pqrs for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));
