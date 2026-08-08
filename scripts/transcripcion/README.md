# Transcripción de audios de consulta

Flujo **audio → transcripción → LLM → formulario IRIS**.

- **Paso 1 — `vigilante.py`**: vigila una carpeta sincronizada con Google Drive,
  y cada audio que aparece lo limpia, lo transcribe con Whisper y deja un `.txt`
  y un `.json`.
- **Paso 2 — `extraer_soip.py`**: lee esos `.json` y produce el SOIP estructurado
  (motivo, S/O/I/P, 7 signos vitales, hallazgos por sistema) listo para el
  formulario.
- **`vocabulario_clinico.py`**: vocabulario del dominio compartido por los dos
  pasos (ver sección abajo).

## Uso

```bat
iniciar_vigilante.bat
```

O desde la terminal:

```bash
python vigilante.py                  # vigila para siempre
python vigilante.py --una-vez        # procesa lo pendiente y sale
python vigilante.py --modelo small   # más rápido, menos preciso
python vigilante.py --sin-limpiar    # sin limpieza de audio (para comparar)
```

Paso 2 (requiere `ANTHROPIC_API_KEY` en el entorno):

```bash
python extraer_soip.py               # procesa las transcripciones pendientes
python extraer_soip.py --rehacer     # reprocesa todo
```

## Carpetas

```
Audios Consultas\          <- dejar los audios acá (sincronizada con Drive)
  Procesados\              <- audio ya transcrito (se mueve solo)
  Transcripciones\         <- .txt y .json del paso 1
  Consultas\               <- SOIP estructurado del paso 2  <-- ENTRADA DEL PASO 3
  Fallidos\                <- audios que reventaron, para revisar a mano
  _estado.json             <- registro de lo procesado (no borrar)
  _vigilante.log           <- historial
```

La ruta se cambia con la variable de entorno `IRIS_AUDIO_DIR`.

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

## Mediciones en este equipo

Ryzen 5 3500U, 8 hilos, 10 GB RAM, **sin GPU**. Sobre audio real de consulta:

| Configuración | Velocidad | Consulta de 38 min | Calidad |
|---|---|---|---|
| openai-whisper `small`, audio crudo | 0,28× | ~2,2 h | inservible |
| faster-whisper `large-v3-turbo` | 0,19× | ~3,3 h | no mejor que medium |
| faster-whisper `small` | 1,88× | ~20 min | aceptable |
| **faster-whisper `medium`** | **0,94×** | **~40 min** | **elegida** |

`medium` se eligió por precisión, no por velocidad. En la misma frase:

- `small` → "hace 30 días no soy contento de **los primeros dos segundos**"
- `medium` → "hace 30 días usted contó que son **los primeros síntomas**"

Como el proceso corre desatendido, la exactitud clínica vale más que terminar antes.

## Por qué el script hace lo que hace

Tres decisiones que no son obvias y que conviene no deshacer:

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

## Lo que más mejoraría el resultado

**Acercar el micrófono.** Ningún modelo compensa un audio grabado a dos metros.
Un celular a 30-50 cm de quien habla, o un micrófono de solapa de USD 15, mejora
la transcripción más que saltar de `medium` a `large`. Los errores que quedan hoy
son de audio, no de modelo.

Conviene además nombrar los audios de forma consistente, por ejemplo
`2026-08-07_Canela_Gomez.m4a`, para poder cruzarlos con el paciente después.
