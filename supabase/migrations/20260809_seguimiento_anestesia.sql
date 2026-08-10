-- ══════════════════════════════════════════════════════════════
-- BACKFILL: SEGUIMIENTO DE ANESTESIA (drift entre producción y repo)
-- ══════════════════════════════════════════════════════════════
-- Este archivo NO se aplica a producción — ya está aplicado ahí desde la
-- migración `seguimiento_anestesia` (versión 20260809225725, seguida de
-- `fusionar_mascotas_incluye_anestesia`, versión 20260809225803). Se agrega
-- acá para que el repo vuelva a ser fuente de verdad reconstruible: alguien
-- corriendo `supabase db reset` sobre este árbol de migraciones terminaba
-- con una base sin `anestesia_mediciones`, mientras la de producción sí la
-- tiene y `fusionar_mascotas` ya la referencia en `c_tablas`.
--
-- Se detectó al preparar 20260810_problemas_y_plan_consulta.sql: re-emitir
-- `fusionar_mascotas` copiando el `20260809_fusionar_mascotas.sql` local
-- (que no conoce esta tabla) habría borrado 'anestesia_mediciones' de
-- `c_tablas` en silencio. La definición real se leyó en vivo con
-- `pg_get_functiondef` contra el proyecto de producción antes de tocar nada.
--
-- Estructura, índices y policies reconstruidos exactamente desde
-- information_schema / pg_policy / pg_indexes / pg_constraint de la base
-- real — no son un diseño nuevo, es la foto de lo que ya existe.
create table if not exists public.anestesia_mediciones (
  id                     uuid primary key default gen_random_uuid(),
  establecimiento_id     uuid not null references public.establecimientos (id) on delete cascade,
  mascota_id             uuid not null references public.mascotas (id) on delete cascade,
  cirugia_id             uuid not null references public.cirugias (id) on delete cascade,
  fecha                  timestamp not null,
  fc                     integer,
  fr                     integer,
  pas                    integer,
  pad                    integer,
  pam                    integer,
  spo2                   numeric,
  tc                     numeric,
  etco2                  integer,
  observaciones          text,
  registrado_por         integer,
  registrado_por_nombre  text,
  created_by             uuid references auth.users (id) on delete set null,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

create index if not exists anestesia_mediciones_establecimiento_id_idx
  on public.anestesia_mediciones (establecimiento_id);
create index if not exists anestesia_mediciones_mascota_id_idx
  on public.anestesia_mediciones (mascota_id);
create index if not exists anestesia_mediciones_cirugia_id_idx
  on public.anestesia_mediciones (cirugia_id, fecha);

alter table public.anestesia_mediciones enable row level security;

drop policy if exists "anestesia_mediciones_select_member" on public.anestesia_mediciones;
create policy "anestesia_mediciones_select_member" on public.anestesia_mediciones for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "anestesia_mediciones_insert_member" on public.anestesia_mediciones;
create policy "anestesia_mediciones_insert_member" on public.anestesia_mediciones for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "anestesia_mediciones_update_member" on public.anestesia_mediciones;
create policy "anestesia_mediciones_update_member" on public.anestesia_mediciones for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "anestesia_mediciones_delete_member" on public.anestesia_mediciones;
create policy "anestesia_mediciones_delete_member" on public.anestesia_mediciones for delete
  using (public.user_is_member_of(establecimiento_id));

-- La re-emisión de `fusionar_mascotas` que suma esta tabla a `c_tablas`
-- (migración real `fusionar_mascotas_incluye_anestesia`) no se repite acá
-- por separado: 20260810_problemas_y_plan_consulta.sql ya re-emite la
-- función completa con 'anestesia_mediciones' Y 'mascota_problemas' juntos,
-- reflejando el estado final real. Repetir un paso intermedio acá solo
-- agregaría una versión de la función que nunca existió tal cual sola en
-- el historial de este repo.
