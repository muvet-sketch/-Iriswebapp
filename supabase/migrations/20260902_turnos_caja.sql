-- Turnos de caja — soporte del interruptor "Usar turnos" de
-- Admin > Configuración de la veterinaria > Ventas e inventario
-- (establecimientos.ventas_usar_turnos, migración 20260901b).
--
-- Con ese interruptor encendido, registrar un ingreso/egreso exige tener un
-- turno abierto, y cada movimiento queda etiquetado con el turno en el que
-- se registró. Ese es el objetivo real del ajuste: poder agrupar la caja por
-- turno, no solo por fecha — dos personas que atienden el mismo día en
-- jornadas distintas hoy quedan mezcladas en el cierre.
--
-- El turno es POR PERSONA, no por establecimiento: en una clínica con dos
-- cajas abiertas a la vez, cada quien responde por lo suyo. Por eso el
-- índice parcial de abajo es sobre (establecimiento_id, user_id) y no solo
-- sobre establecimiento_id.

create table if not exists public.turnos (
  id                 uuid primary key default gen_random_uuid(),
  establecimiento_id uuid not null references public.establecimientos (id) on delete cascade,
  user_id            uuid not null references auth.users (id) on delete cascade,
  -- Copia del nombre al abrir: el roster se arma con
  -- list_establecimiento_members en cada sesión y un turno viejo tiene que
  -- seguir diciendo de quién fue aunque esa persona ya no esté en la clínica.
  usuario_nombre     text,
  abierto_at         timestamptz not null default now(),
  cerrado_at         timestamptz,
  base_inicial       numeric,
  notas              text,
  created_at         timestamptz not null default now()
);

create index if not exists turnos_establecimiento_id_idx on public.turnos (establecimiento_id);

-- Un turno abierto a la vez por persona y establecimiento. Es una garantía
-- de la BASE, no del front: sin esto, dos pestañas del mismo usuario abren
-- dos turnos y los movimientos se reparten entre ambos sin que nadie lo note.
create unique index if not exists turnos_uno_abierto_por_usuario_idx
  on public.turnos (establecimiento_id, user_id)
  where cerrado_at is null;

alter table public.turnos enable row level security;

-- Ver los turnos es ver el cierre de caja de la clínica: cualquier miembro.
drop policy if exists "turnos_select_member" on public.turnos;
create policy "turnos_select_member"
  on public.turnos for select
  using (public.user_is_member_of(establecimiento_id));

-- Abrir y cerrar, en cambio, solo el propio turno: `user_id = auth.uid()`
-- va además de user_is_member_of, no en su lugar. Sin esa mitad, cualquier
-- miembro podría cerrarle el turno a otro y el arqueo de esa persona
-- quedaría cortado por alguien más.
drop policy if exists "turnos_insert_propio" on public.turnos;
create policy "turnos_insert_propio"
  on public.turnos for insert
  with check (public.user_is_member_of(establecimiento_id) and user_id = auth.uid());

drop policy if exists "turnos_update_propio" on public.turnos;
create policy "turnos_update_propio"
  on public.turnos for update
  using (public.user_is_member_of(establecimiento_id) and user_id = auth.uid())
  with check (public.user_is_member_of(establecimiento_id) and user_id = auth.uid());

-- Sin policy de DELETE a propósito: un turno cerrado es el respaldo de un
-- arqueo. Se cierra, no se borra.

-- Etiqueta del movimiento. Nullable y `on delete set null`: los movimientos
-- anteriores a los turnos (y los registrados con el interruptor apagado) son
-- válidos y no tienen ninguno — no hay backfill que hacer.
alter table public.movimientos add column if not exists turno_id uuid references public.turnos (id) on delete set null;
create index if not exists movimientos_turno_id_idx on public.movimientos (turno_id);
