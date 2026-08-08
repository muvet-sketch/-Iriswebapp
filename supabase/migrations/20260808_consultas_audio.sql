-- ============================================================
-- GRABACIÓN DE CONSULTA DESDE EL NAVEGADOR
-- ============================================================
-- Cierra el flujo audio → Whisper → LLM → formulario sin que nadie
-- tenga que mover archivos a mano. Antes el veterinario grababa con el
-- celular, alguien dejaba el audio en la carpeta de Drive y después
-- había que buscar el .json resultante y cargarlo con un <input file>.
--
-- Ahora el Tablero de trabajo graba con el micrófono del equipo, sube
-- el audio acá, y el PC de la oficina (scripts/transcripcion/puente_iris.py)
-- lo baja a la carpeta "Audios Consultas" — que está sincronizada con
-- Drive, así que el audio queda igual en Drive —, lo transcribe con el
-- vigilante de siempre y escribe el SOIP extraído de vuelta en
-- `resultado`. El navegador consulta esa fila hasta que quede en
-- 'listo'.
--
-- Esta tabla es un BUZÓN de trabajo, no historia clínica: nada de lo
-- que hay acá se guarda en la consulta hasta que el veterinario pulsa
-- "Finalizar consulta" en el Tablero. Por eso las filas se pueden
-- borrar sin perder nada clínico.

create table if not exists public.consultas_audio (
  id                  uuid primary key default gen_random_uuid(),
  establecimiento_id  uuid not null references public.establecimientos (id) on delete cascade,
  -- La mascota puede desaparecer (on delete set null) sin que se pierda
  -- el registro del trabajo pendiente: el puente necesita poder cerrar
  -- la fila igual. `pet_key`/`paciente_nombre` se guardan aparte para
  -- que el nombre del archivo en Drive siga siendo legible.
  mascota_id          uuid references public.mascotas (id) on delete set null,
  pet_key             text,
  paciente_nombre     text,
  -- Ruta DENTRO del bucket privado `audios-consultas` (no una URL), mismo
  -- criterio que formularios.pdf_url con el bucket `pdfs`.
  audio_path          text not null,
  -- Nombre con el que el audio aterriza en la carpeta vigilada. Lo arma
  -- el navegador con el prefijo `IRIS-<id>__` porque el id del registro
  -- viaja por el pipeline dentro del nombre del archivo: vigilante.py y
  -- extraer_soip.py conservan el stem, así que el .json final de
  -- Consultas/ se puede volver a asociar a esta fila sin tocar esos dos
  -- scripts.
  audio_nombre        text not null,
  audio_mime          text,
  duracion_seg        integer,
  tamano_bytes        bigint,
  estado              text not null default 'subido'
                      check (estado in ('subido', 'transcribiendo', 'listo', 'error')),
  -- El .json de Consultas/ tal cual, con la misma estructura que ya leía
  -- el <input file> del modal (campos/evidencia_vitales/examen_sistemas/…).
  resultado           jsonb,
  error_mensaje       text,
  created_by          uuid references auth.users (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index if not exists consultas_audio_establecimiento_id_idx on public.consultas_audio (establecimiento_id);
create index if not exists consultas_audio_mascota_id_idx on public.consultas_audio (mascota_id);
-- El puente pregunta por estado en cada vuelta del ciclo.
create index if not exists consultas_audio_estado_idx on public.consultas_audio (estado);

alter table public.consultas_audio enable row level security;

drop policy if exists "consultas_audio_select_member" on public.consultas_audio;
create policy "consultas_audio_select_member"
  on public.consultas_audio for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "consultas_audio_insert_member" on public.consultas_audio;
create policy "consultas_audio_insert_member"
  on public.consultas_audio for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "consultas_audio_update_member" on public.consultas_audio;
create policy "consultas_audio_update_member"
  on public.consultas_audio for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "consultas_audio_delete_member" on public.consultas_audio;
create policy "consultas_audio_delete_member"
  on public.consultas_audio for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── STORAGE: bucket `audios-consultas` ───────────────────────
-- Privado: es la voz del tutor y del veterinario hablando de un
-- paciente real. Misma convención de carpeta por usuario que `pdfs`
-- ("<user_id>/..."), que ya está probada — quien lee el audio para
-- transcribirlo es el puente del PC de la oficina, que usa la service
-- role key y no pasa por estas policies.
--
-- Límite de 50 MB por archivo: es el tope del plan y conviene que
-- falle en la subida con un mensaje claro y no a mitad de camino. Con
-- Opus mono a 32 kbps (lo que graba el navegador) eso son ~3,5 horas
-- de consulta.
insert into storage.buckets (id, name, public, file_size_limit)
values ('audios-consultas', 'audios-consultas', false, 52428800)
on conflict (id) do update set file_size_limit = excluded.file_size_limit;

drop policy if exists "audios_consultas_insert_own_folder" on storage.objects;
create policy "audios_consultas_insert_own_folder"
  on storage.objects for insert
  with check (
    bucket_id = 'audios-consultas'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "audios_consultas_select_own_folder" on storage.objects;
create policy "audios_consultas_select_own_folder"
  on storage.objects for select
  using (
    bucket_id = 'audios-consultas'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "audios_consultas_delete_own_folder" on storage.objects;
create policy "audios_consultas_delete_own_folder"
  on storage.objects for delete
  using (
    bucket_id = 'audios-consultas'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
