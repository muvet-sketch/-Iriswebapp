-- ============================================================
-- Ficha de mascota — Temperamento / Antecedentes / Alergias
--
-- Tres campos de texto libre nuevos, mismo criterio que
-- alimentacion/frecuencia_bano: editables desde "Editar mascota"
-- (y desde "Registrar mascota"), se muestran en la tarjeta
-- "Contexto histórico" del Tablero de trabajo junto al motivo de la
-- última consulta (ese último dato no es columna nueva, sale de
-- consultas.motivo). Nullable, sin backfill — mascotas existentes
-- quedan en null hasta que alguien los diligencie.
-- ============================================================

alter table public.mascotas add column if not exists temperamento text;
alter table public.mascotas add column if not exists antecedentes text;
alter table public.mascotas add column if not exists alergias    text;
