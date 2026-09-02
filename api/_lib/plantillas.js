// Renderiza una fila de la bandeja `correos` en el mensaje que sale.
//
// El render pasa acá y NO en el momento de encolar: un recordatorio se
// programa con días de antelación y tiene que salir con la plantilla vigente
// el día del envío, no con la del día en que se agendó (ver el comentario de
// `correos.payload` en la migración).

const { layoutIris, textoPlano, escapeHtml } = require('./correo');
const { fechaHumana, instanteDesdeLocal } = require('./fechas');
const { adjuntoIcs } = require('./ics');

// Cómo se le habla a cada destinatario del mismo evento. El tutor recibe un
// mensaje de servicio ("tu cita quedó agendada"); el equipo de la clínica, uno
// operativo con el paciente por delante.
const TITULOS_AGENDA = {
  agenda_evento_creado:     { tutor: 'Tu cita quedó agendada',     equipo: 'Nueva cita agendada' },
  agenda_evento_actualizado:{ tutor: 'Tu cita cambió',             equipo: 'Cita modificada' },
  agenda_evento_cancelado:  { tutor: 'Tu cita fue cancelada',      equipo: 'Cita cancelada' },
  agenda_recordatorio:      { tutor: 'Recordatorio de tu cita',    equipo: 'Recordatorio de cita' }
};

function esTutor(rol) {
  return rol === 'tutor';
}

// Ojo con dos etiquetas que ya causaron confusión:
//   · "Responsable" NO es el tutor. Es quién agendó la cita (o el nombre de
//     la clínica cuando la agendó un administrador, ver `agendadoPor` en
//     agenda-notificar.js). La versión anterior ponía ahí al tutor y se leía
//     como si el dueño de la mascota hubiera hecho la reserva.
//   · El tutor solo se lista en el correo del EQUIPO. En el del tutor sería
//     decirle su propio nombre.
// "Termina" se quitó a pedido del cliente: la hora de fin no le aporta nada a
// quien recibe la cita y alargaba la tabla. El .ics sí la conserva, que es
// donde de verdad importa (el bloque en el calendario).
function filasAgenda(p, rol) {
  return [
    ['Motivo', p.titulo],
    ['Tipo', p.tipoLabel],
    ['Paciente', p.mascota],
    esTutor(rol) ? null : ['Tutor', p.propietario],
    [p.sinHora ? 'Día' : 'Fecha y hora', fechaHumana(p.inicioLocal, { sinHora: p.sinHora })],
    ['Profesional', p.encargadoNombre],
    ['Lugar', p.lugar],
    ['Estado', p.estadoLabel],
    ['Agendado por', p.agendadoPor],
    ['Notas', p.descripcion]
  ].filter(Boolean);
}

function introAgenda(tipo, rol, p) {
  const cuando = fechaHumana(p.inicioLocal, { sinHora: p.sinHora });
  const quien = p.mascota ? `${p.mascota}` : 'tu mascota';
  if (esTutor(rol)) {
    if (tipo === 'agenda_evento_cancelado') {
      return `La cita de ${quien} programada para el ${cuando} fue cancelada. Si necesitas reprogramarla, comunícate con nosotros.`;
    }
    if (tipo === 'agenda_evento_actualizado') {
      return `La cita de ${quien} cambió. Estos son los datos actualizados; el evento adjunto reemplaza al anterior en tu calendario.`;
    }
    if (tipo === 'agenda_recordatorio') {
      return `Te recordamos la cita de ${quien}, ${cuando} — te esperamos.`;
    }
    return `Agendamos la cita de ${quien} para el ${cuando} — adjuntamos el evento para que lo agregues a tu calendario.`;
  }
  if (tipo === 'agenda_evento_cancelado') return `Se canceló una cita de tu agenda.`;
  if (tipo === 'agenda_evento_actualizado') return `Se modificó una cita de tu agenda.`;
  if (tipo === 'agenda_recordatorio') return `Cita próxima en tu agenda.`;
  return `Se agendó una nueva cita a tu nombre.`;
}

