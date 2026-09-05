// Vercel Serverless Function — POST /api/agenda-notificar
//
// Lo que la pantalla de Agenda prometía y no hacía. El interruptor
// "Notificaciones" de Configuración de la veterinaria > Agenda y
// disponibilidad dice "Enviar un evento de calendario al correo del
// propietario y del responsable al crear, editar o eliminar un
// agendamiento", y hasta acá eso solo abría un modal mock
// (#agenda-notif-modal) sin mandar nada. Los recordatorios configurados
// tampoco salían: solo se calculaba `agenda_eventos.recordatorio_24h` para
// mostrarlo en el detalle del evento.
//
// Body: { establecimientoId, eventoId, accion: 'creado'|'actualizado'|'eliminado' }
//
// El evento se RELEE de la base, no se confía en lo que mande el navegador:
// así el correo dice lo que quedó realmente guardado, y un cliente no puede
// hacer que se manden correos con datos que nunca se persistieron. Por eso el
// navegador tiene que llamar a este endpoint ANTES de borrar la fila cuando la
// acción es 'eliminado'.

const { autorizar, sbSelect, SUPABASE_URL } = require('./_lib/supabase');
const { encolar, cancelarPendientesDe, procesarPendientes } = require('./_lib/bandeja');
const { instanteDesdeLocal, fechaHumana, zonaValida } = require('./_lib/fechas');
const { emailValido } = require('./_lib/correo');

// Espejo de AGENDA_TIPO_LABELS / los <option> de #ag-estado en index.html.
// Está duplicado porque el cron de recordatorios corre sin navegador y tiene
// que poder rotular un evento agendado hace una semana. Si se agrega un tipo
// de cita en index.html, hay que agregarlo también acá o el correo mostrará
// el código crudo.
const TIPO_LABELS = {
  consulta: 'Consulta', vacunacion: 'Vacunación', cirugia: 'Cirugía',
  desparasitacion: 'Desparasitación', control: 'Control',
  imagenes_diagnosticas: 'Imágenes diagnósticas', examenes_laboratorio: 'Exámenes de laboratorio',
  revision: 'Revisión', consulta_especializada: 'Consulta especializada', otro: 'Otro'
};
const ESTADO_LABELS = {
  programada: 'Programada', confirmada: 'Confirmada', en_curso: 'En curso',
  completada: 'Completada', no_asistio: 'No asistió', cancelada: 'Cancelada'
};

const TIPO_POR_ACCION = {
  creado: 'agenda_evento_creado',
  actualizado: 'agenda_evento_actualizado',
  eliminado: 'agenda_evento_cancelado'
};

// Quién agendó la cita. Sale de `agenda_eventos.created_by`, no de quien esté
// llamando ahora: editar una cita no cambia quién la reservó.
//
// **Si quien agendó es un administrador se muestra el nombre de la CLÍNICA**,
// no su nombre personal — pedido explícito del cliente y además lo correcto de
// cara al tutor: cuando reserva la clínica, el interlocutor es la clínica, no
// la persona detrás del mostrador. Para médico/auxiliar/ventas sí va el nombre
// propio, que es con quien el tutor va a hablar.
async function resolverAgendadoPor(evento, establecimientoId, nombreClinica) {
  if (!evento.created_by) return nombreClinica;
  try {
    const membresias = await sbSelect(
      'memberships',
      `select=rol&user_id=eq.${encodeURIComponent(evento.created_by)}&establecimiento_id=eq.${encodeURIComponent(establecimientoId)}&limit=1`
    );
    const rol = membresias && membresias[0] ? membresias[0].rol : null;
    if (rol === 'admin' || !rol) return nombreClinica;

    const perfiles = await sbSelect(
      'profiles',
      `select=nombre&id=eq.${encodeURIComponent(evento.created_by)}&limit=1`
    );
    const nombre = perfiles && perfiles[0] ? (perfiles[0].nombre || '').trim() : '';
    return nombre || nombreClinica;
  } catch (_) {
    // Un fallo acá no puede tumbar la notificación: el nombre de la clínica
    // es un valor por defecto correcto, no un relleno.
    return nombreClinica;
  }
}

// El bucket `logos-clinica` es público (getPublicUrl en index.html), así que la
// URL sirve tal cual dentro de un correo. Se arma a mano en vez de usar el
// cliente de Supabase para no traer el SDK a la función.
function urlLogoClinica(logoPath) {
  if (!logoPath) return null;
  return `${SUPABASE_URL}/storage/v1/object/public/logos-clinica/${logoPath.split('/').map(encodeURIComponent).join('/')}`;
}

