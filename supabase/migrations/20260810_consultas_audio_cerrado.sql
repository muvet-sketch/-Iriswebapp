-- ============================================================
-- BORRADOR DE AUDIO: MARCA DE "YA RESUELTO"
-- ============================================================
-- El SOIP transcrito vive en `consultas_audio.resultado`, pero hasta
-- ahora el navegador solo llegaba a él a través de `audioSoipPendiente`
-- (un objeto en localStorage: UN solo hueco y TTL de 8 h). En la
-- práctica eso dejaba el borrador inalcanzable en tres casos normales:
--   • se venció el TTL — consulta grabada de noche, revisada al otro día;
--   • se grabó otro audio encima — el hueco es uno solo;
--   • se abre IRIS desde otro equipo o después de limpiar el navegador.
-- En los tres el .json seguía acá, completo, sin ninguna pantalla que lo
-- mostrara. Ahora el modal consulta esta tabla por mascota, así que el
-- borrador vive donde siempre debió: en la base, no en un navegador.
--
-- Esa consulta necesita saber cuáles borradores ya se resolvieron; sin
-- eso el mismo texto se volvería a ofrecer cada vez que se abre una
-- consulta de ese paciente. `estado` no sirve para esto: lo escribe el
-- puente del PC de la oficina (scripts/transcripcion/puente_iris.py) y
-- su check no admite valores nuevos. Se marca en columnas propias.
--
-- No se borra la fila: queda el rastro de qué borrador se cargó y desde
-- qué audio. Sigue siendo un buzón de trabajo — por eso `consultas_audio`
-- tampoco entra en RESPALDO_TABLAS (ver CLAUDE.md).

alter table public.consultas_audio
  add column if not exists cerrado_at     timestamptz,
  add column if not exists cerrado_motivo text;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'consultas_audio_cerrado_motivo_check'
  ) then
    alter table public.consultas_audio
      add constraint consultas_audio_cerrado_motivo_check
      check (cerrado_motivo is null or cerrado_motivo in ('aplicado', 'descartado'));
  end if;
end $$;

comment on column public.consultas_audio.cerrado_at is
  'Cuándo el navegador dejó de ofrecer este borrador: se cargó en el formulario del Tablero o se descartó a mano. null = todavía se ofrece.';
comment on column public.consultas_audio.cerrado_motivo is
  'aplicado | descartado. Solo para saber qué pasó con el borrador; no cambia ningún permiso.';

-- Índice de la consulta que hace el modal: los borradores vivos de UNA
-- mascota, del más nuevo al más viejo. Parcial porque lo cerrado no se
-- vuelve a mirar nunca.
create index if not exists consultas_audio_vivos_por_mascota_idx
  on public.consultas_audio (mascota_id, created_at desc)
  where cerrado_at is null;
