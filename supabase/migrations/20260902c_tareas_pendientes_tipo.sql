-- Tareas Pendientes: "Tipo de tarea" (Enviar documentos, Agendar cita con
-- especialista, Agendar ecografía, Agendar rayos X, …). Es un catálogo FIJO
-- del front (TAREA_TIPOS en index.html), no un catálogo ampliable como el de
-- Vacunas/Desparasitaciones: su valor está en poder FILTRAR por él en la
-- nueva vista Agenda > Tareas, y un catálogo libre por clínica haría que ese
-- filtro dejara de ser comparable.
--
-- La columna es nullable a propósito y no hay backfill: las tareas creadas
-- antes de esta migración no tienen tipo y se muestran como "Sin tipo".
-- Tampoco lleva `check`: si mañana se agrega un tipo al catálogo del front,
-- una restricción acá obligaría a una migración por cada valor nuevo.
alter table public.tareas_pendientes
  add column if not exists tipo text;
