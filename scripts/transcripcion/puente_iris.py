"""
Puente entre la app IRIS y la carpeta de audios de este equipo.

Es lo que convierte el pipeline en algo automatico de punta a punta. Antes el
veterinario grababa con el celular, alguien copiaba el audio a Drive, y despues
habia que buscar el .json de Consultas/ y cargarlo a mano en el Tablero. Ahora
el Tablero graba con el microfono, sube el audio a Supabase, y este script:

  1. BAJA  los audios nuevos (consultas_audio.estado = 'subido') a la carpeta
     vigilada. Como esa carpeta esta sincronizada con Google Drive, el audio
     queda tambien en "Audios Consultas" de Drive sin hacer nada mas.
     -> vigilante.py (que ya esta corriendo) lo detecta y lo transcribe.
  2. EXTRAE el SOIP de las transcripciones nuevas llamando a extraer_soip.py.
  3. SUBE  ese .json de vuelta a la fila (estado = 'listo'), que es lo que el
     navegador esta esperando para rellenar el formulario.

El id de la fila viaja DENTRO del nombre del archivo (prefijo `IRIS-<id>__`),
que es lo que permite volver a asociar el .json final con la consulta que lo
pidio: vigilante.py y extraer_soip.py conservan el stem a lo largo de todo el
pipeline, asi que ninguno de los dos necesito cambios para esto.

Solo toca los archivos con ese prefijo. Un audio que alguien deje a mano en la
carpeta se sigue transcribiendo como siempre y este script lo ignora --
incluida la extraccion del SOIP, que cuesta plata por llamada a la API.

Uso:
    python puente_iris.py                # ciclo continuo
    python puente_iris.py --una-vez      # una pasada y sale (util para probar)
    python puente_iris.py --sin-extraer  # solo baja audios y sube .json ya hechos

Config por variables de entorno:
    IRIS_SUPABASE_URL          por defecto el proyecto de produccion
    IRIS_SUPABASE_SERVICE_KEY  OBLIGATORIA. Service role key del proyecto.
    IRIS_AUDIO_DIR             carpeta vigilada (la misma de vigilante.py)
    IRIS_PUENTE_SEG            segundos entre vueltas (por defecto 20)
    ANTHROPIC_API_KEY          la que ya usa extraer_soip.py

La service role key SALTA las policies RLS -- es la unica forma de que este
equipo lea audios de cualquier usuario de la clinica. No la pongas en el
codigo ni la subas al repo (que es publico): va en una variable de entorno de
este PC.
"""

import argparse
import json
import logging
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

# --------------------------------------------------------------------------
# Configuracion
# --------------------------------------------------------------------------

SUPABASE_URL = os.environ.get(
    "IRIS_SUPABASE_URL", "https://ayyggymsblvxrrzfjhmw.supabase.co"
).rstrip("/")
SERVICE_KEY = os.environ.get("IRIS_SUPABASE_SERVICE_KEY", "")

CARPETA_VIGILADA = Path(
    os.environ.get(
        "IRIS_AUDIO_DIR",
        r"C:\Users\Admin\Documents\Nanimals\Audios Consultas",
    )
)
CARPETA_TRANSCRIPCIONES = CARPETA_VIGILADA / "Transcripciones"
CARPETA_CONSULTAS = CARPETA_VIGILADA / "Consultas"
CARPETA_FALLIDOS = CARPETA_VIGILADA / "Fallidos"
ARCHIVO_ESTADO = CARPETA_VIGILADA / "_puente.json"
ARCHIVO_LOG = CARPETA_VIGILADA / "_puente.log"

BUCKET = "audios-consultas"
TABLA = "consultas_audio"
INTERVALO_SEG = int(os.environ.get("IRIS_PUENTE_SEG", "20"))

# Cuantas filas se atienden por vuelta. Bajar audios es rapido, pero
# transcribir no: no tiene sentido inundar la carpeta de una sola vez.
LOTE = 5

# El prefijo con el que la app bautiza los audios que manda. Todo lo que no
# empieza asi es de alguien que dejo un archivo a mano y no se toca.
RE_ID = re.compile(r"^IRIS-([0-9a-fA-F-]{36})__")

log = logging.getLogger("puente")


def configurar_log():
    CARPETA_VIGILADA.mkdir(parents=True, exist_ok=True)
    fmt = logging.Formatter("%(asctime)s  %(levelname)-7s %(message)s", "%Y-%m-%d %H:%M:%S")
    log.setLevel(logging.INFO)
    consola = logging.StreamHandler(sys.stdout)
    consola.setFormatter(fmt)
    log.addHandler(consola)
    archivo = logging.FileHandler(ARCHIVO_LOG, encoding="utf-8")
    archivo.setFormatter(fmt)
    log.addHandler(archivo)


