"""
Vigilante de audios de consulta -> transcripcion con Whisper.

Primer paso del flujo: audio (subido a Drive) -> transcripcion -> [despues] LLM -> formulario IRIS.

Que hace:
  1. Vigila la carpeta de audios y detecta archivos nuevos (incluidos los que baja Drive).
  2. Espera a que el archivo termine de sincronizar (tamano estable), no un sleep fijo.
  3. LIMPIA el audio con ffmpeg (mono 16 kHz, filtro de ruido, normalizacion de volumen).
  4. Transcribe con faster-whisper en espanol, en GPU NVIDIA si hay una y si no en CPU.
  5. Escribe <nombre>.txt y <nombre>.json en Transcripciones/ y mueve el audio a Procesados/.
  6. Lleva un registro en _estado.json para no repetir trabajo si se reinicia.

Uso:
    python vigilante.py                  # vigila para siempre
    python vigilante.py --una-vez        # procesa lo pendiente y sale (util para probar)
    python vigilante.py --modelo medium  # cambia el modelo de esta corrida
    python vigilante.py --sin-limpiar    # salta la limpieza de audio (para comparar)

Config por variables de entorno (opcional):
    IRIS_AUDIO_DIR       carpeta vigilada
    IRIS_WHISPER_MODEL   tiny | base | small | medium | large-v3-turbo | large-v3
                         (por defecto large-v3 con GPU, medium sin GPU)
    IRIS_WHISPER_DEVICE  auto (por defecto) | cuda | cpu

Requisitos: faster-whisper, watchdog, ffmpeg en el PATH.
Para usar GPU en Windows hacen falta ademas los DLL de CUDA/cuDNN, que
faster-whisper NO trae: los aportan torch con CUDA o los paquetes
nvidia-cublas-cu12 / nvidia-cudnn-cu12 (ver _preparar_dlls_cuda).
"""

import argparse
import gc
import json
import logging
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime
from pathlib import Path

from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

# --------------------------------------------------------------------------
# Configuracion
# --------------------------------------------------------------------------

CARPETA_VIGILADA = Path(
    os.environ.get(
        "IRIS_AUDIO_DIR",
        r"C:\Users\Admin\Documents\Nanimals\Audios Consultas",
    )
)
CARPETA_PROCESADOS = CARPETA_VIGILADA / "Procesados"
CARPETA_TRANSCRIPCIONES = CARPETA_VIGILADA / "Transcripciones"
CARPETA_FALLIDOS = CARPETA_VIGILADA / "Fallidos"
ARCHIVO_ESTADO = CARPETA_VIGILADA / "_estado.json"
ARCHIVO_LOG = CARPETA_VIGILADA / "_vigilante.log"

# El modelo por defecto DEPENDE del equipo, porque el que conviene en CPU y el
# que conviene en GPU no son el mismo (medido sobre el mismo audio real de
# consulta, ver la tabla del README):
#
#   Sin GPU (Ryzen 5 3500U, 8 hilos)     medium         0.94x   <- por defecto
#   Con GPU (GTX 1050 3 GB)              large-v3       6.10x   <- por defecto
#
# En CPU 'medium' se eligio por precision: 'small' entendio "los primeros dos
# segundos" donde 'medium' entendio "los primeros sintomas", y large-v3-turbo
# era inviable (0.19x). Con GPU el calculo cambia por completo: alcanza para el
# modelo COMPLETO large-v3, que sobre el mismo audio acerto el nombre de la
# paciente ("Ella es samba") y el producto real ("fabulosos") donde medium
# entendio "¿Ella de Sampa es cierto?" y "fomoroso". Sigue valiendo el criterio
# de siempre: esto corre desatendido, la exactitud clinica vale mas que terminar
# antes.
DISPOSITIVO_WHISPER = os.environ.get("IRIS_WHISPER_DEVICE", "auto")  # auto | cuda | cpu
HILOS_CPU = int(os.environ.get("IRIS_CPU_THREADS", os.cpu_count() or 4))

MODELO_POR_DEFECTO_GPU = "large-v3"
MODELO_POR_DEFECTO_CPU = "medium"
# Modelo de respaldo en GPU: 4 capas de decoder contra las 32 de large-v3, asi
# que necesita la TERCERA parte de VRAM (1.1 GB contra 2.0 GB) y va aun mas
# rapido (8.2x). Es a donde se cae si large-v3 no entra (ver transcribir()).
MODELO_RESPALDO_GPU = "large-v3-turbo"

