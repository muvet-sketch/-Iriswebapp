-- ══════════════════════════════════════════════════════════════
-- UNIFICAR MASCOTAS DUPLICADAS
-- ══════════════════════════════════════════════════════════════
-- Caso real: el mismo animal se registra dos veces porque lo llevó
-- primero una persona y después otra (distinta cédula, distinto tutor).
-- No es un error de la app — es cómo funciona una clínica. Al unificar,
-- uno de los dos tutores queda como RESPONSABLE de la mascota y el otro
-- como CONTACTO SECUNDARIO, y las dos historias clínicas pasan a ser una.
--
-- La fila duplicada se BORRA (decisión explícita del cliente). Por eso:
--   1. La operación entera es UNA transacción — o se mueve todo o nada.
--   2. Antes de borrar se guarda la fila completa y el conteo de lo
--      movido en `mascota_fusiones`, que es un log de auditoría: si
--      alguien unifica dos perros distintos que se llaman igual, ahí
--      queda registrado qué había y quién lo hizo.
--
-- Por qué `security definer` y no invoker: `mensajes` y `red_solicitudes`
-- NO tienen policy de UPDATE (un mensaje enviado no se edita, y las
-- solicitudes de la red solo las mueven sus propias RPC). Con los
-- permisos del usuario, esos UPDATE afectarían 0 filas EN SILENCIO y los
-- mensajes se irían por el CASCADE al borrar la ficha duplicada. La
-- contrapartida es que la función valida la membresía ella misma.

-- ── Contactos secundarios de una mascota ────────────────────
-- Tabla y no una columna en `mascotas`: una mascota puede terminar con
-- más de un contacto (dueño anterior, cuidador, familiar), y cada uno es
-- un `propietarios` real —con su documento, su celular y su propia
-- facturación— no un texto suelto.
create table if not exists public.mascota_contactos (
  id                 uuid primary key default gen_random_uuid(),
  establecimiento_id uuid not null references public.establecimientos (id) on delete cascade,
  mascota_id         uuid not null references public.mascotas (id) on delete cascade,
  propietario_id     uuid not null references public.propietarios (id) on delete cascade,
  relacion           text,
  nota               text,
  created_by         uuid references auth.users (id) on delete set null,
  created_at         timestamptz not null default now(),
  unique (mascota_id, propietario_id)
);

create index if not exists mascota_contactos_mascota_idx on public.mascota_contactos (mascota_id);
create index if not exists mascota_contactos_establecimiento_idx on public.mascota_contactos (establecimiento_id);

alter table public.mascota_contactos enable row level security;

drop policy if exists "mascota_contactos_select_member" on public.mascota_contactos;
create policy "mascota_contactos_select_member" on public.mascota_contactos for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "mascota_contactos_insert_member" on public.mascota_contactos;
create policy "mascota_contactos_insert_member" on public.mascota_contactos for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "mascota_contactos_update_member" on public.mascota_contactos;
create policy "mascota_contactos_update_member" on public.mascota_contactos for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "mascota_contactos_delete_member" on public.mascota_contactos;
create policy "mascota_contactos_delete_member" on public.mascota_contactos for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── Auditoría de fusiones ───────────────────────────────────
-- Es lo único que queda de la ficha borrada. Sin policies de escritura a
-- propósito: solo la escribe fusionar_mascotas() (definer). Un log que
-- el usuario pudiera editar no sirve de log.
create table if not exists public.mascota_fusiones (
  id                        uuid primary key default gen_random_uuid(),
  establecimiento_id        uuid not null references public.establecimientos (id) on delete cascade,
  mascota_principal_id      uuid references public.mascotas (id) on delete set null,
  mascota_eliminada_id      uuid not null,
  mascota_eliminada_nombre  text,
  snapshot                  jsonb not null,   -- la fila completa que se borró
  propietario_responsable   uuid,
  propietario_secundario    uuid,
  registros_movidos         jsonb not null default '{}'::jsonb,
  ejecutado_por             uuid references auth.users (id) on delete set null,
  created_at                timestamptz not null default now()
);

create index if not exists mascota_fusiones_establecimiento_idx
  on public.mascota_fusiones (establecimiento_id, created_at desc);

alter table public.mascota_fusiones enable row level security;

drop policy if exists "mascota_fusiones_select_member" on public.mascota_fusiones;
create policy "mascota_fusiones_select_member" on public.mascota_fusiones for select
  using (public.user_is_member_of(establecimiento_id));

