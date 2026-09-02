-- Configuración de la veterinaria: pestañas "Localización y servicios" y
-- "Agenda y disponibilidad" (Admin > Configuración de la veterinaria).
-- Todas las columnas son nullable o traen default: cambio aditivo, no
-- destructivo. La policy establecimientos_update_admin (a nivel de fila,
-- user_is_admin_of(id)) ya cubre estas columnas sin cambios, y la query de
-- sesión (`memberships` con `establecimientos(*)`) las trae sola.

-- ── Localización y servicios ──────────────────────────────────────
-- `ciudad` ya existe en la tabla base, se reutiliza.
alter table public.establecimientos add column if not exists direccion text;
alter table public.establecimientos add column if not exists departamento text;
alter table public.establecimientos add column if not exists pais text;
alter table public.establecimientos add column if not exists servicios_ofrecidos jsonb not null default '[]'::jsonb;
alter table public.establecimientos add column if not exists especies_atendidas jsonb not null default '[]'::jsonb;
alter table public.establecimientos add column if not exists precio_consulta numeric;
alter table public.establecimientos add column if not exists moneda text;
alter table public.establecimientos add column if not exists zona_horaria text;

-- ── Agenda y disponibilidad ───────────────────────────────────────
-- horario_atencion: array de bloques
--   [{ "dias": ["lun","mar","mie","jue","vie"], "apertura": "08:00", "cierre": "18:00" }]
-- duracion_cita_min alimenta el default de "Hora de fin" del modal de
-- evento de Agenda; horario_atencion define el rango de la grilla de
-- Disponibilidad; prevenir_solapamientos hace que guardarEventoAgenda()
-- bloquee (no solo advierta) al chocar con otro evento del mismo encargado.
alter table public.establecimientos add column if not exists horario_atencion jsonb not null default '[]'::jsonb;
alter table public.establecimientos add column if not exists duracion_cita_min integer;
alter table public.establecimientos add column if not exists prevenir_solapamientos boolean not null default false;
