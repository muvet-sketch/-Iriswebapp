-- ============================================================
-- Agenda > Eventos — persistencia real de EVENTOS_SEGUIMIENTO
--
-- Era el último array de Agenda que seguía viviendo solo en memoria
-- (junto a DISPONIBILIDAD_MEDICOS). Consecuencia visible: registrar una
-- vacunación con "próxima vacunación" creaba el recordatorio, y al
-- refrescar la página Agenda > Eventos aparecía vacío. Para una clínica
-- que no es la demo era peor todavía: resetMockDataForClinic() vaciaba
-- el array en cada login, así que la lista arrancaba en cero siempre.
--
-- El comentario que justificaba dejarlo mock ("es un derivado de
-- Vacunaciones/Desparasitaciones/Seguimientos, que tampoco persisten")
-- quedó obsoleto: esos tres módulos ya persisten desde hace varias
-- iteraciones, así que el derivado era lo único que se perdía.
--
-- Notas de diseño:
--
--  * fecha_sugerida es `date`, no timestamp: el front la maneja como
--    cadena local ingenua 'YYYY-MM-DD' y la compara como string contra
--    los filtros de rango y contra "hoy" (ver eventoSeguimientoEstaVencido
--    e isoDateOnly en index.html). Mismo criterio que movimientos.fecha.
--
--  * pet_key (no mascota_id), igual que agenda_eventos.pet_key: el
--    evento referencia la clave con la que patientData indexa a la
--    mascota, y puede quedar sin resolver si esa mascota ya no existe.
--
--  * agenda_evento_id apunta al evento de calendario que se creó con la
--    acción "Agendar" de la tabla. `on delete set null` porque borrar la
--    cita no debe borrar el recordatorio que la originó — solo lo
--    desvincula.
-- ============================================================

create table if not exists public.eventos_seguimiento (
  id                 uuid primary key default gen_random_uuid(),
  establecimiento_id uuid not null references public.establecimientos (id) on delete cascade,
  fecha_sugerida     date not null,
  propietario        text,
  pet_key            text,
  tipo_evento        text not null,
  origen             text,
  estado             text not null default 'pendiente',
  agenda_evento_id   uuid references public.agenda_eventos (id) on delete set null,
  created_by         uuid references auth.users (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index if not exists eventos_seguimiento_establecimiento_id_idx
  on public.eventos_seguimiento (establecimiento_id);

alter table public.eventos_seguimiento enable row level security;

drop policy if exists "eventos_seguimiento_select_member" on public.eventos_seguimiento;
create policy "eventos_seguimiento_select_member"
  on public.eventos_seguimiento for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "eventos_seguimiento_insert_member" on public.eventos_seguimiento;
create policy "eventos_seguimiento_insert_member"
  on public.eventos_seguimiento for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "eventos_seguimiento_update_member" on public.eventos_seguimiento;
create policy "eventos_seguimiento_update_member"
  on public.eventos_seguimiento for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "eventos_seguimiento_delete_member" on public.eventos_seguimiento;
create policy "eventos_seguimiento_delete_member"
  on public.eventos_seguimiento for delete
  using (public.user_is_member_of(establecimiento_id));
