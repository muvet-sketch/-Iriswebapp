-- ============================================================
-- Documentos — proceso de firma real + formatos propios de la clínica
--
-- Dos huecos del módulo Documentos que este cambio cierra:
--
--  1. FIRMA. La tabla ya tenía estado 'firmado' y las columnas
--     firma_nombre/_fecha/_hora, pero nada en la app las escribía: el
--     documento se quedaba para siempre en 'borrador' o 'pendiente'.
--     Ahora el tutor firma en pantalla (mouse o dedo) sobre un pad y el
--     trazo se guarda en firma_imagen como PNG en data URL.
--
--     La imagen va en la fila y NO en Storage a propósito: pesa unos
--     pocos KB (el canvas se recorta al trazo antes de exportarlo) y así
--     la firma se pinta en el modal "Ver", en el PDF de "Imprimir" y en
--     el PDF que se sube al bucket `pdfs`, sin depender de una URL
--     firmada que expira ni de que html2canvas logre traer una imagen de
--     otro origen.
--
--  2. FORMATOS. "+ Crear nuevo formato" era un placeholder que solo
--     mostraba un toast, y los 3 formatos existentes seguían
--     hardcodeados en index.html. Los que crea cada clínica viven ahora
--     en documento_plantillas. Los de fábrica NO se copian acá: existen
--     en toda clínica y la UI concatena las dos listas, mismo criterio
--     que VACUNAS_CATALOGO_BASE + catalogos_custom.
--
-- Nullable y sin backfill: los documentos y las clínicas que ya existen
-- quedan exactamente como estaban.
-- ============================================================

alter table public.documentos add column if not exists firma_documento text;
alter table public.documentos add column if not exists firma_imagen    text;

-- Borrar un formato no toca los documentos ya creados con él: cada
-- documento guarda su propio contenido_html y el nombre del formato como
-- texto plano en `tipo` (no hay FK a propósito).
create table if not exists public.documento_plantillas (
  id                 uuid primary key default gen_random_uuid(),
  establecimiento_id uuid not null references public.establecimientos (id) on delete cascade,
  nombre             text not null,
  contenido_html     text,
  created_by         uuid references auth.users (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (establecimiento_id, nombre)
);

create index if not exists documento_plantillas_establecimiento_id_idx
  on public.documento_plantillas (establecimiento_id);

alter table public.documento_plantillas enable row level security;

drop policy if exists "documento_plantillas_select_member" on public.documento_plantillas;
create policy "documento_plantillas_select_member"
  on public.documento_plantillas for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "documento_plantillas_insert_member" on public.documento_plantillas;
create policy "documento_plantillas_insert_member"
  on public.documento_plantillas for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "documento_plantillas_update_member" on public.documento_plantillas;
create policy "documento_plantillas_update_member"
  on public.documento_plantillas for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "documento_plantillas_delete_member" on public.documento_plantillas;
create policy "documento_plantillas_delete_member"
  on public.documento_plantillas for delete
  using (public.user_is_member_of(establecimiento_id));