# --------------------------------------------------------------------------
# Estado local (que .json ya se publicaron)
# --------------------------------------------------------------------------
# Sin esto, cada vuelta volveria a subir el mismo resultado. No alcanza con
# mirar el estado remoto: la fila puede quedar en 'listo' y el archivo seguir
# en Consultas/ para siempre.

def cargar_estado() -> dict:
    estado = {}
    if ARCHIVO_ESTADO.exists():
        try:
            with open(ARCHIVO_ESTADO, "r", encoding="utf-8") as f:
                estado = json.load(f)
        except Exception as e:
            log.warning("No se pudo leer %s (%s). Empiezo de cero.", ARCHIVO_ESTADO.name, e)
            estado = {}
    if not isinstance(estado, dict):
        estado = {}
    # Se normalizan las claves en vez de confiar en el archivo: un estado
    # viejo o a medio escribir no puede tumbar el puente con un KeyError.
    estado.setdefault("publicados", {})
    estado.setdefault("bajados", {})
    return estado


def guardar_estado(estado: dict):
    tmp = ARCHIVO_ESTADO.with_suffix(".json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(estado, f, ensure_ascii=False, indent=2)
    tmp.replace(ARCHIVO_ESTADO)


# --------------------------------------------------------------------------
# Cliente HTTP minimo (stdlib, para no sumar dependencias)
# --------------------------------------------------------------------------

def _cabeceras(extra=None) -> dict:
    h = {
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
    }
    if extra:
        h.update(extra)
    return h


def _pedir(url: str, metodo: str = "GET", cuerpo=None, cabeceras=None, timeout=60):
    datos = None
    h = _cabeceras(cabeceras)
    if cuerpo is not None:
        datos = json.dumps(cuerpo, ensure_ascii=False).encode("utf-8")
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=datos, headers=h, method=metodo)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        crudo = r.read()
    if not crudo:
        return None
    return json.loads(crudo.decode("utf-8"))


def listar_filas(estado: str, limite: int = LOTE):
    campos = "id,pet_key,paciente_nombre,audio_path,audio_nombre,duracion_seg,created_at"
    url = (f"{SUPABASE_URL}/rest/v1/{TABLA}"
           f"?estado=eq.{estado}&select={campos}&order=created_at.asc&limit={limite}")
    return _pedir(url) or []


def actualizar_fila(fila_id: str, cambios: dict):
    cambios = dict(cambios)
    cambios["updated_at"] = datetime.now().astimezone().isoformat(timespec="seconds")
    url = f"{SUPABASE_URL}/rest/v1/{TABLA}?id=eq.{fila_id}"
    _pedir(url, "PATCH", cambios, {"Prefer": "return=minimal"})


def descargar_audio(ruta_bucket: str, destino: Path) -> bool:
    """Baja el objeto del bucket. Escribe en .part y renombra al final.

    El rename es lo que importa: vigilante.py escucha `on_moved` justamente
    porque asi es como aparecen los archivos que baja Drive, y ademas evita
    que llegue a ver un archivo a medio escribir.
    """
    url = f"{SUPABASE_URL}/storage/v1/object/{BUCKET}/{urllib.parse.quote(ruta_bucket)}"
    parcial = destino.with_suffix(destino.suffix + ".part")
    req = urllib.request.Request(url, headers=_cabeceras(), method="GET")
    try:
        with urllib.request.urlopen(req, timeout=300) as r, open(parcial, "wb") as f:
            while True:
                trozo = r.read(1024 * 256)
                if not trozo:
                    break
                f.write(trozo)
    except Exception:
        parcial.unlink(missing_ok=True)
        raise
    parcial.replace(destino)
    return True


def borrar_audio(ruta_bucket: str):
    """El bucket es solo transporte: una vez que el audio esta en la carpeta
    (y por lo tanto en Drive, que es donde se guarda de verdad), la copia
    remota no cumple ninguna funcion y ocupa el espacio del plan free."""
    url = f"{SUPABASE_URL}/storage/v1/object/{BUCKET}/{urllib.parse.quote(ruta_bucket)}"
    _pedir(url, "DELETE")


# --------------------------------------------------------------------------
# Paso 1 - bajar audios nuevos a la carpeta vigilada
# --------------------------------------------------------------------------