-- ── La fusión ───────────────────────────────────────────────
-- p_datos trae los valores YA RESUELTOS de la ficha que queda (el front
-- muestra los dos valores lado a lado y el usuario elige campo por
-- campo), incluido `propietario_id`: el responsable puede ser el tutor
-- de cualquiera de las dos fichas.
create or replace function public.fusionar_mascotas(
  p_principal_id uuid,
  p_duplicada_id uuid,
  p_datos jsonb default '{}'::jsonb,
  p_relacion_contacto text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  -- Las tablas que cuelgan de `mascotas` por FK. Si se agrega un módulo
  -- clínico nuevo con mascota_id, SUMARLO ACÁ o su historia se perderá
  -- en la próxima fusión (la fila duplicada se borra con CASCADE).
  c_tablas constant text[] := array[
    'consultas', 'formulas_medicas', 'documentos', 'examenes', 'vacunaciones',
    'desparasitaciones', 'cirugias', 'hospitalizaciones', 'seguimientos',
    'remisiones', 'peluquerias', 'guarderias', 'tareas_pendientes',
    'mensajes', 'consultas_audio'
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
    raise exception 'Las dos fichas tienen que ser de la misma clínica';
  end if;
  if not public.user_is_member_of(v_estab) then
    raise exception 'No tienes acceso a esta clínica';
  end if;

  -- Responsable final: el tutor de cualquiera de las dos fichas, o el que
  -- venga explícito en p_datos.
  v_resp := coalesce(nullif(p_datos ->> 'propietario_id', '')::uuid, v_pri.propietario_id);
  perform 1 from public.propietarios
   where id = v_resp and establecimiento_id = v_estab
     and coalesce(red_vinculado, true);
  if not found then
    raise exception 'El tutor responsable elegido no existe en esta clínica o está sin vincular';
  end if;

  -- El histórico de peso son mediciones reales de las dos fichas: se
  -- fusionan, no se elige una. Es historia, igual que las consultas.
  select coalesce(jsonb_agg(e order by e ->> 'fechaISO'), '[]'::jsonb)
    into v_peso_hist
    from (
      select distinct e from jsonb_array_elements(
        coalesce(v_pri.peso_historico, '[]'::jsonb) || coalesce(v_dup.peso_historico, '[]'::jsonb)
      ) e
    ) s;

  -- Campos de la ficha: `p_datos ? 'campo'` distingue "el usuario eligió
  -- vaciarlo" de "el front no lo mandó", que no es lo mismo.
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

  -- ── Mover la historia clínica ────────────────────────────
  foreach v_tabla in array c_tablas loop
    execute format('update public.%I set mascota_id = $1 where mascota_id = $2', v_tabla)
      using p_principal_id, p_duplicada_id;
    get diagnostics v_n = row_count;
    if v_n > 0 then v_mov := v_mov || jsonb_build_object(v_tabla, v_n); end if;
  end loop;

  update public.red_solicitudes set mascota_solicitante_id = p_principal_id
   where mascota_solicitante_id = p_duplicada_id;
  update public.red_solicitudes set mascota_destino_id = p_principal_id
   where mascota_destino_id = p_duplicada_id;

  -- Agenda y recordatorios NO referencian la mascota por FK sino por
  -- `pet_key` (texto). Sin esto quedarían apuntando a una key que ya no
  -- existe y los eventos desaparecerían de la ficha sin ningún error.
  update public.agenda_eventos set pet_key = v_pri.pet_key
   where establecimiento_id = v_estab and pet_key = v_dup.pet_key;
  get diagnostics v_n = row_count;
  if v_n > 0 then v_mov := v_mov || jsonb_build_object('agenda_eventos', v_n); end if;

  update public.eventos_seguimiento set pet_key = v_pri.pet_key
   where establecimiento_id = v_estab and pet_key = v_dup.pet_key;
  get diagnostics v_n = row_count;
  if v_n > 0 then v_mov := v_mov || jsonb_build_object('eventos_seguimiento', v_n); end if;

  -- Contactos que ya tuviera la ficha duplicada (fusiones encadenadas).
  update public.mascota_contactos set mascota_id = p_principal_id
   where mascota_id = p_duplicada_id
     and propietario_id not in (
       select propietario_id from public.mascota_contactos where mascota_id = p_principal_id
     );
  delete from public.mascota_contactos where mascota_id = p_duplicada_id;

  -- ── Contactos secundarios ────────────────────────────────
  -- Los dos tutores originales que NO quedaron como responsable pasan a
  -- ser contacto. Son dos porque el responsable elegido puede ser el de
  -- la ficha duplicada, y entonces el que se desplaza es el de la principal.
  insert into public.mascota_contactos (establecimiento_id, mascota_id, propietario_id, relacion, created_by)
  select v_estab, p_principal_id, prop, nullif(btrim(p_relacion_contacto), ''), auth.uid()
    from (select unnest(array[v_pri.propietario_id, v_dup.propietario_id]) as prop) s
   where prop is not null and prop <> v_resp
  on conflict (mascota_id, propietario_id)
    do update set relacion = coalesce(excluded.relacion, public.mascota_contactos.relacion);

  -- El responsable no puede figurar además como contacto secundario.
  delete from public.mascota_contactos
   where mascota_id = p_principal_id and propietario_id = v_resp;

  -- ── Auditoría y borrado ──────────────────────────────────
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

-- ── Higiene de privilegios ──────────────────────────────────
-- Definer que MUEVE Y BORRA historia clínica: nunca alcanzable sin
-- sesión. `anon` no tiene ningún motivo para invocarla.
revoke execute on function public.fusionar_mascotas(uuid, uuid, jsonb, text) from public, anon;
grant  execute on function public.fusionar_mascotas(uuid, uuid, jsonb, text) to authenticated;