// ── Agenda ───────────────────────────────────────────────────────
function plantillaAgenda(fila) {
  const p = fila.payload || {};
  const rol = fila.rol_destinatario || 'tutor';
  const tipo = fila.tipo;
  const titulos = TITULOS_AGENDA[tipo] || TITULOS_AGENDA.agenda_evento_creado;
  const titulo = esTutor(rol) ? titulos.tutor : titulos.equipo;

  const base = {
    clinica: p.clinica,
    logoUrl: p.logoUrl,
    ciudadClinica: p.ciudadClinica,
    direccionClinica: p.direccionClinica,
    telefonoClinica: p.telefonoClinica,
    correoClinica: p.correoClinica,
    acento: p.acento,
    titulo,
    intro: introAgenda(tipo, rol, p),
    filas: filasAgenda(p, rol),
    aviso: tipo === 'agenda_evento_cancelado'
      ? 'Si tenías esta cita en tu calendario, el archivo adjunto la marca como cancelada.'
      : null,
    pie: p.pie
  };

  const adjuntos = [];
  // El .ics solo tiene sentido con una hora concreta y un instante calculable.
  const inicio = instanteDesdeLocal(p.inicioLocal, p.zona);
  const fin = instanteDesdeLocal(p.finLocal, p.zona) || (inicio && new Date(inicio.getTime() + 30 * 60000));
  if (inicio && fin && tipo !== 'agenda_recordatorio') {
    adjuntos.push(adjuntoIcs({
      uid: `${p.eventoId}@iris.appmuvet.com`,
      secuencia: Number(p.secuencia) || 0,
      inicio,
      fin,
      titulo: `${p.titulo}${p.mascota ? ` — ${p.mascota}` : ''}`,
      descripcion: [p.tipoLabel, p.descripcion, p.propietario ? `Responsable: ${p.propietario}` : null]
        .filter(Boolean).join('\n'),
      lugar: p.lugar || p.clinica,
      organizador: p.correoClinica ? { nombre: p.clinica, email: p.correoClinica } : null,
      asistentes: (p.asistentes || []),
      cancelado: tipo === 'agenda_evento_cancelado'
    }, 'cita.ics'));
  }

  return { html: layoutIris(base), texto: textoPlano(base), adjuntos };
}

// ── Genérica ─────────────────────────────────────────────────────
// La usan el resto de disparadores (documento por correo, mensaje al
// propietario, invitación de usuario, link de autorregistro, prueba de
// envío). Todo lo variable viaja en el payload: no hace falta una plantilla
// nueva por módulo, y así los correos de toda la app se ven iguales.
function plantillaGenerica(fila) {
  const p = fila.payload || {};
  const base = {
    clinica: p.clinica,
    logoUrl: p.logoUrl,
    ciudadClinica: p.ciudadClinica,
    direccionClinica: p.direccionClinica,
    telefonoClinica: p.telefonoClinica,
    correoClinica: p.correoClinica,
    acento: p.acento,
    titulo: p.titulo || fila.asunto,
    intro: p.intro,
    filas: p.filas || [],
    cta: p.cta,
    aviso: p.aviso,
    pie: p.pie,
    // Cuerpo libre (el texto de un mensaje al propietario, por ejemplo). Se
    // escapa acá: nunca se confía en HTML que venga del navegador.
    htmlExtra: p.cuerpo
      ? `<div style="margin:4px 0 0;padding:14px 16px;background:#F9FAFB;border:1px solid #E5E7EB;border-radius:6px;color:#374151;font-size:14px;line-height:1.65;white-space:pre-wrap;">${escapeHtml(p.cuerpo)}</div>`
      : ''
  };
  const texto = [textoPlano(base), p.cuerpo ? `\n${p.cuerpo}` : ''].join('');
  return { html: layoutIris(base), texto, adjuntos: p.adjuntos || [] };
}

function renderizar(fila) {
  if (String(fila.tipo || '').startsWith('agenda_')) return plantillaAgenda(fila);
  return plantillaGenerica(fila);
}

module.exports = { renderizar, plantillaAgenda, plantillaGenerica };