# En una GPU de 3 GB el ancho del beam es lo que decide si large-v3 entra o no:
# con beam 5 revienta por falta de VRAM y con beam 1 corre a 6.1x. En CPU no hay
# esa restriccion y se mantiene el beam 5 de siempre.
BEAM_SIZE_GPU = int(os.environ.get("IRIS_BEAM_SIZE_GPU", "1"))
BEAM_SIZE_CPU = int(os.environ.get("IRIS_BEAM_SIZE_CPU", "5"))

# El asignador asincrono de CUDA fragmenta mucho menos la VRAM, que es
# justamente el recurso escaso aca. Se fija antes de que se importe ctranslate2
# (lo lee al cargarse) y se puede desactivar con IRIS_CUDA_ALLOCATOR=default.
_ASIGNADOR_CUDA = os.environ.get("IRIS_CUDA_ALLOCATOR", "cuda_malloc_async")
if _ASIGNADOR_CUDA != "default":
    os.environ.setdefault("CT2_CUDA_ALLOCATOR", _ASIGNADOR_CUDA)

# .webm es lo que graba el navegador desde el Tablero de trabajo (Opus dentro
# de WebM; Safari da .m4a y Firefox puede dar .ogg). ffmpeg los lee sin nada
# extra, pero sin la extension en esta lista el vigilante los ignoraba.
EXTENSIONES_AUDIO = {".mp3", ".wav", ".m4a", ".ogg", ".opus", ".flac", ".aac",
                     ".wma", ".mp4", ".webm"}

# Carpetas temporales de Drive para escritorio: nunca mirar adentro.
CARPETAS_IGNORADAS = {".tmp.drivedownload", ".tmp.driveupload", "Procesados",
                      "Transcripciones", "Fallidos"}

# Whisper decodifica mejor si se le adelanta el vocabulario del dominio.
# Sin esto confunde terminos clinicos ("meloxicam" -> "melo si can").
# El prompt vive en vocabulario_clinico.py (compartido con extraer_soip.py) y
# esta medido contra el presupuesto real de ~224 tokens del initial_prompt —
# si se agranda alla, hay que volver a medirlo (ver el comentario del modulo).
from vocabulario_clinico import PROMPT_WHISPER as PROMPT_INICIAL

# Cadena de filtros de ffmpeg. Los audios reales vienen de un celular sobre la mesa:
# voz lejana y baja (medido: -34.7 dB de media) con golpes que saturan a 0 dB.
#   highpass=f=80   quita el retumbe de la sala y los golpes contra la mesa
#   afftdn          reduccion de ruido de fondo (ventilador, calle)
#   loudnorm        empareja el volumen: es lo que mas mejora el resultado
FILTROS_FFMPEG = "highpass=f=80,afftdn=nf=-25,loudnorm=I=-16:TP=-1.5:LRA=11"

# Calidad del audio recibido. Dos consultas reales de 28 y 31 minutos llegaron
# con el 97% de las muestras en CERO EXACTO: el celular bloqueo la pantalla y el
# microfono dejo de entregar audio mientras el navegador seguia grabando. La
# transcripcion salio de 500 caracteres y NADA en el pipeline lo dijo — parecia
# una consulta corta. Estas constantes son lo que hace que se note.
#
# OJO: no se toca la cadena de ffmpeg ni el umbral del VAD por este motivo. Se
# midio sobre ese audio: con la cadena actual, con speechnorm, con dynaudnorm,
# con acompressor y SIN limpiar nada, el VAD conserva los mismos 10,5 s de 600;
# bajar el umbral de 0.5 a 0.2 lo mueve a 10,7 s. No hay habla que rescatar,
# no fue grabada. Ver README, "Por que el script hace lo que hace".
COBERTURA_HABLA_MINIMA = 0.15     # fraccion del audio que el VAD da por habla
DURACION_MINIMA_AVISO_SEG = 300   # por debajo de 5 min una cobertura baja es normal

# Descarte de segmentos alucinados (ver _transcribir_con). Hacen falta las dos
# condiciones a la vez: cualquiera de ellas sola tumba habla real.
NO_SPEECH_PROB_MAXIMA = 0.8
AVG_LOGPROB_MINIMO = -1.0

# Cuanto esperar a que el tamano del archivo deje de cambiar antes de darlo por completo.
ESPERA_ENTRE_CHEQUEOS_SEG = 3
CHEQUEOS_ESTABLES_REQUERIDOS = 3
ESPERA_MAXIMA_SEG = 30 * 60  # 30 min: un audio grande por Drive puede tardar

