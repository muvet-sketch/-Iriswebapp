# IRIS SaaS — Prototipo HTML (MUVET)

## Qué es esto
Prototipo visual estático de la webapp IRIS (clínica veterinaria SaaS).
Un solo archivo `index.html` con TODO el shell + módulos ya construidos
(HTML+CSS+JS inline, sin framework, sin backend real).

**`login.html` ya NO existe como archivo separado.** El flujo de
autenticación (login, selección de rol, crear/vincular establecimiento,
pantalla de aprobación pendiente con el bypass "Simular aprobación y
continuar") vive dentro de `index.html`, en `<div id="auth-shell">`,
justo después de `<body>`, con su propio `<script>` inmediatamente
después (mismo scope global que el resto — sin `type="module"`). El
shell normal (header/nav/sidebar de 18 módulos) vive en
`<div id="app-shell">`, más abajo en el mismo archivo. Al cargar la
página, `mostrarShellSegunSesion()` decide cuál de los dos se muestra
según `localStorage.getItem('iris_session_active')`. El auth shell
"loguea" llamando a `entrarAlShellDesdeAuth(roleKey)` (definida en el
script del auth shell), que fija `iris_session_active`/`iris_sim_role`
en localStorage y llama a `mostrarShellSegunSesion()` (definida en el
script del app shell) — no hay recarga de página, es solo un cambio de
vista. "Cerrar sesión" en el dropdown de perfil llama a `cerrarSesion()`.
El CSS del auth shell está en el mismo `<style>` de `<head>`, con cada
selector prefijado `#auth-shell ...` para no chocar con `.card`,
`.btn-primary`, etc. del shell principal (mismos nombres de clase,
scope distinto). Si un módulo futuro necesita saber si hay "sesión
simulada" activa, usa esas mismas funciones — no inventes un mecanismo
paralelo.

**Trampa ya sufrida DOS VECES (bug corregido) — orden de ejecución
dentro del `<script>` del app shell:** `mostrarShellSegunSesion()` está
DEFINIDA cerca del principio de ese script, pero su llamada inicial
real vive al FINAL del `<script>` (justo antes de que cierre, después
de `renderUsuariosTable(); renderPrivilegiosMatrix();` — reemplazó ahí
a un `applySimRole()` suelto que ya existía). Motivo: cuando hay
sesión activa en `localStorage` (ej. al volver de `dashboard.html` o
recargar ya logueado), esa llamada dispara `applySimRole()` →
`applyTabRoleVisibility()` (lee `tabs`/`tabContents`) y también →
`refreshRowActionMenus()` (lee `ROW_ACTION_DEFS` y `kardexContext`).
La PRIMERA vez que este bug apareció, la llamada vivía justo después
del bloque "NAVEGACIÓN NIVEL 1" (que declara `tabs`/`tabContents`) y
eso alcanzaba. Pero el código siguió creciendo, `ROW_ACTION_DEFS` y
`kardexContext` se agregaron MUCHO más abajo en el mismo script, y la
llamada volvió a disparar el mismo bug (esta vez por esas dos
variables). Si la llamada ocurre antes de que CUALQUIERA de esas
`const`/`let` se ejecute, es un acceso en temporal dead zone →
`ReferenceError` sin ningún mensaje visible para el usuario → aborta
el resto del script → todo lo que se inicializa después en ese mismo
`<script>` (tabs de nivel 1, menús "...", módulos nuevos, etc.) se
queda sin funcionar, de forma persistente en cada recarga mientras la
sesión siga activa. Por eso la llamada ahora vive al final del
script: es la única posición que no puede quedar desactualizada por
código nuevo agregado en medio. **No la muevas más arriba** aunque
parezca que "ya no hace falta esperar tanto" — si en el futuro hace
falta adelantarla, hay que verificar línea por línea TODA la cadena de
llamadas que dispara (no solo la parte que causó el bug la última
vez), incluyendo cualquier `const`/`let` de nivel superior que lea
directa o indirectamente (los `const`/`let` de nivel superior NO están
hoisted como sí lo están las `function`).

**Trampa relacionada (real, no solo teórica) — nunca escribas la
secuencia literal `</script>` dentro de un comentario o string JS
dentro de un `<script>` de este archivo**, ni siquiera describiendo
"el script" en prosa. El parser HTML cierra la etiqueta `<script>` en
cuanto ve esa secuencia de caracteres, sin que importe que esté dentro
de un comentario `//` — corta el bloque de JS a la mitad y produce
errores de sintaxis con mensajes que no apuntan para nada a la causa
real (ej. `Unexpected identifier '...'` señalando texto de un
comentario cercano). Si necesitás referirte a la etiqueta en un
comentario, escribilo distinto (ej. "este bloque de script" o "donde
cierra el script") en vez del literal `</script>`.

## NO hacer
- No crear archivos nuevos por módulo. Todo módulo nuevo se integra
  DENTRO de index.html, reutilizando el shell existente.
- No inventar nomenclatura clínica nueva. El formato de consulta es
  SIEMPRE S/O/I/P — SOIP, no SOAP — (Subjetivo/Objetivo/Interpretación/
  Plan). La letra "I" reemplazó a la "A" de Assessment en toda la app
  (ids `soap-i`/`tablero-soap-i`, campo `interpretacion` en
  `patientData[petKey].consultas`/timeline y en la columna Supabase
  `consultas.interpretacion`) — no reintroduzcas "Assessment"/"A" ni
  inventes una tercera variante.
- No conectar a base de datos real todavía — todo está simulado en
  memoria con JS (arrays/objetos mock).

## Patrones ya establecidos — reutilizar, no reinventar
- `ROLES` (objeto JS): privilegios por defecto de Administrador/Médico
  Veterinario/Auxiliar/Ventas. El selector "Viendo como" simula rol activo.
- `patientData`: datos mock por mascota (timeline, consultas, etc.)
- `CATALOGO_PRODUCTOS_SERVICIOS`: catálogo mock usado SOLO por
  Consultorio > Órdenes (detalle según tipo de orden) — no confundir con
  el catálogo de Inventario/Ventas, que es `VENTAS_CATALOGO` (+
  `VENTAS_CATEGORIAS`/`VENTAS_PROVEEDORES`), ya integrado entre ambos
  módulos.
- Menú de acciones "..." por fila (Ver/Editar/Imprimir/Email/Eliminar),
  ya implementado en Consultas — reutilizar en cada módulo nuevo.
- `showToast(msg)`: función ya existente para notificaciones.
- Modales: mismo patrón `.modal-overlay` / `.modal-card` con
  `onclick="event.stopPropagation()"` para no cerrar al click interno.
- Paleta: variables CSS `--clinic-accent`, `--surface`, `--border`,
  `--text-1`, `--text-2` — nunca hardcodear colores nuevos.
- Restricción de tabs de nivel 1 por rol: objeto `TAB_ROLE_RESTRICTIONS`
  (mapa `data-tab` → array de roles permitidos) + función
  `applyTabRoleVisibility()`, llamada desde `applySimRole()`. A
  diferencia del sidebar de Consultorio (que bloquea visualmente con
  candado, `.sidebar-item.locked`, porque Ventas sí ve la mayoría de
  esos módulos salvo excepciones puntuales), un tab de nivel 1
  restringido se OCULTA por completo (`.tab-btn.role-hidden`,
  `display:none`) para los roles sin acceso — no aparece en el
  top-nav. Si el tab oculto estaba activo al cambiar de rol, se
  redirige automáticamente a Consultorio. Para restringir un tab
  futuro, solo agrega su entrada a `TAB_ROLE_RESTRICTIONS`, ej.
  `{ admin: ['admin'], facturacion: ['admin', 'ventas'] }` — no hace
  falta tocar el resto de la lógica.
- Patrón "resultado vinculado a orden + timeline de Historia" (usado en
  Resultados de Órdenes de Imagen diagnóstica/Prueba-Examen; reutilizar
  para Vacunaciones, Cirugías y Hospitalizaciones):
  - El registro del "resultado"/"evento clínico" vive en su propio
    array mock dentro de `patientData[petKey]` (ej. `resultados`) y
    guarda un `ordenIndex` (o el índice/id del registro origen) para
    poder ubicar y actualizar ese registro origen — nunca duplicar los
    datos de la orden dentro del resultado.
  - El registro origen (la orden) tiene un campo `estado` propio
    (`pendiente` → `completado`) independiente del `estado` del
    resultado (`borrador` → `finalizado`, mismo patrón de dos estados
    que Documentos con Borrador/Firmado). Solo la acción de FINALIZAR
    (no la de guardar borrador) escribe `estado: 'completado'` en el
    registro origen.
  - Al finalizar, se hace `data.timeline.unshift({...})` sobre el
    mismo array que ya pinta `renderHistoriaTimeline()` (el que usan
    las Consultas SOIP) — no crear un timeline paralelo.
  - El punto de entrada es una acción condicional en el menú "..." del
    registro origen (extra action agregada vía el 4º parámetro de
    `renderRowActionsMenu(moduleKey, recordId, extraActions)`),
    visible solo cuando aplica (tipo correcto Y `estado !== 'completado'`).
    Si ya existe un resultado en borrador para ese origen, la acción
    debe reabrirlo en modo edición en vez de crear uno duplicado.
  - Si se elimina el resultado, el registro origen debe volver a su
    estado previo a completado (no queda huérfano en "Completado" sin
    resultado real).
- Componente "Foto + Peso + Datos generales": fusionado dentro de
  `.pet-header-card` (la cabecera del paciente en el Consultorio,
  visible en TODOS los subtabs — Historia, Consultas, Fórmulas, etc.,
  no solo Historia). Antes eran dos bloques apilados: la franja de
  identidad (`.pet-header-card`, foto/nombre/meta/acciones) arriba y
  una tarjeta `#historia-pet-general` aparte (solo en Historia) con
  foto+peso+datos generales debajo — se veían como datos repetidos
  (Especie/Raza/Peso/Edad/Chip aparecían en ambos bloques) y ahora es
  una sola tarjeta con dos filas (`.pet-header-top-row` con la
  identidad y `.pet-header-bottom-row` con histórico de peso + datos
  generales). El avatar de la fila de identidad (`#pet-header-photo`,
  clase `.pet-photo-circle`, no ya `.pet-profile-avatar`) es ahora la
  ÚNICA foto de la mascota en esta pantalla y muestra la imagen real
  (`data.fotoUrl`) con el mismo botón de cámara editable — antes era
  una tarjeta de foto aparte y el avatar de la cabecera solo mostraba
  la inicial del nombre. "Editar mascota" vive ahora en
  `.pet-header-right` junto a "Volver a buscar"/"Nueva Consulta" (antes
  estaba debajo de la foto). `petDataTableHTML(data)` YA NO repite
  Especie/Raza/Peso/Edad/Código-Chip (esos siguen en la fila de
  identidad, `#pet-profile-species/-breed/-weight/-age/-chip`) — solo
  trae Color/Género/Talla/Estado reproductivo/Animal de servicio/
  Fallecido; si se agrega un campo nuevo de mascota a esta tabla,
  verificar primero que no esté ya en la fila de identidad para no
  reintroducir la misma redundancia.
  - `mountPetGeneralCard(containerId, petKey)` — con `containerId`
    fijo `'pet-header'` (ids `pet-header-photo`/`-table`/
    `-weight-chart`, ya existentes en el HTML de `.pet-header-card`,
    no un template que la función inyecte). El Kardex de
    Hospitalizaciones tiene su propio header independiente
    (`mountKardexHeader`) que replica la misma lógica de foto —
    no reutiliza esta función ni esta tarjeta.
  - `renderWeightChartSVG(containerId, pesoHistorico)` es la pieza
    atómica reutilizable por separado (usada también en el header del
    Kardex de Hospitalizaciones) — línea de tiempo simple con tooltip
    al pasar el mouse. **Importante:** el `<svg>` interno solo dibuja
    la línea (`viewBox="0 0 100 100"` con `preserveAspectRatio="none"`,
    y `vector-effect="non-scaling-stroke"` en el trazo). Los puntos y
    las etiquetas del eje X se pintan como HTML normal posicionado en
    `%` ENCIMA del SVG, nunca como `<circle>`/`<text>` dentro de ese
    mismo viewBox — esa combinación de viewBox + preserveAspectRatio
    escala X e Y de forma no uniforme y deforma círculos/texto
    (óvalos, texto aplastado). Si se agrega un punto nuevo a un
    gráfico de este tipo, síguelo pintando fuera del `<svg>`.
  - Los campos de mascota mock (`color`, `genero`, `talla`,
    `estadoReproductivo`, `animalServicio`, `fallecido`,
    `alimentacion`, `vivienda`, `frecuenciaBano`, `fotoUrl`,
    `pesoHistorico`, `ownerPhone`) viven en `patientData[petKey]`
    junto a los campos originales — son los únicos campos nuevos de
    mascota agregados hasta ahora; no agregues más sin que se pidan.
  - "Editar mascota" abre `#editar-mascota-modal`
    (`openEditMascotaModal(petKey)` / `guardarMascotaEdit()`) y
    refresca tanto la ficha de Historia como el header del Kardex si
    corresponde al mismo paciente.
  - Edad de la mascota: el formulario (crear/editar) NUNCA guarda un
    texto libre de edad. El campo "Edad" es un select de 3 modos (En
    años / En meses / Fecha de nacimiento exacta,
    `#<prefix>-edad-tipo` con `onChangeEdadTipo(prefix)` alternando
    entre `#<prefix>-edad-cantidad` y `#<prefix>-edad-fecha`) que
    siempre se resuelve a una FECHA (`calcularFechaNacimientoDesdeEdadInputs(prefix)`
    — si el modo es años/meses, resta esa cantidad a hoy para
    aproximar la fecha de nacimiento; si es fecha exacta, la usa tal
    cual). Esa fecha es lo único que se persiste
    (`patientData[petKey].fechaNacimiento` / columna
    `mascotas.fecha_nacimiento`, `date`, agregada vía migración — no
    existía en el schema original). La edad mostrada en cualquier
    lugar (ficha de Historia, header del paciente, etc.) se calcula
    SIEMPRE a partir de esa fecha vía `edadTextoParaMostrar(data)` →
    `formatearEdadYMD(fechaISO)` (formato "X años, Y meses, Z días",
    omitiendo las unidades en 0 salvo que todas lo sean), nunca se
    guarda como string fijo — así se mantiene correcta con el paso
    del tiempo en vez de quedar congelada en lo que se escribió al
    registrar. El campo legado `data.age`/`mascotas.edad` (texto) solo
    sirve de respaldo en `edadTextoParaMostrar` para mascotas viejas
    sin `fechaNacimiento`. Al editar una mascota que ya tiene
    `fechaNacimiento`, el modal siempre precarga el modo "Fecha exacta"
    con ese valor (reconstruir años/meses desde ahí sería ambiguo).
  - `renderWeightChartSVG` (Histórico de peso) pinta además números de
    kg a la izquierda del gráfico (`.weight-chart-yaxis`, 3 ticks:
    máximo/medio/mínimo, alineados al mismo padTop/padBottom que ya
    usan los puntos) y la fecha completa dd/mm/aaaa debajo de cada
    punto (antes solo dd/mm) — mismo criterio de "pintar fuera del
    `<svg>`" del punto anterior, aplica también a estos ticks nuevos.
- Patrón de Kardex (Hospitalizaciones/ambulatorios, `abrirKardex()`):
  - Es una "pantalla completa" propia (`#kardex-view`, hermana de
    `#consultorio-search-view`/`#consultorio-patient-view` dentro de
    `#tab-consultorio`), no un subtab más. Al abrirla hay que ocultar
    **el wrapper `.consultorio-wrapper` completo** (no solo quitar
    `.active` de `#consultorio-patient-view`) porque ambos son
    `flex:1` dentro del mismo contenedor flex — si el wrapper se deja
    visible (aunque esté "vacío"), se sigue llevando la mitad del
    ancho. `cerrarKardexAConsultorio()` / `verEnConsultorioDesdeKardex()`
    restauran `display:''` en el wrapper al salir.
  - Estructura de datos: `patientData[petKey].hospitalizaciones[]`
    (registro de ingreso/salida) → cada uno con `dias[]` (un
    acordeón por día/turno) → cada día con `tratamientos[]`
    (medicamento/fluidoterapia/procedimiento/alimentación, todos con
    un array `horas` de 24 booleanos) y `signos` (8 filas fijas de
    signos vitales, cada una un array de 24 strings). `seguimientos[]`
    vive en el registro de hospitalización, no por día.
  - La grilla horaria SÍ calcula periodicidad real:
    `calcularHorasPorPeriodicidad(periodicidad, horaInicialStr)` (junto
    a `renderTratamientoHoraGrid`/`toggleTtHoraGridCell`) recibe los
    valores de `#tt-periodicidad` + `#tt-hora-inicial` y devuelve el
    array de 24 booleanos correspondiente (SID/UD/C2D/C3D/B2M → 1 hora;
    BID/TID/QID → 2/3/4 horas equiespaciadas con wraparound de 24h;
    C4H/C3H/C2H → todas las horas del ciclo; CONST → las 24; Manual →
    `null`, es decir "no toques nada"). Los 4 tipos de tratamiento
    (Medicamento/Fluidoterapia/Procedimiento/Alimentación) reutilizan
    el MISMO modal `#tratamiento-modal` (no hay 4 modales separados),
    así que esta función y su disparador
    `aplicarAutoRellenoTtHoraGrid()` (enlazado por `onchange` en ambos
    campos) sirven para los 4 sin duplicar nada. El auto-relleno solo
    se dispara en esos dos `onchange` — marcar/desmarcar celdas a mano
    (`toggleTtHoraGridCell`) NO lo vuelve a llamar, así que la edición
    manual del usuario queda intacta hasta que cambie de nuevo
    Periodicidad u Hora inicial. Los ciclos multi-día (C2D/C3D/B2M)
    solo marcan la hora del día en la grilla de hoy — la repetición
    entre días la sigue manejando el campo Duración existente.
  - Restricción de rol (`puedeProgramarTratamientos()` → solo
    `currentSimRole === 'medico'`): controla el toggle "Modo
    programación" Y todo lo que dependa de tenerlo activo (crear
    tratamiento vía "Registrar nuevo", editar/eliminar fila de
    tratamiento — editar el registro de hospitalización en sí ya lo
    cubre el sistema genérico `getRowActionsForRole()`, no hace falta
    duplicarlo). Marcar/desmarcar los puntos de la grilla horaria,
    llenar signos vitales y registrar seguimientos son acciones
    DISTINTAS, disponibles para Auxiliar sin ese modo — no las
    gatees con `puedeProgramarTratamientos()`.
  - El widget "Viendo como" (`.role-sim-widget`) está duplicado en el
    header del Kardex además del header de Historia — si se agrega
    otra pantalla de tipo "kardex" (pantalla completa fuera del
    patient-view), agrégaselo también, si no, no hay forma de probar
    la restricción de rol sin salir de esa pantalla.

## Sidebar de Consultorio (18 módulos, orden fijo)
Historia · Consultas · Vacunaciones · Fórmulas médicas ·
Desparasitaciones · Hospitalizaciones/ambulatorios ·
Cirugías/procedimientos · Órdenes · Tareas Pendientes ·
Exámenes de laboratorio · Imágenes diagnósticas · Peluquería y spa ·
Guardería · Seguimientos · Documentos · Remisiones · Citas ·
Mensajes al propietario

## Ya construido
Consultas, Fórmulas médicas, Órdenes (con catálogo mock dinámico) +
Resultados (sub-tabla vinculada a Órdenes de Imagen diagnóstica/
Prueba-Examen, ver patrón "resultado vinculado a orden" arriba),
Documentos (plantillas + firma simulada), Admin — Usuarios (Vista A,
crear/editar/desactivar) y Privilegios (Vista B, matriz de referencia
de solo lectura); tab de nivel 1 visible solo para Administrador.
Ficha general del paciente (Historia) con el componente reutilizable
foto+peso+datos generales (ver patrón arriba). Hospitalizaciones/
ambulatorios completo: lista + modal de registro, Kardex/Trazabilidad
de pantalla completa con acordeón por día, grilla horaria de 24h para
tratamientos (Medicamento/Fluidoterapia/Procedimiento/Alimentación)
con auto-relleno por Periodicidad + Hora inicial (ver patrón de Kardex
arriba) y signos vitales, Seguimientos, y restricción de rol para
"Modo programación" (ver patrón de Kardex arriba). Auth shell (login,
registro de clínica, vinculación, aprobación pendiente con bypass de
prototipo) integrado como estado inicial de `index.html` (ver sección
"Qué es esto"). "Registrar propietario" (buscador de Consultorio):
modal `#registrar-propietario-modal` (`openRegistrarPropietarioModal()`
/ `guardarPropietario()`) con validación de campos obligatorios y de
términos y condiciones; los propietarios nuevos se guardan en el
array `propietarios` y se insertan como fila en
`#propietarios-tbody` (los 3 propietarios de ejemplo siguen siendo
filas estáticas del HTML, no vienen de ese array). Vacunaciones y
Desparasitaciones: formulario simple (sin patrón de dos estados
borrador/finalizado, a diferencia de Resultados) + lista + timeline de
Historia, mismo patrón de catálogo mock ampliable "+Registrar X" que
Hospitalizaciones (`getVacunasCatalogo()`/`registrarNuevaVacuna()` y
`getTiposDesparasitacion()`/`registrarNuevoTipoDesparasitacion()`, cada
uno con su propio array `...Custom` en memoria). El timeline solo se
agrega al CREAR (no al editar un registro existente), para no duplicar
eventos de historia en cada edición — mismo criterio a seguir en
futuros módulos de este tipo que no sigan el patrón de dos estados de
Resultados. Las alertas de vencimiento a partir de "próxima
vacunación"/"próximo control" ya están resueltas vía Agenda > Eventos
(ver más abajo) — el TODO que existía sobre esto ya no aplica.

Agenda ampliada con sub-navegación (`.admin-subview-tabs`, función
`switchAgendaView()`) en 4 vistas: **Agenda general** (la vista
FullCalendar original, sin cambios), **Agenda personal** (filtrada al
usuario simulado actual vía `CURRENT_SIM_USER_ID_BY_ROLE`/
`getCurrentSimUserId()` — extensión del mismo criterio que
`CURRENT_MEDICO_SIM_ID`; toggle Mes/Semana/Día/Lista, Lista por
defecto agrupada por día), **Disponibilidad / Programador** (grilla
propia de bloques de 30 min por encargado en `DISPONIBILIDAD_MEDICOS`,
click cicla Disponible/No disponible/Bloqueado vía
`toggleDisponibilidadCell()` — sin plugin de recursos de FullCalendar;
`chequearDisponibilidadAgendaModal()` solo advierte, no bloquea, al
crear un evento en un horario marcado; sus columnas salen de la misma
lista que el select de Encargado del modal, ver abajo) y **Eventos**
(`EVENTOS_SEGUIMIENTO`,
generados automáticamente por `crearEventoSeguimiento()` desde
Vacunaciones/Desparasitaciones/Seguimientos al guardar con fecha de
próximo control diligenciada — create-only, mismo criterio que el
timeline; acción "Agendar" reabre `#agenda-evento-modal` precargado y
vincula el ítem al evento creado). `guardarEventoAgenda()` también
calcula `recordatorio24hISO` (mock, Tarea 3) y abre `#agenda-notif-modal`
listando destinatarios simulados (tutor/clínica/médico) — sin envío
real.

**`AGENDA_EVENTOS` SÍ persiste en Supabase** (tabla `agenda_eventos`,
ver `supabase/schema.sql`), igual que propietarios/mascotas/facturas/
movimientos: `guardarEventoAgenda()` es `async` y hace insert/update
BLOQUEANTE antes de tocar el array (si falla la escritura remota no se
aplica el cambio local), `eliminarEventoAgendaReal()` borra de forma
optimista, y `cargarDatosClinicaDesdeSupabase()` reconstruye el array al
iniciar sesión. El id de un evento nuevo es el uuid que devuelve el
insert — ya no existe `agendaEventSeq` ni ids `ag-N` (esos sobreviven
solo como semilla de la clínica demo, que `sembrarDemoEnSupabase()`
inserta una vez). Por eso `resetMockDataForClinic()` ya NO resetea
`AGENDA_EVENTOS`. Detalle importante del esquema: `start_iso`/`end_iso`/
`recordatorio_24h` son `timestamp` SIN zona horaria a propósito — todo
el módulo trabaja con cadenas locales ingenuas (`'2026-07-06T09:00:00'`,
con `.split('T')` por todas partes) y con `timestamptz` PostgREST las
devolvería en UTC con offset, rompiendo FullCalendar y el formateo. Lo
que sigue mock en Agenda: `EVENTOS_SEGUIMIENTO` y
`DISPONIBILIDAD_MEDICOS`.

**Trampa de zona horaria (ya sufrida en el Dashboard) — `fechaISO` NO
siempre es una fecha local ingenua.** `consultas.fecha_hora` sí es
`timestamptz` (a diferencia de `agenda_eventos`, ver arriba) y además
`guardarConsulta()` la escribe con `new Date(valor).toISOString()`: el
`fechaISO` de una consulta está SIEMPRE en UTC, tanto en memoria como
al volver de Supabase. Hacer `fechaISO.slice(0, 10)` para compararlo
contra "hoy" devuelve el día UTC, que en Colombia (UTC-5) ya es el día
siguiente a partir de las 19:00 — "Consultas Hoy" contaba 0 con una
consulta guardada a las 9pm, mientras la tabla la mostraba con la
fecha de hoy (esa pasa por `formatFechaHoraCorta`, que sí convierte a
local). Para agrupar/comparar por día o mes usa
`dashDiaLocalDeISO()`/`dashMesLocalDeISO()` (módulo Dashboard): pasan
por `new Date()` solo las cadenas con zona (`Z` u offset) y dejan
intactas las ingenuas (`'2026-07-07'`, `'2026-07-07T09:00'`), que
serían corridas un día hacia atrás si se parsearan. Las fechas que el
usuario escribe a mano y se guardan en columnas `date`
(`movimientos.fecha`, `ventas_facturas.fecha`, escritas con
`VENTAS_HOY`) ya son locales y se comparan como strings, sin helper.

**"Ingresos Hoy" del Dashboard sale de `VENTAS_MOVIMIENTOS`, no de
`VENTAS_FACTURAS`.** Ingresos y Egresos es el ledger real de caja y una
factura cerrada como Pagada entra ahí sola vía
`crearMovimientoDesdeFactura()`, así que sumar facturas además de
movimientos duplicaría lo cobrado por Facturación; al revés, sumar
solo facturas dejaba el dashboard en $0 con la caja llena, porque el
registro rápido de un ingreso no crea ninguna factura. Cualquier
métrica nueva de dinero cobrado debe salir del mismo array — y
acordarse de llamar `renderDashboard()` al mutarlo
(`guardarMovimiento`/`eliminarMovimientoReal`/`confirmarCerrarCuenta`
ya lo hacen).

El botón **"Registrar propietario"** del buscador de Consultorio está
también en el header del pane de Agenda (`#btn-registrar-propietario-agenda`),
reusando el mismo `openRegistrarPropietarioModal()` — va en el header
del pane, no en el toolbar de una sub-vista, para verse en las 4 vistas.
`applySimRole()` ya no los toca por id sino por
`[data-btn-registrar-propietario]`: cualquier botón nuevo que abra ese
modal solo necesita ese atributo para heredar la restricción por rol
(`role.canRegisterOwner`).

**Encargado / médico de un evento (`#ag-encargado`) — identidad real vs.
mock:** el select se llena con `getEncargadosAgendaCandidatos()`, que son
los usuarios ACTIVOS con rol `medico` **o `admin`** (médicos primero, los
admin con el rol entre paréntesis vía `labelEncargadoAgenda()`). Antes era
solo `rol === 'medico'` y eso dejaba el select literalmente vacío —
imposible crear ningún evento — en una clínica real recién creada donde
todavía no hay ningún miembro con ese rol (el caso normal: quien crea la
clínica queda como `admin` y las invitaciones a médicos pueden seguir sin
aceptarse). Si el roster igual queda vacío, el select muestra una opción
placeholder y `guardarEventoAgenda()` avisa con un toast propio en vez del
genérico "Completa los campos obligatorios". La misma lista alimenta el
filtro del toolbar y las columnas de Disponibilidad. Relacionado: la
identidad del usuario logueado dentro de `USUARIOS_SISTEMA` sale de
`getUsuarioActualSistema()` (flag `esUsuarioActual`, que pone
`cargarUsuariosRealesDesdeSupabase()`), y `getCurrentSimUserId()` /
`getMedicoAgendaSimId()` la prefieren antes de caer a los ids fijos del
mock (`CURRENT_SIM_USER_ID_BY_ROLE` / `CURRENT_MEDICO_SIM_ID = 2`). Esos
ids fijos SOLO son válidos en el roster de demo: con datos reales los ids
son 1..N en el orden que devuelve `list_establecimiento_members`, así que
cualquier código nuevo que necesite "el usuario actual" debe usar esas
funciones y nunca las constantes directamente.

Inventario > Productos y servicios: el botón "+ Registrar" (antes
"Nuevo producto/servicio") abre el mismo `#producto-modal`, ahora con
tabs internas General/Precio (`.prod-modal-tabs`, clon de
`.kardex-tabs` adaptado a modal — mismo patrón reutilizado en
Configuración de facturación) y campos nuevos (`barcode`,
`cuantificable`, `excluidoListaPrecio`, `valorBase` con cálculo simple
Valor total ⇄ Valor base vía `TASA_TRIBUTARIA`). "Actualizar desde
Siigo" (mock) junto a Importar/Exportar Excel. Ventas > Configuración
de facturación extendida (no duplicada): la tarjeta "Método de
facturación electrónica" ahora es un bloque de 2 tabs
(`.factconfig-tabs`, mismo clon) Siigo (credenciales/impuestos/medios
de pago/grupo de inventario, todo mock) y Facturación POS (toggle +
límite + tablas `SIIGO_RESOLUCIONES`/`SIIGO_DISPOSITIVOS` con sus
modales de registro). Ventas > Clientes: botón "Importar clientes"
(`openImportarClientesModal()`) que lee un .csv (ej. export OkVet con
columnas T.Doc/Identificación/Nombre/Correo/Teléfono/Dirección) con un
parser CSV propio que respeta comillas/comas internas
(`parsearFilasCSV`), detecta las columnas por nombre de encabezado
tolerante a acentos/mayúsculas (`normalizarHeaderCSV`) y muestra un
paso de previsualización antes de confirmar — mismo patrón de 2 pasos
(seleccionar → previsualizar → confirmar) que "Importar Excel" de
Inventario, pero sin SheetJS porque el archivo es texto plano. Es
creación pura: si el número de identificación de una fila (solo
dígitos) ya coincide con un cliente existente en `VENTAS_CLIENTES`, esa
fila se omite en vez de sobreescribir.

Tareas Pendientes (18º módulo del sidebar de Consultorio, agregado
después de Órdenes): mismo patrón simple de Vacunaciones/
Desparasitaciones (formulario + lista, sin patrón de dos estados
borrador/finalizado ni timeline al crear — a diferencia de esos dos,
acá el propio registro ES el estado que importa, no hay evento
clínico que documentar en Historia). Campos: descripción, responsable
(select poblado desde `USUARIOS_SISTEMA` activos vía
`poblarSelectResponsableTarea()`), prioridad (Alta/Media/Baja, mismo
`.priority-tag`/`.priority-dot` que Órdenes pero con paleta propia
`TAREA_PRIORIDADES`, sin el selector buscable con descripción que sí
usa Órdenes), fecha límite y notas. Estado pendiente/completada NO se
edita desde el modal — se alterna con la acción extra "Marcar como
completada"/"Reabrir tarea" del menú "..." de cada fila
(`toggleEstadoTareaPendiente()`, vía el 3er parámetro `extraActions` de
`renderRowActionsMenu()`, mismo mecanismo que "Registrar resultado" en
Órdenes). El contador del sidebar (`renderTareasPendientesTable()`)
es la única excepción al criterio de "total de registros" que usan
todos los demás módulos con contador: acá cuenta solo las tareas SIN
completar, porque es el número que importa para un módulo llamado
"Tareas Pendientes" — replicar este criterio si se agrega otro módulo
con semántica de pendiente/completado y contador propio.
`patientData[petKey].tareasPendientes` se agregó tanto a los 3
pacientes mock (Luna/Toby/Milo) como a `crearScaffoldClinicoVacio()`
(mascota nueva + reconstrucción desde Supabase). Este módulo también
reemplazó a Órdenes dentro de `TABLERO_QUICKNAV_MODULOS`/
`TABLERO_NAV_ORDEN` (el nav acotado de la pantalla de "Registro de
consulta"/Tablero de trabajo, ver patrón de Kardex arriba aunque el
Tablero es una pantalla distinta) — Órdenes sigue existiendo intacto
como módulo completo del sidebar normal, simplemente ya no tiene
entrada en ese nav acotado de 10 módulos durante una consulta activa;
si se necesita volver a él desde ahí, es vía "Ver órdenes completo"
saliendo del Tablero, no hay atajo directo.

**Cirugías/procedimientos y Tareas Pendientes SÍ persisten en Supabase**
(tablas `cirugias`/`tareas_pendientes`, ver `supabase/schema.sql`) —
mismo criterio que vacunaciones/desparasitaciones: `guardarCirugia()`/
`guardarTareaPendiente()` son `async` y hacen insert/update BLOQUEANTE
antes de tocar `patientData[petKey].cirugias`/`.tareasPendientes` (si
falla la escritura remota no se aplica el cambio local),
`eliminarCirugiaReal()`/`eliminarTareaPendienteReal()` borran de forma
optimista, `toggleEstadoTareaPendiente()` también persiste el cambio
de estado, y `cargarDatosClinicaDesdeSupabase()` reconstruye ambos
arrays (más las entradas de timeline de Cirugías, vía
`construirCirugiaTimelineDesdeFila()`) al iniciar sesión. Antes vivían
solo en memoria y se perdían al refrescar la página o volver a
iniciar sesión. `medico_responsable`/`auxiliar_asignado` (Cirugías) se
guardan como texto (nombre), no como id, porque el modal ya los llena
así. `responsable_id` (Tareas Pendientes) tiene la misma limitación
que `agenda_eventos.encargado_id`: es el id LOCAL numérico de
`USUARIOS_SISTEMA`, que se regenera 1..N en cada sesión — no un uuid
estable — por eso el registro también guarda `responsable_nombre`
aparte.

**Seguimientos y Remisiones SÍ persisten en Supabase** (tablas
`seguimientos`/`remisiones`, ver `supabase/schema.sql`) — mismo
criterio que Cirugías/Tareas Pendientes arriba: `guardarSeguimiento()`/
`guardarRemision()` son `async` y hacen insert/update BLOQUEANTE antes
de tocar `patientData[petKey].seguimientos`/`.remisiones` (si falla la
escritura remota no se aplica el cambio local),
`eliminarSeguimientoReal()`/`eliminarRemisionReal()` borran de forma
optimista, y `cargarDatosClinicaDesdeSupabase()` reconstruye ambos
arrays (más sus entradas de timeline, vía
`construirSeguimientoTimelineDesdeFila()`/`construirRemisionTimelineDesdeFila()`,
mismo patrón que Cirugías) al iniciar sesión. Antes vivían solo en
memoria y se perdían al refrescar la página o volver a iniciar sesión.
`seguimientos.origen_modulo`/`origen_referencia_id` reemplazan al
objeto `origen` en memoria (`{modulo, referenciaId}`); `referenciaId`
sigue siendo `${hospId}:${diaIndex}` y `hospId` ya es el uuid real de
`hospitalizaciones.id`, así que el enlace al Kardex sigue siendo
válido tras recargar. `seguimientos.adjuntos` solo guarda `{nombre}`
por elemento (jsonb) — el archivo nunca se sube a Storage, mismo
criterio que `desparasitaciones.archivo_adjunto_nombre`, así que el
adjunto no es descargable tras recargar, solo se conserva su nombre.
`registrado_por` (Seguimientos) tiene la misma limitación que
`responsable_id` (Tareas Pendientes): id LOCAL numérico de
`USUARIOS_SISTEMA`, no un uuid estable — por eso también guarda
`registrado_por_nombre` aparte, y `seguimientoUsuarioNombre()` cae a
ese nombre guardado si el id ya no resuelve contra el roster actual.
`remisiones.profesional` se guarda como texto (nombre), no como id,
mismo criterio que `cirugias.medico_responsable`.

**Peluquería y spa y Guardería SÍ persisten en Supabase** (tablas
`peluquerias`/`guarderias`, ver `supabase/schema.sql`) — mismo criterio
que Seguimientos/Remisiones arriba: `guardarPeluqueria()`/
`guardarGuarderia()` son `async` y hacen insert/update BLOQUEANTE antes
de tocar `patientData[petKey].peluquerias`/`.guarderias` (si falla la
escritura remota no se aplica el cambio local),
`eliminarPeluqueriaReal()`/`eliminarGuarderiaReal()` borran de forma
optimista, y `cargarDatosClinicaDesdeSupabase()` reconstruye ambos
arrays (más sus entradas de timeline, vía
`construirPeluqueriaTimelineDesdeFila()`/`construirGuarderiaTimelineDesdeFila()`)
al iniciar sesión. Antes vivían solo en memoria y se perdían al
refrescar la página o volver a iniciar sesión.
`peluquerias.fotos_antes`/`.fotos_despues` solo guardan `{nombre}` por
elemento (jsonb) — mismo criterio que `seguimientos.adjuntos`: el
archivo en sí nunca se sube a Storage (la URL de blob local del
`<input type="file">` no sobrevive al refresco de todas formas), así
que las fotos no son descargables tras recargar, solo se conserva el
nombre de cada una.

**Mensajes al propietario SÍ persiste en Supabase** (tabla `mensajes`,
ver `supabase/schema.sql`) — `enviarMensaje()` ya era `async` e
insertaba en Supabase antes de tocar `patientData[petKey].mensajes`,
pero `cargarDatosClinicaDesdeSupabase()` no reconstruía el array (se
perdía al refrescar igual) y "Eliminar" desde el menú "..." solo
spliceaba local sin borrar en el servidor — ambos huecos ya se
completaron (`construirMensajeDesdeFila()`/
`construirMensajeTimelineDesdeFila()` + `eliminarMensajeReal()`, mismo
patrón que el resto). Sin patrón de edición (un mensaje enviado no se
edita) — por eso no hay `updated_at` ni política de update en esa
tabla, a diferencia de vacunaciones/desparasitaciones.

**RED IRIS — identidad de tutores/mascotas compartida entre
establecimientos.** Son DOS mecanismos separados, con niveles de
acceso distintos; no los mezcles:

1. **Vincular tutor (solo ficha).** Cada propietario con documento se
   publica automáticamente en un directorio global
   (`red_personas` + `red_persona_moviles` + `red_mascotas`, ver
   `supabase/schema.sql`) mediante triggers `before insert or update`
   sobre `propietarios`/`mascotas`, condicionados a
   `propietarios.consentimiento_red` (default true, viene de los
   términos y condiciones). Al guardar un propietario NUEVO,
   `guardarPropietario()` llama primero a `redDetectarCoincidencia()`
   (RPC `red_buscar_persona`), que devuelve solo un "hint" — nombre
   enmascarado (`Pe*** Gó***`) y contadores, nunca datos usables. Si
   hay coincidencia se abre `#red-vincular-modal` y el guardado se
   ABORTA; de ahí solo se sale verificando identidad (cédula **y**
   celular deben coincidir con la misma persona, RPC
   `red_verificar_identidad`) o pulsando "Registrar como nuevo de
   todas formas" (fija `redOmitirDeteccion` y reentra a
   `guardarPropietario()`). La verificación devuelve un token de 10
   min (`red_verificaciones`) que `red_vincular_con_token()` consume
   para copiar la ficha del tutor y las fichas de mascota
   seleccionadas. **Por acá no viaja NADA de historia clínica** — ni
   consultas, ni documentos, ni registros.
