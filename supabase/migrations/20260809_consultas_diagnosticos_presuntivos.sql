-- Diagnósticos presuntivos de la consulta (chips del riel "I" del SOIP).
--
-- La columna ya estaba declarada en supabase/schema.sql (create table +
-- add column if not exists) pero nunca se aplicó a la base viva: no había
-- archivo de migración. Resultado: `guardarConsulta()` mandaba
-- `diagnosticos_presuntivos` en el payload y PostgREST rechazaba el INSERT
-- COMPLETO con 400/PGRST204 ("Could not find the column ... in the schema
-- cache") — no se podía guardar ninguna consulta.
--
-- jsonb (array de strings) y no text[]: mismo criterio que
-- consultas.examen_fisico, que ya guarda su lista así.
-- `not null default '[]'` para que las consultas anteriores queden con
-- lista vacía en vez de null (el front hace Array.isArray(...) sobre este
-- campo al reconstruir desde Supabase, ver construirConsultaDesdeFila).
alter table public.consultas
  add column if not exists diagnosticos_presuntivos jsonb not null default '[]'::jsonb;
