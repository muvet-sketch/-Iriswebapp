// Vercel Serverless Function — POST/GET /api/correos-cron
//
// Único consumidor de la bandeja de salida. Lo llama:
//   · pg_cron cada 5 minutos vía pg_net (ver la migración
//     20260902b_correos_notificaciones.sql, función
//     public.disparar_correos_pendientes) — es lo que hace que los
//     recordatorios salgan solos, sin que nadie tenga la app abierta;
//   · /api/agenda-notificar y /api/enviar-correo justo después de encolar,
//     para que un correo inmediato no espere al siguiente tick.
//
// NO se usó un Vercel Cron: en el plan Hobby corre como mucho una vez al día,
// y un recordatorio de "2 horas antes" llegaría con medio día de retraso.
//
// La autorización es un secreto compartido (CRON_SECRET en Vercel =
// app_config.correos_cron_secret en Supabase). Sin él este endpoint sería un
// disparador anónimo de correos con el remitente verificado de la clínica.

const { procesarPendientes } = require('./_lib/bandeja');

// Comparación en tiempo constante: con `===` sobre strings, el tiempo de
// respuesta filtra cuántos caracteres del secreto acertó quien prueba.
function secretoValido(recibido, esperado) {
  if (!recibido || !esperado || recibido.length !== esperado.length) return false;
  let dif = 0;
  for (let i = 0; i < recibido.length; i++) dif |= recibido.charCodeAt(i) ^ esperado.charCodeAt(i);
  return dif === 0;
}

module.exports = async function handler(req, res) {
  const esperado = process.env.CRON_SECRET;
  if (!esperado) {
    res.status(500).json({ error: 'CRON_SECRET no está configurada en las variables de entorno de Vercel' });
    return;
  }

  const auth = String(req.headers.authorization || '').replace(/^Bearer\s+/i, '').trim();
  const alterno = String(req.headers['x-cron-secret'] || '').trim();
  if (!secretoValido(auth || alterno, esperado)) {
    res.status(401).json({ error: 'No autorizado' });
    return;
  }

  // Tope por ejecución: el tick es cada 5 minutos, así que una cola grande se
  // drena en varias pasadas sin acercarse al límite de tiempo de la función ni
  // al rate limit de Resend.
  const limite = Math.min(Number((req.query && req.query.limite) || 25) || 25, 100);
  const resumen = await procesarPendientes(limite);
  res.status(200).json({ ok: true, ...resumen });
};
