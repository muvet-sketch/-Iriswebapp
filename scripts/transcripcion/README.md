# Transcripción de audios de consulta

Flujo **audio → transcripción → LLM → formulario IRIS**, automático de punta a
punta: el veterinario pulsa **Grabar audio** en el Tablero de trabajo y, cuando
el borrador está listo, el mismo botón se lo avisa. Nadie copia archivos a mano.

- **Paso 0 — `puente_iris.py`**: baja los audios que graba la app a la carpeta
  vigilada (que está sincronizada con Drive, así que quedan también en
  **Audios Consultas** de Drive) y, al final del recorrido, devuelve el SOIP a
  la app. Es el único que habla con Supabase.
- **Paso 1 — `vigilante.py`**: vigila esa carpeta, y cada audio que aparece lo
  limpia, lo transcribe con Whisper y deja un `.txt` y un `.json`.
- **Paso 2 — `extraer_soip.py`**: lee esos `.json` y produce el SOIP estructurado
  (motivo, S/O/I/P, 7 signos vitales, hallazgos por sistema) listo para el
  formulario.
- **`vocabulario_clinico.py`**: vocabulario del dominio compartido por los dos
  pasos (ver sección abajo).

Los pasos 1 y 2 no saben nada de la app y siguen funcionando igual con un audio
dejado a mano en la carpeta.

## Uso

Hacen falta **las dos ventanas** abiertas en el PC de la oficina:

```bat
iniciar_vigilante.bat
iniciar_puente.bat
```

O desde la terminal:

```bash
python vigilante.py                  # vigila para siempre
python vigilante.py --una-vez        # procesa lo pendiente y sale
python vigilante.py --modelo small   # más rápido, menos preciso
python vigilante.py --sin-limpiar    # sin limpieza de audio (para comparar)
```

El modelo por defecto **no es fijo**: usa la GPU NVIDIA si el equipo tiene una
(ver "Mediciones" abajo). Para forzarlo, `IRIS_WHISPER_DEVICE=cpu` o
`IRIS_WHISPER_MODEL=medium`.

Paso 2 (requiere `ANTHROPIC_API_KEY` en el entorno):

```bash
python extraer_soip.py               # procesa las transcripciones pendientes
python extraer_soip.py --rehacer     # reprocesa todo
```

## Carpetas

```
Audios Consultas\          <- acá aterrizan los audios (sincronizada con Drive)
  Procesados\              <- audio ya transcrito (se mueve solo)
  Transcripciones\         <- .txt y .json del paso 1
  Consultas\               <- SOIP estructurado del paso 2
  Fallidos\                <- audios que reventaron, para revisar a mano
  _estado.json             <- registro de lo procesado por vigilante (no borrar)
  _puente.json             <- registro de lo publicado por el puente (no borrar)
  _vigilante.log           <- historial
  _puente.log              <- historial
```

La ruta se cambia con la variable de entorno `IRIS_AUDIO_DIR`.

## Paso 0 — el puente con la app (`puente_iris.py`)

```bash
python puente_iris.py                # ciclo continuo (cada 20 s)
python puente_iris.py --una-vez      # una pasada y sale
python puente_iris.py --sin-extraer  # no llama al LLM; solo mueve archivos
```

Necesita dos variables de entorno: `IRIS_SUPABASE_SERVICE_KEY` (la
*service_role* key del proyecto) y la `ANTHROPIC_API_KEY` que ya usaba el paso
2. La service key **salta las policies RLS** — es la única forma de que este
equipo lea audios de cualquier usuario de la clínica. Va en una variable de
entorno del PC, nunca en el repo, que es público.

Cada vuelta hace tres cosas:

1. Busca filas de `consultas_audio` en estado `subido`, baja el audio del bucket
   `audios-consultas` a la carpeta vigilada y pasa la fila a `transcribiendo`.
   Después borra la copia del bucket: **es solo transporte**, la copia que se
   guarda es la de Drive.
2. Extrae el SOIP de las transcripciones nuevas llamando a
   `extraer_soip.procesar_archivo()`.