function asuntoDe(tipo, p, rol) {
  const cuando = fechaHumana(p.inicioLocal, { sinHora: p.sinHora });
  const quien = p.mascota ? ` de ${p.mascota}` : '';
  if (tipo === 'agenda_evento_cancelado') return `Cita cancelada${quien} — ${cuando}`;
  if (tipo === 'agenda_evento_actualizado') return `Cambió la cita${quien} — ${cuando}`;
  if (tipo === 'agenda_recordatorio') return `Recordatorio: cita${quien} el ${cuando}`;
  return rol === 'tutor' ? `Cita agendada${quien} — ${cuando}` : `Nueva cita${quien} — ${cuando}`;
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Método no permitido, usa POST' });
    return;
  }

  const { establecimientoId, eventoId, accion } = req.body || {};
  const tipoCorreo = TIPO_POR_ACCION[accion];
  if (!eventoId || !tipoCorreo) {
    res.status(400).json({ error: 'Faltan eventoId o accion (creado|actualizado|eliminado)' });
    return;
  }

  const permiso = await autorizar(req, establecimientoId);
  if (permiso.error) {
    res.status(permiso.estado).json({ error: permiso.error });
    return;
  }

  try {
    const eventos = await sbSelect('agenda_eventos', `select=*&id=eq.${encodeURIComponent(eventoId)}&limit=1`);
    const ev = eventos && eventos[0];
    // El evento tiene que existir y ser de la clínica del usuario: sin este
    // chequeo, un miembro de la clínica A notificaría eventos de la B.
    if (!ev || ev.establecimiento_id !== establecimientoId) {
      res.status(404).json({ error: 'El evento no existe en esta clínica' });
      return;
    }

    const estabs = await sbSelect('establecimientos', `select=*&id=eq.${encodeURIComponent(establecimientoId)}&limit=1`);
    const estab = (estabs && estabs[0]) || {};
    const zona = zonaValida(estab.zona_horaria);

    // Reagendar o eliminar invalida todo lo que quedaba por salir de este
    // evento: sin esto, el tutor recibiría el recordatorio de una cita movida
    // (o cancelada) a la hora vieja.
    await cancelarPendientesDe('agenda_eventos', eventoId);

    // Email del tutor: se relee de `propietarios` para que salga el actual si
    // lo cambió después de agendar; el guardado en la fila del evento es el
    // respaldo para tutores ya borrados.
    let emailTutor = ev.propietario_email || null;
    let nombreTutor = ev.propietario || null;
    if (ev.propietario_id) {
      const props = await sbSelect('propietarios', `select=nombre,email&id=eq.${encodeURIComponent(ev.propietario_id)}&limit=1`);
      if (props && props[0]) {
        emailTutor = props[0].email || emailTutor;
        nombreTutor = props[0].nombre || nombreTutor;
      }
    }

    // SEQUENCE del .ics: tiene que subir en cada cambio o el calendario del
    // destinatario ignora la actualización. Se cuentan las notificaciones ya
    // emitidas para este evento en vez de inventar un contador nuevo.
    let secuencia = 0;
    try {
      const previos = await sbSelect(
        'correos',
        `select=id&referencia_id=eq.${encodeURIComponent(eventoId)}&tipo=like.agenda_evento_%25&limit=200`
      );
      secuencia = (previos || []).length;
    } catch (_) { /* el .ics sale con SEQUENCE:0, no vale la pena abortar */ }

    const nombreClinica = estab.nombre || 'IRIS';
    const agendadoPor = await resolverAgendadoPor(ev, establecimientoId, nombreClinica);
    const direccionClinica = [estab.direccion, estab.ciudad].filter(Boolean).join(', ');

    const payloadBase = {
      eventoId,
      secuencia,
      clinica: nombreClinica,
      // Identidad de la clínica en el correo: quien lo lee tiene que saber
      // quién le escribe (puede atenderse en más de una veterinaria) y a
      // dónde llamar si necesita reprogramar.
      logoUrl: urlLogoClinica(estab.logo_path),
      ciudadClinica: estab.ciudad || null,
      direccionClinica: direccionClinica || null,
      telefonoClinica: estab.telefono || null,
      correoClinica: emailValido(estab.correo_contacto) ? estab.correo_contacto.trim() : null,
      agendadoPor,
      acento: (req.body && req.body.acento) || null,
      zona,
      titulo: ev.titulo,
      tipoLabel: TIPO_LABELS[ev.tipo] || ev.tipo,
      estadoLabel: ESTADO_LABELS[ev.estado] || ev.estado,
      inicioLocal: ev.start_iso,
      finLocal: ev.end_iso,
      sinHora: !!ev.sin_hora,
      // Sin lugar explícito se asume la sede: es lo que pasa en la inmensa
      // mayoría de las citas, y "Lugar: —" obligaría al tutor a preguntar. Un
      // servicio a domicilio siempre trae el campo lleno (los atajos del modal
      // de Agenda ponen ahí la dirección del tutor).
      lugar: ev.lugar || direccionClinica || null,
      descripcion: ev.descripcion || null,
      mascota: ev.mascota_nombre || null,
      propietario: nombreTutor,
      encargadoNombre: ev.encargado_nombre || null
    };

    // Destinatarios. "Solo reservar espacio" no tiene tutor, y un evento sin
    // encargado con correo tampoco: cada uno se cae solo si falta el dato.
    //
    // PRIVACIDAD: cada uno recibe su PROPIO correo (una fila de `correos` por
    // destinatario, sin CC), y ni el cuerpo ni el .ics pueden llevar la
    // dirección de los otros. El correo que sí comparten los tres es el de la
    // clínica: va en el pie, en el reply-to y como ORGANIZER del .ics, que es
    // el canal por el que tutor y médico deben comunicarse. Por eso el payload
    // que se guarda en la bandeja YA NO lleva la lista de asistentes del
    // evento: el .ics se arma en `plantillaAgenda()` con el destinatario de la
    // fila y con nadie más.
    const candidatos = [
      { rol: 'tutor', email: emailTutor, nombre: nombreTutor },
      { rol: 'encargado', email: ev.encargado_email, nombre: ev.encargado_nombre },
      { rol: 'clinica', email: estab.correo_contacto, nombre: estab.nombre }
    ];
    const vistos = new Set();
    const destinatarios = candidatos.filter(d => {
      const email = String(d.email || '').trim().toLowerCase();
      if (!emailValido(email) || vistos.has(email)) return false;
      vistos.add(email);
      d.email = email;
      return true;
    });

    const aEncolar = [];
    const ahora = new Date().toISOString();

    // 1. Aviso inmediato — solo si el establecimiento tiene el interruptor
    //    "Notificaciones" activo.
    if (estab.notif_email_evento !== false) {
      destinatarios.forEach(d => {
        aEncolar.push({
          establecimiento_id: establecimientoId,
          tipo: tipoCorreo,
          referencia_tabla: 'agenda_eventos',
          referencia_id: eventoId,
          destinatario_email: d.email,
          destinatario_nombre: d.nombre,
          rol_destinatario: d.rol,
          asunto: asuntoDe(tipoCorreo, payloadBase, d.rol),
          payload: payloadBase,
          programado_para: ahora,
          created_by: permiso.usuario.id
        });
      });
    }

    // 2. Recordatorios programados. La pantalla los rotula "Recordatorios al
    //    propietario", así que van solo al tutor. Solo el canal 'email': los
    //    de WhatsApp/SMS siguen sin integración de envío y encolarlos acá
    //    haría creer que salieron.
    const recordatorios = Array.isArray(estab.recordatorios) ? estab.recordatorios : [];
    const inicioReal = instanteDesdeLocal(ev.start_iso, zona);
    const programados = [];
    const tutor = destinatarios.find(d => d.rol === 'tutor');

    if (accion !== 'eliminado' && ev.estado !== 'cancelada' && tutor && inicioReal) {
      recordatorios.forEach(r => {
        const canales = Array.isArray(r.canales) ? r.canales : [];
        if (!canales.includes('email')) return;
        const cantidad = Number(r.cantidad);
        if (!isFinite(cantidad) || cantidad <= 0) return;
        const ms = cantidad * (r.unidad === 'horas' ? 3600000 : 86400000);
        const cuando = new Date(inicioReal.getTime() - ms);
        // Un recordatorio cuyo momento ya pasó no se manda: agendar hoy una
        // cita para mañana no puede disparar al instante el aviso "de 7 días
        // antes".
        if (cuando.getTime() <= Date.now()) return;
        const payload = { ...payloadBase, antelacion: `${cantidad} ${r.unidad === 'horas' ? (cantidad === 1 ? 'hora' : 'horas') : (cantidad === 1 ? 'día' : 'días')}` };
        aEncolar.push({
          establecimiento_id: establecimientoId,
          tipo: 'agenda_recordatorio',
          referencia_tabla: 'agenda_eventos',
          referencia_id: eventoId,
          destinatario_email: tutor.email,
          destinatario_nombre: tutor.nombre,
          rol_destinatario: 'tutor',
          asunto: asuntoDe('agenda_recordatorio', payload, 'tutor'),
          payload,
          programado_para: cuando.toISOString(),
          created_by: permiso.usuario.id
        });
        programados.push({ cuando: cuando.toISOString(), antelacion: payload.antelacion, email: tutor.email });
      });
    }

    const insertadas = await encolar(aEncolar);

    // Se procesa en el acto lo que ya vencía (los avisos inmediatos). Los
    // recordatorios quedan para el cron de cada 5 minutos.
    let resumen = { enviados: 0, fallidos: 0 };
    if (insertadas.some(f => new Date(f.programado_para).getTime() <= Date.now())) {
      resumen = await procesarPendientes(20);
    }

    res.status(200).json({
      ok: true,
      notificacionesActivas: estab.notif_email_evento !== false,
      destinatarios: destinatarios.map(d => ({ rol: d.rol, email: d.email, nombre: d.nombre })),
      recordatoriosProgramados: programados,
      enviados: resumen.enviados || 0,
      fallidos: resumen.fallidos || 0,
      detalle: resumen.detalle || []
    });
  } catch (err) {
    res.status(500).json({ error: err.message || String(err) });
  }
};
