// Vercel Serverless Function (Node.js) — POST /api/verify-code
// Verifica el código de 6 dígitos emitido por send-verification-code.js
// contra el registro más reciente en verification_codes para ese
// usuario, usando la Service Role key (la única forma de tocar esa
// tabla — su RLS no tiene policies para clientes). Máximo 5 intentos
// por código.

const crypto = require('crypto');

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://ayyggymsblvxrrzfjhmw.supabase.co';
const MAX_ATTEMPTS = 5;

function hashCode(code) {
  return crypto.createHash('sha256').update(code).digest('hex');
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Método no permitido, usa POST' });
    return;
  }

  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceRoleKey) {
    res.status(500).json({ error: 'Falta SUPABASE_SERVICE_ROLE_KEY en el panel de Vercel' });
    return;
  }

  const { userId, code } = req.body || {};
  if (!userId || !code) {
    res.status(400).json({ error: 'Faltan userId o code' });
    return;
  }

  const authHeaders = {
    apikey: serviceRoleKey,
    Authorization: `Bearer ${serviceRoleKey}`,
    'Content-Type': 'application/json'
  };

  try {
    const lookupRes = await fetch(
      `${SUPABASE_URL}/rest/v1/verification_codes?user_id=eq.${encodeURIComponent(userId)}&verified_at=is.null&order=created_at.desc&limit=1`,
      { headers: authHeaders }
    );
    if (!lookupRes.ok) {
      res.status(500).json({ error: 'No se pudo consultar el código' });
      return;
    }
    const rows = await lookupRes.json();
    const record = rows[0];

    if (!record) {
      res.status(200).json({ ok: false, error: 'No hay un código pendiente. Solicita uno nuevo.' });
      return;
    }
    if (new Date(record.expires_at).getTime() < Date.now()) {
      res.status(200).json({ ok: false, error: 'El código expiró. Solicita uno nuevo.' });
      return;
    }
    if (record.attempts >= MAX_ATTEMPTS) {
      res.status(200).json({ ok: false, error: 'Demasiados intentos. Solicita un código nuevo.' });
      return;
    }

    const matches = record.code_hash === hashCode(String(code).trim());

    await fetch(`${SUPABASE_URL}/rest/v1/verification_codes?id=eq.${record.id}`, {
      method: 'PATCH',
      headers: { ...authHeaders, Prefer: 'return=minimal' },
      body: JSON.stringify(
        matches
          ? { verified_at: new Date().toISOString() }
          : { attempts: record.attempts + 1 }
      )
    });

    if (!matches) {
      res.status(200).json({ ok: false, error: 'Código incorrecto' });
      return;
    }

    res.status(200).json({ ok: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
};
