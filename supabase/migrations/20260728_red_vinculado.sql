-- ============================================================
-- RED IRIS — estado de vinculación por establecimiento
--
-- Problema que cierra: hasta ahora una clínica podía terminar con la
-- ficha de un tutor que en realidad pertenece a otro establecimiento
-- (registrándolo "como nuevo de todas formas", o importándolo por CSV,
-- que ni siquiera consultaba la red) y quedaba con acceso completo a
-- perfil, consultorio y módulos sin haber pasado NUNCA por la
-- verificación de identidad. La vinculación existía pero era opcional.
--
-- `propietarios.red_vinculado` convierte eso en un estado explícito:
--   true  → la clínica puede abrir y editar la ficha.
--   false → la ficha existe (se ve en el buscador, para poder
--           reclamarla) pero está bloqueada hasta que alguien complete
--           red_verificar_identidad + red_vincular_con_token.
--
-- Una ficha nace SIN vincular únicamente cuando esa misma identidad ya
-- vive en otro establecimiento. Si la persona es nueva en la red — o no
-- tiene cédula, así que no hay identidad canónica — esta clínica es el
-- origen y la ficha nace utilizable.
-- ============================================================

alter table public.propietarios
  add column if not exists red_vinculado boolean;

-- Backfill deliberadamente permisivo: TODO lo que ya existe queda
-- vinculado. La regla se aplica solo de aquí en adelante.
--
-- No es pereza: 80 de los 95 tutores de la clínica en producción
-- comparten `red_persona_id` con la clínica de pruebas (ambas
-- importaron la misma lista de clientes por CSV antes de que la red
-- existiera). Cualquier regla retroactiva que mire "identidad
-- compartida" dejaría a esa clínica sin acceso a la mayoría de sus
-- propios pacientes reales. Grandfathering es la única opción que no
-- rompe producción.
update public.propietarios set red_vinculado = true where red_vinculado is null;

create index if not exists propietarios_red_vinculado_idx
  on public.propietarios (establecimiento_id, red_vinculado);

-- ── Decisión del estado, en el trigger de publicación ────────
-- Vive acá y no en el front porque así queda cubierta TODA vía de
-- inserción — "Registrar propietario", la importación de clientes por
-- CSV, la siembra de demo y cualquier camino futuro — sin tener que
-- acordarse de replicar la regla en cada una.
create or replace function public.red_trg_publicar_propietario()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if coalesce(new.consentimiento_red, true) then
    v_id := public.red_upsert_persona(
      new.doc_tipo, new.doc_numero, new.movil, new.nombre, new.email,
      new.direccion, new.ciudad, new.contacto_autorizado,
      new.telefono_alterno, new.telefono_opcional
    );
    if v_id is not null then new.red_persona_id := v_id; end if;
  end if;

  -- Solo al CREAR, y solo si quien inserta no lo fijó explícitamente
  -- (red_vincular_con_token sí lo hace, porque ahí la verificación ya
  -- ocurrió).
  if TG_OP = 'INSERT' and new.red_vinculado is null then
    new.red_vinculado := not (
      new.red_persona_id is not null and exists (
        select 1 from public.propietarios p
         where p.red_persona_id = new.red_persona_id
           and p.establecimiento_id <> new.establecimiento_id
      )
    );
  end if;

  return new;
end;
$$;

-- ── Cierre server-side ──────────────────────────────────────
-- El bloqueo de verdad no puede vivir solo en index.html: quien tenga
-- la anon key puede hablarle a PostgREST directo. Se cubren las dos
-- tablas de identidad; la historia clínica cuelga de `mascotas`, así
-- que sin poder crear mascota tampoco se le puede colgar nada.
-- Ojo: esta función se evalúa DENTRO de una policy, así que la ejecuta
-- el rol que consulta (`authenticated`). No le quites el EXECUTE por
-- higiene como sí se hace con red_upsert_persona — acá revocarlo
-- rompería las policies de `mascotas` con "permission denied".
create or replace function public.propietario_vinculado(p_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select red_vinculado from public.propietarios where id = p_id), true);
$$;

drop policy if exists "propietarios_update_member" on public.propietarios;
create policy "propietarios_update_member"
  on public.propietarios for update
  using (public.user_is_member_of(establecimiento_id) and coalesce(red_vinculado, true))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "mascotas_insert_member" on public.mascotas;
create policy "mascotas_insert_member"
  on public.mascotas for insert
  with check (
    public.user_is_member_of(establecimiento_id)
    and public.propietario_vinculado(propietario_id)
  );

drop policy if exists "mascotas_update_member" on public.mascotas;
create policy "mascotas_update_member"
  on public.mascotas for update
  using (
    public.user_is_member_of(establecimiento_id)
    and public.propietario_vinculado(propietario_id)
  )
  with check (public.user_is_member_of(establecimiento_id));

