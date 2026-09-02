# Envío de correos — puesta en marcha y operación

Runbook del subsistema de correo de IRIS. El diseño y las razones de cada
decisión están en la sección "Envío de correos — un solo camino para toda la
app" de `CLAUDE.md`; acá solo está lo que hay que **hacer**.

## 1. Variables de entorno en Vercel

Proyecto `iriswebapp` → Settings → Environment Variables. Las cuatro van en
**Production, Preview y Development**.

| Variable | Para qué | Si falta |
|---|---|---|
| `RESEND_API_KEY` | Autenticación contra Resend | No sale ningún correo (500) |
| `RESEND_FROM_EMAIL` | Remitente, ej. `IRIS <citas@appmuvet.com>` | **El remitente cae a `onboarding@resend.dev`, que Resend SOLO entrega al correo dueño de la cuenta: nada falla y los correos no llegan.** Es la causa nº 1 de "no llega nada" |
| `SUPABASE_SERVICE_ROLE_KEY` | Lectura/escritura del backend saltando RLS | Todos los endpoints responden 500 |
| `CRON_SECRET` | Autoriza `/api/correos-cron` | Los recordatorios no salen (401 silencioso) |

La dirección de `RESEND_FROM_EMAIL` tiene que estar **en un dominio
verificado** en Resend (Domains → estado `verified`). Con el dominio sin
verificar, Resend rechaza cualquier envío a terceros.

Después de agregarlas hay que **volver a desplegar**: Vercel no las inyecta
en un despliegue ya construido.

## 2. Secreto del cron (Supabase ↔ Vercel)

El disparador vive en Postgres (`pg_cron` + `pg_net`, job
`iris-correos-pendientes`, cada 5 minutos) y necesita saber a qué URL llamar
y con qué secreto. Eso vive en `public.app_config`, **no en la migración**:
el repositorio de GitHub es público.

```sql
insert into public.app_config (clave, valor) values
  ('correos_cron_url',    'https://iris.appmuvet.com/api/correos-cron'),
  ('correos_cron_secret', '<el mismo valor que CRON_SECRET en Vercel>')
on conflict (clave) do update set valor = excluded.valor, updated_at = now();
```

**El valor de `correos_cron_secret` y el de `CRON_SECRET` tienen que ser
idénticos.** Si rotás uno sin el otro, los recordatorios dejan de salir en
silencio: el endpoint devuelve 401 y nadie está mirando esa respuesta.

Para generar uno nuevo:

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"
```

## 3. Verificación

En la app: **Admin → Configuración de la veterinaria → Agenda y
disponibilidad → "Estado del envío de correos"** (solo la ve un
administrador). Los cinco checks cubren exactamente los cinco modos de falla
de arriba. Ahí mismo está "Enviar correo de prueba" y el log de los últimos
correos con su estado.

Desde SQL, para ver si el cron está corriendo:

```sql
select jobid, jobname, schedule, active from cron.job where jobname = 'iris-correos-pendientes';

select status, return_message, start_time
  from cron.job_run_details
 where jobid = (select jobid from cron.job where jobname = 'iris-correos-pendientes')
 order by start_time desc limit 10;
```

Y para ver la cola:

```sql
select estado, count(*), min(programado_para) as proximo
  from public.correos group by estado;

select programado_para, destinatario_email, asunto, estado, intentos, ultimo_error
  from public.correos
 where estado in ('pendiente','error')
 order by programado_para limit 20;
```

## 4. Forzar un procesamiento sin esperar el tick

```bash
curl -X POST https://iris.appmuvet.com/api/correos-cron \
  -H "Authorization: Bearer $CRON_SECRET"
```

Es seguro llamarlo cuantas veces se quiera: el reclamo de trabajos es
atómico (`correos_reclamar`, `for update skip locked`), así que dos
ejecuciones simultáneas nunca mandan el mismo correo dos veces.

## 5. Reintentar algo que falló

Un correo en `error` no se reintenta solo (se agotaron los 3 intentos o el
fallo era permanente — dominio sin verificar, destinatario inválido).
Después de arreglar la causa:

```sql
update public.correos
   set estado = 'pendiente', intentos = 0, ultimo_error = null
 where id = '<uuid>';
```

y disparar el procesamiento con el `curl` de arriba.
