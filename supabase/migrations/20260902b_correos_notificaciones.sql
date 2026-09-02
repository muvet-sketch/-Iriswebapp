-- ═══════════════════════════════════════════════════════════════════
-- ENVÍO REAL DE CORREOS — bandeja de salida `correos` + los datos que el
-- servidor necesita para resolver destinatarios SIN el navegador.
-- ═══════════════════════════════════════════════════════════════════
-- Hasta acá el único correo real de la app era el de confirmación de
-- registro de propietario y el código de verificación (api/send-email.js
-- y api/send-verification-code.js). Agenda "notificaba" abriendo un modal
-- mock (#agenda-notif-modal) y los recordatorios configurados en
-- Configuración de la veterinaria > Agenda y disponibilidad nunca se
-- enviaban: solo se calculaba `agenda_eventos.recordatorio_24h` para
-- mostrarlo en el detalle del evento.
--
-- Esta migración agrega lo que faltaba del lado de la base:
--   1. columnas para que un proceso SIN navegador sepa a quién escribirle,
--   2. la tabla `correos` — bandeja de salida + log auditable,
--   3. el reclamo atómico de trabajos por parte del cron,
--   4. el disparador programado (pg_cron + pg_net).

-- ── 1. Zona horaria del establecimiento ──────────────────────────
-- `agenda_eventos.start_iso` es `timestamp` SIN zona a propósito (ver
-- CLAUDE.md: todo el módulo de Agenda trabaja con cadenas locales
-- ingenuas). Para programar "24 h antes" hay que convertir esa hora local
-- a un instante real, y eso exige saber en qué zona está la clínica.
-- Colombia no tiene horario de verano, pero la columna existe para no
-- volver a clavar -05:00 dentro del código.
alter table public.establecimientos
  add column if not exists zona_horaria text not null default 'America/Bogota';

-- ── 2. Destinatarios resolubles desde el servidor ────────────────
-- `agenda_eventos.encargado_id` es el id LOCAL numérico de
-- USUARIOS_SISTEMA, que se regenera 1..N en cada sesión del navegador
-- (misma limitación ya documentada para tareas_pendientes.responsable_id).
-- El cron de recordatorios corre sin navegador y no puede reconstruir ese
-- roster, así que el correo y el nombre del encargado se guardan en la
-- fila. `propietario` también era solo un nombre en texto: se agrega la
-- FK real para poder releer el email del tutor en el momento de enviar (si
-- lo cambió después de agendar, sale al actual), con el email guardado
-- como respaldo para tutores que ya no existan.
alter table public.agenda_eventos
  add column if not exists propietario_id uuid references public.propietarios (id) on delete set null,
  add column if not exists propietario_email text,
  add column if not exists encargado_email text,
  add column if not exists encargado_nombre text,
  add column if not exists mascota_nombre text;

create index if not exists agenda_eventos_propietario_id_idx
  on public.agenda_eventos (propietario_id);

-- ── 3. Bandeja de salida ─────────────────────────────────────────
-- Una fila por (correo × destinatario). Los envíos inmediatos nacen en
-- 'pendiente' con programado_para = now() y los procesa el mismo cron que
-- los recordatorios: así hay UN solo camino de envío, un solo lugar donde
-- mirar qué salió y qué falló, y un reintento uniforme. La API igual
-- dispara el procesamiento al vuelo para que el correo de "cita creada" no
-- espere al siguiente tick.
create table if not exists public.correos (
  id                  uuid primary key default gen_random_uuid(),
  establecimiento_id  uuid not null references public.establecimientos (id) on delete cascade,
  -- 'agenda_evento_creado' | 'agenda_evento_actualizado' |
  -- 'agenda_evento_cancelado' | 'agenda_recordatorio' | 'documento' |
  -- 'mensaje_propietario' | 'invitacion_usuario' | 'link_registro' |
  -- 'registro_propietario' | 'prueba' | 'generico'
  tipo                text not null,
  -- Origen del correo, para poder cancelar/reprogramar lo pendiente de un
  -- registro cuando ese registro cambia. Texto y no FK: apunta a tablas
  -- distintas según el tipo.
  referencia_tabla    text,
  referencia_id       text,
  destinatario_email  text not null,
  destinatario_nombre text,
  -- 'tutor' | 'encargado' | 'clinica' | 'usuario' — informativo, se muestra
  -- en el log de correos de la app.
  rol_destinatario    text,
  asunto              text not null,
  -- Todo lo necesario para RENDERIZAR el correo en el momento del envío.
  -- Se guarda el dato, no el HTML ya armado: un recordatorio programado con
  -- 7 días de antelación debe salir con la plantilla vigente el día que se
  -- envía, no con la del día en que se agendó.
  payload             jsonb not null default '{}'::jsonb,
  programado_para     timestamptz not null default now(),
  estado              text not null default 'pendiente'
                        check (estado in ('pendiente','enviando','enviado','error','cancelado')),
  intentos            integer not null default 0,
  ultimo_error        text,
  resend_id           text,
  enviado_at          timestamptz,
  created_by          uuid references auth.users (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index if not exists correos_establecimiento_id_idx
  on public.correos (establecimiento_id, created_at desc);
-- El índice que usa el cron: solo lo que está por salir.
create index if not exists correos_pendientes_idx
  on public.correos (programado_para)
  where estado in ('pendiente','enviando');
create index if not exists correos_referencia_idx
  on public.correos (referencia_tabla, referencia_id);

-- Un mismo recordatorio no puede quedar encolado dos veces para el mismo
-- destinatario. Guardar el evento otra vez reprograma (cancela + vuelve a
-- insertar), y sin esto un doble click dejaría al tutor recibiendo el
-- recordatorio duplicado. Los cancelados quedan fuera del índice para que
-- reprogramar a la misma hora siga siendo posible.
create unique index if not exists correos_no_duplicados_idx
  on public.correos (referencia_id, tipo, destinatario_email, programado_para)
  where estado in ('pendiente','enviando');

alter table public.correos enable row level security;

-- Lectura para la clínica (el log de correos que se ve en la app).
drop policy if exists "correos_select_member" on public.correos;
create policy "correos_select_member"
  on public.correos for select
  using (public.user_is_member_of(establecimiento_id));

-- Sin policies de insert/update/delete a propósito: la bandeja de salida la
-- escriben SOLO las funciones serverless con la Service Role key. Si un
-- cliente pudiera insertar filas acá, cualquier usuario autenticado podría
-- mandar correos con el remitente verificado de la clínica.

-- ── 4. Reclamo atómico ───────────────────────────────────────────
-- `for update skip locked` es lo que impide que dos ejecuciones solapadas
-- (el cron y el disparo inmediato de la API, o dos ticks encimados) manden
-- el mismo correo dos veces. PostgREST no sabe expresar esto, por eso es
-- una RPC. Reencola además lo que quedó 'enviando' hace más de 10 minutos:
-- eso solo pasa si la función se murió a mitad, y sin este rescate el
-- correo se quedaría atascado para siempre.
create or replace function public.correos_reclamar(p_limite integer default 25)
returns setof public.correos
language plpgsql
security definer
set search_path = public
as $fn$
begin
  update public.correos
     set estado = 'pendiente'
   where estado = 'enviando'
     and updated_at < now() - interval '10 minutes';

  return query
  with candidatos as (
    select id
      from public.correos
     where estado = 'pendiente'
       and programado_para <= now()
       and intentos < 3
     order by programado_para
     limit greatest(1, least(coalesce(p_limite, 25), 100))
     for update skip locked
  )
  update public.correos c
     set estado = 'enviando',
         intentos = c.intentos + 1,
         updated_at = now()
    from candidatos
   where c.id = candidatos.id
  returning c.*;
end;
$fn$;

-- Solo el backend. Ver el bloque de revoke/grant de RED IRIS en schema.sql:
-- revocar a `public` no basta, Supabase concede EXECUTE a anon/authenticated
-- explícitamente y hay que nombrarlos.
revoke all on function public.correos_reclamar(integer) from public;
revoke all on function public.correos_reclamar(integer) from anon;
revoke all on function public.correos_reclamar(integer) from authenticated;
grant execute on function public.correos_reclamar(integer) to service_role;

-- ── 4.1 Red de seguridad al borrar una cita ──────────────────────
-- /api/agenda-notificar ya cancela lo pendiente al eliminar un evento, pero
-- solo si el navegador llegó a llamarlo. Un recordatorio de una cita que ya
-- no existe es el peor resultado posible de este módulo (el tutor se
-- presenta a una cita cancelada), así que la garantía vive en la BASE: se
-- cancela pase lo que pase, incluso si la fila se borra desde el panel de
-- Supabase o por un CASCADE.
create or replace function public.correos_cancelar_por_evento_borrado()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  update public.correos
     set estado = 'cancelado', updated_at = now()
   where referencia_tabla = 'agenda_eventos'
     and referencia_id = old.id::text
     and estado in ('pendiente','enviando');
  return old;
end;
$fn$;

drop trigger if exists agenda_eventos_cancelar_correos on public.agenda_eventos;
create trigger agenda_eventos_cancelar_correos
  before delete on public.agenda_eventos
  for each row execute function public.correos_cancelar_por_evento_borrado();

-- ── 5. Configuración privada del backend ─────────────────────────
-- URL y secreto que necesita pg_net para llamar al endpoint del cron.
-- RLS habilitada y CERO policies, igual que las tablas de RED IRIS: ningún
-- cliente de PostgREST la lee. El valor real NO va en este archivo (el
-- repo de GitHub es PÚBLICO) — se inserta una sola vez a mano, ver el
-- README de scripts/correos.
create table if not exists public.app_config (
  clave      text primary key,
  valor      text not null,
  updated_at timestamptz not null default now()
);

alter table public.app_config enable row level security;

-- ── 6. Disparador programado ─────────────────────────────────────
-- pg_cron + pg_net en vez de un Vercel Cron: en el plan Hobby de Vercel los
-- cron jobs corren como mucho UNA vez al día, lo que dejaría un recordatorio
-- de "2 horas antes" llegando con medio día de retraso. Acá el tick es cada
-- 5 minutos y no depende del plan de Vercel.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

create or replace function public.disparar_correos_pendientes()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_url   text;
  v_token text;
begin
  select valor into v_url   from public.app_config where clave = 'correos_cron_url';
  select valor into v_token from public.app_config where clave = 'correos_cron_secret';
  -- Sin configurar todavía: no es un error, simplemente no hay a quién
  -- llamar. Se evita llenar el log de pg_cron de fallos cada 5 minutos.
  if v_url is null or v_token is null then
    return;
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || v_token
               ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 25000
  );
end;
$fn$;

revoke all on function public.disparar_correos_pendientes() from public;
revoke all on function public.disparar_correos_pendientes() from anon;
revoke all on function public.disparar_correos_pendientes() from authenticated;

-- Idempotente: `cron.schedule` con el mismo nombre reemplaza el job.
select cron.schedule(
  'iris-correos-pendientes',
  '*/5 * * * *',
  $cron$ select public.disparar_correos_pendientes(); $cron$
);
