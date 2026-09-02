// Cliente de Resend + plantilla base de los correos de IRIS.
//
// Vive en api/_lib/ y NO es una ruta: Vercel ignora como endpoint todo lo
// que empieza por "_", pero sí lo empaqueta con las funciones que lo
// requieren. Todos los endpoints que mandan correo pasan por acá — un solo
// lugar donde está el remitente, el manejo de errores de Resend y el
// maquetado, para que un correo de agenda y uno de facturación no se vean
// como si salieran de dos productos distintos.

const RESEND_ENDPOINT = 'https://api.resend.com/emails';

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// Remitente. Si RESEND_FROM_EMAIL no está configurada se cae a
// onboarding@resend.dev, que Resend SOLO entrega a la dirección dueña de la
// cuenta: es exactamente el síntoma de "los correos no llegan y nada falla".
// Por eso remitenteEsDePruebas() lo marca y /api/correo-estado lo reporta.
function remitente() {
  return process.env.RESEND_FROM_EMAIL || 'IRIS <onboarding@resend.dev>';
}

function remitenteEsDePruebas() {
  return /resend\.dev/i.test(remitente());
}

function emailValido(valor) {
  return typeof valor === 'string' && /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(valor.trim());
}

// ── Plantilla base ───────────────────────────────────────────────
// Un solo layout para todo. `acento` llega desde el tema de la clínica
// cuando quien dispara el correo lo conoce; el verde de IRIS es el default.
function layoutIris(opts) {
  const o = opts || {};
  const acento = /^#[0-9a-f]{6}$/i.test(o.acento || '') ? o.acento : '#0F766E';
  const clinica = escapeHtml(o.clinica || 'IRIS');
  const filas = (o.filas || [])
    .filter(([, valor]) => valor !== undefined && valor !== null && String(valor).trim() !== '')
    .map(([etiqueta, valor]) => `
      <tr>
        <td style="padding:9px 0;color:#6B7280;font-size:13px;border-bottom:1px solid #E5E7EB;width:42%;vertical-align:top;">${escapeHtml(etiqueta)}</td>
        <td style="padding:9px 0;color:#111827;font-size:13px;border-bottom:1px solid #E5E7EB;font-weight:600;">${escapeHtml(valor)}</td>
      </tr>`)
    .join('');

  const cta = o.cta && o.cta.url
    ? `<p style="margin:24px 0 0;">
         <a href="${escapeHtml(o.cta.url)}" style="background:${acento};color:#ffffff;text-decoration:none;padding:11px 22px;border-radius:6px;font-size:14px;display:inline-block;font-weight:600;">
           ${escapeHtml(o.cta.texto || 'Abrir')}
         </a>
       </p>`
    : '';

  const aviso = o.aviso
    ? `<div style="margin:20px 0 0;padding:12px 14px;background:#FFFBEB;border:1px solid #FDE68A;border-radius:6px;color:#92400E;font-size:13px;line-height:1.5;">${escapeHtml(o.aviso)}</div>`
    : '';

  const cuerpoExtra = o.htmlExtra || '';

  return `<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:24px 12px;background:#F3F4F6;">
  <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Inter,Arial,sans-serif;max-width:560px;margin:0 auto;background:#ffffff;border-radius:10px;overflow:hidden;border:1px solid #E5E7EB;">
    <div style="background:${acento};padding:22px 28px;">
      <span style="color:#ffffff;font-size:19px;font-weight:700;letter-spacing:.5px;">IRIS</span>
      <p style="color:rgba(255,255,255,.82);font-size:13px;margin:4px 0 0;">${clinica}</p>
    </div>
    <div style="padding:26px 28px;">
      <h1 style="font-size:17px;color:#111827;margin:0 0 10px;line-height:1.35;">${escapeHtml(o.titulo || '')}</h1>
      ${o.intro ? `<p style="font-size:14px;color:#374151;line-height:1.65;margin:0 0 18px;">${escapeHtml(o.intro)}</p>` : ''}
      ${filas ? `<table style="width:100%;border-collapse:collapse;">${filas}</table>` : ''}
      ${cuerpoExtra}
      ${cta}
      ${aviso}
    </div>
    <div style="padding:16px 28px 22px;border-top:1px solid #E5E7EB;background:#FAFAFA;">
      <p style="font-size:11px;color:#9CA3AF;margin:0;line-height:1.6;">
        ${escapeHtml(o.pie || `Este mensaje fue enviado automáticamente por ${o.clinica || 'tu clínica veterinaria'} a través de IRIS.`)}
      </p>
    </div>
  </div>
</body></html>`;
}

