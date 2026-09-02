// Vercel Serverless Function — GET /api/correo-estado?establecimientoId=...
//
// Diagnóstico del envío de correo. Existe por un motivo concreto: el modo de
// falla de este sistema es SILENCIOSO. Sin RESEND_API_KEY la función responde
// 500; con la key pero sin RESEND_FROM_EMAIL el remitente cae a
// onboarding@resend.dev, que Resend SOLO entrega a la dirección dueña de la
// cuenta — nada falla, no hay error en ningún log, y los correos simplemente
// no llegan. Este endpoint responde esa pregunta en un request, en vez de
// dejarla en "no sé por qué no llega".
//
// Solo admin: expone qué variables de entorno están puestas y los dominios de
// la cuenta de Resend.

const { autorizar, sbSelect } = require('./_lib/supabase');
const { remitente, remitenteEsDePruebas } = require('./_lib/correo');
const { ultimosCorreos } = require('./_lib/bandeja');

async function dominiosResend() {
  const apiKey = process.env.RESEND_API_KEY;
  if (!apiKey) return { error: 'Sin RESEND_API_KEY' };
  try {
    const res = await fetch('https://api.resend.com/domains', {
      headers: { Authorization: `Bearer ${apiKey}` }
    });
    const data = await res.json().catch(() => ({}));
    const mensaje = (data && (data.message || data.name)) || '';
    if (!res.ok) {
      // "No puedo listar los dominios" NO es lo mismo que "no hay dominios
      // verificados", y confundirlos hace que el diagnóstico acuse un
      // problema que no existe. Una API key de tipo "Sending access" —la
      // opción correcta y más restringida— puede enviar pero no leer
      // /domains, y responde exactamente esto. Se reporta como
      // indeterminado, no como fallo.
      const restringida = res.status === 401 || res.status === 403 || /restricted|permission/i.test(mensaje);
      return { error: mensaje || `Resend respondió ${res.status}`, restringida, estado: res.status };
    }
    return {
      dominios: ((data && data.data) || []).map(d => ({
        nombre: d.name,
        estado: d.status,
        region: d.region
      }))
    };
  } catch (err) {
    return { error: err.message || String(err) };
  }
}

module.exports = async function handler(req, res) {
  const establecimientoId = (req.query && req.query.establecimientoId) || (req.body && req.body.establecimientoId);
  const permiso = await autorizar(req, establecimientoId);
  if (permiso.error) {
    res.status(permiso.estado).json({ error: permiso.error });
    return;
  }
  if (permiso.membresia.rol !== 'admin') {
    res.status(403).json({ error: 'Solo un administrador puede ver el diagnóstico de correo' });
    return;
  }

  const resend = await dominiosResend();

  // Configuración del cron. Solo se reporta si el valor EXISTE, nunca el
  // valor: el secreto no tiene por qué salir del servidor.
  let cron = { url: null, secreto: false };
  try {
    const filas = await sbSelect('app_config', 'select=clave,valor&clave=in.(correos_cron_url,correos_cron_secret)');
    (filas || []).forEach(f => {
      if (f.clave === 'correos_cron_url') cron.url = f.valor;
      if (f.clave === 'correos_cron_secret') cron.secreto = !!f.valor;
    });
  } catch (_) { /* app_config puede no existir todavía */ }

  let correos = [];
  try {
    correos = await ultimosCorreos(establecimientoId, Number(req.query && req.query.limite) || 25);
  } catch (_) { /* la tabla puede no existir si falta correr la migración */ }

  const pendientes = correos.filter(c => c.estado === 'pendiente').length;
  const conError = correos.filter(c => c.estado === 'error').length;

  res.status(200).json({
    ok: true,
    entorno: {
      resendApiKey: !!process.env.RESEND_API_KEY,
      resendFromEmail: !!process.env.RESEND_FROM_EMAIL,
      serviceRoleKey: !!process.env.SUPABASE_SERVICE_ROLE_KEY,
      cronSecret: !!process.env.CRON_SECRET
    },
    remitente: remitente(),
    remitenteEsDePruebas: remitenteEsDePruebas(),
    resend,
    cron,
    resumen: { total: correos.length, pendientes, conError },
    correos
  });
};
