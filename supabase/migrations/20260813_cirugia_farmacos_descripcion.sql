-- Cirugías/procedimientos: el formulario reemplaza "Notas pre-operatorias"
-- (texto libre) por tres listas rápidas de fármacos —premedicación,
-- pre-anestesia y anestesia—, cada una con nombre+dosis por fila, y suma
-- "Descripción quirúrgica". `notas_preop` NO se borra ni se deja de leer:
-- los registros previos a esta migración la siguen mostrando como
-- respaldo (ver cirugiaViewContentHTML en index.html), solo que el
-- formulario ya no escribe ahí.
--
-- El campo "Estado" también salió del formulario, pero la columna
-- `estado` no cambia: pasó a controlarse con acciones del menú "..." de
-- la fila (cambiarEstadoCirugia() en index.html), no con un select.
alter table public.cirugias
  add column if not exists premedicacion jsonb not null default '[]'::jsonb,
  add column if not exists preanestesia jsonb not null default '[]'::jsonb,
  add column if not exists medicamentos_anestesia jsonb not null default '[]'::jsonb,
  add column if not exists descripcion_quirurgica text;
