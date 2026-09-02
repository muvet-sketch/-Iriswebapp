// Acceso a Supabase desde las funciones serverless, con la Service Role key,
// más la verificación de quién está llamando.
//
// La Service Role key SALTA RLS por completo. Por eso ningún endpoint la usa
// antes de haber comprobado dos cosas: que hay un usuario real detrás del
// token que mandó el navegador (usuarioDesdeRequest) y que ese usuario es
// miembro del establecimiento sobre el que pide actuar (esMiembroDe). Sin
// ese par de chequeos, un usuario de la clínica A podría mandar correos con
// el remitente de la clínica B.

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://ayyggymsblvxrrzfjhmw.supabase.co';

function serviceRoleKey() {
  return process.env.SUPABASE_SERVICE_ROLE_KEY || '';
}

function faltaConfiguracion() {
  if (!serviceRoleKey()) return 'SUPABASE_SERVICE_ROLE_KEY no está configurada en las variables de entorno de Vercel';
  return null;
}

async function restFetch(path, opciones) {
  const o = opciones || {};
  const key = serviceRoleKey();
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    method: o.method || 'GET',
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
      Prefer: o.prefer || 'return=representation',
      ...(o.headers || {})
    },
    body: o.body ? JSON.stringify(o.body) : undefined
  });
  const texto = await res.text();
  let data = null;
  try { data = texto ? JSON.parse(texto) : null; } catch (_) { data = texto; }
  if (!res.ok) {
    const err = new Error((data && (data.message || data.hint)) || `Supabase respondió ${res.status}`);
    err.estado = res.status;
    err.detalle = data;
    throw err;
  }
  return data;
}

const sbSelect = (tabla, query) => restFetch(`${tabla}?${query}`);
const sbInsert = (tabla, filas, prefer) =>
  restFetch(tabla, { method: 'POST', body: filas, prefer: prefer || 'return=representation' });
const sbUpdate = (tabla, query, patch) =>
  restFetch(`${tabla}?${query}`, { method: 'PATCH', body: patch, prefer: 'return=minimal' });
const sbRpc = (fn, args) =>
  restFetch(`rpc/${fn}`, { method: 'POST', body: args || {} });

// Token del usuario que manda el navegador (session.access_token de
// supabase-js). Se valida contra /auth/v1/user: si el token venció o es de
// otro proyecto, Supabase responde 401 y acá devolvemos null.
async function usuarioDesdeRequest(req) {
  const auth = (req.headers && (req.headers.authorization || req.headers.Authorization)) || '';
  const token = auth.replace(/^Bearer\s+/i, '').trim();
  if (!token) return null;
  try {
    const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: serviceRoleKey(), Authorization: `Bearer ${token}` }
    });
    if (!res.ok) return null;
    const user = await res.json();
    return user && user.id ? { id: user.id, email: user.email } : null;
  } catch (_) {
    return null;
  }
}

// Miembro ACTIVO del establecimiento. Devuelve el rol, que algunos endpoints
// usan para restringir más (el diagnóstico de correo, por ejemplo, es de
// admin).
async function esMiembroDe(userId, establecimientoId) {
  if (!userId || !establecimientoId) return null;
  const filas = await sbSelect(
    'memberships',
    `select=rol,estado&user_id=eq.${encodeURIComponent(userId)}&establecimiento_id=eq.${encodeURIComponent(establecimientoId)}&estado=eq.activo&limit=1`
  );
  return filas && filas.length ? filas[0] : null;
}

// Guarda común de todos los endpoints que actúan sobre una clínica.
// Devuelve { error, estado } listo para responder, o { usuario, membresia }.
async function autorizar(req, establecimientoId) {
  const falta = faltaConfiguracion();
  if (falta) return { error: falta, estado: 500 };
  if (!establecimientoId) return { error: 'Falta establecimientoId', estado: 400 };
  const usuario = await usuarioDesdeRequest(req);
  if (!usuario) return { error: 'Sesión no válida — vuelve a iniciar sesión', estado: 401 };
  const membresia = await esMiembroDe(usuario.id, establecimientoId);
  if (!membresia) return { error: 'No perteneces a esta clínica', estado: 403 };
  return { usuario, membresia };
}

module.exports = {
  SUPABASE_URL,
  serviceRoleKey,
  faltaConfiguracion,
  restFetch,
  sbSelect,
  sbInsert,
  sbUpdate,
  sbRpc,
  usuarioDesdeRequest,
  esMiembroDe,
  autorizar
};
