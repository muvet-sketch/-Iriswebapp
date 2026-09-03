// Vercel Serverless Function — POST /api/enviar-correo
//
// El camino genérico de correo de la app: todo lo que NO es Agenda entra por
// acá. Documento enviado desde el menú "..." de una fila, mensaje al
// propietario con el método "Email" marcado, invitación de usuario, link
// público de autorregistro, correo de prueba del diagnóstico.
//
// Es un solo endpoint y no uno por módulo a propósito: la plantilla, el
// remitente, el registro en la bandeja de salida y el reintento son los
// mismos para todos, y lo único que cambia por módulo es el contenido. Ver
// plantillaGenerica() en _lib/plantillas.js.
//
// Body:
//   { establecimientoId, tipo, asunto, destinatarios: [{email,nombre,rol}],
//     titulo, intro, cuerpo, filas: [[etiqueta,valor]], cta: {texto,url},
//     aviso, acento, referencia: {tabla,id},
//     adjuntos: [{filename, contenidoBase64, contentType}] }

const { autorizar } = require('./_lib/supabase');
const { encolar, procesarPendientes } = require('./_lib/bandeja');
const { emailValido } = require('./_lib/correo');

// Tope de adjuntos. Resend rechaza por encima de 40 MB y un PDF de la app pesa
// unos pocos cientos de KB; 8 MB deja margen de sobra y evita que un envío
// accidental de 30 archivos tumbe la función.
const MAX_ADJUNTOS_BYTES = 8 * 1024 * 1024;

const TIPOS_VALIDOS = new Set([
  'documento', 'mensaje_propietario', 'invitacion_usuario', 'link_registro',
  'registro_propietario', 'factura', 'prueba', 'pqrs', 'generico'
]);

// El buzón de soporte al que llegan las PQRS. El navegador NO decide este
// destinatario (podría cambiarlo): para tipo 'pqrs' el servidor lo fija acá.
const PQRS_EMAIL_DESTINO = process.env.PQRS_EMAIL_DESTINO || 'soporteiris@appmuvet.com';

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Método no permitido, usa POST' });
    return;
  }

  const b = req.body || {};
  const permiso = await autorizar(req, b.establecimientoId);
  if (permiso.error) {
    res.status(permiso.estado).json({ error: permiso.error });
    return;
  }

  const tipo = TIPOS_VALIDOS.has(b.tipo) ? b.tipo : 'generico';

  // Una PQRS siempre va al buzón de soporte de IRIS, no a donde diga el
  // navegador.
  if (tipo === 'pqrs') {
    b.destinatarios = [{ email: PQRS_EMAIL_DESTINO, nombre: 'Soporte IRIS', rol: 'soporte' }];
  }

  const vistos = new Set();
  const destinatarios = (Array.isArray(b.destinatarios) ? b.destinatarios : [])
    .map(d => ({
      email: String((d && d.email) || '').trim().toLowerCase(),
      nombre: (d && d.nombre) || null,
      rol: (d && d.rol) || null
    }))
    .filter(d => {
      if (!emailValido(d.email) || vistos.has(d.email)) return false;
      vistos.add(d.email);
      return true;
    });

  if (!destinatarios.length) {
    res.status(400).json({ error: 'No hay ningún destinatario con correo válido' });
    return;
  }
  if (!b.asunto || !String(b.asunto).trim()) {
    res.status(400).json({ error: 'Falta el asunto' });
    return;
  }

  // Adjuntos: se normalizan al formato de Resend y se acota el peso total.
  let pesoAdjuntos = 0;
  const adjuntos = (Array.isArray(b.adjuntos) ? b.adjuntos : [])
    .map(a => {
      const contenido = String((a && a.contenidoBase64) || '');
      pesoAdjuntos += Math.floor(contenido.length * 0.75);
      return {
        filename: String((a && a.filename) || 'adjunto.pdf').slice(0, 120),
        content: contenido,
        content_type: (a && a.contentType) || 'application/pdf'
      };
    })
    .filter(a => a.content);

  if (pesoAdjuntos > MAX_ADJUNTOS_BYTES) {
    res.status(413).json({ error: 'Los adjuntos superan el límite de 8 MB' });
    return;
  }

  const payload = {
    clinica: b.clinica || null,
    correoClinica: emailValido(b.correoClinica) ? String(b.correoClinica).trim() : null,
    acento: b.acento || null,
    titulo: b.titulo || b.asunto,
    intro: b.intro || null,
    // `cuerpo` es texto libre del usuario (el mensaje al propietario). Se
    // escapa al renderizar, nunca se interpreta como HTML.
    cuerpo: b.cuerpo || null,
    filas: Array.isArray(b.filas) ? b.filas.slice(0, 30) : [],
    cta: b.cta && b.cta.url ? { texto: b.cta.texto, url: String(b.cta.url).slice(0, 2000) } : null,
    aviso: b.aviso || null,
    pie: b.pie || null,
    adjuntos
  };

  const ahora = new Date().toISOString();
  const filas = destinatarios.map(d => ({
    establecimiento_id: b.establecimientoId,
    tipo,
    referencia_tabla: (b.referencia && b.referencia.tabla) || null,
    referencia_id: (b.referencia && b.referencia.id) ? String(b.referencia.id) : null,
    destinatario_email: d.email,
    destinatario_nombre: d.nombre,
    rol_destinatario: d.rol,
    asunto: String(b.asunto).slice(0, 300),
    payload,
    programado_para: ahora,
    created_by: permiso.usuario.id
  }));

  try {
    await encolar(filas);
    const resumen = await procesarPendientes(Math.max(filas.length, 10));
    res.status(200).json({
      ok: resumen.fallidos === 0,
      destinatarios: destinatarios.map(d => d.email),
      enviados: resumen.enviados || 0,
      fallidos: resumen.fallidos || 0,
      detalle: resumen.detalle || []
    });
  } catch (err) {
    res.status(500).json({ error: err.message || String(err) });
  }
};
