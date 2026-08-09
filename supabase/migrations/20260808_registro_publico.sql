-- ══════════════════════════════════════════════════════════════
-- LINK PÚBLICO DE AUTORREGISTRO (tutor + mascotas)
-- ══════════════════════════════════════════════════════════════
-- La clínica genera un enlace de un solo uso, se lo manda al tutor por
-- WhatsApp, y el tutor llena el formulario desde su celular en
-- `registro.html`. Al enviarlo, la ficha queda creada en esta clínica y
-- el médico la encuentra en el buscador del Consultorio.
--
-- Un visitante `anon` NO puede insertar en `propietarios`
-- (propietarios_insert_member exige user_is_member_of) ni en `mascotas`
-- (que además exige propietario_vinculado). Por eso todo el camino de
-- escritura pasa por funciones `security definer`, igual que hace toda
-- la sección RED IRIS — aquí NO se abre ninguna policy nueva a `anon`.
--
-- El modelo del token es el de `invites`: el uuid de la fila ES el
-- token, no hay columna aparte.

-- ── Origen de la ficha ──────────────────────────────────────
-- null = la registró la clínica (todo lo preexistente).
-- 'autorregistro' = la llenó el tutor por el link. Es lo único que
-- alimenta la etiqueta del buscador; no cambia ningún permiso.
alter table public.propietarios add column if not exists origen text;

-- ── Tabla de enlaces ────────────────────────────────────────
create table if not exists public.intake_links (
  id                  uuid primary key default gen_random_uuid(),  -- el token
  establecimiento_id  uuid not null references public.establecimientos (id) on delete cascade,
  nota                text,          -- "Ana, la del gato" — a quién se le mandó
  -- Se reusa como `created_by` del propietario que salga de este link:
  -- quien lo envía es `anon` y no tiene auth.uid().
  created_by          uuid references auth.users (id) on delete set null,
  expira_at           timestamptz not null default (now() + interval '7 days'),
  usado_at            timestamptz,
  propietario_id      uuid references public.propietarios (id) on delete set null,
  -- Payload crudo tal como lo envió el tutor. Es lo único que queda si
  -- la ficha no se pudo crear entera (ver el caso red_vinculado=false).
  datos_recibidos     jsonb,
  estado              text not null default 'pendiente'
                        check (estado in ('pendiente', 'completado', 'sin_vincular')),
  created_at          timestamptz not null default now()
);

create index if not exists intake_links_establecimiento_idx
  on public.intake_links (establecimiento_id, created_at desc);

alter table public.intake_links enable row level security;

-- Solo los miembros de la clínica ven y crean sus enlaces. `anon` no
-- tiene ninguna policy a propósito: entra únicamente por las dos RPC.
drop policy if exists "intake_links_select_member" on public.intake_links;
create policy "intake_links_select_member"
  on public.intake_links for select
  using (public.user_is_member_of(establecimiento_id));

drop policy if exists "intake_links_insert_member" on public.intake_links;
create policy "intake_links_insert_member"
  on public.intake_links for insert
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "intake_links_update_member" on public.intake_links;
create policy "intake_links_update_member"
  on public.intake_links for update
  using (public.user_is_member_of(establecimiento_id))
  with check (public.user_is_member_of(establecimiento_id));

drop policy if exists "intake_links_delete_member" on public.intake_links;
create policy "intake_links_delete_member"
  on public.intake_links for delete
  using (public.user_is_member_of(establecimiento_id));

-- ── Helpers internos ────────────────────────────────────────
-- Lee un texto del jsonb con tope de longitud. Sin esto, un envío
-- público podría meter megabytes en cualquier columna.
create or replace function public.intake_txt(p_obj jsonb, p_key text, p_max int)
returns text language sql immutable set search_path = public as $$
  select nullif(left(btrim(coalesce(p_obj ->> p_key, '')), p_max), '');
$$;

-- Réplica en SQL de crearMascotaKey() (index.html): minúsculas, sin
-- tildes, solo [a-z0-9], fallback 'mascota', y sufijo 2,3,… hasta que
-- no choque. `mascotas` tiene unique (establecimiento_id, pet_key), así
-- que la deduplicación es por establecimiento, no global.
create or replace function public.intake_pet_key(p_establecimiento_id uuid, p_nombre text)
returns text language plpgsql stable set search_path = public as $$
declare
  v_base text := coalesce(public.red_norm_txt(p_nombre), 'mascota');
  v_key  text := v_base;
  v_i    int  := 2;
begin
  while exists (
    select 1 from public.mascotas m
     where m.establecimiento_id = p_establecimiento_id and m.pet_key = v_key
  ) loop
    v_key := v_base || v_i::text;
    v_i := v_i + 1;
  end loop;
  return v_key;
end;
$$;