2. **Solicitar información (historia).** Desde el header del paciente
   ("Solicitar a otra clínica" → `#red-solicitud-modal`) se pide a un
   establecimiento concreto uno o más de 7 tipos
   (documentos/consultas/vacunaciones/desparasitaciones/examenes/
   formulas/cirugias). La clínica destino aprueba o rechaza en
   **Admin > Red IRIS** (`#admin-outer-red`, `renderRedSolicitudes()`).
   Aprobar **no copia ni duplica nada**: agrega lectura sobre las filas
   originales vía las policies `*_select_red` (que llaman a
   `red_puede_ver_registro`), y "Revocar acceso" la corta de
   inmediato. Los PDFs se leen en su ruta original del bucket `pdfs`
   (policy `pdfs_select_red_compartido` + `red_puede_ver_pdf`), que es
   justamente el "no volver a subir cada documento en cada módulo".

Detalles que hay que respetar al tocar esto:
- Las tablas del directorio tienen RLS **habilitada y cero policies a
  propósito**: nada de PostgREST las lee. Todo pasa por funciones
  `security definer`. Si necesitas un campo nuevo de la red, agrégalo
  al jsonb que devuelve la RPC correspondiente — no abras un select
  sobre `red_personas`/`red_mascotas`.
- `red_persona_moviles` ACUMULA celulares, nunca los pisa: la gente
  cambia de número y, sobre todo, así una clínica no puede
  "secuestrar" la verificación de otra sobreescribiendo el segundo
  factor.