# Cada cuanto rebarrer la carpeta por si watchdog perdio un evento.
# Configurable sobre todo para poder probar la carrera contra watchdog bajandolo a 2 s.
INTERVALO_RESCANEO_SEG = int(os.environ.get("IRIS_RESCAN_SEG", "60"))


# --------------------------------------------------------------------------
# Log
# --------------------------------------------------------------------------

def configurar_log():
    CARPETA_VIGILADA.mkdir(parents=True, exist_ok=True)
    formato = logging.Formatter(
        "%(asctime)s  %(levelname)-7s  %(message)s", datefmt="%Y-%m-%d %H:%M:%S"
    )
    raiz = logging.getLogger()
    raiz.setLevel(logging.INFO)

    consola = logging.StreamHandler(sys.stdout)
    consola.setFormatter(formato)
    # La consola de Windows es cp1252 y revienta con acentos si no se fuerza utf-8.
    try:
        consola.stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    raiz.addHandler(consola)

    archivo = logging.FileHandler(ARCHIVO_LOG, encoding="utf-8")
    archivo.setFormatter(formato)
    raiz.addHandler(archivo)


log = logging.getLogger("vigilante")


# --------------------------------------------------------------------------
# Estado (que se proceso ya)
# --------------------------------------------------------------------------

def cargar_estado():
    if not ARCHIVO_ESTADO.exists():
        return {"procesados": {}}
    try:
        with open(ARCHIVO_ESTADO, "r", encoding="utf-8") as f:
            datos = json.load(f)
        datos.setdefault("procesados", {})
        return datos
    except Exception as e:
        log.warning("No se pudo leer %s (%s). Empiezo con estado vacio.", ARCHIVO_ESTADO.name, e)
        return {"procesados": {}}


