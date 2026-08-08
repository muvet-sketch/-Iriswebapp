"""
Vigilante de audios de consulta -> transcripcion con Whisper.

Primer paso del flujo: audio (subido a Drive) -> transcripcion -> [despues] LLM -> formulario IRIS.

Que hace:
  1. Vigila la carpeta de audios y detecta archivos nuevos (incluidos los que baja Drive).
  2. Espera a que el archivo termine de sincronizar (tamano estable), no un sleep fijo.
  3. LIMPIA el audio con ffmpeg (mono 16 kHz, filtro de ruido, normalizacion de volumen).
  4. Transcribe con faster-whisper en espanol.
  5. Escribe <nombre>.txt y <nombre>.json en Transcripciones/ y mueve el audio a Procesados/.
  6. Lleva un registro en _estado.json para no repetir trabajo si se reinicia.

Uso:
    python vigilante.py                  # vigila para siempre
    python vigilante.py --una-vez        # procesa lo pendiente y sale (util para probar)
    python vigilante.py --modelo medium  # cambia el modelo de esta corrida
    python vigilante.py --sin-limpiar    # salta la limpieza de audio (para comparar)

Config por variables de entorno (opcional):
    IRIS_AUDIO_DIR      carpeta vigilada
    IRIS_WHISPER_MODEL  tiny | base | small | medium | large-v3-turbo

Requisitos: faster-whisper, watchdog, ffmpeg en el PATH.
"""

import argparse
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

# Medido en este equipo (Ryzen 5 3500U, 8 hilos, sin GPU) sobre audio real de consulta:
#   small           1.88x tiempo real   (38 min de audio -> ~20 min)
#   medium          0.94x tiempo real   (38 min de audio -> ~40 min)  <- elegido
#   large-v3-turbo  0.19x tiempo real   (38 min de audio -> ~3 horas)
# 'medium' se eligio por precision, no por velocidad: en la misma frase 'small'
# entendio "los primeros dos segundos" donde 'medium' entendio "los primeros
# sintomas". Como esto corre desatendido, la exactitud clinica vale mas que
# terminar antes. 'turbo' es inviable: 10x mas lento sin mejor texto.
MODELO_WHISPER = os.environ.get("IRIS_WHISPER_MODEL", "medium")
HILOS_CPU = int(os.environ.get("IRIS_CPU_THREADS", os.cpu_count() or 4))

EXTENSIONES_AUDIO = {".mp3", ".wav", ".m4a", ".ogg", ".opus", ".flac", ".aac", ".wma", ".mp4"}

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


def obtener_modelo(nombre):
    global _modelo, _modelo_nombre
    if _modelo is None or _modelo_nombre != nombre:
        log.info("Cargando modelo '%s' (la primera vez lo descarga)...", nombre)
        from faster_whisper import WhisperModel  # import tardio: --help responde al instante
        t0 = time.time()
        # int8 en CPU: ~6x mas rapido que openai-whisper y usa mucha menos RAM.
        _modelo = WhisperModel(nombre, device="cpu", compute_type="int8", cpu_threads=HILOS_CPU)
        _modelo_nombre = nombre
        log.info("Modelo cargado en %.1f s.", time.time() - t0)
    return _modelo


def transcribir(ruta: Path, nombre_modelo: str) -> dict:
    modelo = obtener_modelo(nombre_modelo)
    t0 = time.time()
    segmentos_gen, info = modelo.transcribe(
        str(ruta),
        language="es",
        initial_prompt=PROMPT_INICIAL,
        # El VAD corta los silencios. Ademas de acelerar, evita que el modelo
        # alucine en los tramos mudos (el clasico "y y y y y y" repetido).
        vad_filter=True,
        vad_parameters=dict(min_silence_duration_ms=500),
        beam_size=5,
        condition_on_previous_text=False,  # un error no se propaga al resto
    )
    # transcribe() devuelve un generador perezoso: el trabajo ocurre al recorrerlo.
    segmentos = [
        {"inicio": round(s.start, 2), "fin": round(s.end, 2), "texto": s.text.strip()}
        for s in segmentos_gen
    ]
    return {
        "texto": " ".join(s["texto"] for s in segmentos).strip(),
        "segmentos": segmentos,
        "idioma": info.language,
        "duracion_audio_seg": round(info.duration, 1),
        "duracion_proceso_seg": round(time.time() - t0, 1),
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

    # El JSON es lo que consumira el paso siguiente (LLM -> formulario IRIS).
    payload = {
        "archivo_audio": ruta.name,
        "transcrito_en": datetime.now().isoformat(timespec="seconds"),
        "modelo": nombre_modelo,
        "audio_limpiado": temporal is not None or (limpiar and fuente is not ruta),
        "idioma": resultado["idioma"],
        "duracion_audio_seg": resultado["duracion_audio_seg"],
        "duracion_proceso_seg": resultado["duracion_proceso_seg"],
        "texto": texto,
        "segmentos": resultado["segmentos"],
    }
    with open(ruta_json, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)

    dur_audio = resultado["duracion_audio_seg"] or 0
    dur_proc = resultado["duracion_proceso_seg"] or 1
    log.info("Listo: %.0f s de audio en %.0f s (%.2fx tiempo real) -> %s [%d caracteres, %d segmentos]",
             dur_audio, dur_proc, dur_audio / dur_proc, ruta_txt.name,
             len(texto), len(resultado["segmentos"]))

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
        "modelo": nombre_modelo,
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
    parser.add_argument("--modelo", default=MODELO_WHISPER,
                        help="tiny | base | small | medium | large-v3-turbo")
    parser.add_argument("--una-vez", action="store_true",
                        help="Procesa lo pendiente y sale, sin quedarse vigilando")
    parser.add_argument("--sin-limpiar", action="store_true",
                        help="Salta la limpieza con ffmpeg (para comparar resultados)")
    args = parser.parse_args()

    limpiar = not args.sin_limpiar
    configurar_log()

    for carpeta in (CARPETA_VIGILADA, CARPETA_PROCESADOS, CARPETA_TRANSCRIPCIONES):
        carpeta.mkdir(parents=True, exist_ok=True)

    log.info("=" * 64)
    log.info("Carpeta vigilada : %s", CARPETA_VIGILADA)
    log.info("Transcripciones  : %s", CARPETA_TRANSCRIPCIONES)
    log.info("Modelo           : %s  (%d hilos, int8)", args.modelo, HILOS_CPU)
    log.info("Limpieza de audio: %s", "si" if limpiar else "NO")
    log.info("=" * 64)

    estado = cargar_estado()

    # Un solo hilo transcribe, siempre. Todo lo demas solo encola.
    hilo = threading.Thread(target=trabajador, args=(estado, args.modelo, limpiar), daemon=True)
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