def bajar_pendientes(estado: dict) -> int:
    try:
        filas = listar_filas("subido")
    except Exception as e:
        log.warning("No se pudo consultar la lista de audios pendientes: %s", e)
        return 0

    bajados = 0
    for fila in filas:
        fid = fila["id"]
        nombre = fila.get("audio_nombre") or f"IRIS-{fid}__consulta.webm"
        destino = CARPETA_VIGILADA / nombre
        try:
            # Si el audio ya esta en la carpeta (o ya se transcribio y se
            # movio a Procesados), no se vuelve a bajar: solo se avanza el
            # estado, que es lo que quedo a medias.
            ya_esta = destino.exists() or (CARPETA_VIGILADA / "Procesados" / nombre).exists()
            if not ya_esta:
                log.info("Bajando audio de %s -> %s", fila.get("paciente_nombre") or "?", nombre)
                descargar_audio(fila["audio_path"], destino)
                mb = destino.stat().st_size / (1024 * 1024)
                log.info("  %.1f MB en la carpeta vigilada (Drive lo sube solo).", mb)
            else:
                log.info("El audio %s ya estaba en la carpeta; solo marco el estado.", nombre)
            actualizar_fila(fid, {"estado": "transcribiendo"})
            estado["bajados"][fid] = {
                "archivo": nombre,
                "fecha": datetime.now().isoformat(timespec="seconds"),
            }
            guardar_estado(estado)
            bajados += 1
            # Recien despues de marcar el estado: si el borrado se hiciera
            # antes y el PATCH fallara, la fila quedaria en 'subido' apuntando
            # a un objeto que ya no existe y el ciclo la reintentaria para
            # siempre. Falla blanda -- que quede un audio de sobra en el
            # bucket es molesto, no grave.
            try:
                borrar_audio(fila["audio_path"])
            except Exception as e:
                log.warning("El audio %s quedo en el bucket (no se pudo borrar): %s", nombre, e)
        except Exception as e:
            log.error("Fallo bajando el audio %s: %s", nombre, e)
            try:
                actualizar_fila(fid, {
                    "estado": "error",
                    "error_mensaje": f"No se pudo bajar el audio al equipo de la clinica: {e}",
                })
            except Exception as e2:
                log.error("Tampoco se pudo marcar el error en la fila %s: %s", fid, e2)
    return bajados


# --------------------------------------------------------------------------
# Paso 2 - extraer el SOIP de las transcripciones nuevas
# --------------------------------------------------------------------------
# extraer_soip.py se importa como modulo y se le pide UN archivo por vez
# (procesar_archivo), en vez de invocarlo por linea de comandos: asi solo se
# procesan los audios que vinieron de la app y no todo lo que haya en la
# carpeta, que cuesta una llamada a la API por archivo.

_cliente_anthropic = None


def cliente_anthropic():
    global _cliente_anthropic
    if _cliente_anthropic is None:
        import anthropic
        cli = anthropic.Anthropic()
        if not cli.api_key and not cli.auth_token:
            raise RuntimeError("falta ANTHROPIC_API_KEY en el entorno")
        _cliente_anthropic = cli
    return _cliente_anthropic


def extraer_pendientes() -> int:
    if not CARPETA_TRANSCRIPCIONES.exists():
        return 0
    import extraer_soip

    hechos = 0
    for ruta in sorted(CARPETA_TRANSCRIPCIONES.glob("IRIS-*.json")):
        if (CARPETA_CONSULTAS / ruta.name).exists():
            continue
        try:
            log.info("Extrayendo el SOIP de %s...", ruta.name)
            if extraer_soip.procesar_archivo(cliente_anthropic(), ruta, False):
                hechos += 1
        except Exception as e:
            log.error("Fallo la extraccion del SOIP de %s: %s", ruta.name, e)
            fid = id_de_archivo(ruta)
            if fid:
                try:
                    actualizar_fila(fid, {
                        "estado": "error",
                        "error_mensaje": f"El audio se transcribio, pero fallo la extraccion del SOIP: {e}",
                    })
                except Exception as e2:
                    log.error("Tampoco se pudo marcar el error en la fila %s: %s", fid, e2)
    return hechos


# --------------------------------------------------------------------------
# Paso 3 - publicar el resultado de vuelta en la app
# --------------------------------------------------------------------------

def id_de_archivo(ruta: Path):
    m = RE_ID.match(ruta.name)
    return m.group(1) if m else None


