// Invitación de calendario (.ics) adjunta a los correos de Agenda.
//
// El interruptor de Configuración de la veterinaria > Agenda dice literalmente
// "Enviar un evento de calendario al correo del propietario y del
// responsable": el correo sin el .ics no cumple lo que promete la pantalla —
// con él, Gmail/Outlook/Apple Calendar ofrecen agregar la cita con un click y,
// al reagendar o cancelar, ACTUALIZAN la que ya estaba en vez de duplicarla.
//
// Eso último depende de dos campos y por eso no se pueden tocar a la ligera:
//   · UID    — el id del evento en `agenda_eventos`. Mismo UID = mismo evento.
//   · SEQUENCE — sube en cada cambio. Un cliente de calendario ignora una
//     actualización con SEQUENCE menor o igual al que ya tiene guardado.
// Las horas van en UTC (sufijo Z) para no tener que adjuntar un bloque
// VTIMEZONE completo, que es donde suelen fallar los clientes estrictos.

const { icsUtc } = require('./fechas');

// RFC 5545: escapar , ; \ y saltos de línea.
function escaparIcs(valor) {
  return String(valor ?? '')
    .replace(/\\/g, '\\\\')
    .replace(/;/g, '\\;')
    .replace(/,/g, '\\,')
    .replace(/\r?\n/g, '\\n');
}

// Las líneas no pueden pasar de 75 octetos; se parten con un espacio al
// principio de la continuación.
function plegar(linea) {
  if (linea.length <= 73) return linea;
  const partes = [linea.slice(0, 73)];
  let resto = linea.slice(73);
  while (resto.length > 72) {
    partes.push(' ' + resto.slice(0, 72));
    resto = resto.slice(72);
  }
  if (resto) partes.push(' ' + resto);
  return partes.join('\r\n');
}

function construirIcs(evento) {
  const e = evento || {};
  const metodo = e.cancelado ? 'CANCEL' : 'REQUEST';
  const asistentes = (e.asistentes || [])
    .filter(a => a && a.email)
    .map(a => `ATTENDEE;CN=${escaparIcs(a.nombre || a.email)};RSVP=FALSE:mailto:${a.email}`);

  const lineas = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//MUVET//IRIS//ES',
    'CALSCALE:GREGORIAN',
    `METHOD:${metodo}`,
    'BEGIN:VEVENT',
    `UID:${escaparIcs(e.uid)}`,
    `SEQUENCE:${Number.isFinite(e.secuencia) ? e.secuencia : 0}`,
    `DTSTAMP:${icsUtc(new Date())}`,
    `DTSTART:${icsUtc(e.inicio)}`,
    `DTEND:${icsUtc(e.fin)}`,
    `SUMMARY:${escaparIcs(e.titulo || 'Cita')}`,
    e.descripcion ? `DESCRIPTION:${escaparIcs(e.descripcion)}` : null,
    e.lugar ? `LOCATION:${escaparIcs(e.lugar)}` : null,
    e.organizador && e.organizador.email
      ? `ORGANIZER;CN=${escaparIcs(e.organizador.nombre || e.organizador.email)}:mailto:${e.organizador.email}`
      : null,
    ...asistentes,
    `STATUS:${e.cancelado ? 'CANCELLED' : 'CONFIRMED'}`,
    'END:VEVENT',
    'END:VCALENDAR'
  ].filter(Boolean);

  return lineas.map(plegar).join('\r\n') + '\r\n';
}

// Adjunto listo para Resend (espera el contenido en base64).
function adjuntoIcs(evento, nombreArchivo) {
  return {
    filename: nombreArchivo || 'cita.ics',
    content: Buffer.from(construirIcs(evento), 'utf8').toString('base64'),
    content_type: 'text/calendar; charset=utf-8; method=' + (evento && evento.cancelado ? 'CANCEL' : 'REQUEST')
  };
}

module.exports = { construirIcs, adjuntoIcs };
