// Bandeja de salida: encolar y procesar.
//
// TODO correo de la app pasa por acá, incluidos los "inmediatos": se encolan
// con programado_para = now() y se procesan en el mismo request. La ventaja de
// no tener dos caminos es que hay un único log auditable, un único reintento y
// un único lugar donde mirar cuando alguien dice "no me llegó".

const { sbInsert, sbUpdate, sbRpc, sbSelect } = require('./supabase');
const { enviarCorreo } = require('./correo');
const { renderizar } = require('./plantillas');

// Encola filas ignorando las que choquen con correos_no_duplicados_idx (el
// mismo recordatorio ya estaba encolado para ese destinatario a esa hora).
// Devuelve las filas realmente insertadas.
async function encolar(filas) {
  const utiles = (filas || []).filter(f => f && f.destinatario_email);
  if (!utiles.length) return [];
  try {
    return await sbInsert('correos', utiles, 'return=representation,resolution=ignore-duplicates');
  } catch (err) {
    // 23505 = choque con correos_no_duplicados_idx: ese correo YA estaba en
    // cola, no es un error. Como el insert del lote es una sola sentencia,
    // una fila repetida tumba el lote entero, así que se reintenta de a una
    // para no perder las demás. `resolution=ignore-duplicates` no alcanza:
    // PostgREST infiere el ON CONFLICT por la PK, no por un índice único
    // parcial como el nuestro. Cualquier error que NO sea 23505 (permisos,
    // columna inexistente) sí se relanza.
    const insertadas = [];
    for (const fila of utiles) {
      try {
        const r = await sbInsert('correos', [fila], 'return=representation,resolution=ignore-duplicates');
        if (r && r.length) insertadas.push(r[0]);
      } catch (e) {
        if (String(e.detalle && e.detalle.code) !== '23505') throw e;
      }
    }
    return insertadas;
  }
}

// Cancela lo que todavía no salió de un registro (al reagendar o eliminar un
// evento). Lo ya enviado no se toca: es historia.
async function cancelarPendientesDe(referenciaTabla, referenciaId) {
  if (!referenciaId) return;
  await sbUpdate(
    'correos',
    `referencia_tabla=eq.${encodeURIComponent(referenciaTabla)}&referencia_id=eq.${encodeURIComponent(referenciaId)}&estado=in.(pendiente,enviando)`,
    { estado: 'cancelado', updated_at: new Date().toISOString() }
  );
}

async function marcar(id, patch) {
  await sbUpdate('correos', `id=eq.${encodeURIComponent(id)}`, { ...patch, updated_at: new Date().toISOString() });
}

// Toma lo que ya venció, lo manda y lo marca. El reclamo es atómico
// (correos_reclamar, `for update skip locked`), así que dos ejecuciones
// simultáneas nunca se pisan.
async function procesarPendientes(limite) {
  let filas = [];
  try {
    filas = await sbRpc('correos_reclamar', { p_limite: limite || 25 });
  } catch (err) {
    return { procesados: 0, enviados: 0, fallidos: 0, error: err.message };
  }
  if (!Array.isArray(filas) || !filas.length) return { procesados: 0, enviados: 0, fallidos: 0 };

  let enviados = 0;
  let fallidos = 0;
  const detalle = [];

  for (const fila of filas) {
    let render;
    try {
      render = renderizar(fila);
    } catch (err) {
      await marcar(fila.id, { estado: 'error', ultimo_error: `No se pudo construir el mensaje: ${err.message}` });
      fallidos++;
      detalle.push({ id: fila.id, email: fila.destinatario_email, ok: false, error: err.message });
      continue;
    }

    const res = await enviarCorreo({
      to: fila.destinatario_email,
      subject: fila.asunto,
      html: render.html,
      text: render.texto,
      attachments: render.adjuntos,
      replyTo: (fila.payload && fila.payload.correoClinica) || undefined,
      // La clave incluye el intento: un reintento tras un 429 SÍ debe salir,
      // mientras que dos ticks del cron sobre la misma fila (que compartirían
      // intento) no pueden duplicar el envío.
      idempotencyKey: `iris-${fila.id}-${fila.intentos}`
    });

    if (res.ok) {
      await marcar(fila.id, { estado: 'enviado', resend_id: res.id || null, enviado_at: new Date().toISOString(), ultimo_error: null });
      enviados++;
      detalle.push({ id: fila.id, email: fila.destinatario_email, ok: true });
    } else {
      // Un error permanente (dominio sin verificar, destinatario inválido) no
      // mejora reintentando: se cierra ya, en vez de gastar los 3 intentos y
      // dejar al usuario esperando 15 minutos por un fallo que no cambia.
      const agotado = res.permanente || fila.intentos >= 3;
      await marcar(fila.id, { estado: agotado ? 'error' : 'pendiente', ultimo_error: String(res.error).slice(0, 500) });
      fallidos++;
      detalle.push({ id: fila.id, email: fila.destinatario_email, ok: false, error: res.error });
    }
  }

  return { procesados: filas.length, enviados, fallidos, detalle };
}

// Últimos correos de una clínica — alimenta el log que se ve en la app.
async function ultimosCorreos(establecimientoId, limite) {
  return sbSelect(
    'correos',
    `select=id,tipo,destinatario_email,destinatario_nombre,rol_destinatario,asunto,estado,programado_para,enviado_at,ultimo_error,created_at` +
    `&establecimiento_id=eq.${encodeURIComponent(establecimientoId)}&order=created_at.desc&limit=${Math.min(Number(limite) || 25, 100)}`
  );
}

module.exports = { encolar, cancelarPendientesDe, marcar, procesarPendientes, ultimosCorreos };
