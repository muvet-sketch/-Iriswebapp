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
  `--text-1`, `--text-2` — nunca hardcodear colores nuevos. El acento
  lo elige cada usuario en Mi perfil > Tema (`aplicarTemaClinica()`,
  `CLINIC_THEMES`), que reescribe `--clinic-accent`/`-light`/`-rgb` en
  `documentElement` — por eso cualquier color derivado se escribe
  `rgba(var(--clinic-accent-rgb), α)` y nunca con el hex del tema.
- Botón "+ Registrar …" de la cabecera de cada módulo del Consultorio:
  es `.btn-outline` + su clase de rol (`module-create-btn` /
  `documentos-create-btn` / `seguimiento-create-btn` /
  `peluqueria-create-btn` / `guarderia-create-btn` — `applySimRole()`
  las oculta con reglas distintas, ver ahí). Las cinco comparten una
  regla CSS que las pinta con el acento del tema del usuario (texto y
  borde `--clinic-accent`, fondo tenue) en vez del gris de
  `.btn-outline`: son la acción principal de su módulo. Si agregás un
  módulo con su propia clase de creación, sumala a ese selector; si el
  botón no necesita regla de rol, usá el hook de solo estilo
  `.accent-create-btn` (el que usa el "Registrar" del quicknav del
  Tablero).
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
  la inicial del nombre. "Editar mascota" se abre haciendo click en el
  nombre de la mascota (`.pet-name-title-btn`), no como botón aparte.
  La ÚNICA acción de la cabecera es el menú "+ Nuevo"
  (`#btn-nueva-consulta` → `#pet-header-nuevo-menu`), que vive en la
  columna derecha de `.pet-header-top-row` (`.pet-header-right-col`) —
  ahí estaba antes el widget "Viendo como", que se mudó al header
  global de la app. Hubo una fila propia de acciones
  (`.pet-header-actions-row`, debajo de peso/datos generales) mientras
  esa columna estaba ocupada; ya no existe, no la reintroduzcas.
  Orden de la tarjeta: identidad (+ "Nuevo") → peso/datos generales →
  contexto. Al hacer scroll siguen colapsando solo
  `.pet-header-bottom-row` y `.pet-header-context-row`; la identidad
  queda fija, y con ella el botón.
  **Trampa ya sufrida en ese colapso (`setupPatientPaneHeaderCollapse`):**
  colapsar el header AGRANDA el alto visible de `.patient-pane-body`, así
  que el navegador recorta `scrollTop` al nuevo máximo. Con el umbral único
  original (`scrollTop > 12`) y un módulo de pocas filas, ese recorte dejaba
  el scroll por debajo del umbral → se expandía → volvía a haber scroll →
  se colapsaba: la pantalla "se subía sola" y los últimos registros eran
  imposibles de ver. Ahora hay dos guardas y las dos hacen falta:
  histéresis con dos umbrales (32 para colapsar, 10 para expandir — mismo
  criterio que `onTableroScroll()`) y, sobre todo, **no colapsar si tras
  colapsar no queda scroll de sobra** (se mide el alto que liberan las dos
  filas y se exige que el contenido lo exceda por un margen). Si agregás
  otra fila colapsable al header, sumala a esa medición o la guarda queda
  corta.
  `petDataTableHTML(data)` YA NO repite
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
    no reutiliza esta función ni esta tarjeta. También rellena
    `${containerId}-contexto` si ese id existe: es la banda oscura
    "Contexto histórico" del Tablero, reusada tal cual como tercera fila
    de `.pet-header-card` (`#pet-header-contexto` dentro de
    `.pet-header-context-row`, que colapsa con el mismo
    `.pet-header-collapsed` que `.pet-header-bottom-row`). El HTML sale
    de `contextoHistoricoHTML(petKey)` — ver patrón del Tablero abajo;
    no dupliques el markup en las dos pantallas.
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
    `pesoHistorico`, `ownerPhone`, `temperamento`, `antecedentes`,
    `alergias`) viven en `patientData[petKey]` junto a los campos
    originales — son los únicos campos nuevos de mascota agregados
    hasta ahora; no agregues más sin que se pidan. Los últimos tres
    (`temperamento`/`antecedentes`/`alergias`, columnas homónimas en
    `mascotas`) se agregaron para alimentar la tarjeta "Contexto
    histórico" del Tablero de trabajo (ver patrón del Tablero más
    abajo) — mismo criterio de edición que `alimentacion`: inputs de
    texto libre en ambos modales (`#editar-mascota-modal`/
    `#registrar-mascota-modal`), sin estructura ni catálogo.
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
  - El widget "Viendo como" (`.role-sim-widget`) ya NO se duplica por
    pantalla: hay una sola instancia, en el header global del app shell
    (`.header-right`, a la izquierda de la campana, variante
    `.role-sim-widget-header`), así que cualquier pantalla nueva —
    incluidas las de tipo "kardex"/Tablero, que son pantallas completas
    dentro de un tab y no tapan el header — la hereda sin agregar nada.
    Antes había cinco copias sueltas (Dashboard, buscador de
    Consultorio, cabecera del paciente, Tablero y Kardex). `applySimRole()`
    sigue sincronizando por clase (`.role-sim-select` /
    `[data-privileges-text]`), no por id, así que agregar otra copia
    sigue siendo posible si algún día hace falta.