-- ── La vinculación marca la ficha como utilizable ───────────
-- Es el ÚNICO camino que pone red_vinculado en true después de creada
-- la fila (la policy de update de arriba impide hacerlo por PostgREST),
-- y cubre tanto la ficha que crea la propia RPC como la que ya estaba
-- bloqueada en la clínica y ahora se reclama.
create or replace function public.red_vincular_con_token(
  p_token uuid, p_red_mascota_ids uuid[]
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_ver     public.red_verificaciones%rowtype;
  v_persona public.red_personas%rowtype;
  v_prop    public.propietarios%rowtype;
  v_rm      public.red_mascotas%rowtype;
  v_key     text;
  v_base    text;
  v_i       int;
  v_nueva   public.mascotas%rowtype;
  v_mascotas jsonb := '[]'::jsonb;
  v_copiadas int := 0;
begin
  select * into v_ver from public.red_verificaciones
   where id = p_token and user_id = auth.uid() and not usada and expira_at > now();
  if v_ver.id is null then
    return jsonb_build_object('ok', false, 'motivo', 'token_invalido');
  end if;
  if not public.user_is_member_of(v_ver.establecimiento_id) then
    raise exception 'No autorizado';
  end if;

  update public.red_verificaciones set usada = true where id = v_ver.id;

  select * into v_persona from public.red_personas where id = v_ver.persona_id;

  -- Si la clínica ya tenía a esta persona (p. ej. dos vinculaciones
  -- seguidas, o una ficha creada sin vincular) se reutiliza su
  -- propietario en vez de duplicarlo, y se desbloquea.
  select * into v_prop from public.propietarios
   where red_persona_id = v_persona.id and establecimiento_id = v_ver.establecimiento_id
   limit 1;

  if v_prop.id is null then
    insert into public.propietarios (
      establecimiento_id, doc_tipo, doc_numero, movil, email, nombre, direccion, ciudad,
      contacto_autorizado, telefono_alterno, telefono_opcional, created_by, red_persona_id,
      red_vinculado
    ) values (
      v_ver.establecimiento_id, v_persona.doc_tipo, v_persona.doc_numero, v_persona.movil,
      v_persona.email, coalesce(v_persona.nombre, 'Sin nombre'), v_persona.direccion, v_persona.ciudad,
      v_persona.contacto_autorizado, v_persona.telefono_alterno, v_persona.telefono_opcional,
      auth.uid(), v_persona.id, true
    ) returning * into v_prop;
  elsif not coalesce(v_prop.red_vinculado, true) then
    update public.propietarios
       set red_vinculado = true, updated_at = now()
     where id = v_prop.id
     returning * into v_prop;
  end if;

  for v_rm in
    select rm.* from public.red_mascotas rm
     where rm.persona_id = v_persona.id
       and rm.id = any(coalesce(p_red_mascota_ids, array[]::uuid[]))
       and not exists (select 1 from public.mascotas m
                        where m.red_mascota_id = rm.id
                          and m.establecimiento_id = v_ver.establecimiento_id)
  loop
    -- pet_key: mismo criterio que crearMascotaKey() en index.html
    -- (slug del nombre, sufijo numérico ante colisión) porque es la
    -- llave con la que el front indexa patientData.
    v_base := coalesce(public.red_norm_txt(v_rm.nombre), 'mascota');
    v_key := v_base;
    v_i := 2;
    while exists (select 1 from public.mascotas
                   where establecimiento_id = v_ver.establecimiento_id and pet_key = v_key) loop
      v_key := v_base || v_i::text;
      v_i := v_i + 1;
    end loop;

    insert into public.mascotas (
      establecimiento_id, propietario_id, pet_key, nombre, chip, especie, raza,
      fecha_nacimiento, peso, color, genero, talla, estado_reproductivo,
      animal_servicio, fallecido, foto_path, created_by, red_mascota_id
    ) values (
      v_ver.establecimiento_id, v_prop.id, v_key, v_rm.nombre, v_rm.chip, v_rm.especie, v_rm.raza,
      v_rm.fecha_nacimiento, v_rm.peso, v_rm.color, v_rm.genero, v_rm.talla, v_rm.estado_reproductivo,
      v_rm.animal_servicio, v_rm.fallecido, v_rm.foto_path, auth.uid(), v_rm.id
    ) returning * into v_nueva;

    v_mascotas := v_mascotas || to_jsonb(v_nueva);
    v_copiadas := v_copiadas + 1;
  end loop;

  insert into public.red_vinculaciones (persona_id, establecimiento_id, propietario_id, mascotas_copiadas, user_id)
  values (v_persona.id, v_ver.establecimiento_id, v_prop.id, v_copiadas, auth.uid());

  return jsonb_build_object('ok', true, 'propietario', to_jsonb(v_prop), 'mascotas', v_mascotas);
end;
$$;

grant execute on function public.red_vincular_con_token(uuid, uuid[]) to authenticated;
