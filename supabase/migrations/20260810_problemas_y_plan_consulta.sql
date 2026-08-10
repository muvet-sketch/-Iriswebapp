-- ══════════════════════════════════════════════════════════════
-- LISTA DE PROBLEMAS DEL PACIENTE + RECUADRO DEL PLAN
-- ══════════════════════════════════════════════════════════════
-- Dos cosas que hasta ahora no se guardaban en ninguna parte:
--
--   1. La Lista de problemas del Tablero vivía SOLO en memoria
--      (patientData[petKey].problemas) y se perdía al recargar la
--      página. Ahora que el audio de la consulta los crea solo, y
--      priorizados, perderlos en cada refresco los volvería inútiles.
--
--   2. Los exámenes solicitados y la especialidad a la que se remite
--      al paciente se hundían dentro del textarea del Plan, sin quedar
--      consultables ni imprimibles como dato propio.
--
-- El ORDEN de los problemas es información clínica, no presentación:
-- un listado de problemas se lee de arriba hacia abajo y el primero
-- es siempre el que más compromete la vida del paciente. Por eso hay
-- una columna `orden` explícita y no se depende de la posición en un
-- array ni de created_at.

-- ── Problemas del paciente ──────────────────────────────────
-- Cuelga de `mascotas`, no de `consultas`: el problema es del paciente
-- y sobrevive a la consulta que lo detectó. De ahí `consulta_id ... on
-- delete set null` — borrar la consulta de origen no borra el problema.
create table if not exists public.mascota_problemas (
  id                 uuid primary key default gen_random_uuid(),
  establecimiento_id uuid not null references public.establecimientos (id) on delete cascade,
  mascota_id         uuid not null references public.mascotas (id) on delete cascade,
  texto              text not null,
  estado             text not null default 'activo',   -- 'activo' | 'resuelto'
  -- Menor = más arriba = más compromete la vida. Se reescribe con las
  -- flechas ↑↓ del Tablero y lo fija el orden que trae el audio.
  orden              integer not null default 0,
  origen             text,                             -- 'manual' | 'audio'
  -- 'critico' | 'mayor' | 'menor', tal como lo clasificó el audio. Es
  -- informativa (tooltip y orden inicial), no un check: el catálogo
  -- puede crecer y un check obligaría a otra migración para eso.
  gravedad           text,
  consulta_id        uuid references public.consultas (id) on delete set null,
  created_by         uuid references auth.users (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index if not exists mascota_problemas_establecimiento_idx
  on public.mascota_problemas (establecimiento_id);
create index if not exists mascota_problemas_mascota_orden_idx
  on public.mascota_problemas (mascota_id, orden);

alter table public.mascota_problemas enable row level security;

drop policy if exists "mascota_problemas_select_member" on public.mascota_problemas;
create policy "mascota_problemas_select_member" on public.mascota_problemas for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "mascota_problemas_insert_member" on public.mascota_problemas;
create policy "mascota_problemas_insert_member" on public.mascota_problemas for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "mascota_problemas_update_member" on public.mascota_problemas;
create policy "mascota_problemas_update_member" on public.mascota_problemas for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "mascota_problemas_delete_member" on public.mascota_problemas;
create policy "mascota_problemas_delete_member" on public.mascota_problemas for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── Recuadro del Plan terapéutico ───────────────────────────
-- Mismo patrón que `consultas.diagnosticos_presuntivos`: jsonb con una
-- lista de textos, alimentada por el multiselect de chips del Tablero.
-- El modal clásico de edición NO las escribe (igual que los vital_*),
-- así que editar una consulta desde ahí no las pisa a lista vacía.
alter table public.consultas
  add column if not exists examenes_solicitados jsonb not null default '[]'::jsonb;
alter table public.consultas
  add column if not exists especialidades_indicadas jsonb not null default '[]'::jsonb;

-- ── Re-emisión de fusionar_mascotas ─────────────────────────
-- `mascota_problemas` tiene mascota_id, así que va en `c_tablas` o la
-- lista de problemas de la ficha duplicada se pierde con el CASCADE en
-- la próxima unificación, sin ningún error visible.
--
-- OJO: la base de esta re-emisión NO es 20260809_fusionar_mascotas.sql
-- (ese archivo local está desactualizado). En producción ya se habían
-- aplicado, sin que quedara reflejado en este repo, dos migraciones
-- posteriores: `seguimiento_anestesia` (crea `anestesia_mediciones`,
-- ver 20260809_seguimiento_anestesia.sql, agregada junto con esta) y
-- `fusionar_mascotas_incluye_anestesia` (suma esa tabla a `c_tablas`).
-- Re-emitir desde el archivo local viejo habría BORRADO
-- 'anestesia_mediciones' de `c_tablas` en silencio — la próxima fusión
-- de fichas habría dejado las mediciones de anestesia de la ficha
-- duplicada huérfanas. Esta versión sale de
-- `pg_get_functiondef('fusionar_mascotas'::regproc)` leído en vivo del
-- proyecto de producción, diffeada línea a línea contra esa salida:
-- los únicos cambios sobre lo que ya corre en producción son
-- 'mascota_problemas' en `c_tablas` y los dos pasos de renumeración de
-- `orden` marcados con comentario propio abajo.

create or replace function public.fusionar_mascotas(
  p_principal_id uuid,
  p_duplicada_id uuid,
  p_datos jsonb default '{}'::jsonb,
  p_relacion_contacto text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c_tablas constant text[] := array[
    'consultas', 'formulas_medicas', 'documentos', 'examenes', 'vacunaciones',
    'desparasitaciones', 'cirugias', 'anestesia_mediciones', 'hospitalizaciones',
    'seguimientos', 'remisiones', 'peluquerias', 'guarderias', 'tareas_pendientes',
    'mensajes', 'consultas_audio', 'mascota_problemas'
  ];
  v_pri        public.mascotas;
  v_dup        public.mascotas;
  v_estab      uuid;
  v_resp       uuid;
  v_tabla      text;
  v_n          int;
  v_mov        jsonb := '{}'::jsonb;
  v_peso_hist  jsonb;
  v_snapshot   jsonb;
  v_fusion_id  uuid;
begin
  if p_principal_id is null or p_duplicada_id is null then
    raise exception 'Faltan las dos fichas a unificar';
  end if;
  if p_principal_id = p_duplicada_id then
    raise exception 'No se puede unificar una ficha consigo misma';
  end if;

  select * into v_pri from public.mascotas where id = p_principal_id;
  if not found then raise exception 'La ficha que se conserva ya no existe'; end if;
  select * into v_dup from public.mascotas where id = p_duplicada_id;
  if not found then raise exception 'La ficha duplicada ya no existe'; end if;

  v_estab := v_pri.establecimiento_id;
  if v_dup.establecimiento_id <> v_estab then
    raise exception 'Las dos fichas tienen que ser de la misma clinica';
  end if;
  if not public.user_is_member_of(v_estab) then
    raise exception 'No tienes acceso a esta clinica';
  end if;

  v_resp := coalesce(nullif(p_datos ->> 'propietario_id', '')::uuid, v_pri.propietario_id);
  perform 1 from public.propietarios
   where id = v_resp and establecimiento_id = v_estab
     and coalesce(red_vinculado, true);
  if not found then
    raise exception 'El tutor responsable elegido no existe en esta clinica o esta sin vincular';
  end if;

  select coalesce(jsonb_agg(e order by e ->> 'fechaISO'), '[]'::jsonb)
    into v_peso_hist
    from (
      select distinct e from jsonb_array_elements(
        coalesce(v_pri.peso_historico, '[]'::jsonb) || coalesce(v_dup.peso_historico, '[]'::jsonb)
      ) e
    ) s;

  update public.mascotas set
    propietario_id      = v_resp,
    nombre              = coalesce(nullif(btrim(p_datos ->> 'nombre'), ''), v_pri.nombre),
    chip                = case when p_datos ? 'chip'                then nullif(btrim(p_datos ->> 'chip'), '')                else chip                end,
    especie             = case when p_datos ? 'especie'             then nullif(btrim(p_datos ->> 'especie'), '')             else especie             end,
    raza                = case when p_datos ? 'raza'                then nullif(btrim(p_datos ->> 'raza'), '')                else raza                end,
    color               = case when p_datos ? 'color'               then nullif(btrim(p_datos ->> 'color'), '')               else color               end,
    genero              = case when p_datos ? 'genero'              then nullif(btrim(p_datos ->> 'genero'), '')              else genero              end,
    talla               = case when p_datos ? 'talla'               then nullif(btrim(p_datos ->> 'talla'), '')               else talla               end,
    estado_reproductivo = case when p_datos ? 'estado_reproductivo' then nullif(btrim(p_datos ->> 'estado_reproductivo'), '') else estado_reproductivo end,
    peso                = case when p_datos ? 'peso'                then nullif(btrim(p_datos ->> 'peso'), '')                else peso                end,
    alimentacion        = case when p_datos ? 'alimentacion'        then nullif(btrim(p_datos ->> 'alimentacion'), '')        else alimentacion        end,
    frecuencia_bano     = case when p_datos ? 'frecuencia_bano'     then nullif(btrim(p_datos ->> 'frecuencia_bano'), '')     else frecuencia_bano     end,
    temperamento        = case when p_datos ? 'temperamento'        then nullif(btrim(p_datos ->> 'temperamento'), '')        else temperamento        end,
    antecedentes        = case when p_datos ? 'antecedentes'        then nullif(btrim(p_datos ->> 'antecedentes'), '')        else antecedentes        end,
    alergias            = case when p_datos ? 'alergias'            then nullif(btrim(p_datos ->> 'alergias'), '')            else alergias            end,
    foto_path           = case when p_datos ? 'foto_path'           then nullif(btrim(p_datos ->> 'foto_path'), '')           else foto_path           end,
    fecha_nacimiento    = case
                            when p_datos ? 'fecha_nacimiento' then
                              case when (p_datos ->> 'fecha_nacimiento') ~ '^\d{4}-\d{2}-\d{2}$'
                                   then (p_datos ->> 'fecha_nacimiento')::date else null end
                            else fecha_nacimiento
                          end,
    animal_servicio     = case when p_datos ? 'animal_servicio' then coalesce((p_datos ->> 'animal_servicio')::boolean, false) else animal_servicio end,
    fallecido           = case when p_datos ? 'fallecido'       then coalesce((p_datos ->> 'fallecido')::boolean, false)       else fallecido       end,
    peso_historico      = v_peso_hist,
    red_mascota_id      = coalesce(red_mascota_id, v_dup.red_mascota_id),
    updated_at          = now()
   where id = p_principal_id;

  -- Los `orden` de las dos listas de problemas colisionan: las dos empiezan
  -- en 0. Hay que correr los de la duplicada DETRAS de los de la principal
  -- ANTES de moverlos — despues del move las dos listas son indistinguibles
  -- (todas las filas quedan con mascota_id = principal) y el primer problema,
  -- que es el que mas compromete la vida, dejaria de ser el primero.
  update public.mascota_problemas
     set orden = orden + coalesce(
           (select max(orden) + 1 from public.mascota_problemas where mascota_id = p_principal_id), 0)
   where mascota_id = p_duplicada_id;

  foreach v_tabla in array c_tablas loop
    execute format('update public.%I set mascota_id = $1 where mascota_id = $2', v_tabla)
      using p_principal_id, p_duplicada_id;
    get diagnostics v_n = row_count;
    if v_n > 0 then v_mov := v_mov || jsonb_build_object(v_tabla, v_n); end if;
  end loop;

  -- Ya juntas, se renumeran 1..N para que la secuencia quede densa (las
  -- flechas del front intercambian `orden` entre vecinos y con huecos el
  -- intercambio sigue funcionando, pero la lista es mas facil de leer asi).
  with ordenados as (
    select id, row_number() over (order by orden, created_at) as rn
      from public.mascota_problemas
     where mascota_id = p_principal_id
  )
  update public.mascota_problemas p
     set orden = o.rn, updated_at = now()
    from ordenados o
   where p.id = o.id and p.orden <> o.rn;

  update public.red_solicitudes set mascota_solicitante_id = p_principal_id
   where mascota_solicitante_id = p_duplicada_id;
  update public.red_solicitudes set mascota_destino_id = p_principal_id
   where mascota_destino_id = p_duplicada_id;

  update public.agenda_eventos set pet_key = v_pri.pet_key
   where establecimiento_id = v_estab and pet_key = v_dup.pet_key;
  get diagnostics v_n = row_count;
  if v_n > 0 then v_mov := v_mov || jsonb_build_object('agenda_eventos', v_n); end if;

  update public.eventos_seguimiento set pet_key = v_pri.pet_key
   where establecimiento_id = v_estab and pet_key = v_dup.pet_key;
  get diagnostics v_n = row_count;
  if v_n > 0 then v_mov := v_mov || jsonb_build_object('eventos_seguimiento', v_n); end if;

  update public.mascota_contactos set mascota_id = p_principal_id
   where mascota_id = p_duplicada_id
     and propietario_id not in (
       select propietario_id from public.mascota_contactos where mascota_id = p_principal_id
     );
  delete from public.mascota_contactos where mascota_id = p_duplicada_id;

  insert into public.mascota_contactos (establecimiento_id, mascota_id, propietario_id, relacion, created_by)
  select v_estab, p_principal_id, prop, nullif(btrim(p_relacion_contacto), ''), auth.uid()
    from (select unnest(array[v_pri.propietario_id, v_dup.propietario_id]) as prop) s
   where prop is not null and prop <> v_resp
  on conflict (mascota_id, propietario_id)
    do update set relacion = coalesce(excluded.relacion, public.mascota_contactos.relacion);

  delete from public.mascota_contactos
   where mascota_id = p_principal_id and propietario_id = v_resp;

  v_snapshot := to_jsonb(v_dup);

  delete from public.mascotas where id = p_duplicada_id;

  insert into public.mascota_fusiones (
    establecimiento_id, mascota_principal_id, mascota_eliminada_id, mascota_eliminada_nombre,
    snapshot, propietario_responsable, propietario_secundario, registros_movidos, ejecutado_por
  ) values (
    v_estab, p_principal_id, p_duplicada_id, v_dup.nombre,
    v_snapshot, v_resp,
    case when v_dup.propietario_id <> v_resp then v_dup.propietario_id else v_pri.propietario_id end,
    v_mov, auth.uid()
  ) returning id into v_fusion_id;

  return jsonb_build_object(
    'ok', true,
    'fusion_id', v_fusion_id,
    'mascota_id', p_principal_id,
    'pet_key', v_pri.pet_key,
    'movidos', v_mov,
    'total_movidos', (select coalesce(sum((value)::int), 0) from jsonb_each_text(v_mov))
  );
end;
$$;

-- Se re-emite el bloque de privilegios: `create or replace` los conserva,
-- pero dejarlo escrito acá evita que un proyecto reconstruido desde las
-- migraciones se quede sin él (ver la sección RED IRIS del CLAUDE.md).
revoke execute on function public.fusionar_mascotas(uuid, uuid, jsonb, text) from public, anon;
grant  execute on function public.fusionar_mascotas(uuid, uuid, jsonb, text) to authenticated;