- Patrón del **Tablero de trabajo** (`#tablero-view`, pantalla completa de
  "Registro de consulta", misma mecánica de ocultar `.consultorio-wrapper`
  que el Kardex). Su estilo visual se adoptó del mockup de Stitch
  `stitch_screen_encounter.html`/`.png` (raíz del repo, "Encounter:
  Horizontal Nav Edition"), pero **reconstruido con las variables de
  paleta existentes** — el mockup trae Tailwind y verde `#006e22`
  hardcodeado; acá el acento sigue siendo `--clinic-accent` y la tarjeta
  oscura reusa `--sidebar-bg`/`--sidebar-active`. Si se retoma ese mockup
  para otra pantalla, mismo criterio: tomar la ESTRUCTURA, no sus colores
  ni su CSS.
  - Estructura: **bloque fijo** `.tablero-sticky-stack` (barra de acciones
    `.tablero-header` con Volver/rol simulado/Finalizar — reemplaza al FAB
    del mockup, no lo dupliques → hero de vidrio del paciente
    `.tablero-hero`, `mountTableroHeader()` → **strip horizontal** de
    módulos `.tablero-modstrip`/`.tablero-modchip`, antes era la columna
    `.tablero-nav-col`) → `.tablero-body`, que es lo único que scrollea:
    grid de 2 columnas con el riel SOIP (`.tablero-soip-rail` + una
    `.tablero-step`/`.tablero-card` por letra) y el panel lateral
    (Navegación rápida + Lista de problemas). Los tres bloques de arriba
    van DENTRO del sticky a propósito (el strip vivía en `.tablero-body` y
    se perdía al bajar); si se agrega algo más ahí, tiene que traer su
    propio padding horizontal de 24px, que `.tablero-body` ya no le da.
  - **El hero es un `grid` con `grid-template-areas`, no flex** — y esa es
    la pieza que sostiene todo lo demás. Sus 5 bloques son hijos DIRECTOS
    (`.tablero-hero-photo`/`-id`/`.tablero-context-card`/`-weight`/`-owner`,
    sin wrapper intermedio: un wrapper solo se podría colocar como un bloque)
    y el orden del DOM es el del modo COMPACTO (foto → identidad → contexto →
    peso → responsable); el modo expandido lo reacomodan las áreas. Así la
    banda de contexto se mueve entre dos posiciones muy distintas cambiando
    únicamente `grid-template-areas`, sin tocar el DOM:
    - Expandido: `"foto id peso owner" / "ctx ctx ctx ctx"` — el contexto es
      una segunda fila de ancho completo y el histórico de peso ocupa el
      hueco entre los datos de la mascota y el responsable.
    - Compacto: `"foto id ctx owner"` — el gráfico de peso se va
      (`display:none`, ver abajo) y el contexto le toma ese hueco.
    - El bloque de peso (`.tablero-hero-weight`, área `peso`) solo pinta
      `renderWeightChartSVG('tablero-hero-weight-chart', data.pesoHistorico)`
      desde `mountTableroHeader()` — la misma pieza atómica de la ficha de
      Historia y del header del Kardex, con el alto del trazado achicado a
      62px por CSS (los 96px de la ficha estirarían la barra fija). En
      `.condensed` tiene que ser `display:none` y no `visibility`/`opacity`:
      un item de grid cuya área no existe en el template condensado se
      auto-colocaría en una fila implícita y rompería la barra de una línea.
  - **Modo compacto al hacer scroll** (`onTableroScroll()` sobre
    `#tablero-view`, que es el scroller): pone `.condensed` en
    `.tablero-sticky-stack` y el hero se REORGANIZA en una sola línea —
    foto de 64→40px, `.tablero-hero-id` de columna a fila, la banda de
    contexto al hueco del medio (ver arriba) con cada dato en una línea
    `ETIQUETA valor`, y se ocultan solo microchip/"Consulta en curso"/
    rótulo del bloque de contexto/label y teléfono del responsable. **Nada
    de esto se oculta por completo a pedido del cliente** — la versión
    anterior escondía la banda entera y dejaba ese espacio vacío. Todo el
    reacomodo es CSS; el JS solo prende la clase. Dos umbrales distintos a
    propósito (32px para condensar, 10px para expandir): con uno solo, el
    cambio de alto del hero mueve el scroll lo justo para volver a
    cruzarlo y la barra parpadea. El botón "Ficha completa"
    (`.tablero-hero-toggle`, `toggleTableroHeroExpandido()`) fuerza el hero
    entero sin subir el scroll (`.forzar-expandido`, de ahí el
    `:not(.forzar-expandido)` en todas las reglas de `.condensed`), y
    `resetTableroSticky()` limpia ambas clases al abrir el Tablero —
    después de `.active`, porque con la vista en `display:none` fijar
    `scrollTop` no tiene efecto.
  - La banda oscura "Contexto histórico" (`.tablero-context-card`) es de
    ancho completo con los datos en columnas (`.tablero-context-facts` es
    un grid `auto-fit`) y el rótulo del bloque a la izquierda. Antes era la
    columna del medio de un hero de 3 columnas, con los datos apilados: eso
    le fijaba al hero un alto de ~230px que las otras dos columnas no
    llenaban, y se veía como espacio en blanco. Cada valor va en UNA sola
    línea con elipsis (un antecedente largo no puede estirar el alto de las
    otras columnas) y el texto completo queda en el `title=`. Sigue siendo
    el mismo `renderTableroContexto()`, que la busca por id — la clase
    `.tablero-hero-context` quedó solo como enganche del `grid-area`.
    El markup en sí vive en `contextoHistoricoHTML(petKey)` porque la
    misma banda se pinta también en la cabecera del paciente del
    Consultorio (ver `mountPetGeneralCard` más arriba): son el mismo dato
    de referencia y no pueden divergir entre las dos pantallas.
    `cerrarTableroAConsultorio()` la repinta al volver, porque finalizar
    una consulta cambia el "Motivo última consulta".
  - Los chips de alerta del hero (`tableroAlertChipsHtml()`) salen SOLO de
    datos reales del paciente (fallecido, problemas activos, vencimientos
    de `EVENTOS_SEGUIMIENTO`) — el mockup muestra alertas de alergia/dieta
    inventadas, no las reintroduzcas como texto fijo ahí.
  - La banda "Contexto histórico" (`renderTableroContexto()`) muestra 3
    datos de referencia rápida para llenar el Subjetivo sin ir a
    buscarlos a otro lado: Antecedentes/Alergias (campos de la ficha de la
    mascota — `data.antecedentes`/`.alergias`, editables desde "Editar
    mascota"/"Registrar mascota", columnas homónimas en `mascotas`, ver
    patrón de campos de mascota mock más arriba) y Motivo de la última
    consulta (`data.consultas[0]`, ya viene ordenado
    más-reciente-primero por el `unshift` de `guardarConsulta()` — no es un
    dato nuevo). Antes mostraba consultas registradas/último peso/próximos
    vencimientos; ese contenido se quitó de acá a pedido del cliente (el
    peso ya vive en la fila de identidad del hero y los vencimientos
    vencidos ya salen como chip de alerta) — no lo reintroduzcas sin que
    se pida.
  - **Temperamento NO vive en esa banda**: es un chip de color en la fila
    de meta del hero, al lado del sexo (`temperamentoChipHtml()`), porque
    es el dato que condiciona cómo se manipula al paciente y hay que verlo
    antes de tocarlo. No lo reintroduzcas en el contexto — quedaría
    duplicado. Dentro del chip el nivel de manejo se lee como un
    **TERMÓMETRO horizontal en miniatura** (`.temperamento-term-mini`:
    bulbo + tubo llenado al 33/66/100% según `def.nivel`), que reemplazó al
    icono de Lucide suelto que había antes — es la misma escala de 3
    niveles que el termómetro vertical del preview de
    `#temperamento-modal` (`temperamentoTermometroHtml()`), para que las
    dos pantallas y el modal muestren el mismo objeto y no tres
    representaciones distintas. `nivel` y `label` viven en
    `TEMPERAMENTO_TONOS`/`TEMPERAMENTO_TONO_NEUTRO`, no repetidos en cada
    render. Todo el termómetro mini se pinta con `currentColor` a
    propósito: hereda el color del tono del chip sin repetir las 4 reglas
    de color (en `riesgo`, que es chip rojo sólido, sale blanco solo). El
    color es un semáforo de manejo de 4 tonos
    (`calmo`/`precaucion`/`riesgo`/`neutro`, sobre `--success`/`--warning`/
    `--danger`, sin color nuevo) que sale de `temperamentoTono()`: como
    `mascotas.temperamento` es texto libre a propósito (sin catálogo, ver
    patrón de campos de mascota mock), la clasificación es por palabras
    clave sobre el texto normalizado y **gana el tono más grave que
    aparezca** — "dócil pero muerde si le tocan las patas" tiene que salir
    rojo, no verde. Sin coincidencias el tono es `neutro`: nunca se asume
    que un temperamento desconocido es manejable. Si hace falta afinarlo,
    agregá palabras a `TEMPERAMENTO_TONOS` (ordenado de más grave a menos
    grave, el primero que coincide manda), no cambies el campo a select.
    El MISMO chip se pinta también en la fila de meta de la cabecera del
    paciente del Consultorio, al lado del propietario
    (`#pet-header-temperamento`, lo rellena `mountPetGeneralCard()` con el
    mismo criterio opcional que la banda de contexto: solo si el contenedor
    declara el id, por eso el Kardex no se ve afectado). Ahí es clickeable
    (`.pet-temperamento-btn` → `openTemperamentoModal()`) y abre un modal
    propio (`#temperamento-modal`, `guardarTemperamento()`) que escribe
    `mascotas.temperamento` de forma BLOQUEANTE antes de tocar
    `patientData[petKey].temperamento`, igual que "Actualizar peso" — es un
    atajo para registrarlo/actualizarlo sin abrir "Editar mascota", que
    sigue teniendo el mismo campo. Guardar con el campo vacío lo BORRA (el
    chip vuelve a "sin registrar"). El modal muestra el chip en vivo como
    preview, pero sigue siendo un textarea de texto libre — no lo conviertas
    en un select de las palabras de `TEMPERAMENTO_TONOS`.
  - **Peso clickeable y símbolo de sexo** en esa misma fila de meta:
    - El peso abre `openActualizarPesoModal(petKey)` —el MISMO
      `#actualizar-peso-modal` del botón de balanza de "Histórico de peso"
      de la cabecera del Consultorio, que es el único camino que escribe
      `pesoHistorico`; no se duplica lógica de guardado—. La cabecera del
      Consultorio también lo abre haciendo click en `#pet-profile-weight`.
      Por eso `guardarPesoActualizado()` ahora repinta TAMBIÉN el hero
      (`mountTableroHeader()` si `#tablero-view` está activo): sin eso el
      número seguía mostrando el peso viejo hasta cerrar la consulta.
      El envoltorio clickeable es `.pet-peso-btn`, hermano de
      `.pet-temperamento-btn` (misma regla CSS, un lápiz que aparece al
      hover). Ese lápiz lleva la clase `.pet-edit-hint` y es lo único que
      se oculta: sin ella la regla tapaba también el icono de balanza del
      propio dato.
    - El sexo se pinta con el glifo Unicode ♀/♂ (`generoSimbolo()` /
      `generoSimboloHtml()` / `generoMetaItemHtml()`), no con un icono de
      Lucide: antes era `user`, que dibuja una persona y no dice nada del
      sexo del paciente, y `mars`/`venus` son iconos recientes que un
      cambio de `lucide@latest` podría dejar sin dibujar. El mismo símbolo
      se suma al texto de la fila Género de `petDataTableHTML()`.
  - La tarjeta "Responsable" (`mountTableroOwnerCard()`) lista además las
    mascotas a cargo de ese tutor como chips, con la del paciente actual
    marcada (`.tablero-owner-pet-chip.current`). Salen de
    `getMascotasDePropietario(p.id)` (FK real) y solo caen a comparar
    `d.owner` por nombre cuando la mascota semilla no tiene
    `propietarioId` — mismo respaldo que `getPropietarioDeMascota()`. Los
    chips NO son navegables a propósito: cambiar de paciente a mitad de una
    consulta abierta perdería el SOIP en curso. Se ocultan en `.condensed`,
    igual que el teléfono y el rótulo.
  - Microchip ya NO se repite en "Navegación rápida": vive en el hero.
    Mismo criterio que la fusión de `.pet-header-card` — antes de agregar
    un dato al panel lateral, verificar que no esté ya arriba.
  - Los ids de los campos (`tablero-soap-*`, incluidos los 7
    `-vital-*`) son contrato con `guardarConsulta('tablero-soap-', …)` —
    la maqueta cambió, los ids no. Los inputs de vitales usan
    `.tablero-vital-input` dentro de `.tablero-vital-tile` (ya no
    `.input-control`), pero siguen siendo los mismos ids.
  - **Los 7 tiles de vitales ya no son HTML estático y no viven solo acá.**
    Salen de `SOAP_VITALES` (rótulo, unidad, placeholder, rango y valor
    neutro del slider, y el campo del registro en memoria) vía
    `vitalesGridHTML(idPrefix)` / `montarVitalesGrid(containerId, idPrefix,
    valores)`, y se montan en DOS pantallas: el contenedor
    `#tablero-vitals-grid` del Tablero (`abrirTableroTrabajo()`, siempre en
    blanco: el Tablero solo da de alta consultas nuevas) y
    `#soap-vitals-grid`, el bloque Objetivo del modal clásico de
    crear/**editar** una consulta. Antes los vitales solo existían en el
    Tablero, así que una consulta ya guardada se editaba sin poder ver ni
    corregir lo que se había medido. Agregar un vital es agregar una
    entrada a esa constante más su columna `vital_*` en `consultas` — mismo
    criterio que `ANESTESIA_VITALES`; no repitas los tiles a mano.
    Corolario: **repintar la grilla ES el reset**, por eso ya no existen
    `resetVitalesNoEvaluados()`/`resetVitalSliders()` — los interruptores
    "No evaluado", el `disabled` y la posición de los sliders se van con el
    `innerHTML`. Una pantalla futura que reuse los tiles sin repintarlos
    necesita su propio reset. Los ids que genera
    (`<prefijo>vital-<id>`) siguen siendo el contrato con
    `guardarConsulta(idPrefix)` y con `AUDIO_SOIP_VITALES`.
  - Al EDITAR, `guardarConsulta()` actualiza los `vital*` del registro en
    memoria **solo si la pantalla que guardó trae la grilla** (misma
    condición que ya gobernaba el payload de Supabase): así una pantalla sin
    vitales edita el resto de la consulta sin borrar en memoria lo que sí
    quedó en la base. Efecto secundario que se corrigió de paso: editar
    desde el modal ya no borra los vitales de la línea `summary` del
    timeline.
  - Los 6 vitales numéricos (todos menos TLLC, que es texto libre) tienen
    además un `<input type="range">` bajo el número
    (`.tablero-vital-range`), sincronizado en ambos sentidos con
    `setVitalDesdeSlider()` / `syncVitalSliderDesdeInput()` y reseteado
    por `resetVitalSliders()` al abrir el Tablero. **Invariante que no se
    puede romper:** el slider arranca en `data-neutro` solo como posición
    visual — mientras el campo esté vacío el tile NO lleva `.has-value` y
    el número sigue vacío. Si el slider escribiera su valor por defecto al
    abrir la pantalla, cada consulta se guardaría con 6 signos vitales que
    nadie midió, y `guardarConsulta()` los persiste tal cual en
    `consultas.vital_*`. Por lo mismo, un número fuera del rango del
    slider es válido y se conserva: el thumb se pega al extremo, el valor
    NO se recorta. `min`/`max`/`step`/`data-neutro` viven solo en el HTML
    — el JS los lee del DOM, no los duplica.
  - **"No evaluado" no se registra en ninguna parte.** Cada uno de los 7
    tiles de vitales tiene un interruptor (`.tablero-vital-ne`, clon
    reducido de `.mini-toggle`) que marca esa variable como no evaluada:
    `toggleVitalNoEvaluado()` vacía el input, lo deshabilita, apaga el
    slider y pone `.no-evaluado` en el tile. Eso es TODO lo que hace.
    **Requisito explícito del cliente:** un vital marcado así no puede
    quedar registrado ni ser legible por nadie — ni en la consulta, ni en
    la historia, ni en un PDF/export. Por eso el mecanismo es "guardarlo
    como `null`" y NO una marca de omisión: no hay columna `no_evaluado`
    en `consultas` y no hay que crearla, ni escribir el texto "No
    evaluado" en `objetivo`/`summary`, ni un flag en el registro en
    memoria. El estado del interruptor es de PANTALLA y muere al cerrar el
    Tablero (`resetVitalesNoEvaluados()`, que corre ANTES de
    `resetVitalSliders()` porque este último no toca `disabled`).
    Consecuencia deliberada: después de guardar es indistinguible de "el
    campo nunca se llenó" — así lo pidió el cliente.
    - Corolario que ya se aplicó: la presión arterial ya no se imprime
      como `PA —/80` cuando falta una de las dos mitades (ese guion era
      justamente un rastro de la variable ausente). Se imprime `PA
      120/80`, o `PAS 120` / `PAD 80` sueltas. Son 3 lugares con la misma
      lógica y hay que mantenerlos alineados: `guardarConsulta()` (línea
      del `summary`), `consultaViewContentHTML()` (modal Ver + el PDF de
      `rowActionImprimir`, que reusa ese mismo HTML) y
      `construirConsultaDesdeFila()` al recargar desde Supabase.
      Si se agrega otro par de vitales combinados, mismo criterio.
  - El badge de cada letra se rellena (`.tablero-step.filled`) desde el
    `oninput` que ya fijaba `abrirTableroTrabajo()` para limpiar
    `field-error` — un solo handler por textarea, no agregues otro.

## Grabar audio de la consulta → SOIP (botón "Grabar audio" del Tablero)
Flujo completo: el Tablero graba con el micrófono del equipo, el audio va a
Supabase, el PC de la oficina lo transcribe y devuelve el SOIP para
precargar el formulario. El pipeline de transcripción vive en
`scripts/transcripcion/` (README propio ahí) y el paso 3 —el navegador— en
el bloque "Grabar la consulta y precargar el SOIP" de `index.html`.
Antes el botón se llamaba "Desde audio" y pedía a mano el `.json` que dejaba
`extraer_soip.py`; eso sobrevive solo como escape dentro de un `<details>`
del modal, para cuando el equipo de la oficina está apagado.

- **Recorrido del audio, y por qué es así.** `MediaRecorder` (Opus mono a
  32 kbps) → bucket privado `audios-consultas` + fila en `consultas_audio`
  con estado `subido` → `puente_iris.py` la baja a la carpeta
  `Audios Consultas`, **que está sincronizada con Drive**, así que el audio
  queda en Drive sin que nadie suba nada → `vigilante.py` la transcribe →
  `extraer_soip.py` extrae el SOIP → el puente escribe ese `.json` en
  `consultas_audio.resultado` con estado `listo` → el navegador, que
  consulta la fila cada 15 s, pinta la previsualización de siempre.
  No se usó la API de Drive desde el navegador a propósito: exigiría OAuth
  de Google en una app cuya sesión es de Supabase, y el archivo termina en
  Drive igual por la carpeta sincronizada.
- **El id de la fila viaja DENTRO del nombre del archivo**
  (`IRIS-<uuid>__2026-08-08_canela-gomez.webm`, lo arma
  `audioSoipNombreArchivo()`). Es lo que permite reasociar el `.json` final
  con la consulta que lo pidió, y funciona porque `vigilante.py` y
  `extraer_soip.py` conservan el *stem* de punta a punta — por eso ninguno
  de los dos necesitó cambios. Si algún día uno de ellos renombra archivos,
  esto se rompe en silencio.
- **El bucket es solo transporte.** El puente borra el objeto apenas lo
  baja: la copia que se guarda es la de Drive, y el plan free tiene poco
  espacio. Por eso tampoco hay política de retención en Supabase.
- **Cerrar el modal NO detiene nada** — ni la grabación ni la
  transcripción. El caso real es grabar la consulta entera mientras se
  escribe el SOIP a mano, con el modal cerrado. El único indicador en ese
  rato es el botón (`actualizarBotonAudioSoip()`): cronómetro mientras
  graba, "Transcribiendo…", punto verde cuando el borrador volvió. Salir
  del Tablero sí detiene la grabación (`detenerGrabacionAudioSoipAlSalir()`
  desde `cerrarTableroAConsultorio()`) porque hay que soltar el
  `MediaStream`: si no, el indicador de micrófono del navegador se queda
  encendido con la pantalla cerrada.
- **El pendiente sobrevive a la recarga de la página** (`localStorage`,
  `audioSoipRestaurarPendiente()` llamada al final de `bootstrapSession()`):
  transcribir una consulta larga tarda minutos y nadie se queda quieto
  mirando. Caduca a las 8 h — si el PC de la oficina estuvo apagado toda la
  noche, arrastrar ese borrador solo confunde.
- **Un pendiente de OTRO paciente no se abre en la ficha actual.** Cargar
  el SOIP de una mascota en la historia de otra es el error más caro de
  todo este flujo; `openAudioSoipModal()` compara `petKey` y, si no
  coincide, muestra el grabador con un aviso. El guard por nombre que ya
  tenía `renderAudioSoipPreview()` (el audio menciona a otra mascota) sigue
  igual y es independiente de este.
- **Persona gramatical del borrador (regla 9 de `SYSTEM` en
  `extraer_soip.py`).** Objetivo, Interpretación y Plan se redactan en
  PRIMERA persona del singular ("Encuentro mucosas pálidas", "Indico
  meloxicam"), porque quien firma la historia es el veterinario; Subjetivo
  va en TERCERA persona refiriéndose al tutor y al paciente ("El tutor
  refiere que Canela vomita desde hace dos días"), que es lo que ese campo
  es: el relato de otro. Reescribir a la persona correcta es reformular, no
  inventar — el contenido sigue limitado a lo que se dijo en el audio
  (regla 1), y las citas literales de los vitales (regla 3) no se tocan.
  Las descripciones de los campos del modelo repiten la persona esperada a
  propósito: el `messages.parse()` las usa tanto como al `SYSTEM`.
- Lo que este bloque **no** hace no cambió: solo PRECARGA los campos. No
  guarda, no finaliza y no toca `consultas`. Un LLM no cierra una historia
  clínica.
- El medidor de nivel (`.audio-rec-nivel`) no es decorado: el problema
  medido nº 1 de los audios reales es el micrófono lejos (ver "Lo que más
  mejoraría el resultado" en el README del pipeline), y ver la barra es lo
  único que avisa antes de grabar 40 minutos inservibles.
- **El celular corta el micrófono al bloquear la pantalla, y eso ya arruinó
  dos consultas reales.** Los `.webm` tenían la duración completa (28 y 31
  min) pero el **97 % de las muestras era cero exacto**: silencio digital, no
  "sala tranquila". `MediaRecorder` sigue grabando y nada falla — la
  transcripción salía de 500 caracteres y parecía una consulta corta. **No es
  un problema del pipeline**: se midió que la cadena de ffmpeg y el umbral del
  VAD conservan lo mismo que sin limpiar nada sobre ese audio (números en el
  README de `scripts/transcripcion/`). Antes de tocar `FILTROS_FFMPEG` o
  `vad_parameters` por una transcripción corta, medí el audio. Hay tres
  guardas y las tres hacen falta, porque ninguna cubre sola todos los casos:
  - **Wake lock de pantalla** mientras graba (`audioSoipPedirWakeLock()`), que
    se vuelve a pedir en `visibilitychange` porque el navegador lo suelta al
    ocultarse la página. Evita el apagado por INACTIVIDAD, que es el caso
    real; no evita un bloqueo manual ni que otra app tome el micrófono.
  - **Vigía de corte** (`audioSoipRevisarMicrofono()`, `setInterval` de 1 s —
    NO `requestAnimationFrame`, que se detiene justo cuando la página se
    oculta, que es cuando ocurre el corte). La señal buena es `track.muted`;
    el RMS del medidor es secundaria y solo cuenta con la página VISIBLE
    (oculta, el `AudioContext` puede estar suspendido en móvil y daría un
    falso positivo permanente) y tras 8 s seguidos bajo el piso, para que una
    pausa normal de la conversación no dispare la alarma. Tampoco cuenta en
    pausa, donde el micrófono sigue tomado a propósito. Al cortarse: toast,
    vibración y el botón del Tablero en `.audio-mudo` — con el modal cerrado
    ese botón es lo único que se ve.
  - **Confirmación antes de subir** (`audioSoipGrabacionSospechosa()`): con
    menos de la mitad del tiempo con sonido, el primer click en "Enviar" solo
    avisa con los minutos reales. Sin esto un audio inservible se sube, viaja
    al PC de la oficina, se transcribe varios minutos y vuelve como un SOIP
    vacío.
  Detectar el corte no alcanzaba: avisado el problema, **no había forma de
  volver a grabar**. Pausar y reanudar no sirve —y es lo primero que intenta
  quien lo sufre— porque el problema no es el grabador sino la fuente: un
  `MediaRecorder` queda atado al `MediaStream` que se le pasó al construirlo
  y no existe API para cambiarle el track. De ahí el reenganche en caliente:
  - **Lo que se graba NO es el micrófono, es la salida de un nodo de mezcla**
    (`audioSoipMezclaDest`, un `MediaStreamAudioDestinationNode`). El
    micrófono es solo una entrada de ese grafo
    (`audioSoipConectarMicrofonoAlGrafo()`), así que se puede soltar y pedir
    otro con `getUserMedia` sin tocar el `MediaRecorder`: el archivo sigue
    siendo UNO solo y continuo, que es innegociable — el pipeline asocia el
    resultado por el *stem* del nombre y no admite partes sueltas. Concatenar
    dos `.webm` no es una salida: ffmpeg solo lee el primer segmento.
  - **`audioSoipAnclaSilencio` (un `ConstantSourceNode` en 0, conectado de
    punta a punta) es obligatorio, no decorativo.** Medido en el navegador:
    un destino sin NINGUNA entrada deja de emitir muestras y el grabador no
    graba el hueco — 8,6 s reales daban un archivo de 5,3 s con los dos
    tramos de voz pegados y sin rastro del tiempo sin micrófono. Con el ancla
    el archivo dura lo mismo que el cronómetro y el hueco queda como silencio
    en su lugar, que es lo que la contabilidad de tiempo mudo y la
    `cobertura_habla` del pipeline dan por sentado. También evita que un
    reenganche fallido deje el grabador colgado sin ninguna fuente.
  - **Un `AudioContext` suspendido mata la grabación entera**, no la degrada:
    la mezcla no entrega nada. Se crea después de `await getUserMedia`, así
    que puede haber perdido el gesto del click — por eso se hace `resume()`
    explícito antes de `rec.start()` y otra vez al volver de segundo plano.
    Si aun así no arranca se suelta el grafo y se graba el micrófono directo
    (sin medidor ni reenganche, pero graba).
  - **El reenganche se dispara solo en los dos casos que no vuelven nunca**:
    al volver a la app con el micrófono todavía mudo (`visibilitychange`) y
    al terminarse el track (`onended` — permiso revocado, otra app se quedó
    con el dispositivo). Los automáticos pasan por un cooldown
    (`AUDIO_SOIP_REENGANCHE_COOLDOWN_MS`) porque un track que muere apenas se
    abre haría un bucle de `getUserMedia`; el botón manual no, y está SIEMPRE
    visible mientras se graba, no solo con el corte ya detectado.
  - **Un track TERMINADO no está `muted`** (`muted` queda en `false` y lo que
    cambia es `readyState`). El vigía miraba solo `muted`, así que el corte
    más duro de todos —el micrófono muerto— no se contaba hasta que el
    medidor acumulara sus 8 s, o nunca con la página en segundo plano.
  - **Un reenganche fallido abre el corte a mano** (`audioSoipAbrirCorte()`):
    el micrófono viejo ya se soltó y el vigía quedó apagado, así que si no,
    ese tiempo sin señal no se sumaría y la grabación parecería sana al
    momento de enviarla. La grabación NO se detiene: sigue corriendo y el
    usuario puede reintentar o enviar lo que sirva.
  - El aviso de un reenganche fallido vive en `audioSoipAvisoReenganche`, no
    en `audioSoipError()`: `renderAudioSoipGrabador()` reescribe
    `#audio-soip-error` entero en cada repintado y lo borraría al instante.
  Del otro lado, `vigilante.py` mide `cobertura_habla` (de
  `info.duration_after_vad`, no de la suma de duraciones de segmento, que
  sobreestima porque Whisper estira el `end` sobre el silencio) y escribe
  `calidad_audio` en el `.json`; `extraer_soip.py` lo copia tal cual al
  `.json` de `Consultas/` —campo propio, **NO** dentro de
  `avisos_automaticos`— y `renderAudioSoipPreview()` lo pinta primero y en
  rojo, porque es lo que explica por qué el borrador viene pobre y perdido
  entre los demás avisos no se lee. Un audio del que no se puede extraer nada
  ahora igual produce un `.json` válido (`salida_sin_extraccion()`): sin él la
  fila se quedaba en `transcribiendo` para siempre y el navegador mostraba
  "Transcribiendo…" sin fin.
- `vigilante.py` tuvo que sumar `.webm` a `EXTENSIONES_AUDIO`: es lo que
  graba Chrome/Edge. Safari da `.m4a` y Firefox puede dar `.ogg`, los tres
  ya estaban o se agregaron.
- **`consultas_audio` NO está en `RESPALDO_TABLAS`, y es a propósito** (no
  es el olvido contra el que avisa la sección de RESPALDOS). Es un buzón de
  trabajo: sus filas se consumen en minutos y lo que importa —el SOIP— o
  ya está en `consultas` porque el veterinario lo cargó y finalizó, o
  todavía no existe. Respaldar la fila sin el audio (que se borra del
  bucket y vive en Drive) no permitiría reconstruir nada.

## Importar tutor + mascotas desde WhatsApp (botón del buscador)
A los clientes nuevos se les envía por WhatsApp una plantilla pidiendo sus
datos y los del "chiquitín". Este flujo convierte esa respuesta en campos y
evita transcribir a mano 11 + 18 campos. Entrada:
`#btn-importar-whatsapp` en `.header-actions-col` del buscador de Consultorio
→ `#intake-whatsapp-modal` (2 pasos: pegar → previsualizar/editar → continuar,
clon estructural de `#importar-clientes-modal`). El botón lleva
`data-btn-registrar-propietario`, así que `applySimRole()` ya lo oculta para
los roles sin `canRegisterOwner` sin tocar nada más.

- **Este flujo NO escribe en Supabase — solo PRECARGA los dos formularios de
  siempre.** Es la decisión que gobierna todo el resto: quien guarda sigue
  siendo `guardarPropietario()`/`guardarMascotaRegistro()`, así que la
  detección de Red IRIS, la validación de celular por país, los T&C, el PDF de
  intake y el encadenamiento tutor → mascota siguen funcionando sin duplicar
  una línea de lógica de guardado. Mismo criterio que el audio → SOIP: un
  LLM no cierra un registro. Si algún día se agrega un camino que inserte
  directo, se pierde todo eso de golpe.
- **Dos parsers, y el determinista manda.** `parsearIntakeWhatsapp()` lee por
  etiquetas (instantáneo, sin costo) y cubre a quien responde sobre la
  plantilla — que es el caso normal, justamente porque la plantilla se la
  enviamos nosotros. Solo si reconoció poco (< 4 campos, o sin nombre de tutor,
  o sin mascota) se llama a `/api/parsear-intake`, y su resultado **rellena
  huecos, nunca pisa** lo que el parser local sí reconoció (`intakeFusionar`).
  Si el endpoint falla, se muestra lo parcial con un aviso **que incluye el
  motivo real** (ej. "ANTHROPIC_API_KEY no está configurada"): la
  interpretación asistida es un respaldo, no un requisito, pero sin el motivo
  ese fallo se ve idéntico a "el mensaje no traía nada" y nadie sabe qué
  arreglar — mismo criterio que la pantalla de estado del envío de correos.
- **Tres cosas que el parser por etiquetas NO puede dar por sentadas**, porque
  las tres se dieron con mensajes reales y las tres devolvían CERO campos (o,
  peor, el nombre de la mascota en el nombre del tutor):
  - **El mensaje viene copiado de WhatsApp, no tecleado.** Cada línea trae
    `[2/9/26, 10:05 a. m.] Juan Pérez: ` delante, así que el primer `:` de la
    línea es el de la hora y ninguna etiqueta se reconocía.
    `intakeQuitarPrefijoWhatsapp()` lo quita (formato con corchetes de
    Web/iOS y formato de exportación de Android) antes de partir por `:`.
  - **El cliente responde sin los encabezados de sección.** `INTAKE_CAMPOS_SOLO_MASCOTA`
    infiere la sección: la primera etiqueta que solo puede ser de un animal
    (especie/raza/color/peso/edad/sexo/…) abre la mascota aunque nadie haya
    escrito "DATOS DE TU CHIQUITIN", y un segundo `Nombre:` con el tutor ya
    nombrado también. Si el `Nombre:` **inmediatamente anterior** era ambiguo
    (`nombre`/`nombres`/`comosellama`, no "Nombre completo"), se le devuelve a
    la mascota — pero solo si fue el último dato reconocido: con una cédula o
    un teléfono de por medio ese nombre sí era del tutor.
  - **La respuesta va DEBAJO de la etiqueta**, no al lado (el que copia la
    plantilla y escribe abajo es tan común como el que responde en la misma
    línea). Una etiqueta sin valor toma la siguiente línea no vacía, salvo que
    esa línea sea otra etiqueta conocida o un encabezado de sección — así la
    plantilla reenviada en blanco sigue sin aportar nada.
- **Un solo lugar convierte texto libre a valores de `<select>`**: los
  `intakeNormalizar*` (especie/genero/esterilizado/peso/fecha/edad/chip/movil/
  docTipo). Por eso `api/parsear-intake.js` devuelve el texto **crudo** del
  cliente y no normaliza nada — si normalizara, las dos vías podrían divergir.
  Dos criterios que no son cosméticos: una especie desconocida cae en `Otro`,
  nunca en `Canino`; y en `intakeNormalizarEsterilizado()` el orden de las tres
  pruebas importa — "no sé" se mira antes que "no", porque guardar "No
  esterilizado" es una afirmación clínica que nadie hizo.
- **Guard anti-alucinación** (`intakeVerificarContraTexto` /
  `intakeDigitosPresentes`): cédula, celular, peso y fecha que el modelo
  devuelva se descartan si sus dígitos no están en el mensaje pegado. Mismo
  criterio que `depurar_vitales()` en `extraer_soip.py`; son los cuatro campos
  donde un dígito inventado hace daño real (dos son identidad).
- **La precarga de la mascota va DENTRO de `openRegistrarMascotaModal()`, al
  final.** Esa función limpia los 12 campos al abrir, así que hacerlo desde el
  llamador lo borraría. Ubicada ahí cubre todas las vías de apertura, incluida
  la reapertura para la segunda mascota de la misma cola.
- **`intakeMascotasPendientes` se declara junto a `postRegistroMascotaAccion`**
  (~línea 8580), no junto a su propio bloque: `openRegistrarMascotaModal()` la
  lee y vive mucho más arriba en el mismo script, y un `let` de nivel superior
  no está hoisted (ver la trampa de temporal dead zone en "Qué es esto").
- **La cola se vacía en los tres puntos de abandono**, y los tres hacen falta:
  `closeRegistrarMascotaModal()`, `closeRegistrarPropietarioModal()` y el
  `return` de tutor sin vincular de `guardarPropietario()`. Sin esto, unas
  mascotas huérfanas se precargarían en el siguiente registro manual, que sería
  de otro tutor — el error más caro de este flujo. Como cerrar el modal de
  tutor significa cancelar, `guardarPropietario()` **captura la cola antes de
  cerrar y la restaura justo antes de abrir el modal de mascota**, exactamente
  el mismo patrón que ya usa con `agendaRegistroPropietarioPendiente`.
  `redConfirmarVinculacion()` también cierra ese modal, y ahí vaciar es lo
  correcto: las mascotas ya llegaron de la red.
- **Los T&C no se marcan por código** ni se inventa `prop-como-encontro`. El
  consentimiento del tutor no es algo que la app pueda dar por él.
- El endpoint usa `claude-sonnet-5` (override: `IRIS_MODELO_INTAKE`) con **tool
  use forzado** — el equivalente sin SDK de `messages.parse()` de
  `extraer_soip.py`. Necesita `ANTHROPIC_API_KEY` en Vercel; sin ella el parser
  por etiquetas sigue funcionando completo y solo se pierde el respaldo.

## Link público de autorregistro — `registro.html`
Tercera vía para dar de alta un tutor, y la única en la que **no digita
nadie de la clínica**: el botón `#btn-link-registro` del buscador de
Consultorio genera un enlace, se le manda al tutor por WhatsApp, él llena
sus datos y los de sus mascotas desde el celular, y la ficha queda creada.
Complementa a "Importar de WhatsApp" (que convierte un mensaje pegado en
formulario); acá el formulario lo ve el tutor.

- **`registro.html` es el ÚNICO archivo de la app fuera de `index.html`, y
  es deliberado.** La regla "no crear archivos nuevos por módulo" habla de
  módulos DENTRO del shell; esta es una pantalla **sin sesión**, para
  alguien que no es usuario de IRIS. Meterla en `index.html` obligaría al
  tutor a bajar 1,87 MB desde datos móviles y a montar un tercer shell
  hermano de `#auth-shell`/`#app-shell` — justo el acoplamiento que ya
  causó dos veces el bug de temporal dead zone. Es autocontenida: su
  propio CSS (copia acotada de las variables de paleta), su propia lista
  de países y su propia copia de la edad de 3 modos. No la conviertas en
  dependiente de `index.html`; que diverja un poco es el precio correcto.
- **`anon` no escribe en ninguna tabla.** No puede: `propietarios_insert_member`
  exige `user_is_member_of` y `mascotas_insert_member` además exige
  `propietario_vinculado`. Todo pasa por dos RPC `security definer` —
  `intake_link_preview` (qué ve el tutor al abrir) e `intake_link_enviar`
  (el envío) — calcadas de `get_invite_preview()`. **No abras una policy
  de `anon` sobre `propietarios`/`mascotas` "para simplificar"**: eso
  expondría las dos tablas centrales de la app a internet.
- **El bloque de `revoke`/`grant` del final de la migración hay que
  mantenerlo**, igual que el de la sección RED IRIS, y acá hacen falta los
  TRES roles: Postgres da EXECUTE a `public` por default (y `anon` lo
  hereda por ahí, así que revocarle solo a `anon`/`authenticated` no
  cambia nada — se verificó con `has_function_privilege`), y Supabase
  además concede explícitamente a `anon`/`authenticated`, así que revocar
  solo a `public` tampoco alcanza. Los helpers `intake_txt`/`intake_pet_key`
  no validan nada y no tienen por qué ser invocables desde afuera.
- **El id de la fila de `intake_links` ES el token**, igual que `invites`.
  Un solo uso (`usado_at`, tomado con `for update` para que dos envíos
  simultáneos no pasen los dos) y vence a los 7 días. Por eso no hace
  falta rate limiting propio: la superficie es un envío por token.
- **Si el documento ya existe en esa clínica, NO se duplica la ficha**: se
  rellenan solo las columnas vacías (`coalesce(nullif(actual,''), nuevo)`).
  Lo que la clínica ya había escrito nunca se pisa con lo que digitó el
  tutor — el tutor puede equivocarse y el operador ya verificó.
- **Si `red_vinculado` vuelve `false`** (la identidad ya vivía en otra
  clínica, lo decide el trigger `red_trg_publicar_propietario`), se crea el
  tutor pero **cero mascotas**, y el link queda en `estado='sin_vincular'`.
  No es una limitación a rodear: sin vincular no se le cuelga nada, y al
  verificar la identidad las mascotas llegan de la red. El payload crudo
  igual queda en `intake_links.datos_recibidos`. Al tutor se le muestra un
  mensaje neutro — nunca se le cuenta nada de la red.
- **`programarBusquedaEnServidor()` es lo que hace que el médico lo
  encuentre.** `cargarDatosClinicaDesdeSupabase()` solo corre al iniciar
  sesión, así que un tutor creado por la RPC después de eso no está en
  memoria y el buscador diría "no se encontraron resultados" sobre una
  ficha que sí existe. Se engancha en el mismo empty-state que
  `programarBusquedaEnRed()` (primero la clínica propia, después la red),
  con debounce de 700 ms, y **filtra por el término**, no "todos los
  propietarios" — así no se topa con el límite de 1000 filas de PostgREST.
  Un término solo se marca hecho si la consulta respondió.
- `propietarios.origen = 'autorregistro'` es solo señalización (etiqueta
  `.owner-origen-tag` en el buscador, con el acento del tema): no cambia
  ningún permiso. Las fichas registradas por la clínica lo tienen en null.
- **`intake_links` SÍ está en `RESPALDO_TABLAS`** — a diferencia de
  `consultas_audio`, que es un buzón efímero, acá la fila guarda el
  payload original y el estado de cada enlace enviado.
- El formulario público NO sube foto de mascota: haría falta una policy de
  `anon` sobre el bucket `fotos-mascotas`. La foto se toma en la clínica.
- No hay ni hace falta `vercel.json`: el proyecto es zero-config y sirve
  cualquier `.html` de la raíz tal cual.

## Unificar mascotas duplicadas (menú "+ Nuevo" de la ficha)
El mismo animal termina con dos fichas cuando lo lleva primero una persona y
después otra: distinta cédula → distinto tutor → mascota nueva. **No es un bug
de la app, es cómo funciona una clínica.** Al unificar, uno de los dos tutores
queda como responsable y el otro como **contacto secundario**.

- **Quien mueve los datos es la RPC `fusionar_mascotas`, nunca el navegador.**
  Son 17 tablas con FK a `mascotas` más dos `pet_key` de texto: media fusión
  aplicada sería peor que ninguna, así que va todo en UNA transacción.
  `ejecutarFusionMascotas()` solo arma `p_datos` y llama.
- **Es `security definer` por una razón concreta, no por comodidad:**
  `mensajes` y `red_solicitudes` **no tienen policy de UPDATE** (un mensaje
  enviado no se edita). Con los permisos del usuario esos UPDATE afectarían
  0 filas EN SILENCIO y los mensajes se irían por el CASCADE al borrar la
  ficha duplicada. Por eso la función valida `user_is_member_of` ella misma,
  que las dos fichas sean del mismo establecimiento, y que el responsable
  elegido exista en esa clínica y esté vinculado.
- **`c_tablas` dentro de la función es la lista de tablas con `mascota_id`.**
  Si agregás un módulo clínico nuevo con esa columna, **sumalo ahí** o su
  historia se perderá en la próxima fusión — la fila duplicada se borra y el
  CASCADE se la lleva. Ese es el punto de mantenimiento del módulo.
- **`agenda_eventos` y `eventos_seguimiento` referencian la mascota por
  `pet_key` (texto), no por FK.** Se actualizan aparte. Sin eso quedarían
  apuntando a una key inexistente y los eventos desaparecerían de la ficha
  sin ningún error visible.
- **La ficha duplicada se BORRA** (decisión explícita del cliente). Antes de
  borrar, la fila completa y el conteo de lo movido quedan en
  `mascota_fusiones`, que es un log de auditoría — sin policies de escritura
  a propósito: un log que el usuario pueda editar no sirve de log. Es lo
  único que queda si alguien unificó dos mascotas distintas.
- **Tres pasos y confirmación escribiendo el nombre, a propósito.** Dos
  mascotas homónimas de clientes distintos son un caso NORMAL (en producción
  ya hay "Canela" y "Oreo" así). El paso 1 muestra tutor, microchip, número
  de registros clínicos y fecha de la última consulta de cada candidata: sin
  esos datos es imposible distinguirlas. No agregues un atajo que se salte
  la comparación.
- **Solo se pide elegir en los campos donde de verdad hay conflicto** (los dos
  con valor y distintos). Si la ficha que se conserva tiene el chip vacío y la
  otra lo tiene, se toma el de la otra sin preguntar — la elección por defecto
  nunca pierde un dato que solo existe en un lado. Por defecto se conserva la
  ficha con MÁS historia clínica (mover menos registros es menos superficie de
  error), pero se puede cambiar.
- **El histórico de peso se combina siempre, no se elige.** Son mediciones
  reales de las dos fichas, igual que las consultas.
- El responsable puede ser el tutor de cualquiera de las dos fichas, incluida
  la que se elimina. Los dos tutores originales conservan su ficha, su
  documento y su facturación: `ventas_facturas`/`ventas_cotizaciones` apuntan
  a `cliente_id`, no al propietario ni a la mascota, así que **la fusión no
  toca facturación**.
- Después de fusionar se llama a `cargarDatosClinicaDesdeSupabase()` completo
  en vez de parchear el modelo en memoria. Es una acción rara y deliberada, y
  cualquier parche parcial dejaría `patientData` mintiendo sobre 17 arrays.
- `mascota_contactos` se pinta en la fila de meta de la cabecera del paciente
  (`#pet-header-contactos`, mismo patrón de slot opcional que
  `#pet-header-temperamento`, por eso el Kardex no se ve afectado). Se puede
  quitar un contacto desde ahí; eso NO borra la ficha del tutor.
- **Buscar al contacto secundario tiene que llevar al Consultorio.** Es la
  mitad que le faltaba a la unificación: la otra persona sigue llamando y
  preguntando por el animal, y su fila salía con "Sin mascotas registradas"
  porque no es responsable de ninguna por FK. Lo resuelve
  `getMascotasRelacionadasDePropietario(id)` = propias (FK) + aquellas donde
  figura en `contactos`, cada entrada con un tercer elemento `esContacto`
  (formato compatible con quien solo desestructura `[petKey, data]`). La usan
  el buscador, Admin > Tutores, el perfil del tutor, el popover del
  propietario, el hero del Tablero y `getUltimaGestionPropietario`.
  **`getMascotasDePropietario` sigue siendo FK pura y NO hay que sustituirla
  en la guarda de borrado de un tutor** ("tiene mascotas registradas"): ahí lo
  que importa es de quién SON las mascotas, y un contacto secundario no tiene
  ninguna propia — su fila de `mascota_contactos` se va sola por CASCADE.
- Esas mascotas se marcan con `contactoTagHTML()` (pastilla "contacto" +
  responsable real en el `title`). Sin la marca, la fila del contacto se ve
  idéntica a la del responsable y se pierde quién responde por el animal. La
  única excepción es el hero del Tablero, donde el marcador va solo en el
  `title`: es de una sola línea en modo compacto y una pastilla por chip lo
  desbordaría.
- Las dos tablas están en `RESPALDO_TABLAS`.

## Seguimiento de anestesia (sub-registro de Cirugías)
Durante una cirugía con anestesia se monitorea al paciente **cada 5–10
minutos**: FC, FR, PAS/PAD/PAM, SpO₂, TC y EtCO₂. Antes eso terminaba como
prosa dentro de "Notas post-operatorias", que no es consultable ni comparable
en el tiempo. Entrada: acción **"Seguimiento de anestesia (N)"** en el menú
"..." de la fila de Cirugías → `#anestesia-modal`. Tabla
`anestesia_mediciones` (migración `20260809_seguimiento_anestesia.sql`).

- **El enlace al padre es `cirugia_id`, un uuid con FK real** — no un índice
  de array ni una cadena tipo `${hospId}:${diaIndex}`. Los seguimientos de
  hospitalización usan esa cadena porque un día de kardex no es una fila
  propia; acá el padre SÍ lo es. `getAnestesiaMediciones(petKey, cirugiaId)`
  filtra por ese uuid, nunca por posición: `renderCirugiasTable()` reordena
  las filas al pintar y el array se altera con `unshift`.
- **`puedeSeguimientoAnestesia()` exige `!!record.id`, y no es opcional.**
  Sin el uuid de la cirugía no hay a qué colgar la medición, y las cirugías
  mock de los pacientes de ejemplo no lo tienen — por eso la acción no
  aparece ahí. Las otras dos condiciones son de negocio: `anestesia !==
  'Ninguna'` y `estado !== 'cancelado'`.
- **`ANESTESIA_VITALES` es la fuente ÚNICA de los 8 vitales.** De esa
  constante salen la grilla del formulario, las columnas de la tabla
  (`anestesiaTablaColumnas()`) y el detalle del modal Ver. Agregar un vital
  es agregar una entrada ahí y una columna en Supabase, nada más. En el
  Kardex las 8 filas de signos están repetidas a mano en cada render; ese es
  justamente el error que este módulo no repite.
- **Un vital vacío se guarda `null` y desaparece por completo** — no se lista
  en el modal Ver, no sale en la tabla salvo como `—`, y no hay columna
  `*_no_evaluado` ni hay que crearla. Es el mismo requisito del interruptor
  "No evaluado" del Tablero, pero acá NO hace falta el control: el campo
  vacío ya produce ese resultado. Por lo mismo, PAS/PAD se imprimen `120/80`
  solo si están las dos (`anestesiaPresionTexto()`); si falta una sale `PAS
  118` suelta, nunca `PA —/80`.
- **UN solo modal, no dos como Seguimientos** (que tiene listado + formulario
  separados). Acá se registran mediciones seguidas mientras dura el
  procedimiento: formulario arriba, mediciones abajo, y "Registrar" **no
  cierra nada** — limpia el formulario, repone la hora actual y enfoca el
  primer campo. Editar tampoco abre un modal: precarga ese mismo formulario y
  el botón pasa a "Actualizar" (`editarAnestesiaMedicion()` /
  `cancelarEdicionAnestesia()`).
- **La tabla ordena ASCENDENTE**, al revés que todos los demás módulos: una
  curva de anestesia se lee hacia adelante, no es un historial. Por eso la
  query de `cargarDatosClinicaDesdeSupabase()` también va `ascending: true` y
  el guardado hace `push` en vez de `unshift`.
- **No escribe en `data.timeline`, a propósito.** Una anestesia produce
  decenas de mediciones; la entrada de historia ya la crea la cirugía
  (`construirCirugiaTimelineDesdeFila`). Volcarlas al timeline lo haría
  ilegible — no lo "arregles".
- Roles: registrar lo puede **admin, médico y auxiliar** (el auxiliar es
  quien monitorea — mismo criterio del Kardex, donde llenar signos vitales
  no exige el "Modo programación"). Editar/eliminar sigue el criterio de
  Seguimientos: admin todo, médico y auxiliar solo lo propio, auxiliar nunca
  elimina.
- `renderCirugiaRowActionsMenu()` es un clon local de `renderRowActionsMenu`
  (Cirugías tiene reglas de rol propias) y **no aceptaba `extraActions`** —
  se le agregó el tercer parámetro con el mismo formato `{icon, label,
  onclick}` de la genérica. Si hace falta otra acción condicional en
  Cirugías, va por ahí.
- `anestesia_mediciones` está en `RESPALDO_TABLAS` y en el `c_tablas` de
  `fusionar_mascotas`. Ese `create or replace` vive en la misma migración, y
  **el nombre del archivo ordena después de `20260809_fusionar_mascotas.sql`
  a propósito**: si ordenara antes, un replay completo de las migraciones
  repondría la lista vieja y la próxima unificación de mascotas perdería el
  monitoreo en silencio.
- Sin policy `_select_red` ni tipo nuevo en `red_solicitudes_tipos_validos`:
  el monitoreo de anestesia no se comparte entre clínicas. La cirugía sí, y
  eso alcanza para que la otra clínica sepa que el procedimiento existió.

## Configuración de la veterinaria (Admin) — 8 subtabs
`#admin-outer-config`. Los 8 subtabs tienen contenido real: Información
general · Localización y servicios · Agenda y disponibilidad · Perfil
fiscal · Ventas e inventario · Preferencias · Sala de espera · Sedes
vinculadas.

- **Un contenedor y un renderer por subtab.** `switchVetConfigTab(tabKey)`
  resuelve `VETCONFIG_RENDERERS[tabKey]` y activa
  `#vetconfig-view-<tabKey>`. Ese mapa vive **dentro** de la función a
  propósito: como `const` de nivel superior quedaría en temporal dead zone
  si alguna vez se llamara antes de esa línea (la trampa de "Qué es esto",
  ya sufrida dos veces); las `function` a las que apunta sí están hoisted.
  Para agregar un subtab: un `<div class="vetconfig-subview"
  id="vetconfig-view-<key>">` vacío + una entrada en el mapa. El panel
  placeholder compartido (`#vetconfig-view-placeholder`) hoy solo lo usa
  **Preferencias**, que lo repinta entero.
- **Dónde persiste cada cosa, y por qué no es lo mismo.**
  **Preferencias** es lo único que vive en `localStorage`
  (`claveVetConfigPreferencias()`): son ajustes del dispositivo. Todo el
  resto son columnas reales de `establecimientos` — configuración de la
  CLÍNICA, que tiene que verse igual desde cualquier equipo. No metas un
  ajuste nuevo de clínica en `localStorage` "porque es más rápido".
- **Un solo camino de escritura: `persistirEstablecimientoConfig(patch, okMsg)`.**
  Update bloqueante + `.select('id')` para detectar el caso "0 filas = no
  eres admin" — la policy `establecimientos_update_admin` filtra en
  silencio, sin devolver error (mismo caso que `subirLogoClinicaReal`).
  Solo si el update afectó una fila se toca `currentSession` y se repinta.
- **Espejo en memoria: `ESTABLECIMIENTO_CONFIG`**, rearmado por
  `cargarEstablecimientoConfigDesdeSesion()` desde
  `currentSession.activeMembership.establecimiento`. La query de sesión ya
  trae `establecimientos(*)`, así que **una columna nueva llega sola** sin
  tocar ninguna lectura. Para agregar un ajuste: columna en una migración
  nueva + entrada en `establecimientoConfigDefaults()` + entrada en el
  mapeo de `cargarEstablecimientoConfigDesdeSesion()`. Los booleanos van
  con el helper `bool(v, fallback)` de esa función: una sesión abierta
  ANTES de correr la migración los trae `undefined`, y `!!undefined` sería
  `false` — con `ventas_habilitar` (default `true`) eso escondería el
  módulo de Ventas sin que nadie lo haya apagado.
- **`establecimientos` está en `RESPALDO_TABLAS`** y es la única entrada
  que `respaldoLeerTablaCompleta()` filtra por `id` y no por
  `establecimiento_id` (su propia PK ES el establecimiento). Desde que la
  fila carga toda esta configuración, un respaldo con los datos clínicos
  pero sin ella no permitiría reconstruir la clínica.
- Migraciones: `20260901_establecimiento_config.sql` (Localización +
  Agenda) y `20260901b_establecimiento_config_fiscal_ventas.sql` (Perfil
  fiscal + Ventas e inventario + Sala de espera + Sedes). Son dos archivos
  porque el primero **ya estaba aplicado en vivo** cuando se agregó el
  segundo grupo — no le agregues columnas a una migración ya corrida;
  verificá con `information_schema.columns` antes de decidir.

### Lo que alimenta cada subtab fuera de su propia pantalla
Estos ajustes no son decorativos; el efecto de cada uno vive en otro
módulo y hay que mantenerlo:

- **Agenda y disponibilidad** → `getDuracionCitaMin()` fija la "Hora de
  fin" por defecto del modal de evento; `getRangoHorarioAtencion()` define
  el rango de la grilla de Disponibilidad **y el de los dos calendarios de
  Agenda** (general y personal); `prevenirSolapamientos` hace
  que `guardarEventoAgenda()` BLOQUEE (no solo advierta) vía
  `haySolapamientoAgenda()`.
  - Los calendarios lo toman vía `agendaSlotTimes()` (rango de la grilla)
    y `agendaBusinessHours()` (sombreado de horas hábiles por día, con
    `AGENDA_DIA_A_FC` mapeando `lun|mar|...` a los días de FullCalendar).
    Tenían `07:00–20:00` clavado, así que configurar el horario no cambiaba
    nada en Agenda. **Un calendario ya montado no se reconstruye solo**: hay
    que llamar a `aplicarHorarioAgendaACalendarios()` (lo hacen
    `guardarVetConfigAgenda()` y los dos `refresh*CalendarEvents()`).
  - **`getRangoCalendarioAgenda()` ENSANCHA ese rango para cubrir los
    eventos ya agendados fuera de él, y eso no es un detalle**: en las
    vistas timeGrid FullCalendar no dibuja nada fuera de
    `slotMinTime`/`slotMaxTime`, así que poner la apertura a las 08:00 haría
    desaparecer sin ningún aviso una cita de las 06:30 que sigue existiendo.
  - Por lo mismo, `seedDisponibilidadMedicos()` completa los slots
    FALTANTES de cada encargado y no solo los de un encargado nuevo: al
    ampliar el horario, los slots que el mapa viejo no tenía se pintaban con
    `DISPONIBILIDAD_COLORS[undefined]` (celda transparente) y el horario
    nuevo salía en blanco.
- **Perfil fiscal** → `sincronizarDatosFiscalesFacturacion()` llena
  "Datos fiscales de la clínica" de Ventas > Configuración de facturación
  (razón social, NIT+DV, dirección), con `CLINIC_INFO` de respaldo
  mientras el perfil esté vacío. Se llama desde `renderVetConfigGeneral()`,
  desde `guardarVetConfigFiscal()` y desde `abrirVentasView('config-facturacion')`.
  `nombreFiscalEstablecimiento()`/`identificacionFiscalEstablecimiento()`
  son los dos únicos lugares que arman esos textos — el PDF de tirilla los
  reusa. El perfil fiscal es **distinto** del nombre comercial de
  Información general a propósito: una clínica puede facturar a nombre de
  otra razón social o de una persona natural (por eso Apellidos solo
  existe en modo "Persona natural", y guardar como jurídica los descarta).
- **Ventas e inventario** → ver la sección siguiente.
- **Sala de espera** → tablero proyectable. Los turnos salen de
  `AGENDA_EVENTOS` (citas de HOY en estado programada/confirmada/en_curso),
  **no de un array paralelo**: quien agenda ya registró ahí a quién se
  atiende, y un segundo listado se desincronizaría con el primer cambio de
  cita. `salaEsperaBoardHTML(cfg)`/`salaEsperaBoardCSS(scope)` los
  comparten la previsualización del subtab y la ventana proyectada — una
  sola fuente, o divergen. La ventana (`abrirPantallaSalaEspera()`) **no
  lleva lógica propia**: la repinta esta pestaña con un `setInterval`
  (`pintarPantallaSalaEspera()`), así no hay que serializar datos hacia
  allá y se apaga sola si alguien cierra la ventana. Los `mostrar_*` son
  ajustes de **privacidad**, no estéticos: el nombre del tutor se lee
  desde toda la sala. `salaEsperaAnunciados` evita que el aviso sonoro
  suene en cada refresco mientras el paciente siga "En curso".
- **Sedes vinculadas** → es **DIRECTORIO, no permiso**. Vincular una sede
  no abre ni una fila: el acceso a historias clínicas entre
  establecimientos sigue pasando exclusivamente por la Red IRIS
  (`red_solicitudes` + policies `*_select_red`), y la pantalla lo dice
  explícitamente. Por eso no hace falta ninguna policy nueva. Los
  candidatos salen de `currentSession.memberships` filtrados a `rol ===
  'admin'`: solo se declara sede a una clínica que la propia persona
  administra.

## Información tributaria del cliente — vive en `propietarios`
Panel "Información tributaria del cliente" (documento, tipo de
organización, razón social, régimen, obligaciones, detalles). Existe DOS
veces en el DOM, con los mismos campos y distinto prefijo de id: `fct-`
en Facturación > Estado de cuenta y `dvfct-` dentro del modal de
Cotización/Factura (los dos modales conviven, unos ids duplicados
romperían `getElementById`).

- **La fuente de verdad es `propietarios`, NO `VENTAS_CLIENTES`.** Ese
  array es un espejo en memoria que `getVentasClienteIdDePropietario()`
  rearma en cada sesión desde los tutores reales, así que lo que se
  escribía sobre él moría al recargar: el tipo de organización se perdía
  y `guardarDocVenta()`/`confirmarCerrarCuenta()` volvían a exigirlo en
  cada factura nueva y en cada edición. Ese era el bug.
- **Los campos que ya tienen columna propia en `propietarios` no se
  duplican**: documento → `doc_tipo`/`doc_numero`, teléfono → `movil`,
  correo → `email`, dirección → `direccion`. Solo los 7 puramente
  tributarios estrenaron columna `trib_*` (migración
  `20260904_propietarios_info_tributaria.sql`). Dos columnas para el
  mismo dato divergirían al primer cambio hecho desde "Editar
  propietario".
- **Un solo camino de escritura: `persistirInfoTributariaCliente(clienteId, datos)`**
  (update BLOQUEANTE sobre `propietarios` y recién después el espejo).
  Los dos paneles leen sus campos con `leerPanelInfoTributaria(prefijo)`
  y llaman ahí — no repliques el `Object.assign` sobre el cliente.
  Usa `.select('id')` para detectar el caso "0 filas": la policy
  `propietarios_update_member` exige `red_vinculado`, así que la ficha de
  un tutor sin verificar se filtra en SILENCIO, sin error (mismo caso que
  `persistirEstablecimientoConfig`) — un tutor sin vincular no puede
  guardar información tributaria, y el toast lo dice.
- **De vuelta al espejo: `volcarInfoTributariaAlCliente(cliente, p)`**,
  llamada desde `getVentasClienteIdDePropietario()` (las dos ramas) y
  desde `poblarDocVentaClienteTributario()`. Solo pisa los campos que el
  tutor YA tiene guardados, para no dejar en blanco a un cliente semilla
  de la demo (`c1..c15`, sin tutor detrás) ni a uno al que nadie le llenó
  el panel. `getPropietarioDeVentasCliente(clienteId)` es el camino
  inverso: `c-prop-<uuid>` trae el id dentro, y los semilla solo se
  resuelven por nombre.
- **Los dos selects de "Tipo de documento" listan las MISMAS 6 opciones
  que `#prop-doc-tipo`** y se traducen con `TRIB_DOC_TIPO_LABEL`/
  `TRIB_DOC_TIPO_ABREV`. Antes el panel guardaba `'C.C.'` o `'NIT'` y
  nada más: guardar desde acá le cambiaba el tipo de documento al tutor.
  Si agregás una opción a uno de los tres selects, agregala a los otros
  dos y al mapa.
- No hace falta tocar `RESPALDO_TABLAS` (`propietarios` ya está) ni el
  `c_tablas` de `fusionar_mascotas` (no tiene `mascota_id`).

## Interruptores de "Ventas e inventario" — dónde actúa cada uno
Cada uno de estos toggles tiene efecto real; el bloque
"EFECTOS REALES DE 'VENTAS E INVENTARIO'" de `index.html` los agrupa.
Si tocás Ventas/Inventario, respetalos:

- **`invPermitirSobreventa`** → `bloqueadoPorSobreventa(tipo, items)` al
  principio de `guardarDocVenta()`, antes de cualquier escritura. Solo
  aplica a **facturas** (una cotización no compromete existencias; el
  documento soporte es una compra a proveedor, suma). `itemsSinExistencias()`
  **agrupa por `productoId` antes de comparar**: un mismo producto puede
  venir en dos filas y evaluarlas por separado dejaría pasar el doble del
  stock. `avisoExistenciasItemHTML()` es solo señalización inline.
  **`productoEsCuantificable(p)` no mira solo `p.cuantificable`**: ese
  campo lo traen únicamente los productos creados desde "+ Registrar" y
  los importados por Excel; el catálogo semilla y los exports viejos no lo
  tienen pero sí traen `stock`, que es el desempate. Sin eso, media
  bodega quedaría fuera del control de existencias.
  **Ojo:** una venta hoy NO descuenta stock (eso lo hacen Inventario >
  Salidas y Compras). El chequeo es contra las existencias actuales.
- **`invConfirmacionPicking`** → `aplicarPickingAItems(items)` en
  `guardarDocVenta()` marca `it.entrega = 'pendiente'` en cada ítem
  cuantificable. **El estado vive DENTRO de cada ítem**, no en una columna
  nueva: `ventas_facturas.items` ya es jsonb y se guarda completo en cada
  update, así que no hace falta migración ni un segundo lugar donde el
  estado pueda desincronizarse. Un ítem que ya tiene estado se respeta
  (editar la factura no revive como pendiente algo entregado) y **apagar
  el interruptor no borra lo pendiente** de las facturas que ya lo tenían
  — quedarían entregas abiertas que nadie volvería a ver.
  `facturaEntregaEstado()` agrega el estado de la factura,
  `facturaEntregaBadgeHTML()` lo pinta y `abrirEntregaModal()` abre
  `#entrega-modal`. `marcarEntregaItem()` **no es optimista**: si el
  update falla se revierte, porque una entrega que quedó solo en pantalla
  haría que bodega la dé por despachada. Gate de rol:
  `puedeConfirmarEntrega()` (admin y ventas — es acción de caja/bodega, no
  clínica). `accionesExtraFactura(f)` junta esta acción con "Cerrar
  cuenta"; cualquier acción condicional nueva de una factura va ahí.
- **`ventasUsarTurnos`** → tabla `turnos` (migración
  `20260902_turnos_caja.sql`) + `movimientos.turno_id`. `TURNO_ACTIVO` es
  el turno abierto de ESTA persona en el establecimiento activo, repuesto
  por `cargarTurnoActivo()` al final de `cargarDatosClinicaDesdeSupabase()`.
  El turno es **por persona, no por establecimiento** (en una clínica con
  dos cajas cada quien responde por lo suyo): el índice único parcial
  `turnos_uno_abierto_por_usuario_idx` es sobre
  `(establecimiento_id, user_id) where cerrado_at is null`, y es una
  garantía de la BASE — sin él, dos pestañas del mismo usuario abren dos
  turnos y los movimientos se reparten sin que nadie lo note (`abrirTurno()`
  trata el `23505` como "ya había uno" y lo retoma, no como error).
  Abrir/cerrar exige `user_id = auth.uid()` ADEMÁS de `user_is_member_of`:
  nadie le cierra el turno a otro. Sin policy de DELETE — un turno cerrado
  respalda un arqueo.
  El guard es `bloqueadoPorTurnoCerrado(accion)` (devuelve `true` = abortar,
  ya avisó) y se llama desde `guardarMovimiento()` y `confirmarCerrarCuenta()`
  (cerrar una cuenta genera un ingreso). **Solo al CREAR**: exigir turno
  para corregir un movimiento viejo dejaría un error de digitación
  imposible de arreglar fuera de horario, y editar no cambia a qué turno
  pertenece el movimiento. La barra `#turno-bar` la pinta `renderTurnoBar()`
  y solo existe en Ingresos y Egresos > Movimientos.
  **Cerrar turno ≠ cerrar caja**: el arqueo del día sigue siendo la
  pestaña "Cierre de caja" (`VENTAS_ARQUEOS`), que agrupa por FECHA. El
  turno agrupa por `turnoId`, que es justamente lo que permite separar dos
  jornadas del mismo día.
- **`recibosPrevenirCierreSaldo`** → `confirmarCerrarCuenta()` rechaza un
  pago menor al total. Sin esto la factura quedaba `Pagada` y generaba el
  ingreso completo con un pago parcial, o sea la clínica declaraba cobrado
  lo que no cobró.
- **`recibosImpresionTirilla`** → `generarPdfEstadoCuentaFactura()` desvía
  a `generarTirillaFactura()` (rollo de 80 mm = `TIRILLA_ANCHO_PT`). El
  desvío vive en esa función y no en cada llamador
  (`confirmarCerrarCuenta`, `rowActionImprimir`…) para que el ajuste valga
  por igual en todos. El alto se estima **de más** a propósito: jsPDF no
  crece la página sola y lo que se pase sale cortado, mientras que el
  papel sobrante lo consume el corte de la impresora.
- **`recibosNotas`** → pie de página fijo, impreso tanto en la tirilla
  como en el PDF A4. **No es** el "Mensaje predeterminado de
  observaciones" de Ventas > Configuración de facturación: aquel vive en
  `localStorage`, es por navegador y precarga un campo EDITABLE de cada
  factura; este es texto fijo de la clínica al pie del documento.
- **`ventasHabilitar` / `factSoftwarePropio` / `factSiigo` /
  `factPosHabilitar`** son el espejo (prender/apagar) de lo que se detalla
  en Ventas > Configuración de facturación; `irAConfiguracionFacturacion(pane)`
  salta allá. Las credenciales, resoluciones y dispositivos NO se duplican
  acá. `guardarVetConfigVentasInv()` sincroniza `#pos-habilitar-toggle` si
  esa pantalla ya está montada, para que las dos no muestren lo contrario.
- **`facturacionModulosVinculados`** (jsonb, claves de módulo clínico) se
  guarda y se lee, pero **todavía no dispara cargos automáticos** en la
  cuenta del tutor: eso exige que cada módulo clínico proponga sus ítems
  al guardar. Es el pendiente conocido de esta sección.

## Envío de correos — un solo camino para toda la app
Antes de esto, lo único que mandaba un correo real era la confirmación de
registro de propietario y el código de verificación de email. Todo lo demás
que decía "enviado" mentía: `rowActionEmail()` era
`showToast('Documento enviado por email')` en los ~10 módulos que ofrecen la
acción, Agenda abría un modal mock (`#agenda-notif-modal`) con el texto
"📧 Notificación enviada a: …", y los recordatorios configurados en
Configuración de la veterinaria > Agenda nunca salían: solo se calculaba
`agenda_eventos.recordatorio_24h` para mostrarlo en el detalle.

**El modo de falla de este subsistema es SILENCIOSO, y es lo primero que hay
que entender antes de tocarlo.** Sin `RESEND_FROM_EMAIL` el remitente cae a
`onboarding@resend.dev`, que Resend SOLO entrega a la dirección dueña de la
cuenta: no falla nada, no hay error en ningún log y los correos simplemente
no llegan. Encima, la llamada vieja era `await fetch('/api/send-email', …)`
sin mirar la respuesta, así que un 500 por API key ausente tampoco dejaba
rastro. Por eso hay dos cosas que no se pueden aflojar: **toda llamada revisa
el resultado y avisa por toast**, y existe una pantalla de diagnóstico
(Configuración de la veterinaria > Agenda > "Estado del envío de correos",
`renderCorreoEstado()` → `GET /api/correo-estado`) que responde "¿por qué no
llega?" sin abrir los logs de Vercel.

### Las piezas
- **`api/_lib/`** — no son rutas (Vercel ignora como endpoint todo lo que
  empieza por `_`, pero sí lo empaqueta). `correo.js` (cliente de Resend +
  plantilla base + `remitenteEsDePruebas()`), `plantillas.js` (render de una
  fila de la bandeja), `ics.js`, `fechas.js`, `supabase.js` (Service Role +
  autorización) y `bandeja.js` (encolar/procesar).
- **`api/enviar-correo.js`** — el camino genérico: documento por correo,
  mensaje al propietario, invitación de usuario, link de autorregistro,
  correo de prueba. **Es UN endpoint y no uno por módulo a propósito**: el
  remitente, la plantilla, el log y el reintento son los mismos para todos y
  lo único que cambia es el contenido, que viaja en el payload. No agregues
  un endpoint nuevo por módulo — agregá un `tipo` a `TIPOS_VALIDOS`.
- **`api/agenda-notificar.js`** — avisos de cita + programación de
  recordatorios.
- **`api/correos-cron.js`** — el único consumidor de la cola.
- **`api/correo-estado.js`** — diagnóstico (solo admin).
- **`index.html`**, bloque "ENVÍO DE CORREO — punto único del lado del
  navegador" (junto a `generarYSubirPdfPropietario`): `enviarCorreoIris()`,
  `notificarAgendaEvento()`, `apiCorreo()`, `blobAAdjuntoCorreo()`,
  `openEnviarCorreoModal()`. Cualquier disparador nuevo pasa por ahí.
- **`api/send-email.js` ya NO existe**: tenía un solo llamador y su
  plantilla estaba clavada al registro de propietario. Ese envío ahora va
  por `/api/enviar-correo`, queda registrado en la bandeja y **manda el PDF
  adjunto en vez de un enlace firmado de Storage** — el anterior vencía en 1
  hora y el tutor que abría el correo al día siguiente encontraba un enlace
  muerto.

### La bandeja de salida (`correos`) — por qué todo pasa por una cola
Migración `20260902b_correos_notificaciones.sql`. **Los correos inmediatos
también se encolan** (con `programado_para = now()`) y se procesan en el
mismo request. Tener un solo camino da un log auditable único, un reintento
uniforme y un solo lugar donde mirar cuando alguien dice "no me llegó". No
agregues un envío que llame a Resend directo saltándose la tabla.
- **Solo el backend escribe.** La tabla tiene policy de SELECT para miembros
  y **ninguna de insert/update/delete a propósito**: si un cliente pudiera
  insertar filas, cualquier usuario autenticado mandaría correos con el
  remitente verificado de la clínica.
- **`payload` guarda el DATO, no el HTML ya armado.** Un recordatorio
  programado con 7 días de antelación tiene que salir con la plantilla
  vigente el día que se envía. Por eso `renderizar()` corre en
  `procesarPendientes()`, no al encolar.
- **`correos_reclamar(p_limite)` es `security definer` con `for update skip
  locked`.** Es lo único que impide que dos ejecuciones solapadas (el cron y
  el disparo inmediato de la API, o dos ticks encimados) manden el mismo
  correo dos veces. PostgREST no sabe expresar ese reclamo, por eso es RPC —
  y por eso `revoke` a `public`/`anon`/`authenticated` + `grant` solo a
  `service_role` (mismo criterio del bloque de RED IRIS: revocar a `public`
  no basta). Reencola además lo que quedó en `enviando` hace más de 10
  minutos, que es lo que pasa si la función se murió a mitad.
- **`correos_no_duplicados_idx`** (único parcial sobre
  `referencia_id + tipo + destinatario_email + programado_para` donde el
  estado es pendiente/enviando) es lo que hace que reprogramar sea
  idempotente: guardar dos veces el mismo evento cancela y vuelve a
  insertar, y sin el índice un doble click dejaría al tutor con el
  recordatorio duplicado. `encolar()` trata el `23505` como "ya estaba", no
  como error.
- **Un error permanente no se reintenta.** `enviarCorreo()` marca
  `permanente: true` en 4xx que no sea 429 (dominio sin verificar,
  destinatario inválido, API key mala): gastar 3 intentos ahí solo haría
  esperar 15 minutos por un fallo que no cambia.
- `correos` **SÍ está en `RESPALDO_TABLAS`** — a diferencia de
  `consultas_audio`, que es un buzón efímero, acá las filas enviadas son la
  única prueba de qué se le comunicó al tutor y cuándo.

### El programador de recordatorios es pg_cron, NO un Vercel Cron
`public.disparar_correos_pendientes()` + job `iris-correos-pendientes` cada
5 minutos, vía `pg_net`. **No se usó Vercel Cron a propósito:** en el plan
Hobby corre como mucho UNA vez al día, y un recordatorio de "2 horas antes"
llegaría con medio día de retraso. Así el tick no depende del plan de
Vercel.
- La URL y el secreto viven en `public.app_config` (**RLS habilitada y CERO
  policies**, igual que las tablas de RED IRIS — ningún cliente de PostgREST
  la lee). **El valor real NO va en la migración: el repo de GitHub es
  PÚBLICO.** Se inserta a mano; ver `scripts/correos/README.md`.
- `CRON_SECRET` (Vercel) tiene que ser IGUAL a
  `app_config.correos_cron_secret` (Supabase). Si rotás uno, rotá el otro:
  los recordatorios dejan de salir en silencio, porque el endpoint devuelve
  401 y nadie está mirando.
- La comparación del secreto es en tiempo constante a propósito
  (`secretoValido()`): con `===` sobre strings el tiempo de respuesta filtra
  cuántos caracteres acertó quien prueba.

### Agenda — lo que hace `/api/agenda-notificar`
Se llama SIEMPRE al guardar o eliminar un evento, **incluso con el
interruptor "Notificaciones" apagado**: ese interruptor gobierna el correo
de calendario inmediato, mientras que los recordatorios al propietario son
un ajuste APARTE de la misma pantalla y hay que programarlos igual. Quien
decide qué sale es el servidor leyendo la configuración del establecimiento,
no un `if` en el navegador.
- **El evento se RELEE de la base, no se confía en lo que mande el
  navegador.** Consecuencia que hay que respetar: al eliminar, el navegador
  llama al endpoint **ANTES** del `delete` (`eliminarEventoAgendaReal()`),
  porque sobre una fila borrada no habría con qué armar el correo ni qué
  cancelar.
- **Cinco columnas nuevas en `agenda_eventos`** (`propietario_id`,
  `propietario_email`, `encargado_email`, `encargado_nombre`,
  `mascota_nombre`), las llena `datosNotificacionEventoAgenda()`. Existen
  porque `encargado_id` es el id LOCAL numérico de `USUARIOS_SISTEMA`, que
  se regenera 1..N en cada sesión del navegador (misma limitación ya
  documentada para `tareas_pendientes.responsable_id`), y `propietario` era
  solo un nombre en texto. **El cron corre sin navegador**: sin estas
  columnas no hay a quién escribirle. El email del tutor igual se RELEE de
  `propietarios` al enviar (por si lo cambió después de agendar); el
  guardado en la fila es el respaldo para tutores ya borrados. Los eventos
  creados antes de esto los traen en null y se completan solos la primera
  vez que se editen.
- **El trigger `agenda_eventos_cancelar_correos` es la garantía real de que
  no salga un recordatorio de una cita borrada.** El endpoint ya cancela lo
  pendiente, pero solo si el navegador llegó a llamarlo; un recordatorio de
  una cita que ya no existe (el tutor se presenta a una cita cancelada) es
  el peor resultado posible del módulo, así que la garantía vive en la BASE
  y cubre también un borrado desde el panel de Supabase o un CASCADE.
- **Los recordatorios van SOLO al tutor y SOLO por el canal `email`.** Lo
  primero porque la pantalla los rotula "Recordatorios al propietario"; lo
  segundo porque WhatsApp/SMS no tienen integración de salida y encolarlos
  haría creer que salieron. El resumen del modal lo dice explícitamente en
  vez de callarlo.
- Un recordatorio cuyo momento ya pasó **no se encola**: agendar hoy una
  cita para mañana no puede disparar al instante el aviso "de 7 días antes".
- **`SEQUENCE` del `.ics` sube en cada cambio** (se cuentan las
  notificaciones ya emitidas del evento). Un cliente de calendario ignora
  una actualización con SEQUENCE menor o igual al que ya tiene, así que sin
  esto reagendar duplicaría la cita en el calendario del tutor en vez de
  moverla. El `UID` es el id del evento, por el mismo motivo. Las horas van
  en UTC (sufijo `Z`) para no adjuntar un `VTIMEZONE`, que es donde fallan
  los clientes estrictos.
- **Identidad de la clínica en el correo.** El encabezado lleva el LOGO y el
  nombre de la clínica como título (antes era "IRIS" grande con la clínica en
  chiquito debajo): quien recibe puede atenderse en más de una veterinaria, y
  "IRIS" es el software, no el remitente. El logo sale de
  `establecimientos.logo_path` armando la URL pública del bucket
  `logos-clinica` a mano — no se trae el SDK de Supabase a la función. **El
  logo nunca es el único portador del nombre**: muchos clientes de correo
  bloquean imágenes remotas, así que va con `alt` al lado del nombre en texto.
  El pie repite nombre + dirección + teléfono + correo: sin eso, un correo de
  cita obliga a buscar a la clínica por fuera para reprogramar.
- **"Agendado por" NO es el tutor, y "Responsable" ya no existe como
  etiqueta.** Esa fila mostraba al propietario y se leía como si el dueño de
  la mascota hubiera hecho la reserva. Ahora sale de
  `agenda_eventos.created_by` (no de quien esté llamando: editar una cita no
  cambia quién la reservó) y **si esa persona es admin se muestra el nombre de
  la CLÍNICA**, no su nombre personal — cuando reserva la clínica, el
  interlocutor es la clínica. Para médico/auxiliar/ventas va el nombre propio,
  que es con quien el tutor va a hablar. `resolverAgendadoPor()` nunca lanza:
  el nombre de la clínica es un default correcto, no un relleno.
- **El tutor solo se lista en el correo del EQUIPO** (`filasAgenda(p, rol)`).
  En el del tutor sería decirle su propio nombre.
- **"Termina" se quitó** a pedido del cliente: la hora de fin no le aporta
  nada a quien recibe la cita y alargaba la tabla. El `.ics` sí la conserva,
  que es donde de verdad importa (el bloque en el calendario).
- **Lugar**: el campo sigue siendo texto libre, pero el modal de Agenda tiene
  dos atajos (`usarDireccionEnLugarAgenda()`) que lo rellenan con la dirección
  de la sede o con el domicilio del tutor — algunos servicios son a domicilio
  y escribir la dirección a mano cada vez es donde aparecían los errores de
  digitación que después el tutor lee en su correo. Si el campo queda vacío,
  el correo asume la dirección de la sede en vez de imprimir "Lugar: —".
- **`TIPO_LABELS`/`ESTADO_LABELS` en `agenda-notificar.js` son un espejo de
  `AGENDA_TIPO_LABELS` y los `<option>` de `#ag-estado`.** Están duplicados
  porque el cron tiene que rotular un evento agendado hace una semana sin
  navegador. Si agregás un tipo de cita en index.html, agregalo también ahí
  o el correo muestra el código crudo.

### Zona horaria — `establecimientos.zona_horaria`
`agenda_eventos.start_iso` es `timestamp` SIN zona a propósito (todo el
módulo trabaja con cadenas locales ingenuas). Para programar "24 h antes"
hace falta el instante real, y para eso la zona. `instanteDesdeLocal()`
(`_lib/fechas.js`) usa `Intl` en **dos pasadas**: la primera estima el
offset y la segunda lo corrige, que es lo que hace falta en los bordes de un
cambio de horario de verano. Colombia no lo tiene, pero la clínica puede no
estar en Colombia y el error sería de una hora entera en el recordatorio.
`fechaHumana()` NO pasa la cadena por `Date`: ya está en la hora de la
clínica y parsearla la movería a la zona del servidor (misma trampa que
`dashDiaLocalDeISO()`).

### Los demás disparadores
- **"Enviar por email" del menú "..."** (`rowActionEmail`) abre
  `#enviar-correo-modal` con el destinatario **a la vista y editable**:
  mandar un documento clínico a la dirección equivocada no se deshace, y el
  correo del tutor puede estar desactualizado o vacío. El adjunto es el
  MISMO PDF de "Imprimir" — `generarPdfRegistroImpresion()` y
  `generarPdfEstadoCuentaFactura()`/`generarTirillaFactura()` recibieron un
  `opciones.devolverBlob` en vez de tener un segundo generador que pudiera
  divergir del que se descarga. El desvío a tirilla se propaga: si la
  clínica imprime en rollo, el correo lleva la tirilla.
- **Mensajes al propietario**: de los 4 métodos, "Email" es el único con
  envío conectado. Los otros tres se siguen registrando como el canal por el
  que la clínica dice haber contactado al tutor, y el toast lo distingue en
  vez de decir "enviado" para todo.
- **Invitación de usuario** (`crearInvitacionParaRol`): ahora se MANDA,
  además de devolver el enlace. El enlace se sigue mostrando porque hace
  falta cuando el correo rebota.
- **Link público de autorregistro**: botón "Correo" junto a WhatsApp. Abre
  el mismo modal de envío en vez de un `mailto:` — así queda en la bandeja
  y se sabe si llegó, que es justo lo que un `mailto:` no permite.
- **`reenviarLinkFirma`** manda el documento y el aviso de que falta la
  firma, **no un enlace**: no existe una pantalla pública de firma (el tutor
  firma en el consultorio, ver el patrón de Documentos).

## PQRS — Peticiones, Quejas, Reclamos y Sugerencias
Canal de la clínica hacia el soporte de IRIS/MUVET. Vive en el **menú
desplegable del perfil** (header del app shell), entre "Perfil" y "Cerrar
sesión": `openPqrsModal()` → `#pqrs-modal` (tipo · asunto · descripción ·
nombre + correo del remitente, estos dos precargados de `currentSession`
pero editables — el correo es a donde soporte responde) → `enviarPqrs()`.
Tabla `pqrs` (migración `20260903_pqrs.sql`).

- **Se guarda la fila EN Supabase (bloqueante) Y ADEMÁS se manda el
  correo — las dos cosas, no una.** El subsistema de correo falla en
  silencio (dominio Resend sin verificar, API key ausente — ver la sección
  "Envío de correos"), así que una PQRS que solo viajara por correo se
  perdería sin dejar rastro. `enviarPqrs()` primero inserta en `pqrs`
  (mismo patrón que `guardarTareaPendiente`: si el insert falla, no se
  manda nada y el modal queda abierto), después llama a `enviarCorreoIris`,
  y al final escribe `pqrs.correo_estado` = `'enviado'` / `'fallido'` con
  un `update` no bloqueante (es solo un flag de diagnóstico).
- **El correo sale por el camino ÚNICO de la app**, no por un endpoint
  nuevo: `enviarCorreoIris({ tipo: 'pqrs', ... })` → `/api/enviar-correo`
  con la plantilla genérica (`titulo`/`intro`/`filas`/`cuerpo`). Lo único
  que hubo que tocar en el backend es sumar `'pqrs'` a `TIPOS_VALIDOS`.
- **El destinatario lo FIJA el servidor, no el navegador.** Para
  `tipo === 'pqrs'`, `api/enviar-correo.js` ignora `b.destinatarios` y usa
  `PQRS_EMAIL_DESTINO` (variable de entorno en Vercel; default en el código
  `soporteiris@appmuvet.com`). `enviarPqrs()` igual manda un destinatario
  de relleno (`enviarCorreoIris` exige al menos uno con `email`), que el
  servidor descarta. Si algún día se cambia el buzón de soporte, es esa
  variable — no hay nada más que tocar.
- **`referencia: { tabla: 'pqrs', id }`** enlaza la fila de `correos` con
  la PQRS que la originó, igual que el resto de disparadores.
- **No hay pantalla de listado/triage todavía**, y por eso `pqrs` NO se
  carga a memoria en `cargarDatosClinicaDesdeSupabase()`. Las columnas
  `estado` (`enviada`/`en_revision`/`resuelta`) y la policy
  `pqrs_update_member` existen para no tener que migrar la tabla cuando se
  agregue ese triage. Sin policy de `delete` a propósito: una PQRS enviada
  es historia (mismo criterio que `mensajes`).
- **RLS**: `pqrs` es contenido que genera el propio usuario para su
  clínica — `_insert_member` / `_select_member` / `_update_member` con
  `user_is_member_of`, a diferencia de `correos` (que solo escribe el
  backend con la Service Role key).
- `pqrs` **SÍ está en `RESPALDO_TABLAS`** y su `create table` sí está en
  `supabase/schema.sql` (a diferencia del hueco conocido de
  `formulas_medicas`/`ventas_facturas`). No entra al `c_tablas` de
  `fusionar_mascotas`: no tiene `mascota_id`.

## Agenda > Tareas + "Tipo de tarea" (Tareas Pendientes)
Quinta sub-vista de Agenda (`#agenda-view-tareas`,
`renderAgendaTareasTable()`) más un campo nuevo en el módulo de Tareas
Pendientes del Consultorio. Las tareas se seguían creando por paciente y
solo se veían abriendo la ficha de esa mascota: nadie tenía la lista de lo
que el equipo debe hacer hoy.

- **El módulo del Consultorio sigue siendo el DUEÑO de los datos.** Agenda
  no tiene array propio: `getTareasPendientesTodas()` recorre
  `patientData[petKey].tareasPendientes` al vuelo, y completar/reabrir llama
  a la MISMA `toggleEstadoTareaPendiente()` del módulo. Mismo criterio que
  Agenda > Eventos. Crear/editar/eliminar siguen viviendo solo en el
  Consultorio — desde acá se consulta y se completa, nada más.
- **`renderTareasPendientesTable(petKey)` ahora sale temprano si `petKey !==
  selectedPetKey`, y esa guarda no es opcional:** pinta el tbody y el
  contador del sidebar del paciente ABIERTO, y desde Agenda se completa la
  tarea de cualquier paciente. Sin la guarda, esa llamada pintaba los
  registros de otra mascota en la tabla del Consultorio.
- **Toda mutación de una tarea pasa por `refrescarAgendaTareasSi()`**
  (guardar/toggle/eliminar y el final de `cargarDatosClinicaDesdeSupabase()`):
  repinta la tabla si esa sub-vista está abierta y vuelve a sumar las tareas
  a los dos calendarios. Importante en el borrado: los `onclick` de la tabla
  y los ids de los eventos del calendario llevan el ÍNDICE del array
  (`tarea:<petKey>:<idx>`, misma convención que los `recordId` de
  `renderRowActionsMenu`), que se corre al hacer `splice`.
- **En el calendario una tarea es un evento de DÍA COMPLETO** en su fecha
  límite (`tareaPendienteToFcEvent()`, borde punteado, color por prioridad):
  no tiene hora ni duración, y meterla en la grilla horaria ocuparía
  visualmente un slot que sí está libre para agendar. Solo se pintan las SIN
  completar y con fecha límite. El `eventClick` de los dos calendarios pasó a
  `agendaFcEventClick()`, que separa por el prefijo `tarea:` del id — si
  agregás otra fuente de eventos al calendario, va por ahí.
- El interruptor "Mostrar tareas pendientes" (`agendaMostrarTareas`) es de
  PANTALLA, no persiste nada, y gobierna los dos calendarios **y** la lista
  de la Agenda personal. La Agenda personal filtra por `responsableId` de la
  tarea, igual que filtra los eventos por `encargadoId`; con
  `getCurrentSimUserId()` en null no se pinta ninguna (`null` significa
  "todas" en `getTareasPendientesCalendario`, y ahí eso sería mostrarle a
  cada quien las del equipo entero).
- **"Completar/Reabrir" no se gatea por rol a propósito**: es la misma acción
  extra que el menú "..." del módulo ya ofrece a todos los roles que ven el
  Consultorio, y el Auxiliar —que ejecuta la mayoría de estas tareas— entra a
  Agenda (`TAB_ROLE_RESTRICTIONS`). El atajo a la mascota sí usa
  `rolPuedeVerTab('consultorio')`, como en Eventos.
- **`TAREA_TIPOS` es un catálogo FIJO** (Enviar documentos / Agendar cita con
  especialista / Agendar ecografía / Agendar rayos X / …), no uno ampliable
  con "+ Registrar" como Vacunas o Desparasitaciones: lo que le da valor es
  poder filtrar por él acá, y un catálogo libre por clínica haría que el
  filtro dejara de ser comparable. Lo que no encaje va en `otro` y se detalla
  en la descripción. El campo es OPCIONAL y la columna
  `tareas_pendientes.tipo` (migración `20260902c_tareas_pendientes_tipo.sql`)
  es nullable y sin `check`: las tareas anteriores traen null y se muestran
  "Sin tipo" (`tareaTipoChipHTML()`), que además es una opción propia del
  filtro. Agregar un tipo nuevo es agregar una entrada a esa constante —
  ninguna migración.

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
Documentos (formatos propios de la clínica + firma en pantalla, ver el
patrón del módulo más abajo), Admin — Usuarios (Vista A,
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
`switchAgendaView()`) en 5 vistas: **Agenda general** (la vista
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
vincula el ítem al evento creado) y **Tareas** (las Tareas Pendientes de
TODOS los pacientes — ver su propia sección más abajo).
`guardarEventoAgenda()` también
calcula `recordatorio24hISO` (mock, Tarea 3) y abre `#agenda-notif-modal`
listando destinatarios simulados (tutor/clínica/médico) — sin envío
real.

**Fila de Agenda > Eventos — tres atajos, ninguno con datos propios.**
El registro solo guarda el NOMBRE del propietario (string) y el
`petKey`; todo lo demás se resuelve al vuelo, no lo dupliques en
`EVENTOS_SEGUIMIENTO`:
- **Propietario** es el disparador de un popover de contacto
  (`toggleEventoOwnerPopover()`, documento/móvil/teléfono alterno/
  email/dirección con `copyIconHTML()` por dato + "Copiar todo" +
  "Perfil"). Es el MISMO componente `.owner-popover` del header de
  Historia, con una diferencia que importa: allá hay un único nodo fijo
  (`#pet-owner-popover`, hay un paciente activo) y acá hay uno por fila,
  así que el contenido se pinta al abrirlo y el estado abierto vive en
  `eventoOwnerPopoverAbiertoId`. `renderEventosSeguimientoTable()` llama
  a `closeEventoOwnerPopovers()` al empezar porque el repintado destruye
  los nodos abiertos. La ficha del tutor sale de
  `getPropietarioDeEventoSeguimiento()`: por la mascota (FK) y, si el
  evento no tiene `petKey` resoluble, por nombre — mismo respaldo que
  `getPropietarioDeMascota()`.
- **Mascota** lleva al Consultorio (`abrirPacienteDesdeEventos()`). El
  gate de rol es `rolPuedeVerTab('consultorio')`, extraído de
  `applyTabRoleVisibility()` para no replicar la condición: **cualquier
  atajo nuevo que salte de un tab a otro debe usarlo**, no leer
  `TAB_ROLE_RESTRICTIONS` a mano. Hoy Consultorio no tiene entrada en
  ese mapa (todos los roles entran), así que el helper es lo único que
  hará falta tocar el día que la tenga. Se chequea además
  `bloqueadoPorTutorSinVincular()` ANTES del salto de tab (`selectPet()`
  lo vuelve a chequear después) para no dejar al usuario en el buscador
  del Consultorio con el modal de vinculación encima.
- **Enviar mensaje** reusa `openMensajeModal(petKey)` tal cual (ya
  recibe `petKey` justamente para abrirse fuera del Consultorio) y
  precarga un texto de recordatorio. Se pinta solo si el rol está en
  `SUBTAB_ROLE_RESTRICTIONS.mensajes` y la mascota existe en
  `patientData` — `openMensajeModal()` no tiene guard propio y revienta
  con un `petKey` muerto. Si había un borrador sin guardar del modal, el
  sistema de borradores lo restaura ENCIMA del texto sugerido y avisa;
  es el comportamiento correcto, no un bug.

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
devolvería en UTC con offset, rompiendo FullCalendar y el formateo.

**`EVENTOS_SEGUIMIENTO` también persiste** (tabla `eventos_seguimiento`,
migración `20260805_eventos_seguimiento.sql`), con el mismo patrón:
`crearEventoSeguimiento()` es `async` y hace insert BLOQUEANTE antes de
tocar el array, el id del registro es el uuid del insert (ya no existe
`eventosSeguimientoSeq` ni ids `evs-N` — sobreviven solo como semilla
demo), `guardarEventoAgenda()` persiste el paso a `agendado` +
`agenda_evento_id` de la misma forma, y
`cargarDatosClinicaDesdeSupabase()` reconstruye el array. Dos matices
propios de este módulo:
- **`crearEventoSeguimiento()` no relanza el error.** Sus 4 llamadores
  (`guardarVacunacion`/`guardarDesparasitacion`/`guardarPeluqueria`/
  `guardarSeguimiento`) ya guardaron su propio registro cuando llegan
  ahí, dentro del mismo `try`: si el recordatorio relanzara, el `catch`
  del llamador diría "no se pudo guardar la vacunación" sobre una
  vacunación que sí se guardó. El recordatorio es un derivado — si
  falla, avisa con su propio toast y el registro principal queda
  intacto. Mismo criterio en el bloque de "Agendar" de
  `guardarEventoAgenda()`.
- **La semilla demo se inserta con `agenda_evento_id` siempre en null**
  aunque `evs-6` traiga `'ag-1'`: ese id es del mock y la columna es un
  uuid con FK a `agenda_eventos`. Solo se conserva su `estado`
  (`'agendado'`), que es lo único que la UI lee — `agendaEventoId` hoy
  se escribe pero no se lee en ninguna parte.

De Agenda solo queda mock `DISPONIBILIDAD_MEDICOS`.

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

**Cierre de día (arqueo) — la caja no arranca en cero y el contado se
digita UNA vez por método de pago.** Dos invariantes del módulo
(`VENTAS_ARQUEOS` / tabla `arqueos`):
- La primera tabla (Tipo + Forma de pago) es SOLO informativa. El
  arqueo se digita en la segunda ("Total por método de pago"), un input
  por método en la columna Total contado — `cierreCajaState.filas` ya
  no lleva `contado`, eso vive en `contadoPorMetodo` (mapa metodoPago →
  neto contado, **puede ser negativo** si ese método tuvo más egresos
  que ingresos). `contadoPorMetodoDeArqueo()` reconstruye ese mapa
  desde el `contado` por fila de los arqueos viejos, así que no borres
  esa función mientras queden registros previos a la migración
  `20260727_arqueos_base_caja.sql` (las columnas nuevas son nullable a
  propósito: null = arqueo de la era anterior, no se hizo backfill).
- La base de caja es DERIVADA, no digitada: sale del
  `saldoFinalEfectivo` del arqueo inmediatamente anterior
  (`baseCajaDesdeCierreAnterior()`). `resolverBaseCierreCaja()` decide
  entre los 3 casos y no hay otro camino: **congelada** (el día ya está
  Cerrado → se conserva la base con la que se cerró, porque un cierre
  firmado no puede cambiar de números y porque los arqueos previos a
  esta función no tienen base y re-derivarlos les inventaría
  diferencias que nunca existieron), **heredada** (se recalcula cada
  vez que se abre la pantalla, para que corregir el día de ayer dentro
  de la ventana de 24h arrastre el de hoy) y **manual** (no hay ningún
  cierre anterior — primer día de uso; único caso en que el input de
  base se habilita). Solo aplica a **Efectivo**:
  tarjeta/transferencia/débito no se guardan en el cajón, su contado es
  el neto que reporta el banco o el datáfono ese día. Por eso el total
  de sistema del efectivo es `base + ingresos − egresos` y es contra
  ese número que se compara lo contado.
- Al editar el "Total contado" NO se repinta la tabla de métodos
  (`actualizarContadoMetodoCierreCaja` actualiza las celdas en sitio):
  el input está dentro de esa misma tabla y un `innerHTML` por tecla le
  quitaría el foco al usuario a mitad del número. La de base sí puede
  repintarla porque su input vive fuera.

El botón **"Registrar propietario"** del buscador de Consultorio está
también en el header del pane de Agenda (`#btn-registrar-propietario-agenda`),
reusando el mismo `openRegistrarPropietarioModal()` — va en el header
del pane, no en el toolbar de una sub-vista, para verse en las 5 vistas.
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
entrada en ese nav acotado durante una consulta activa; si se
necesita volver a él desde ahí, es vía "Ver órdenes completo" saliendo
del Tablero, no hay atajo directo. **`TABLERO_NAV_ORDEN` se acotó
después, a pedido de negocio, de 10 módulos a solo 6**: Vacunaciones/
Desparasitaciones/Fórmulas médicas/Exámenes de laboratorio/Imágenes
diagnósticas/Documentos — Cirugías/Seguimientos/Tareas Pendientes/
Remisiones/Citas ya NO tienen chip en el strip del Tablero. Sus
entradas en `TABLERO_QUICKNAV_MODULOS` NO se borraron a propósito:
`refrescarTableroQuicknavSi()` las sigue referenciando por key desde
`guardarCirugia()`/`guardarSeguimiento()`/`toggleEstadoTareaPendiente()`/
`guardarRemision()`/el guardado de eventos de Agenda — borrar esas
entradas rompería esas funciones (llaman a `cfg.getRecords(...)` sin
guard) aunque el chip ya no exista. Si se vuelve a ampliar el strip,
solo hace falta agregar la key de vuelta a `TABLERO_NAV_ORDEN`, la
config ya está completa.

**El panel "Navegación rápida" NO tiene botón "Ver … completo"** — se
quitó a pedido de negocio junto con `abrirModuloCompletoDesdeTablero()`
y el campo `subtabKey` de la entrada `documentos`, que existía solo
para armar ese botón (era el único módulo del strip cuyo `key` no
coincide con su `data-subtab` real, `patient-documentos`). Desde el
Tablero se consulta y se registra; para gestionar el módulo entero se
sale con "Volver". No lo reintroduzcas — y si alguna vez hace falta,
acordate de que `documentos` necesita su propio mapeo key → subtab.
A cambio, cada módulo puede definir un callback **`extra`** en
`TABLERO_QUICKNAV_MODULOS`: una tercera línea por registro con el dato
concreto que hay que poder leer sin abrirlo (Producto en
Desparasitaciones, Diagnóstico en Fórmulas médicas, y los nombres de
las pruebas/imágenes en Exámenes de laboratorio/Imágenes diagnósticas
vía `examenPruebasNombresResumen()`, que toma el rótulo de
`getExamenCampoLabel()` en vez de duplicar el string por tipo). Es
opcional: Vacunaciones no lo trae a propósito porque su título ya ES la
vacuna, y un módulo sin `extra` renderiza igual que antes. La línea es
de UNA sola línea con elipsis y el texto completo en el `title=`, mismo
criterio que la banda de contexto del hero. Relacionado: el título de
Fórmulas médicas pasó a ser la lista de medicamentos recetados (que es
de lo que trata una fórmula) y el diagnóstico bajó a esa línea de
detalle — antes el diagnóstico era el título y los medicamentos no se
veían en absoluto.

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
válido tras recargar. `seguimientos.adjuntos` (jsonb) SÍ sube el
archivo real al bucket `pdfs` (compartido con Exámenes/Imágenes
diagnósticas) — `{path, nombre}` por elemento, mismo criterio de 2
pasos que `guardarExamen()`: primero un insert sin archivos nuevos
para tener el `id` del seguimiento (necesario para la ruta
`clinica/<establecimiento_id>/seguimientos/<id>/...`), después se
suben los archivos y recién ahí un `update()` con `adjuntos` final.
`seguimientoAdjuntosExistentes`/`seguimientoAdjuntosNuevos`/
`seguimientoAdjuntosAEliminar` (form modal) son el mismo patrón de 3
variables que `examenPendingFiles`/`examenExistingFiles`/
`examenArchivosAEliminar` — cancelar el modal no borra nada, el
`remove()` del bucket corre recién tras un guardado exitoso. "Ver"
pinta cada adjunto como link real (`descargarSeguimientoAdjunto()`,
URL firmada de 1h) vía `seguimientoAdjuntosLinksHTML()`, y
`eliminarSeguimientoReal()` también borra los archivos del bucket.
Registros de antes de esta migración solo tienen `{nombre}` (sin
`path`, nunca se subieron) — se siguen leyendo y mostrando, pero sin
link, con un `title` que lo aclara. Antes de esto no había ninguna
validación sobre `#seg-fecha` (`<input type="datetime-local">`) y un
quirk de Chrome/Edge (tipear rápido en el selector de año) llegó a
guardar un año de 6 dígitos en producción; `seguimientoFechaEsValida()`
bloquea el guardado si el valor no matchea el formato esperado o el
año es irreal — cualquier otro campo `datetime-local` de este archivo
sin validación tiene el mismo riesgo latente.
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

**Exámenes de laboratorio / Imágenes diagnósticas — VARIOS archivos por
bloque.** Cada bloque de `examenes.pruebas` (jsonb) guarda sus adjuntos en
`archivos: [{path, nombre}]`, no en un solo archivo: un estudio de imagen
son varias placas más el informe en PDF, y ese era el límite real del
módulo. Detalles que hay que respetar:
- **Los adjuntos se leen SIEMPRE por `examenPruebaArchivos(prueba)`.** Los
  registros anteriores a esto guardaban un único archivo en
  `resultadoPath`/`resultadoNombre`; ese formato se sigue leyendo ahí y
  **solo ahí** (no hubo backfill ni cambio de schema — la columna ya era
  jsonb). Esos dos campos ya no se escriben: no los reintroduzcas ni
  agregues una segunda forma de leer lo mismo.
- Los archivos elegidos se **acumulan** (`examenPendingFiles[uid]` es un
  array): seleccionar de a tandas es el caso normal y un `input
  type="file"` solo reporta la última selección, por eso
  `handleExamenResultadoFileChange()` limpia el `value` del input — sin
  eso, volver a elegir un archivo que se acaba de quitar no dispara el
  `change`.
- **Quitar un archivo no lo borra del bucket en el momento**: su path se
  encola en `examenArchivosAEliminar` y el `remove()` corre recién después
  del update exitoso en `guardarExamen()`. Cancelar el modal no debe
  borrar nada, y si el guardado falla la fila sigue apuntando a él. Ese
  borrado no relanza el error (dejar un archivo huérfano no invalida el
  registro). `removeExamenBlock()` encola los archivos del bloque por el
  mismo motivo.

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

**Órdenes (tab general de Consultorio) SÍ persiste en Supabase** (tabla
`ordenes`, migración `20260813_ordenes_persistencia.sql`) — mismo
criterio que el resto: `guardarOrdenes()` es `async` y hace insert/update
BLOQUEANTE antes de tocar `patientData[petKey].ordenes` (si falla la
escritura remota no se aplica el cambio local), `eliminarOrdenReal()`
borra de forma optimista, y `cargarDatosClinicaDesdeSupabase()`
reconstruye el array (`construirOrdenDesdeFila()`) al iniciar sesión.
Antes vivía solo en memoria y se perdía al refrescar la página o volver
a iniciar sesión. Detalles propios de este módulo:
- **`tipo`/`prioridad` se guardan como el código crudo**, no la etiqueta
  ni el color ya resueltos (`tipoLabel`/`prioridadLabel`/
  `prioridadColor`): esos se recalculan en `construirOrdenDesdeFila()` a
  partir de `TIPOS_ORDEN`/`PRIORIDADES_ORDEN`, igual que
  `guardarOrdenes()` ya los calculaba al crear. No se agregan columnas
  para el dato derivado.
- **Un solo modal puede crear VARIAS órdenes a la vez** (un bloque por
  cada "+ Agregar orden"): el insert es un solo `.insert([...]).select()`
  con todas las filas, y los ids reales que devuelve se reasignan de
  vuelta a cada registro en memoria en el mismo orden — sin eso, una
  orden creada en esta sesión no tendría `id` y ni editarla ni borrarla
  (ni el flujo de Resultados, ver abajo) podrían alcanzar la fila real.
- **`resultados` (la sub-tabla de Resultados vinculados a una orden de
  Imagen diagnóstica/Prueba-Examen) SIGUE siendo 100% mock** — fuera del
  alcance de esta migración, a propósito. Pero `ordenes.estado`
  (`pendiente`/`completado`) SÍ es una columna real, así que las dos
  transiciones que ese mock dispara sobre la orden padre —finalizar un
  resultado y eliminar un resultado ya finalizado— tienen que persistir
  ese campo aunque el resultado en sí no se guarde: `guardarResultado()`
  llama a `persistirEstadoOrden(orden, 'completado')` y el borrado del
  resultado (menú "..." → `rowActionEliminarConfirmado`, moduleKey
  `'resultado'`) llama a `persistirEstadoOrden(orden, 'pendiente')` al
  revertir. Sin esto, el estado de la orden volvería a `pendiente` en la
  próxima recarga aunque el resultado (mock, ya perdido de todas formas)
  la mostrara como completada — o peor, un `completado` local se perdería
  dentro de la misma sesión si algo más disparaba una recarga completa
  de `patientData`.
- Sin entrada de `data.timeline`: `guardarOrdenes()` nunca escribió ahí
  (solo el resultado, aún mock, lo hace al finalizar) — mismo criterio
  se mantiene en `cargarDatosClinicaDesdeSupabase()`.
- La migración también corrigió `fusionar_mascotas` (sumó `'ordenes'` a
  `c_tablas`) y de paso sincronizó `supabase/schema.sql`, que ya estaba
  desactualizado respecto a la función LIVE (le faltaban
  `anestesia_mediciones`/`mascota_problemas` en el array y el bloque de
  renumeración de `mascota_problemas`) — mismo hueco documentado en
  RESPALDOS para `formulas_medicas`/`ventas_facturas`/
  `ventas_cotizaciones`, aplicado sin querer también acá.

**Documentos — formatos propios de la clínica y proceso de firma.**
La tabla `documentos` ya persistía, pero el módulo tenía tres huecos que
lo dejaban a medio funcionar; los tres ya están cerrados y conviene no
reabrirlos:

- **Formatos (plantillas).** Los 3 de fábrica siguen en
  `PLANTILLAS_DOCUMENTOS_BASE` (constante de la app, existen en TODA
  clínica); los que crea cada clínica viven en la tabla
  `documento_plantillas` y se cargan a `plantillasDocumentosCustom` en
  `cargarDatosClinicaDesdeSupabase()`. La lista que consume la UI es
  SIEMPRE `getPlantillasDocumentos()` (concatena las dos), mismo criterio
  que `VACUNAS_CATALOGO_BASE` + `catalogos_custom`. El link
  "+ Crear nuevo formato" ya no es un toast: abre
  `#formato-documento-modal` (superpuesto al modal de documento con
  `z-index:320`, mismo patrón que la calculadora de dosis sobre el modal
  de fórmula) precargado con lo que el usuario ya escribió en el
  documento — el caso normal es "redacté esto y lo quiero reutilizar".
  Ese modal también edita y borra los formatos propios; los de fábrica se
  listan como referencia y NO se editan. **Ojo con
  `resetMockDataForClinic()`:** antes vaciaba `PLANTILLAS_DOCUMENTOS`, lo
  que dejaba a cualquier clínica que no fuera la demo sin una sola
  plantilla — ya no toca nada de esto, y no hay que volver a agregarlo.
  Borrar un formato no afecta a los documentos ya creados con él (cada
  documento guarda su propio `contenido_html` y el nombre del formato como
  texto en `tipo`; no hay FK a propósito).
- **Firma.** El estado `firmado` existía en el schema pero era
  inalcanzable: nada lo escribía. Ahora el tutor firma en pantalla sobre
  un `<canvas>` (`#firma-documento-modal`, pointer events, sirve con mouse
  o dedo) y `confirmarFirmaDocumento()` escribe estado + `firma_nombre`/
  `firma_documento`/`firma_fecha`/`firma_hora`/`firma_imagen`. "Enviar
  para firmar" (estado `pendiente`) es un paso distinto y OPCIONAL — se
  puede firmar directo desde un borrador.
  - `firma_imagen` guarda el trazo como **PNG en data URL dentro de la
    fila**, no en Storage. Es deliberado: `firmaCanvasDataUrl()` recorta
    el canvas al rectángulo dibujado antes de exportarlo (unos pocos KB) y
    tenerlo embebido es lo que permite pintar la firma en el modal "Ver",
    en el PDF de "Imprimir" y en el PDF que se sube al bucket `pdfs` sin
    URLs firmadas que expiran ni problemas de CORS con html2canvas. No lo
    muevas a Storage "por consistencia" con los adjuntos: esos son
    archivos que sube el usuario, esto es un trazo generado en la app.
  - **Un documento firmado no se edita.** `rowActionEditar` lo bloquea,
    `renderDocumentosTable()` ni siquiera pinta "Editar" en su menú y
    `guardarDocumento()` tiene un guard extra por si se llega por otra
    vía — si el contenido pudiera cambiar después, la firma respaldaría un
    texto que el tutor nunca vio. La salida es "Anular firma"
    (`anularFirmaDocumento()`), que devuelve el documento a borrador y
    borra el rastro de la firma; ahí vuelve a ser editable.
  - Firmar/anular no crea entradas nuevas en el timeline: ACTUALIZA el
    `summary` de la entrada que ya existe (buscada por `dbId`), igual que
    hace la edición del documento. Mismo criterio de "no duplicar eventos
    de historia" de Vacunaciones/Desparasitaciones.
  - Firmar y anular son acciones de gestión: solo aparecen si
    `getRowActionsForRole()` incluye `editar`. Las `extraActions` de
    `renderRowActionsMenu()` NO se filtran por rol solas — si agregas una
    acción extra que modifica datos, gátéala igual.
- **Eliminar.** Antes solo hacía `splice()` en memoria, así que el
  documento reaparecía al recargar. `eliminarDocumentoReal()` borra la
  fila, el PDF del bucket y la entrada de timeline, mismo patrón que
  `eliminarMensajeReal()` y compañía.

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

**Tener la ficha ≠ poder abrirla — `propietarios.red_vinculado`.** Una
clínica puede terminar con la fila de un tutor sin haberlo verificado
nunca (botón "Registrar como nuevo de todas formas", importación de
clientes por CSV). Esa fila nace con `red_vinculado = false` y NO da
acceso a nada: se ve en el buscador con la etiqueta "Sin vincular" y un
botón "Vincular" en la columna de acciones — hay que poder reclamarla —
pero el nombre no es clickeable, los chips de mascota no llevan al
Consultorio y perfil/facturación/editar/registrar mascota están
cerrados. Detalles:
- Lo decide el trigger `red_trg_publicar_propietario` en el `insert`, no
  el front: nace en `false` SOLO si esa `red_persona_id` ya existe en
  otro establecimiento. Tutor nuevo en la red, o sin cédula, nace
  utilizable. Así queda cubierta toda vía de inserción presente y
  futura sin replicar la regla en cada una.
- El único camino que lo pone en `true` después es
  `red_vincular_con_token()`, que además de crear la ficha desbloquea
  la que ya estuviera bloqueada en esa clínica. Por PostgREST no se
  puede: la policy `propietarios_update_member` exige
  `red_vinculado`, y `mascotas_insert_member`/`_update_member` exigen
  `propietario_vinculado(propietario_id)` — el bloqueo no vive solo en
  index.html. La historia clínica cuelga de `mascotas`, así que sin
  poder crear mascota tampoco se le cuelga nada.
- En el front el guard único es `bloqueadoPorFaltaDeVinculacion(id,
  accion)` (y `bloqueadoPorTutorSinVincular(petKey, accion)` entrando
  por la mascota): devuelve `true` si hay que ABORTAR, ya avisó y ya
  abrió el modal de vinculación. Cualquier punto de entrada nuevo a la
  ficha de un tutor debe llamarlo — no repliques el chequeo a mano.
- El backfill dejó en `true` TODO lo preexistente a propósito (ver el
  comentario en `supabase/schema.sql`): en producción 80 de los 95
  tutores de la clínica real comparten identidad con la de pruebas
  porque ambas importaron la misma lista por CSV antes de que la red
  existiera, y una regla retroactiva las habría bloqueado casi todas.
  La regla aplica solo hacia adelante.
- `redDetectarCoincidencia()` ya NO es fail-open: devuelve
  `{estado: 'sin-coincidencia' | 'coincide' | 'indisponible'}` y
  `guardarPropietario()` BLOQUEA el registro ante `indisponible` (rate
  limit de 60 búsquedas/hora, error de red). Antes los tres casos
  devolvían `null` y un error de red creaba el tutor sin vincular —
  justo lo que la detección debía tapar.
- El buscador de Consultorio consulta la red cuando no encuentra nada
  localmente y el término tiene ≥6 dígitos (`programarBusquedaEnRed`):
  espera 900 ms sin tecleo y cachea por término, porque
  `red_buscar_persona` está limitada a 60 búsquedas/hora por usuario y
  dispararla en cada tecla quemaba el cupo al instante. Solo se cachea
  una respuesta real — si la red no contestó, el siguiente intento
  puede volver a preguntar.

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
   Descarga un `.json` con las filas reales de las 35 tablas por
   establecimiento (`RESPALDO_TABLAS`), no el modelo en memoria: el
   objetivo es poder volver a insertar. Si agregas una tabla nueva por
   establecimiento, **agrégala a `RESPALDO_TABLAS`** o el respaldo
   manual la omite en silencio (el automático no necesita cambios,
   vuelca el schema entero). `establecimientos` es la única entrada de esa
   lista que `respaldoLeerTablaCompleta()` filtra por `id` en vez de por
   `establecimiento_id` — su propia PK ES el establecimiento; entró cuando
   la fila pasó a cargar toda la configuración de la clínica (ver
   "Configuración de la veterinaria"). No incluye los archivos binarios, solo el
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