3. Sube el `.json` de `Consultas\` a la fila (`resultado`, estado `listo`), que
   es lo que el navegador está esperando.

Tres decisiones que conviene no deshacer:

- **El id de la consulta viaja dentro del NOMBRE del archivo**
  (`IRIS-<uuid>__2026-08-08_canela-gomez.webm`). Es lo que permite volver a
  asociar el `.json` final con la consulta que lo pidió, y funciona porque
  `vigilante.py` y `extraer_soip.py` conservan el *stem* a lo largo de todo el
  recorrido. Gracias a eso ninguno de los dos necesitó cambios. Si algún día uno
  renombra los archivos, este puente se rompe en silencio.
- **Solo toca lo que empieza con `IRIS-`.** Un audio dejado a mano en la carpeta
  se sigue transcribiendo como siempre, pero el puente no le extrae el SOIP: esa
  extracción cuesta una llamada a la API por archivo y nadie la pidió.
- **Escribe en `.part` y renombra.** `vigilante.py` escucha `on_moved` justamente
  porque así aparecen los archivos que baja Drive; además evita que llegue a ver
  un archivo a medio escribir.

El audio que graba el navegador es **Opus mono a 32 kbps** dentro de WebM
(Safari da `.m4a`). Una consulta de 40 minutos pesa menos de 10 MB — el bucket
corta en 50 MB, que son unas 3,5 horas.

## Paso 2 — extracción del SOIP

Usa `claude-opus-5` con salidas estructuradas (`messages.parse` + un esquema
Pydantic), de modo que la respuesta siempre valida contra los campos reales del
formulario. Las claves de `campos` en el JSON de salida son los ids del Tablero
sin el prefijo `tablero-soap-`, que es el contrato con `guardarConsulta()` en
`index.html`.

**Un signo vital inventado sería un dato clínico falso en la historia de un
paciente real.** Por eso no basta con pedirle al modelo que no invente:

1. El prompt obliga a dejar en `null` cualquier vital que no se diga en el audio.
2. Cada vital con valor debe traer la **cita textual** de la transcripción.
3. `depurar_vitales()` **verifica que esa cita exista de verdad** en la
   transcripción (comparación normalizada, sin acentos ni puntuación). Si no
   aparece, el valor se descarta y queda en `null`.

El paso 3 es real, no decorativo. En la prueba del guard, sobre una transcripción
que decía *"buen llenado capilar"*, un TLLC citado como *"buen llenado capilar de
menos de 2 segundos"* fue descartado: suena plausible, pero nadie lo dijo. Lo
mismo con los sistemas del examen físico — se descarta cualquiera cuyo nombre o
estado no esté en el catálogo de `EXAM_SYSTEMS`.

Un vital en `null` llega al formulario como campo vacío, que es exactamente lo
que el CLAUDE.md exige para "no evaluado": no se registra en ninguna parte.

Todo lo que sale de acá es un **borrador para que el veterinario revise y firme**,
nunca un registro que se guarde solo. `revision_requerida` y `notas_revision`
marcan lo que quedó dudoso.

## Vocabulario clínico (`vocabulario_clinico.py`)

La transcripción automática no reconoce nombres de fármacos ni tecnicismos que
no están en su vocabulario ("meloxicam" → "melo si can", "Traumeel" → "trau
mil"). El módulo concentra ese vocabulario — ~580 fármacos del índice del
*Manual Farmacológico Veterinario* (Plumb, ed. español; extraído por OCR y
**corregido a mano**, no "recorregir" nombres que se vean raros sin verificar
contra el manual), los homeopáticos Heel que usa la clínica, y los
diagnósticos/patógenos/términos del informe de enfermedades tropicales de
Colombia — y lo sirve en dos formatos:

1. **`PROMPT_WHISPER`** (paso 1): Whisper solo usa los **últimos ~224 tokens**
   del `initial_prompt` — si es más largo descarta el *principio*, por eso es
   una selección corta con lo más difícil de reconocer (los Heel) al final.
   Está medido con el tokenizer real del modelo `medium` (216/223 tokens): si
   se agrega algo, hay que volver a medir.
2. **`glosario_para_llm()`** (paso 2): el glosario completo va en el prompt de
   `extraer_soip.py` con la regla 8 — el modelo puede **corregir** una palabra
   mal transcrita solo si es fonéticamente cercana a un término del glosario y
   el contexto coincide, y cada corrección queda auditada en
   `terminos_normalizados` (`"lo que se oyó -> término correcto"`) en el JSON
   de salida. Con duda entre dos términos no corrige: marca
   `revision_requerida`. El glosario **nunca** agrega menciones que no están
   en el audio, y las citas de los vitales siguen siendo literales.

Probado sobre una transcripción sintética con errores reales de Whisper:
`melo si can → meloxicam`, `doxidiclina → Doxiciclina`, `trau mil → Traumeel`,
`engistol → Engystol`, y `reliquiosis → Ehrlichiosis` quedó además marcada
para revisión por ser inferencia de contexto ("por la garrapata").

Para sumar vocabulario nuevo (un producto que la clínica empiece a usar, una
marca local): agregarlo a la lista que corresponda del módulo; solo si además
se oye muy seguido en los audios, sumarlo también al final de
`PROMPT_WHISPER` y volver a medir los tokens.

## Mediciones — el modelo por defecto depende del equipo

El script elige solo: **`large-v3` si hay GPU NVIDIA, `medium` si no**
(`IRIS_WHISPER_MODEL` lo fuerza, `IRIS_WHISPER_DEVICE=cpu` desactiva la GPU).

### Equipo sin GPU — Ryzen 5 3500U, 8 hilos, 10 GB RAM

| Configuración | Velocidad | Consulta de 38 min | Calidad |
|---|---|---|---|
| openai-whisper `small`, audio crudo | 0,28× | ~2,2 h | inservible |
| faster-whisper `large-v3-turbo` | 0,19× | ~3,3 h | no mejor que medium |
| faster-whisper `small` | 1,88× | ~20 min | aceptable |
| **faster-whisper `medium`** | **0,94×** | **~40 min** | **elegida sin GPU** |

`medium` se eligió por precisión, no por velocidad. En la misma frase:

- `small` → "hace 30 días no soy contento de **los primeros dos segundos**"
- `medium` → "hace 30 días usted contó que son **los primeros síntomas**"

### Equipo con GPU — i5-9300H, 8 GB RAM, GTX 1050 (3 GB VRAM)

Todo en `int8`, sobre el mismo audio real de 18 min:

| Configuración | Velocidad | Consulta de 38 min | VRAM |
|---|---|---|---|
| `medium` en CPU | 0,68× | ~56 min | — |
| `medium` en GPU, `float32` | 0,91× | ~42 min | 2,9 GB |
| **`large-v3` en GPU, beam 1** | **6,10×** | **~6 min** | **2,0 GB** |
| `large-v3-turbo` en GPU, beam 5 | 8,23× | ~5 min | 1,1 GB |

Dos cosas que sorprenden y conviene no "corregir":

- **La CPU de este equipo es más lenta que la del otro** (0,68× contra 0,94×)
  pese a ser un procesador mejor: tiene 8 GB de RAM y muy poca libre. La ganancia
  acá viene de la GPU, no del procesador.
- **En GPU el límite es la VRAM, y quien decide es el ancho del beam.** Con
  `beam_size=5` `large-v3` se queda sin memoria; con `beam_size=1` corre a 6,1×.
  Por eso `BEAM_SIZE_GPU` es 1 y `BEAM_SIZE_CPU` sigue siendo 5. Un OOM aparece
  al *recorrer* los segmentos, no al llamar a `transcribe()`, porque el
  generador es perezoso.

`large-v3` se eligió otra vez por precisión, y la diferencia es del tipo que
importa — sobre el mismo audio, comparado contra el `medium` del otro equipo:

| Se dijo | `medium` | `large-v3` |
|---|---|---|
| "Ella es Samba, ¿cierto?" (nombre de la paciente) | "¿Ella de Sampa es cierto?" | "Ella es samba, ¿cierto?" |
| "Fabuloso" (desinfectante) | "fomoroso" | "fabulosos" |

Es exactamente lo que `vocabulario_clinico.py` existe para proteger: nombres
propios y de producto. Como el proceso corre desatendido, la exactitud clínica
vale más que terminar antes — el criterio no cambió, cambió lo que alcanza.

### Si la GPU se queda sin memoria

No se pierde el audio: `_plan_de_intentos()` baja un escalón y reintenta —
`large-v3` en GPU → `large-v3-turbo` en GPU (un tercio de VRAM) → `medium` en
CPU. El modelo que **realmente** produjo el texto queda en el `.json`
(`modelo`/`dispositivo`/`beam_size`) y en `_estado.json`, así que nunca hay que
adivinar con qué se transcribió. Verificado forzando el OOM con
`IRIS_BEAM_SIZE_GPU=5`.

### Requisito de la GPU en Windows

`faster-whisper` no trae los DLL de CUDA/cuDNN. Los aporta `torch` compilado con
CUDA si ya está instalado, o si no:

```bash
python -m pip install nvidia-cublas-cu12 nvidia-cudnn-cu12
```

`_preparar_dlls_cuda()` los ubica solo. Sin ellos el script no falla: detecta que
no hay GPU utilizable y sigue en CPU.

## Por qué el script hace lo que hace

Cinco decisiones que no son obvias y que conviene no deshacer:

1. **Escucha `on_moved`, no solo `on_created`.** Drive para escritorio baja el
   archivo dentro de `.tmp.drivedownload` y después lo *renombra* a su lugar
   final. Eso llega como evento de movimiento. Un vigilante que solo escucha
   `on_created` no se entera de casi ningún audio que venga de Drive.

2. **Espera a que el tamaño se estabilice, no un `sleep` fijo.** Un audio de
   consulta pesa cientos de MB; con un `sleep(5)` se transcribe un archivo a
   medio bajar.

3. **Limpia el audio antes de transcribir.** Los audios reales vienen de un
   celular sobre la mesa: medido, `mean_volume` de **-34,7 dB** con picos que
   saturan a 0 dB (voz lejana + golpes contra la mesa). Sin `loudnorm` el
   modelo devuelve texto inutilizable. El filtro VAD además elimina los
   silencios — en una prueba quitó 48 s de 90 s — y con eso desaparecen las
   alucinaciones del tipo "y y y y y y" que el modelo produce sobre el silencio.

4. **Nadie transcribe en su propio hilo: todo pasa por una cola.** Watchdog y el
   rescaneo periódico corren en hilos distintos y los dos pueden ver el mismo
   archivo. Como un audio solo queda anotado en `_estado.json` cuando *termina*,
   sin la cola los dos lo tomaban a la vez y se transcribía dos veces en
   paralelo, peleando por los mismos 8 hilos de CPU. No es teórico: pasó en las
   pruebas, con el rescaneo cayendo 4 s después del evento de watchdog. Ahora
   ambos solo encolan (con deduplicación por ruta) y un único trabajador consume
   de a un audio por vez. Verificado bajando `IRIS_RESCAN_SEG` a 2 segundos.

5. **Avisa cuando el audio llegó mudo, y NO toca los filtros por eso.** Dos
   consultas reales de 28 y 31 minutos volvieron con transcripciones de 500
   caracteres. Medido sobre los `.webm` originales: **el 97 % de las muestras
   era cero exacto** — silencio digital, no "sala tranquila". El celular
   bloqueó la pantalla y el micrófono dejó de entregar audio mientras el
   navegador seguía grabando; en `bonnie` solo hay sonido en 0-11 s, 935-985 s
   y 1631-1642 s de 1707.

   Antes de tocar nada se midió si el pipeline tenía la culpa, y **no la
   tiene**. Sobre los primeros 600 s de ese audio, el VAD conserva los mismos
   **10,5 s** con la cadena actual, con `speechnorm`, con `dynaudnorm`, con
   `acompressor` y **sin limpiar nada**; `afftdn` tampoco destruye la voz
   (−32,0 → −32,3 dB en la ventana con habla), y bajar el umbral del VAD de
   0.5 a 0.2 lo mueve a 10,7 s. No hay habla que rescatar: no fue grabada.
   **Si aparece otra transcripción demasiado corta, medí el audio antes de
   cambiar `FILTROS_FFMPEG` o `vad_parameters`** — es casi seguro el
   micrófono, no el modelo.

   Lo que sí se agregó: `duracion_habla_seg` / `cobertura_habla` en el `.json`
   (de `info.duration_after_vad`, no de la suma de segmentos, que sobreestima
   porque Whisper estira el `end` sobre el silencio), un `WARNING` bien visible
   por debajo de `COBERTURA_HABLA_MINIMA`, y `calidad_audio`, que
   `extraer_soip.py` copia al `.json` de `Consultas\` y el Tablero pinta en
   rojo arriba de la previsualización. También se descartan los segmentos con
   `no_speech_prob` alto **y** `avg_logprob` bajo: es lo que produjo el texto
   inventado ("Estic Dustomor, cre en vez de pensar que la casita…") sobre los
   tramos casi mudos del segundo audio.

   Del lado del navegador (`index.html`) el problema se ataca en origen: wake
   lock de pantalla mientras graba, detección de corte por `track.muted` con
   alarma en el botón del Tablero, y confirmación antes de subir una grabación
   mayormente muda.

## Lo que más mejoraría el resultado

**Acercar el micrófono.** Ningún modelo compensa un audio grabado a dos metros.
Un equipo a 30-50 cm de quien habla, o un micrófono de solapa de USD 15, mejora
la transcripción más que saltar de `medium` a `large`. Los errores que quedan hoy
son de audio, no de modelo.

Por eso el grabador del Tablero muestra un **medidor de nivel** mientras graba:
es lo único que avisa —antes de grabar 40 minutos inservibles— que el micrófono
está demasiado lejos. Si la barra casi no se mueve mientras alguien habla, hay
que acercar el equipo.

El nombre del archivo ya no hay que cuidarlo: lo arma la app
(`IRIS-<uuid>__2026-08-08_canela-gomez.webm`), y trae la fecha y el paciente
además del id. Solo aplica al que se deje a mano en la carpeta, donde sigue
conviniendo algo como `2026-08-07_Canela_Gomez.m4a`.