def publicar_resultados(estado: dict) -> int:
    if not CARPETA_CONSULTAS.exists():
        return 0

    publicados = 0
    for ruta in sorted(CARPETA_CONSULTAS.glob("IRIS-*.json")):
        fid = id_de_archivo(ruta)
        if not fid or fid in estado["publicados"]:
            continue
        try:
            with open(ruta, "r", encoding="utf-8") as f:
                resultado = json.load(f)
        except Exception as e:
            log.error("No se pudo leer %s: %s", ruta.name, e)
            continue

        if not isinstance(resultado, dict) or "campos" not in resultado:
            log.warning("%s no tiene la estructura esperada (falta 'campos'); lo salto.", ruta.name)
            continue

        try:
            actualizar_fila(fid, {"estado": "listo", "resultado": resultado, "error_mensaje": None})
        except urllib.error.HTTPError as e:
            # 404/PGRST116: la fila ya no existe (el veterinario borro la
            # grabacion). Se anota como publicado igual, si no se reintenta
            # en cada vuelta para siempre.
            if e.code in (404, 406):
                log.warning("La consulta %s ya no existe; marco %s como publicado.", fid, ruta.name)
                estado["publicados"][fid] = {"archivo": ruta.name, "fecha": "huerfano"}
                guardar_estado(estado)
            else:
                log.error("Fallo publicando %s: HTTP %s %s", ruta.name, e.code, e.reason)
            continue
        except Exception as e:
            log.error("Fallo publicando %s: %s", ruta.name, e)
            continue

        vitales = len(resultado.get("evidencia_vitales") or {})
        log.info("Publicado %s -> consulta %s [%s, %d/7 vitales]",
                 ruta.name, fid[:8], (resultado.get("campos") or {}).get("motivo") or "sin motivo", vitales)
        estado["publicados"][fid] = {
            "archivo": ruta.name,
            "fecha": datetime.now().isoformat(timespec="seconds"),
        }
        guardar_estado(estado)
        publicados += 1
    return publicados


def marcar_fallidos(estado: dict) -> int:
    """Audios que vigilante.py movio a Fallidos/: la app no puede quedarse
    esperando para siempre un borrador que nunca va a llegar."""
    if not CARPETA_FALLIDOS.exists():
        return 0
    marcados = 0
    for ruta in sorted(CARPETA_FALLIDOS.glob("IRIS-*")):
        fid = id_de_archivo(ruta)
        if not fid or fid in estado["publicados"]:
            continue
        try:
            actualizar_fila(fid, {
                "estado": "error",
                "error_mensaje": "La transcripcion fallo. El audio quedo en la carpeta Fallidos del equipo de la clinica.",
            })
        except Exception as e:
            log.error("No se pudo marcar como fallida la consulta %s: %s", fid, e)
            continue
        estado["publicados"][fid] = {"archivo": ruta.name, "fecha": "fallido"}
        guardar_estado(estado)
        log.warning("Consulta %s marcada como fallida (%s).", fid[:8], ruta.name)
        marcados += 1
    return marcados


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def una_vuelta(estado: dict, extraer: bool):
    bajados = bajar_pendientes(estado)
    extraidos = extraer_pendientes() if extraer else 0
    publicados = publicar_resultados(estado)
    fallidos = marcar_fallidos(estado)
    if bajados or extraidos or publicados or fallidos:
        log.info("Vuelta: %d audio(s) bajado(s), %d SOIP extraido(s), %d publicado(s), %d fallido(s).",
                 bajados, extraidos, publicados, fallidos)


def main():
    parser = argparse.ArgumentParser(description="Puente entre la app IRIS y la carpeta de audios")
    parser.add_argument("--una-vez", action="store_true", help="Una sola pasada y sale")
    parser.add_argument("--sin-extraer", action="store_true",
                        help="No llama a extraer_soip.py (solo baja audios y publica .json ya hechos)")
    args = parser.parse_args()

    configurar_log()

    if not SERVICE_KEY:
        log.error("Falta IRIS_SUPABASE_SERVICE_KEY.")
        log.error("")
        log.error("Es la 'service_role' key del proyecto (Supabase > Project Settings > API).")
        log.error('Configurala con:  setx IRIS_SUPABASE_SERVICE_KEY "eyJ..."')
        log.error("y despues ABRE UNA TERMINAL NUEVA (setx no afecta a la que ya esta abierta).")
        sys.exit(1)

    for carpeta in (CARPETA_VIGILADA, CARPETA_TRANSCRIPCIONES, CARPETA_CONSULTAS):
        carpeta.mkdir(parents=True, exist_ok=True)

    log.info("Puente IRIS en marcha.")
    log.info("  Proyecto: %s", SUPABASE_URL)
    log.info("  Carpeta:  %s", CARPETA_VIGILADA)
    log.info("  Extraccion del SOIP: %s", "no (--sin-extraer)" if args.sin_extraer else "si")
    log.info("Recorda que vigilante.py tiene que estar corriendo aparte: este script")
    log.info("solo mueve archivos y habla con la app, no transcribe.")

    estado = cargar_estado()

    if args.una_vez:
        una_vuelta(estado, not args.sin_extraer)
        log.info("Listo (--una-vez).")
        return

    try:
        while True:
            try:
                una_vuelta(estado, not args.sin_extraer)
            except Exception as e:
                # Una vuelta que revienta no puede matar el puente: el equipo
                # queda desatendido y nadie se entera hasta que un veterinario
                # espera un borrador que nunca llega.
                log.exception("Error inesperado en la vuelta: %s", e)
            time.sleep(INTERVALO_SEG)
    except KeyboardInterrupt:
        log.info("Puente detenido.")


if __name__ == "__main__":
    main()
