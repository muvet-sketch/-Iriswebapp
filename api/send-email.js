// Vercel Serverless Function (Node.js) — POST /api/send-email
// Recibe los datos de un formulario (ej. registro de propietario) y
// dispara un correo de confirmación con Resend. Se llama desde el
// frontend (index.html) después de guardar el registro en Supabase y
// subir su PDF a Storage. Usa fetch nativo de Node 18+, sin dependencias.

const RESEND_ENDPOINT = 'https://api.resend.com/emails';

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function buildConfirmationHtml(propietario, pdfUrl) {
  const p = propietario || {};
  const rows = [
    ['Nombre / Razón social', p.nombre],
    ['Tipo de identificación', p.docTipo],
    ['Número de identificación', p.docNumero],
    ['Móvil / WhatsApp', p.movil],
    ['Email', p.email],
    ['Dirección', p.direccion],
    ['Ciudad o municipio', p.ciudad]
  ]
    .filter(([, value]) => value)
    .map(
      ([label, value]) => `
        <tr>
          <td style="padding:8px 12px;color:#6B7280;font-size:13px;border-bottom:1px solid #E5E7EB;">${escapeHtml(label)}</td>
          <td style="padding:8px 12px;color:#111827;font-size:13px;border-bottom:1px solid #E5E7EB;">${escapeHtml(value)}</td>
        </tr>`
    )
    .join('');

  const pdfSection = pdfUrl
    ? `<p style="margin:24px 0 0;">
         <a href="${escapeHtml(pdfUrl)}" style="background:#0F766E;color:#fff;text-decoration:none;padding:10px 20px;border-radius:6px;font-size:14px;display:inline-block;">
           Ver documento PDF
         </a>
       </p>
       <p style="font-size:12px;color:#9CA3AF;margin-top:12px;">Este enlace es temporal y expira por seguridad.</p>`
    : '';

  return `
    <div style="font-family:Inter,Arial,sans-serif;max-width:560px;margin:0 auto;">
      <div style="background:#0F766E;padding:24px 28px;border-radius:8px 8px 0 0;">
        <span style="color:#fff;font-size:20px;font-weight:700;">IRIS</span>
        <p style="color:#CCFBF1;font-size:13px;margin:4px 0 0;">Sistema de Gestión Clínica Veterinaria</p>
      </div>
      <div style="border:1px solid #E5E7EB;border-top:none;border-radius:0 0 8px 8px;padding:24px 28px;">
        <h2 style="font-size:16px;color:#111827;margin:0 0 8px;">Registro confirmado</h2>
        <p style="font-size:14px;color:#374151;line-height:1.6;margin:0 0 16px;">
          Hemos recibido y guardado tu información correctamente. Estos son los datos registrados:
        </p>
        <table style="width:100%;border-collapse:collapse;">${rows}</table>
        ${pdfSection}
      </div>
    </div>`;
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Método no permitido, usa POST' });
    return;
  }

  const apiKey = process.env.RESEND_API_KEY;
  if (!apiKey) {
    res.status(500).json({ error: 'RESEND_API_KEY no está configurada en las variables de entorno' });
    return;
  }

  const { to, propietario, pdfUrl } = req.body || {};
  if (!to || typeof to !== 'string') {
    res.status(400).json({ error: 'Falta el destinatario (to)' });
    return;
  }

  const from = process.env.RESEND_FROM_EMAIL || 'IRIS <onboarding@resend.dev>';

  try {
    const resendRes = await fetch(RESEND_ENDPOINT, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        from,
        to: [to],
        subject: 'Confirmación de registro · IRIS',
        html: buildConfirmationHtml(propietario, pdfUrl)
      })
    });

    const data = await resendRes.json();
    if (!resendRes.ok) {
      res.status(resendRes.status).json({ error: data });
      return;
    }

    res.status(200).json({ ok: true, id: data.id });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
};
