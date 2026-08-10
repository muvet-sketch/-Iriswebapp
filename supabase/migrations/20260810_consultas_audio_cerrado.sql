-- ══════════════════════════════════════════════════════════════
-- BACKFILL: consultas_audio.cerrado_at / cerrado_motivo (drift)
-- ══════════════════════════════════════════════════════════════
-- No se aplica a producción — ya está ahí (migración real
-- `consultas_audio_cerrado`, versión 20260810005308), detectada al revisar
-- el estado real de `consultas_audio` antes de aplicar
-- 20260810_problemas_y_plan_consulta.sql. Se agrega acá solo para que el
-- repo vuelva a reconstruirse fiel a producción; el front de esta rama no
-- referencia estas dos columnas todavía.
alter table public.consultas_audio
  add column if not exists cerrado_at     timestamptz;
alter table public.consultas_audio
  add column if not exists cerrado_motivo text;

alter table public.consultas_audio
  drop constraint if exists consultas_audio_cerrado_motivo_check;
alter table public.consultas_audio
  add constraint consultas_audio_cerrado_motivo_check
  check (cerrado_motivo is null or cerrado_motivo = any (array['aplicado', 'descartado']));
