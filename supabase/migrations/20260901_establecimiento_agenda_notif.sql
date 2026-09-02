-- "Agenda y disponibilidad" (Admin > Configuración de la veterinaria):
-- bloques "Notificaciones" y "Solicitudes de agendamiento". Complementa a
-- 20260901_establecimiento_config.sql. Aditivo, no destructivo;
-- establecimientos_update_admin y la query de sesión (`establecimientos(*)`)
-- ya los cubren.

-- ── Notificaciones ────────────────────────────────────────────────
-- notif_email_evento: al crear/editar/eliminar un evento de Agenda se abre
-- la notificación mock #agenda-notif-modal. Con este flag en false, no.
alter table public.establecimientos add column if not exists notif_email_evento boolean not null default true;
-- recordatorios: [{ "cantidad": 1, "unidad": "dias"|"horas", "canales": ["email","whatsapp","sms"] }]
-- El de mayor lead time alimenta el cálculo mock de recordatorio_24h en
-- guardarEventoAgenda() (ver getRecordatorioLeadMs()). No hay envío real.
alter table public.establecimientos add column if not exists recordatorios jsonb not null default '[]'::jsonb;

-- ── Solicitudes de agendamiento ──────────────────────────────────
-- Por ahora SOLO se persiste: IRIS todavía no tiene una bandeja de
-- solicitudes de agendamiento que consuma estos valores.
alter table public.establecimientos add column if not exists solicitudes_recibir boolean not null default false;
alter table public.establecimientos add column if not exists solicitudes_antelacion_min integer;