def guardar_estado(estado):
    tmp = ARCHIVO_ESTADO.with_suffix(".json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(estado, f, ensure_ascii=False, indent=2)
    tmp.replace(ARCHIVO_ESTADO)


def clave_estado(ruta: Path) -> str:
    """Nombre + tamano: si reaparece el mismo nombre con otro contenido, se reprocesa."""
    try:
        return f"{ruta.name}:{ruta.stat().st_size}"
    except OSError:
        return ruta.name


# --------------------------------------------------------------------------
# Deteccion de archivos listos
# --------------------------------------------------------------------------

def es_audio(ruta: Path) -> bool:
    if ruta.suffix.lower() not in EXTENSIONES_AUDIO:
        return False
    # Archivos parciales de Drive / Office / ocultos
    if ruta.name.startswith(("~$", ".", "_")):
        return False
    # Cualquier cosa dentro de una carpeta ignorada
    for parte in ruta.parts:
        if parte in CARPETAS_IGNORADAS:
            return False
    return True


def esperar_archivo_estable(ruta: Path) -> bool:
    """
    Espera a que el archivo deje de crecer. Reemplaza al time.sleep(5) fijo:
    Drive puede tardar minutos en bajar un audio largo y un sleep fijo
    transcribiria un archivo a medio escribir.
    """
    inicio = time.time()
    ultimo_tam = -1
    estables = 0

    while time.time() - inicio < ESPERA_MAXIMA_SEG:
        if not ruta.exists():
            return False
        try:
            tam = ruta.stat().st_size
        except OSError:
            time.sleep(ESPERA_ENTRE_CHEQUEOS_SEG)
            continue

        if tam > 0 and tam == ultimo_tam:
            estables += 1
            if estables >= CHEQUEOS_ESTABLES_REQUERIDOS:
                # Ultima prueba: poder abrirlo significa que nadie esta escribiendolo.
                try:
                    with open(ruta, "rb"):
                        pass
                    return True
                except OSError:
                    estables = 0
        else:
            estables = 0
            ultimo_tam = tam

        time.sleep(ESPERA_ENTRE_CHEQUEOS_SEG)

    log.error("Timeout esperando que se estabilice %s", ruta.name)
    return False


# --------------------------------------------------------------------------
# Limpieza de audio
# --------------------------------------------------------------------------

def limpiar_audio(origen: Path, destino: Path) -> bool:
    """
    Normaliza a mono 16 kHz (lo que Whisper usa internamente) y empareja el volumen.
    Medido sobre audio real: sin este paso el modelo devuelve texto inutilizable.
    """
    cmd = [
        "ffmpeg", "-v", "error", "-y",
        "-i", str(origen),
        "-ac", "1", "-ar", "16000",
        "-af", FILTROS_FFMPEG,
        "-c:a", "pcm_s16le",
        str(destino),
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60 * 60)
    except FileNotFoundError:
        log.error("No se encontro ffmpeg en el PATH. Se transcribe el audio sin limpiar.")
        return False
    except subprocess.TimeoutExpired:
        log.error("ffmpeg tardo demasiado limpiando %s.", origen.name)
        return False

    if proc.returncode != 0 or not destino.exists() or destino.stat().st_size == 0:
        log.warning("ffmpeg fallo limpiando %s: %s", origen.name, (proc.stderr or "").strip()[:300])
        return False
    return True


# --------------------------------------------------------------------------
# Whisper
# --------------------------------------------------------------------------

_modelo = None
_modelo_nombre = None
_modelo_dispositivo = None


def _preparar_dlls_cuda():
    """
    ctranslate2 en Windows NO trae los DLL de CUDA/cuDNN: con device='cuda'
    revienta al cargar el modelo si no los encuentra. Los toma prestados de
    paquetes pip que si los incluyen: torch con CUDA (torch/lib) o los
    paquetes nvidia-cublas-cu12 / nvidia-cudnn-cu12 (nvidia/*/bin).
    Registrar un directorio que no aplica es inocuo, por eso se agregan todos
    los que existan.
    """
    if os.name != "nt":
        return
    import importlib.util
    candidatos = []
    spec = importlib.util.find_spec("torch")
    if spec and spec.submodule_search_locations:
        candidatos.append(Path(list(spec.submodule_search_locations)[0]) / "lib")
    for paquete in ("nvidia.cublas", "nvidia.cudnn"):
        try:
            spec = importlib.util.find_spec(paquete)
        except ModuleNotFoundError:
            spec = None
        if spec and spec.submodule_search_locations:
            candidatos.append(Path(list(spec.submodule_search_locations)[0]) / "bin")
    for carpeta in candidatos:
        if carpeta.is_dir():
            os.add_dll_directory(str(carpeta))


def _hay_gpu_utilizable() -> bool:
    try:
        _preparar_dlls_cuda()
        import ctranslate2
        return ctranslate2.get_cuda_device_count() > 0
    except Exception as e:
        log.info("GPU no utilizable (%s). Se usa CPU.", e)
        return False


_hay_gpu_cache = None


def dispositivo_disponible() -> str:
    """'cuda' o 'cpu' segun IRIS_WHISPER_DEVICE y lo que haya en el equipo."""
    global _hay_gpu_cache
    if DISPOSITIVO_WHISPER == "cpu":
        return "cpu"
    if DISPOSITIVO_WHISPER == "cuda":
        return "cuda"
    if _hay_gpu_cache is None:
        _hay_gpu_cache = _hay_gpu_utilizable()
    return "cuda" if _hay_gpu_cache else "cpu"


def modelo_por_defecto(dispositivo: str) -> str:
    return MODELO_POR_DEFECTO_GPU if dispositivo == "cuda" else MODELO_POR_DEFECTO_CPU


def beam_size_para(dispositivo: str) -> int:
    return BEAM_SIZE_GPU if dispositivo == "cuda" else BEAM_SIZE_CPU


def obtener_modelo(nombre, dispositivo):
    global _modelo, _modelo_nombre, _modelo_dispositivo
    if _modelo is None or _modelo_nombre != nombre or _modelo_dispositivo != dispositivo:
        # Soltar el modelo viejo ANTES de cargar el nuevo: si no, durante un
        # instante conviven los dos en VRAM y el respaldo tambien se queda sin
        # memoria, que es justo el caso en el que se lo llama.
        _modelo = None
        _modelo_nombre = None
        _modelo_dispositivo = None
        gc.collect()

        log.info("Cargando modelo '%s' en %s (la primera vez lo descarga)...", nombre, dispositivo)
        from faster_whisper import WhisperModel  # import tardio: --help responde al instante
        t0 = time.time()
        if dispositivo == "cuda":
            _preparar_dlls_cuda()
        # int8 sirve en ambos: en CPU es ~6x mas rapido que openai-whisper con
        # mucha menos RAM; en GPU Pascal (GTX 1050) es ademas el unico tipo
        # reducido disponible (float16 no tiene soporte eficiente en esa
        # generacion, y float32 no deja VRAM para el decoder).
        _modelo = WhisperModel(nombre, device=dispositivo, compute_type="int8",
                               cpu_threads=HILOS_CPU)
        _modelo_nombre = nombre
        _modelo_dispositivo = dispositivo
        log.info("Modelo cargado en %.1f s (%s).", time.time() - t0, dispositivo)
    return _modelo


def _es_falta_de_memoria(e: Exception) -> bool:
    return "out of memory" in str(e).lower()


def _plan_de_intentos(nombre_modelo: str, dispositivo: str):
    """
    Que probar, en orden, si la GPU se queda sin VRAM.

    En una GPU chica el margen es real: large-v3 carga en 2.0 de los 3.0 GB y
    el decoder puede no entrar segun el audio. Antes de rendirse y mandar el
    audio a Fallidos conviene bajar un escalon, porque cualquiera de los dos
    respaldos da mejor texto que no tener transcripcion:
      1. el modelo pedido en GPU
      2. large-v3-turbo en GPU  (un tercio de la VRAM, y mas rapido)
      3. el modelo de CPU       (lento pero no depende de la VRAM)
    """
    intentos = [(nombre_modelo, dispositivo)]
    if dispositivo == "cuda":
        if nombre_modelo != MODELO_RESPALDO_GPU:
            intentos.append((MODELO_RESPALDO_GPU, "cuda"))
        intentos.append((MODELO_POR_DEFECTO_CPU, "cpu"))
    return intentos


def transcribir(ruta: Path, nombre_modelo: str, dispositivo: str = None) -> dict:
    if dispositivo is None:
        dispositivo = dispositivo_disponible()

    intentos = _plan_de_intentos(nombre_modelo, dispositivo)
    for indice, (nombre, disp) in enumerate(intentos):
        try:
            return _transcribir_con(ruta, nombre, disp)
        except Exception as e:
            ultimo = indice == len(intentos) - 1
            if ultimo or not _es_falta_de_memoria(e):
                raise
            siguiente = intentos[indice + 1]
            log.warning("Sin memoria con '%s' en %s. Reintento con '%s' en %s.",
                        nombre, disp, siguiente[0], siguiente[1])


def _transcribir_con(ruta: Path, nombre_modelo: str, dispositivo: str) -> dict:
    modelo = obtener_modelo(nombre_modelo, dispositivo)
    beam = beam_size_para(dispositivo)
    t0 = time.time()
    segmentos_gen, info = modelo.transcribe(
        str(ruta),
        language="es",
        initial_prompt=PROMPT_INICIAL,
        # El VAD corta los silencios. Ademas de acelerar, evita que el modelo
        # alucine en los tramos mudos (el clasico "y y y y y y" repetido).
        vad_filter=True,
        vad_parameters=dict(min_silence_duration_ms=500),
        beam_size=beam,
        condition_on_previous_text=False,  # un error no se propaga al resto
        # Segunda linea de defensa contra la alucinacion, y no es teorica: un
        # audio real que quedo casi mudo (ver COBERTURA_HABLA_MINIMA) devolvio
        # "Estic Dustomor, cre en vez de pensar que la casita..." sobre los
        # tramos sin voz. El VAD solo no alcanza cuando lo poco que sobrevive
        # es ruido.
        hallucination_silence_threshold=2.0,
    )
    # transcribe() devuelve un generador perezoso: el trabajo ocurre al recorrerlo,
    # asi que un error de VRAM aparece ACA y no en la llamada de arriba.
    segmentos = []
    descartados = 0
    for s in segmentos_gen:
        texto = s.text.strip()
        if not texto:
            continue
        # Segmento que el propio modelo cree que no es habla Y ademas decodifico
        # con baja confianza: es texto inventado sobre ruido. Hacen falta las
        # dos condiciones — habla real y baja pero clara no se descarta.
        if s.no_speech_prob > NO_SPEECH_PROB_MAXIMA and s.avg_logprob < AVG_LOGPROB_MINIMO:
            descartados += 1
            continue
        segmentos.append({"inicio": round(s.start, 2), "fin": round(s.end, 2), "texto": texto})
    if descartados:
        log.warning("Se descartaron %d segmento(s) por parecer texto inventado sobre ruido.", descartados)

    # duration_after_vad es el tiempo que el VAD dio por habla. Es la medida
    # correcta de "cuanto audio util traia el archivo": sumar las duraciones de
    # los segmentos sobreestima, porque Whisper estira el `end` de un segmento
    # sobre el silencio que le sigue (medido: un segmento de 9,97 s a 940,35 s).
    duracion = info.duration or 0
    habla = getattr(info, "duration_after_vad", None)
    if habla is None:
        habla = duracion
    return {
        "modelo": nombre_modelo,
        "dispositivo": dispositivo,
        "beam_size": beam,
        "texto": " ".join(s["texto"] for s in segmentos).strip(),
        "segmentos": segmentos,
        "segmentos_descartados": descartados,
        "idioma": info.language,
        "duracion_audio_seg": round(duracion, 1),
        "duracion_habla_seg": round(habla, 1),
        "cobertura_habla": round(habla / duracion, 4) if duracion else 0.0,
        "duracion_proceso_seg": round(time.time() - t0, 1),
    }


def _mmss(segundos: float) -> str:
    total = int(segundos)
    return f"{total // 60} min {total % 60:02d} s" if total >= 60 else f"{total} s"


def evaluar_calidad_audio(resultado: dict):
    """
    None si el audio traia habla suficiente; si no, el dict que viaja en el
    .json y que extraer_soip.py convierte en un aviso para el veterinario.
    """
    duracion = resultado.get("duracion_audio_seg") or 0
    habla = resultado.get("duracion_habla_seg") or 0
    cobertura = resultado.get("cobertura_habla") or 0.0
    if duracion < DURACION_MINIMA_AVISO_SEG or cobertura >= COBERTURA_HABLA_MINIMA:
        return None
    return {
        "nivel": "bajo",
        "cobertura_habla": cobertura,
        "duracion_audio_seg": duracion,
        "duracion_habla_seg": habla,
        "mensaje": (
            f"el audio dura {_mmss(duracion)} pero solo {_mmss(habla)} tienen sonido "
            f"({cobertura * 100:.0f}%): el microfono estuvo mudo casi todo el tiempo"
        ),
    }


# --------------------------------------------------------------------------
# Procesamiento de un audio
# --------------------------------------------------------------------------

def procesar_audio(ruta: Path, estado: dict, nombre_modelo: str, limpiar: bool = True):
    clave = clave_estado(ruta)
    if clave in estado["procesados"]:
        return

    log.info("Audio detectado: %s", ruta.name)

    if not esperar_archivo_estable(ruta):
        log.warning("Se omite %s (no quedo estable o desaparecio).", ruta.name)
        return

    tam_mb = ruta.stat().st_size / (1024 * 1024)
    temporal = None
    fuente = ruta

    if limpiar:
        log.info("Limpiando audio con ffmpeg...")
        fd, tmp_path = tempfile.mkstemp(suffix=".wav", prefix="iris_audio_")
        os.close(fd)
        temporal = Path(tmp_path)
        if limpiar_audio(ruta, temporal):
            fuente = temporal
        else:
            log.warning("Sigo con el audio original, sin limpiar.")
            temporal.unlink(missing_ok=True)
            temporal = None

    log.info("Transcribiendo %s (%.1f MB) con modelo '%s'...", ruta.name, tam_mb, nombre_modelo)

    try:
        resultado = transcribir(fuente, nombre_modelo)
    except Exception as e:
        log.exception("Fallo la transcripcion de %s: %s", ruta.name, e)
        CARPETA_FALLIDOS.mkdir(parents=True, exist_ok=True)
        try:
            shutil.move(str(ruta), str(CARPETA_FALLIDOS / ruta.name))
            log.info("Movido a Fallidos/ para revisar a mano.")
        except Exception as e2:
            log.error("Tampoco se pudo mover a Fallidos: %s", e2)
        return
    finally:
        if temporal is not None:
            temporal.unlink(missing_ok=True)

    texto = resultado["texto"]
    base = ruta.stem

    CARPETA_TRANSCRIPCIONES.mkdir(parents=True, exist_ok=True)
    ruta_txt = CARPETA_TRANSCRIPCIONES / f"{base}.txt"
    ruta_json = CARPETA_TRANSCRIPCIONES / f"{base}.json"

    ruta_txt.write_text(texto, encoding="utf-8")

    calidad = evaluar_calidad_audio(resultado)

    # El JSON es lo que consumira el paso siguiente (LLM -> formulario IRIS).
    payload = {
        "archivo_audio": ruta.name,
        "transcrito_en": datetime.now().isoformat(timespec="seconds"),
        # El modelo REAL, que puede no ser el pedido si hubo que bajar un
        # escalon por VRAM (ver _plan_de_intentos): quien lea la transcripcion
        # tiene que poder saber con que se produjo.
        "modelo": resultado["modelo"],
        "dispositivo": resultado["dispositivo"],
        "beam_size": resultado["beam_size"],
        "audio_limpiado": temporal is not None or (limpiar and fuente is not ruta),
        "idioma": resultado["idioma"],
        "duracion_audio_seg": resultado["duracion_audio_seg"],
        "duracion_habla_seg": resultado["duracion_habla_seg"],
        "cobertura_habla": resultado["cobertura_habla"],
        "segmentos_descartados": resultado["segmentos_descartados"],
        "calidad_audio": calidad,
        "duracion_proceso_seg": resultado["duracion_proceso_seg"],
        "texto": texto,
        "segmentos": resultado["segmentos"],
    }
    with open(ruta_json, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)

    dur_audio = resultado["duracion_audio_seg"] or 0
    dur_proc = resultado["duracion_proceso_seg"] or 1
    log.info("Listo: %.0f s de audio en %.0f s (%.2fx tiempo real, %s/%s) -> %s [%d caracteres, %d segmentos]",
             dur_audio, dur_proc, dur_audio / dur_proc,
             resultado["modelo"], resultado["dispositivo"], ruta_txt.name,
             len(texto), len(resultado["segmentos"]))

    if calidad:
        # Bien visible: sin esto una consulta de 28 minutos que llego muda se
        # ve igual que una consulta corta, y el veterinario confia en el
        # borrador. No se manda a Fallidos: los segundos que hay son reales.
        log.warning("=" * 64)
        log.warning("AUDIO CASI MUDO: %s", calidad["mensaje"])
        log.warning("Casi siempre es la pantalla del celular bloqueandose durante")
        log.warning("la consulta. El audio en si no se puede recuperar.")
        log.warning("=" * 64)

    vista = texto[:300] + ("..." if len(texto) > 300 else "")
    log.info("Vista previa: %s", vista or "(vacio)")

    # Mover el audio recien despues de escribir la transcripcion:
    # si algo revienta, el audio sigue en su lugar y se reintenta.
    CARPETA_PROCESADOS.mkdir(parents=True, exist_ok=True)
    destino = CARPETA_PROCESADOS / ruta.name
    if destino.exists():
        destino = CARPETA_PROCESADOS / f"{base}_{int(time.time())}{ruta.suffix}"
    try:
        shutil.move(str(ruta), str(destino))
    except Exception as e:
        log.warning("No se pudo mover %s a Procesados (%s). Queda en su sitio.", ruta.name, e)

    estado["procesados"][clave] = {
        "fecha": datetime.now().isoformat(timespec="seconds"),
        "transcripcion": ruta_txt.name,
        "modelo": resultado["modelo"],
    }
    guardar_estado(estado)


# --------------------------------------------------------------------------
# Cola de trabajo
# --------------------------------------------------------------------------
#
# Watchdog y el rescaneo periodico corren en hilos DISTINTOS, y ambos pueden ver
# el mismo archivo. Como un audio solo queda anotado en _estado.json cuando
# TERMINA de procesarse, sin esta cola los dos lo tomaban a la vez: se transcribia
# dos veces en paralelo, peleando por los mismos 8 hilos de CPU. (Pasaba de verdad:
# el rescaneo de 60 s cayo 4 s despues de que watchdog empezara.)
#
# Por eso nadie transcribe en su propio hilo: watchdog y el rescaneo solo ENCOLAN,
# y un unico trabajador consume la cola de a un audio por vez.

_cola = queue.Queue()
_lock_encolados = threading.Lock()
_encolados = set()   # rutas ya en cola o procesandose


def encolar(ruta: Path):
    """Agrega un audio a la cola si no esta ya esperando o en proceso."""
    try:
        clave = str(ruta.resolve()).lower()   # la ruta es estable; el tamano aun cambia si se sigue bajando
    except OSError:
        return
    with _lock_encolados:
        if clave in _encolados:
            return
        _encolados.add(clave)
    _cola.put((ruta, clave))


def trabajador(estado: dict, nombre_modelo: str, limpiar: bool):
    """Unico hilo que transcribe. Garantiza una transcripcion a la vez."""
    while True:
        item = _cola.get()
        if item is None:          # senal de apagado
            _cola.task_done()
            return
        ruta, clave = item
        try:
            procesar_audio(ruta, estado, nombre_modelo, limpiar)
        except Exception:
            log.exception("Error inesperado procesando %s", ruta.name)
        finally:
            with _lock_encolados:
                _encolados.discard(clave)
            _cola.task_done()


def barrer_pendientes():
    """Encola lo que ya estaba en la carpeta. Cubre los audios que llegaron con el PC apagado."""
    if not CARPETA_VIGILADA.exists():
        log.error("La carpeta vigilada no existe: %s", CARPETA_VIGILADA)
        return
    for ruta in sorted(CARPETA_VIGILADA.iterdir()):
        if ruta.is_file() and es_audio(ruta):
            encolar(ruta)


# --------------------------------------------------------------------------
# Watchdog
# --------------------------------------------------------------------------

class VigiaAudios(FileSystemEventHandler):
    """
    Escucha created Y moved. El 'moved' es imprescindible: Drive para escritorio
    baja el archivo dentro de .tmp.drivedownload y despues lo RENOMBRA a su lugar
    final, lo que llega como un evento de movimiento y no de creacion.

    Solo encola: la transcripcion la hace el hilo trabajador (ver arriba).
    """

    def _tomar(self, ruta_str):
        ruta = Path(ruta_str)
        if ruta.is_file() and es_audio(ruta):
            encolar(ruta)

    def on_created(self, event):
        if not event.is_directory:
            self._tomar(event.src_path)

    def on_moved(self, event):
        if not event.is_directory:
            self._tomar(event.dest_path)


def main():
    parser = argparse.ArgumentParser(description="Vigilante de audios -> Whisper")
    # Sin --modelo el valor NO se puede fijar aca: depende de si hay GPU, y eso
    # se averigua recien al arrancar (ver modelo_por_defecto()).
    parser.add_argument("--modelo", default=os.environ.get("IRIS_WHISPER_MODEL"),
                        help="tiny | base | small | medium | large-v3-turbo | large-v3 "
                             "(por defecto: large-v3 con GPU, medium sin GPU)")
    parser.add_argument("--una-vez", action="store_true",
                        help="Procesa lo pendiente y sale, sin quedarse vigilando")
    parser.add_argument("--sin-limpiar", action="store_true",
                        help="Salta la limpieza con ffmpeg (para comparar resultados)")
    args = parser.parse_args()

    limpiar = not args.sin_limpiar
    configurar_log()

    for carpeta in (CARPETA_VIGILADA, CARPETA_PROCESADOS, CARPETA_TRANSCRIPCIONES):
        carpeta.mkdir(parents=True, exist_ok=True)

    dispositivo = dispositivo_disponible()
    modelo = args.modelo or modelo_por_defecto(dispositivo)

    log.info("=" * 64)
    log.info("Carpeta vigilada : %s", CARPETA_VIGILADA)
    log.info("Transcripciones  : %s", CARPETA_TRANSCRIPCIONES)
    log.info("Dispositivo      : %s%s", dispositivo,
             "  (GPU NVIDIA)" if dispositivo == "cuda" else f"  ({HILOS_CPU} hilos)")
    log.info("Modelo           : %s  (int8, beam %d)", modelo, beam_size_para(dispositivo))
    log.info("Limpieza de audio: %s", "si" if limpiar else "NO")
    log.info("=" * 64)

    estado = cargar_estado()

    # Un solo hilo transcribe, siempre. Todo lo demas solo encola.
    hilo = threading.Thread(target=trabajador, args=(estado, modelo, limpiar), daemon=True)
    hilo.start()

    log.info("Barriendo pendientes...")
    barrer_pendientes()

    if args.una_vez:
        _cola.join()               # espera a que se vacie la cola
        _cola.put(None)            # apaga el trabajador
        hilo.join(timeout=10)
        log.info("Modo --una-vez: termino.")
        return

    observador = Observer()
    observador.schedule(VigiaAudios(), path=str(CARPETA_VIGILADA), recursive=False)
    observador.start()
    log.info("Vigilando. Deja audios en la carpeta. Ctrl+C para salir.")

    try:
        ultimo_rescaneo = time.time()
        while True:
            time.sleep(1)
            # Red de seguridad: watchdog a veces pierde eventos en carpetas
            # que toca un agente externo como Drive. Solo encola, asi que
            # solaparse con un evento de watchdog ya no duplica trabajo.
            if time.time() - ultimo_rescaneo > INTERVALO_RESCANEO_SEG:
                ultimo_rescaneo = time.time()
                barrer_pendientes()
    except KeyboardInterrupt:
        log.info("Cerrando (se termina el audio en curso)...")
        observador.stop()
    observador.join()
    _cola.put(None)
    hilo.join(timeout=60)
    log.info("Vigilante detenido.")


if __name__ == "__main__":
    main()
