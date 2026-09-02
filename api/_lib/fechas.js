// Conversión entre las horas LOCALES INGENUAS de Agenda y instantes reales.
//
// `agenda_eventos.start_iso` es `timestamp` SIN zona a propósito (ver
// CLAUDE.md): todo el módulo trabaja con cadenas como '2026-09-05T09:00:00'
// que significan "las 9 de la mañana en la clínica". Para programar un
// recordatorio "24 h antes" hay que saber a qué instante corresponde esa hora
// de pared, y para eso hace falta la zona del establecimiento
// (`establecimientos.zona_horaria`, default America/Bogota).
//
// No se usa una librería: `Intl` ya sabe las reglas de cada zona y viene en
// el runtime de Node.

// Minutos que la zona va por delante de UTC en ese instante (Bogotá: -300).
function offsetMinutos(instante, zona) {
  const dtf = new Intl.DateTimeFormat('en-US', {
    timeZone: zona,
    hour12: false,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit'
  });
  const p = {};
  for (const parte of dtf.formatToParts(instante)) p[parte.type] = parte.value;
  // hour12:false puede devolver "24" a medianoche en algunos runtimes.
  const hora = p.hour === '24' ? '00' : p.hour;
  const comoUtc = Date.UTC(+p.year, +p.month - 1, +p.day, +hora, +p.minute, +p.second);
  return (comoUtc - instante.getTime()) / 60000;
}

function zonaValida(zona) {
  if (!zona) return 'America/Bogota';
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: zona });
    return zona;
  } catch (_) {
    return 'America/Bogota';
  }
}

// '2026-09-05T09:00:00' (hora de pared en `zona`) → Date real.
// Dos pasadas: la primera estima el offset con una fecha aproximada y la
// segunda lo corrige, que es lo que hace falta en los bordes de un cambio de
// horario de verano. Colombia no lo tiene, pero la clínica puede no estar en
// Colombia y el error sería de una hora entera en el recordatorio.
function instanteDesdeLocal(naiveISO, zona) {
  if (!naiveISO) return null;
  const tz = zonaValida(zona);
  const limpio = String(naiveISO).replace(/Z$/, '').slice(0, 19);
  const base = Date.parse(`${limpio.length === 16 ? limpio + ':00' : limpio}Z`);
  if (!isFinite(base)) return null;
  let off = offsetMinutos(new Date(base), tz);
  off = offsetMinutos(new Date(base - off * 60000), tz);
  return new Date(base - off * 60000);
}

const DIAS = ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'];
const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];

// "jueves 5 de septiembre de 2026, 9:00 a. m." — se arma a mano desde la
// cadena ingenua en vez de con toLocaleString() porque el string YA está en
// la hora de la clínica: pasarlo por Date lo movería a la zona del servidor.
function fechaHumana(naiveISO, opciones) {
  const o = opciones || {};
  if (!naiveISO) return '';
  const limpio = String(naiveISO).replace(/Z$/, '');
  const [fecha, hora] = limpio.split('T');
  const [a, m, d] = fecha.split('-').map(Number);
  if (!a || !m || !d) return limpio;
  // Date.UTC solo para sacar el día de la semana, sin corrimiento de zona.
  const diaSemana = DIAS[new Date(Date.UTC(a, m - 1, d)).getUTCDay()];
  let texto = `${diaSemana} ${d} de ${MESES[m - 1]} de ${a}`;
  if (!o.sinHora && hora) {
    const [hh, mm] = hora.split(':').map(Number);
    const sufijo = hh < 12 ? 'a. m.' : 'p. m.';
    const h12 = hh % 12 === 0 ? 12 : hh % 12;
    texto += `, ${h12}:${String(mm || 0).padStart(2, '0')} ${sufijo}`;
  }
  return texto;
}

// Formato de fecha-hora UTC para ICS: 20260905T140000Z
function icsUtc(instante) {
  return instante.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
}

module.exports = { offsetMinutos, zonaValida, instanteDesdeLocal, fechaHumana, icsUtc };