- Toda función nueva `red_*` nace con EXECUTE para `anon` y
  `authenticated` (default privileges de Supabase) y PostgREST la
  expone en `/rest/v1/rpc/...`. Al final de esa sección del schema hay
  un bloque de `revoke`/`grant` que hay que MANTENER: sin él,
  `red_upsert_persona` (definer, sin validaciones porque solo la usan
  los triggers) queda invocable por un anónimo. `revoke from public`
  no basta — hay que nombrar a `anon` y `authenticated`.
- Los registros que llegan compartidos se mezclan en
  `patientData[petKey]` con `cargarCompartidosDeLaRed()` (al final de
  `cargarDatosClinicaDesdeSupabase`) y se marcan con
  `redMarcarCompartido()`: además de la bandera `compartidoDe`,
  reescribe la columna `usuario`/`vet` con "Compartido · <clínica>"
  para que el origen se vea sin tocar el render de los 7 módulos.
  El menú "..." se recorta solo a Ver/Imprimir dentro de
  `renderRowActionsMenu()` vía `registroCompartidoDeFila()`, que
  resuelve el `recordId` (`petKey:indice`, o `petKey:dbId` en
  Consultas) contra el array real — no hay un set de ids porque los
  índices se corren al eliminar registros.
- Una aprobación recién dada solo aparece en la clínica solicitante
  tras recargar/reiniciar sesión (los compartidos se leen una vez al
  cargar los datos de la clínica).
