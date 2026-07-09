// Vercel Serverless Function (Node.js) — POST /api/send-verification-code
// Genera un código de 6 dígitos, lo guarda (hasheado) en
// verification_codes usando la Service Role key (RLS de esa tabla no
// tiene ninguna policy para clientes — solo esta función y
// verify-code.js pueden tocarla) y lo envía por correo con Resend.
// Se llama desde index.html en dos puntos: verificación del email de
// perfil y verificación del correo de contacto de la clínica si se
// cambia del valor pre-llenado.

const crypto = require('crypto');

const RESEND_ENDPOINT = 'https://api.resend.com/emails';
// URL pública del proyecto (misma que usa el frontend) — no es un
// secreto, solo la Service Role key lo es.
const SUPABASE_URL = process.env.SUPABASE_URL || 'https://ayyggymsblvxrrzfjhmw.supabase.co';
const CODE_TTL_MINUTES = 10;

function hashCode(code) {
  return crypto.createHash('sha256').update(code).digest('hex');
}

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function buildCodeEmailHtml(code) {
  return `
    <div style="font-family:Inter,Arial,sans-serif;max-width:480px;margin:0 auto;">
      <div style="background:#0F766E;padding:24px 28px;border-radius:8px 8px 0 0;">
        <span style="color:#fff;font-size:20px;font-weight:700;">IRIS</span>
        <p style="color:#CCFBF1;font-size:13px;margin:4px 0 0;">Sistema de Gestión Clínica Veterinaria</p>
      </div>
      <div style="border:1px solid #E5E7EB;border-top:none;border-radius:0 0 8px 8px;padding:24px 28px;text-align:center;">
        <h2 style="font-size:16px;color:#111827;margin:0 0 8px;">Tu código de verificación</h2>
        <p style="font-size:14px;color:#374151;line-height:1.6;margin:0 0 20px;">
          Ingresa este código para confirmar tu correo. Vence en ${CODE_TTL_MINUTES} minutos.
        </p>
        <div style="font-size:32px;font-weight:700;letter-spacing:8px;color:#0F766E;">${escapeHtml(code)}</div>
      </div>
    </div>`;
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Método no permitido, usa POST' });
    return;
  }

  const resendKey = process.env.RESEND_API_KEY;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!resendKey || !serviceRoleKey) {
    res.status(500).json({ error: 'Faltan variables de entorno (RESEND_API_KEY / SUPABASE_SERVICE_ROLE_KEY) en el panel de Vercel' });
    return;
  }

  const { userId, email } = req.body || {};
  if (!userId || !email) {
    res.status(400).json({ error: 'Faltan userId o email' });
    return;
  }

  try {
    const code = String(Math.floor(100000 + Math.random() * 900000));
    const expiresAt = new Date(Date.now() + CODE_TTL_MINUTES * 60 * 1000).toISOString();

    const insertRes = await fetch(`${SUPABASE_URL}/rest/v1/verification_codes`, {
      method: 'POST',
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        'Content-Type': 'application/json',
        Prefer: 'return=minimal'
      },
      body: JSON.stringify({
        user_id: userId,
        target: email,
        code_hash: hashCode(code),
        expires_at: expiresAt
      })
    });

    if (!insertRes.ok) {
      const detail = await insertRes.text();
      res.status(500).json({ error: `No se pudo guardar el código: ${detail}` });
      return;
    }

    const from = process.env.RESEND_FROM_EMAIL || 'IRIS <onboarding@resend.dev>';
    const resendRes = await fetch(RESEND_ENDPOINT, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${resendKey}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        from,
        to: [email],
        subject: 'Tu código de verificación · IRIS',
        html: buildCodeEmailHtml(code)
      })
    });

    const data = await resendRes.json();
    if (!resendRes.ok) {
      res.status(resendRes.status).json({ error: data });
      return;
    }

    res.status(200).json({ ok: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
};