-- ── RPC 1: qué ve el tutor al abrir el enlace ───────────────
-- Devuelve SOLO el estado del token y el nombre de la clínica. Cero
-- PII, cero datos de tutores — mismo criterio que get_invite_preview().
create or replace function public.intake_link_preview(p_token uuid)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare v_link public.intake_links; v_estab public.establecimientos;
begin
  select * into v_link from public.intake_links where id = p_token;
  if not found then
    return jsonb_build_object('estado', 'inexistente');
  end if;
  if v_link.usado_at is not null then
    return jsonb_build_object('estado', 'usado');
  end if;
  if v_link.expira_at <= now() then
    return jsonb_build_object('estado', 'expirado');
  end if;

  select * into v_estab from public.establecimientos where id = v_link.establecimiento_id;
  return jsonb_build_object(
    'estado', 'valido',
    'clinica_nombre', coalesce(v_estab.nombre, 'la clínica'),
    'clinica_logo_path', v_estab.logo_path
  );
end;
$$;

-- ── RPC 2: el envío del formulario ──────────────────────────
-- Único camino de escritura desde la página pública.
create or replace function public.intake_link_enviar(
  p_token uuid, p_tutor jsonb, p_mascotas jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_link      public.intake_links;
  v_mascotas  jsonb := coalesce(p_mascotas, '[]'::jsonb);
  v_nombre    text;
  v_doc       text;
  v_doc_norm  text;
  v_prop_id   uuid;
  v_vinculado boolean;
  v_m         jsonb;
  v_peso      numeric;
  v_peso_txt  text;
  v_creadas   int := 0;
  v_estado    text;
begin
  -- El FOR UPDATE es lo que hace que el token sea de un solo uso aunque
  -- se envíe el formulario dos veces a la vez.
  select * into v_link from public.intake_links where id = p_token for update;
  if not found then
    return jsonb_build_object('ok', false, 'estado', 'inexistente');
  end if;
  if v_link.usado_at is not null then
    return jsonb_build_object('ok', false, 'estado', 'usado');
  end if;
  if v_link.expira_at <= now() then
    return jsonb_build_object('ok', false, 'estado', 'expirado');
  end if;

  v_nombre := public.intake_txt(p_tutor, 'nombre', 160);
  v_doc    := public.intake_txt(p_tutor, 'doc_numero', 40);
  if v_nombre is null then
    return jsonb_build_object('ok', false, 'estado', 'sin_nombre');
  end if;
  if v_doc is null then
    return jsonb_build_object('ok', false, 'estado', 'sin_documento');
  end if;
  if jsonb_typeof(v_mascotas) <> 'array' or jsonb_array_length(v_mascotas) > 10 then
    return jsonb_build_object('ok', false, 'estado', 'datos_invalidos');
  end if;

  v_doc_norm := public.red_norm_doc(v_doc);

  -- ¿Esta clínica ya tenía a este tutor? Entonces no se duplica la
  -- ficha: se rellenan SOLO las columnas vacías. Lo que la clínica ya
  -- había escrito nunca se pisa con lo que digitó el tutor.
  select p.id into v_prop_id
    from public.propietarios p
   where p.establecimiento_id = v_link.establecimiento_id
     and v_doc_norm is not null
     and public.red_norm_doc(p.doc_numero) = v_doc_norm
   limit 1;

  if v_prop_id is not null then
    update public.propietarios p set
      doc_tipo            = coalesce(nullif(btrim(p.doc_tipo), ''),            public.intake_txt(p_tutor, 'doc_tipo', 20)),
      movil               = coalesce(nullif(btrim(p.movil), ''),               public.intake_txt(p_tutor, 'movil', 40)),
      email               = coalesce(nullif(btrim(p.email), ''),               public.intake_txt(p_tutor, 'email', 160)),
      direccion           = coalesce(nullif(btrim(p.direccion), ''),           public.intake_txt(p_tutor, 'direccion', 200)),
      ciudad              = coalesce(nullif(btrim(p.ciudad), ''),              public.intake_txt(p_tutor, 'ciudad', 80)),
      contacto_autorizado = coalesce(nullif(btrim(p.contacto_autorizado), ''), public.intake_txt(p_tutor, 'contacto_autorizado', 160)),
      telefono_alterno    = coalesce(nullif(btrim(p.telefono_alterno), ''),    public.intake_txt(p_tutor, 'telefono_alterno', 40)),
      updated_at          = now()
     where p.id = v_prop_id;
  else
    insert into public.propietarios (
      establecimiento_id, doc_tipo, doc_numero, movil, email, nombre,
      direccion, ciudad, contacto_autorizado, telefono_alterno,
      origen, created_by
    ) values (
      v_link.establecimiento_id,
      coalesce(public.intake_txt(p_tutor, 'doc_tipo', 20), 'C.C.'),
      v_doc,
      public.intake_txt(p_tutor, 'movil', 40),
      public.intake_txt(p_tutor, 'email', 160),
      v_nombre,
      public.intake_txt(p_tutor, 'direccion', 200),
      public.intake_txt(p_tutor, 'ciudad', 80),
      public.intake_txt(p_tutor, 'contacto_autorizado', 160),
      public.intake_txt(p_tutor, 'telefono_alterno', 40),
      'autorregistro',
      v_link.created_by
    ) returning id into v_prop_id;
  end if;

  -- Lo fijó el trigger red_trg_publicar_propietario, no esta función.
  select coalesce(red_vinculado, true) into v_vinculado
    from public.propietarios where id = v_prop_id;

  -- Si la identidad ya vivía en otra clínica, la ficha nace bloqueada y
  -- NO se le puede colgar ninguna mascota (lo impide la policy de
  -- `mascotas`, y saltársela por ser definer rompería el invariante de
  -- la red). Es además lo correcto de fondo: al verificar la identidad,
  -- las mascotas llegan de la red. El payload queda en datos_recibidos.
  if v_vinculado then
    for v_m in select * from jsonb_array_elements(v_mascotas) loop
      if public.intake_txt(v_m, 'nombre', 80) is null then
        continue;
      end if;

      begin
        v_peso := nullif(public.intake_txt(v_m, 'peso', 20), '')::numeric;
      exception when others then
        v_peso := null;
      end;
      if v_peso is not null and (v_peso <= 0 or v_peso > 2000) then
        v_peso := null;
      end if;
      v_peso_txt := case when v_peso is null then null else v_peso::text || ' kg' end;

      insert into public.mascotas (
        establecimiento_id, propietario_id, pet_key, nombre, chip, especie, raza,
        fecha_nacimiento, peso, color, genero, talla, estado_reproductivo,
        alimentacion, temperamento, antecedentes, alergias, peso_historico, created_by
      ) values (
        v_link.establecimiento_id,
        v_prop_id,
        public.intake_pet_key(v_link.establecimiento_id, public.intake_txt(v_m, 'nombre', 80)),
        public.intake_txt(v_m, 'nombre', 80),
        public.intake_txt(v_m, 'chip', 40),
        public.intake_txt(v_m, 'especie', 40),
        public.intake_txt(v_m, 'raza', 80),
        -- Fecha inválida o futura → null, no revienta el envío entero.
        (case
           when public.intake_txt(v_m, 'fecha_nacimiento', 10) ~ '^\d{4}-\d{2}-\d{2}$'
            and (public.intake_txt(v_m, 'fecha_nacimiento', 10))::date <= current_date
           then (public.intake_txt(v_m, 'fecha_nacimiento', 10))::date
           else null
         end),
        v_peso_txt,
        public.intake_txt(v_m, 'color', 60),
        public.intake_txt(v_m, 'genero', 20),
        public.intake_txt(v_m, 'talla', 20),
        public.intake_txt(v_m, 'estado_reproductivo', 40),
        public.intake_txt(v_m, 'alimentacion', 200),
        public.intake_txt(v_m, 'temperamento', 200),
        public.intake_txt(v_m, 'antecedentes', 500),
        public.intake_txt(v_m, 'alergias', 500),
        -- Mismo formato que guardarMascotaRegistro(): el peso alimenta
        -- el histórico desde el primer día.
        (case when v_peso is null then '[]'::jsonb
              else jsonb_build_array(jsonb_build_object(
                     'fechaISO', to_char(current_date, 'YYYY-MM-DD'),
                     'fecha',    to_char(current_date, 'DD/MM/YYYY'),
                     'peso',     v_peso))
         end),
        v_link.created_by
      );
      v_creadas := v_creadas + 1;
    end loop;
  end if;

  v_estado := case when v_vinculado then 'completado' else 'sin_vincular' end;

  update public.intake_links set
    usado_at        = now(),
    estado          = v_estado,
    propietario_id  = v_prop_id,
    datos_recibidos = jsonb_build_object('tutor', p_tutor, 'mascotas', v_mascotas)
   where id = p_token;

  return jsonb_build_object('ok', true, 'estado', v_estado, 'mascotas_creadas', v_creadas);
end;
$$;

-- ── Higiene de privilegios ──────────────────────────────────
-- Hay que nombrar los TRES roles y ninguno sobra: Postgres da EXECUTE a
-- `public` por default (y anon lo hereda por ahí, así que revocarle solo
-- a anon/authenticated no cambia nada — se verificó con
-- has_function_privilege), y Supabase además concede explícitamente a
-- anon/authenticated, así que revocar solo a `public` tampoco alcanza.
-- Solo las dos RPC de entrada quedan invocables desde afuera; los
-- helpers no validan nada y no tienen por qué serlo.
revoke execute on function public.intake_txt(jsonb, text, int) from public, anon, authenticated;
revoke execute on function public.intake_pet_key(uuid, text) from public, anon, authenticated;

grant execute on function public.intake_link_preview(uuid) to anon, authenticated;
grant execute on function public.intake_link_enviar(uuid, jsonb, jsonb) to anon, authenticated;