- Rate limiting real y auditado en `red_intentos`: 60 búsquedas/hora y
  5 verificaciones fallidas por 15 min y después bloqueo. No los
  quites — son lo único que impide barrer el directorio de cédulas con
  un script. El mensaje de error de la verificación es genérico a
  propósito (no dice si falló la cédula o el celular).

## RESPALDOS — hay datos de producción reales, no es un prototipo más
Ya hay un establecimiento usando la plataforma con información
clínica real (tutores, mascotas, consultas, inventario, caja). La
organización de Supabase está en plan **free**, que **no incluye
ningún respaldo administrado** (ni diario ni PITR), así que lo único
que existe es lo de abajo. Dos mecanismos, no se reemplazan:

1. **Respaldo automático diario** —
   `.github/workflows/respaldo-supabase.yml` +
   `scripts/respaldo/{dump-db.sh,descargar-storage.mjs,verificar-respaldo.mjs}`.
   Corre 02:10 Colombia y a demanda (`workflow_dispatch`). Vuelca la
   base COMPLETA con `pg_dump` (custom + SQL plano con un INSERT por
   fila + estructura), descarga TODOS los objetos de Storage (los
   archivos no están en Postgres: sin ese paso el respaldo tendría las
   filas que apuntan a los PDFs pero no los PDFs), cifra el zip con
   GPG AES-256 y lo sube como artifact con 90 días de retención.
   Runbook completo de restauración en `scripts/respaldo/README.md`.
   Cosas que hay que respetar al tocarlo:
   - **El cifrado no es opcional.** El repo de GitHub es PÚBLICO y los
     artifacts de un repo público los puede bajar cualquiera. Lo mismo
     vale para el `.gitignore`: las entradas `iris-respaldo-*`/`*.dump`
     están para que un respaldo local no termine en un commit.
   - `pg_dump` usa `--no-owner` pero **NO** `--no-privileges`: los
     GRANT a `anon`/`authenticated` son lo que permite que PostgREST
     lea las tablas, y los `revoke`/`grant` de las funciones `red_*`
     son parte del modelo de seguridad (ver sección RED IRIS). Sin
     ellos, un proyecto restaurado tendría todos los datos y la app
     los vería vacíos.
   - Hace falta el cliente de PostgreSQL **17** (el servidor es 17.x y
     `pg_dump` aborta si es más viejo), y la conexión va por el
     **Session pooler** porque en free la conexión directa solo
     resuelve por IPv6 y los runners de GitHub son IPv4.
   - `verificar-respaldo.mjs` compara el conteo exacto de filas del
     servidor contra los INSERT del volcado y **falla el job** si una
     tabla con datos quedó vacía en el respaldo. No lo relajes: el modo
     de falla peligroso no es que truene, es que suba vacío durante
     meses sin que nadie lo note.
   - Efecto secundario deliberado: conectarse a diario evita que
     Supabase pause el proyecto por inactividad (riesgo real del free).