// Versión en texto plano. No es opcional: un correo solo-HTML puntúa peor en
// los filtros de spam y es lo único que ven algunos clientes de correo.
function textoPlano(opts) {
  const o = opts || {};
  const lineas = [o.titulo || '', ''];
  if (o.intro) lineas.push(o.intro, '');
  (o.filas || [])
    .filter(([, v]) => v !== undefined && v !== null && String(v).trim() !== '')
    .forEach(([k, v]) => lineas.push(`${k}: ${v}`));
  if (o.cta && o.cta.url) lineas.push('', `${o.cta.texto || 'Abrir'}: ${o.cta.url}`);
  if (o.aviso) lineas.push('', o.aviso);
  lineas.push('', o.pie || `Enviado automáticamente por ${o.clinica || 'tu clínica veterinaria'} a través de IRIS.`);
  return lineas.join('\n');
}

// ── Envío ────────────────────────────────────────────────────────
// Nunca lanza: devuelve { ok, id, error, estado }. Quien llama decide qué
// hacer, y en la bandeja de salida un fallo tiene que quedar registrado como
// fila en 'error', no tumbar el resto del lote.
async function enviarCorreo(mensaje) {
  const apiKey = process.env.RESEND_API_KEY;
  if (!apiKey) {
    return { ok: false, error: 'RESEND_API_KEY no está configurada en las variables de entorno de Vercel', permanente: true };
  }
  const destinatarios = (Array.isArray(mensaje.to) ? mensaje.to : [mensaje.to])
    .map(e => String(e || '').trim())
    .filter(emailValido);
  if (!destinatarios.length) {
    return { ok: false, error: 'Destinatario inválido o vacío', permanente: true };
  }

  const cuerpo = {
    from: mensaje.from || remitente(),
    to: destinatarios,
    subject: mensaje.subject || '(sin asunto)',
    html: mensaje.html,
    text: mensaje.text
  };
  if (mensaje.replyTo) cuerpo.reply_to = mensaje.replyTo;
  if (mensaje.cc && mensaje.cc.length) cuerpo.cc = mensaje.cc;
  if (mensaje.attachments && mensaje.attachments.length) cuerpo.attachments = mensaje.attachments;

  const headers = {
    Authorization: `Bearer ${apiKey}`,
    'Content-Type': 'application/json'
  };
  // Idempotencia de Resend: si el mismo lote se reintenta (el cron reencola
  // un 'enviando' huérfano, por ejemplo), Resend devuelve el envío original
  // en vez de mandarlo de nuevo.
  if (mensaje.idempotencyKey) headers['Idempotency-Key'] = String(mensaje.idempotencyKey).slice(0, 256);

  try {
    const res = await fetch(RESEND_ENDPOINT, { method: 'POST', headers, body: JSON.stringify(cuerpo) });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      return {
        ok: false,
        estado: res.status,
        // 4xx (dominio sin verificar, destinatario inválido, API key mala) no
        // se arregla reintentando; 429/5xx sí.
        permanente: res.status >= 400 && res.status < 500 && res.status !== 429,
        error: (data && (data.message || data.error || data.name)) || `Resend respondió ${res.status}`
      };
    }
    return { ok: true, id: data && data.id };
  } catch (err) {
    return { ok: false, error: err.message || String(err), permanente: false };
  }
}

module.exports = {
  escapeHtml,
  emailValido,
  remitente,
  remitenteEsDePruebas,
  layoutIris,
  textoPlano,
  enviarCorreo
};