2. **Respaldo manual desde la app** — Admin > Respaldo de datos
   (`#admin-outer-respaldo`, `descargarRespaldoEstablecimiento()`).
   Descarga un `.json` con las filas reales de las 26 tablas por
   establecimiento (`RESPALDO_TABLAS`), no el modelo en memoria: el
   objetivo es poder volver a insertar. Si agregas una tabla nueva por
   establecimiento, **agrégala a `RESPALDO_TABLAS`** o el respaldo
   manual la omite en silencio (el automático no necesita cambios,
   vuelca el schema entero). No incluye los archivos binarios, solo el
   inventario de rutas (`respaldoInventarioArchivos()`, genérico sobre
   campos `*_path`/`*_url` y arrays `fotos_*`).
   - `respaldoLeerTablaCompleta()` pagina de 1000 en 1000 **con
     `.order('id')`**. Las dos cosas son obligatorias: PostgREST
     devuelve máximo 1000 filas y no avisa que truncó, y sin un orden
     estable dos páginas consecutivas pueden repetir y omitir filas.
     `productos` ya tiene 2000+ filas en producción.

**Hueco conocido:** `supabase/schema.sql` NO tiene el `create table` de
`formulas_medicas`, `ventas_facturas` ni `ventas_cotizaciones`, aunque
las tres existen en la base y tienen datos. El respaldo automático sí
las cubre (vuelca la estructura viva del servidor), pero si alguien
intenta reconstruir el proyecto solo desde `schema.sql` le van a
faltar. Al tocar esas tablas, agrega su definición al archivo.

**Trampa de PostgREST, aplica a todo el archivo:**
`cargarDatosClinicaDesdeSupabase()` hace `select('*')` sin `.range()`,
así que en el establecimiento con 2025 productos la app solo carga los
primeros 1000. Es pérdida de VISTA, no de datos (la base los tiene
todos y el respaldo también), pero cualquier lectura nueva de una tabla
que pueda pasar de 1000 filas necesita paginación como la de
`respaldoLeerTablaCompleta()`.

## Al recibir un prompt nuevo de módulo
1. Lee solo la sección del sidebar/JS relevante al módulo pedido, no
   todo el archivo.
2. Sigue exactamente los patrones de arriba.
3. No toques módulos que no se mencionan en el prompt.
