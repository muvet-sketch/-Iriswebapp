"""
Transcripcion de consulta -> SOIP estructurado para el formulario de IRIS.

Paso 2 del flujo: audio -> transcripcion -> [ESTE PASO] -> formulario IRIS.

Lee los .json que deja vigilante.py en Transcripciones/ y produce, por cada uno,
un .json en Consultas/ con exactamente los campos del Tablero de trabajo:
motivo, S/O/I/P, los 7 signos vitales y los hallazgos por sistema.

Uso:
    set ANTHROPIC_API_KEY=...          (o usar `ant auth login`)
    python extraer_soip.py             # procesa lo pendiente
    python extraer_soip.py --rehacer   # reprocesa todo, incluso lo ya hecho
    python extraer_soip.py --archivo Transcripciones/consulta.json

Requisitos: anthropic, pydantic.
"""

import argparse
import json
import os
import re
import sys
import unicodedata
from datetime import datetime
from pathlib import Path
from typing import List, Optional

import anthropic
from pydantic import BaseModel, Field

from vocabulario_clinico import glosario_para_llm

# --------------------------------------------------------------------------
# Configuracion
# --------------------------------------------------------------------------

CARPETA_BASE = Path(
    os.environ.get(
        "IRIS_AUDIO_DIR",
        r"C:\Users\Admin\Documents\Nanimals\Audios Consultas",
    )
)
CARPETA_TRANSCRIPCIONES = CARPETA_BASE / "Transcripciones"
CARPETA_CONSULTAS = CARPETA_BASE / "Consultas"

MODELO = os.environ.get("IRIS_MODELO_LLM", "claude-opus-5")

# Contrato con el formulario (index.html). Si cambian alla, cambian aca:
#   motivo   -> opciones del select #tablero-soap-motivo
#   sistemas -> EXAM_SYSTEMS
MOTIVOS = ["Consulta general", "Urgencia", "Vacunación", "Control", "Revisión", "Otro"]
SISTEMAS = [
    "Cardiovascular", "Respiratorio", "Digestivo", "Urinario", "Reproductivo",
    "Musculoesquelético", "Nervioso", "Piel y anexos", "Ojos", "Oídos",
]


# --------------------------------------------------------------------------
# Esquema de salida
# --------------------------------------------------------------------------
#
# Cada signo vital viene con la CITA TEXTUAL del audio de donde salio. No es
# decorativo: mas abajo se verifica que esa cita exista de verdad en la
# transcripcion, y si no aparece el valor se descarta. Un signo vital inventado
# seria un dato clinico falso en la historia de un paciente real.

class VitalNumerico(BaseModel):
    valor: Optional[float] = Field(
        description="El numero dicho en el audio, o null si nadie lo dijo. Nunca estimar."
    )
    cita: Optional[str] = Field(
        description="Fragmento LITERAL de la transcripcion donde se dice este valor. "
                    "null si valor es null. Copiar palabra por palabra, sin corregir."
    )


class VitalTexto(BaseModel):
    valor: Optional[str] = Field(
        description="El valor dicho en el audio, o null si nadie lo dijo."
    )
    cita: Optional[str] = Field(
        description="Fragmento LITERAL de la transcripcion. null si valor es null."
    )


class SignosVitales(BaseModel):
    temp: VitalNumerico = Field(description="Temperatura rectal en grados Celsius")
    fc: VitalNumerico = Field(description="Frecuencia cardiaca en latidos por minuto")
    fr: VitalNumerico = Field(description="Frecuencia respiratoria en respiraciones por minuto")
    crt: VitalTexto = Field(description="Tiempo de llenado capilar, texto libre (ej: '< 2s')")
    pas: VitalNumerico = Field(description="Presion arterial sistolica en mmHg")
    pad: VitalNumerico = Field(description="Presion arterial diastolica en mmHg")
    pam: VitalNumerico = Field(description="Presion arterial media en mmHg")


class HallazgoSistema(BaseModel):
    sistema: str = Field(description=f"Uno de: {', '.join(SISTEMAS)}")
    estado: str = Field(description="'Normal' o 'Alterado'")
    detalle: str = Field(description="Si es Alterado, que se encontro. Si es Normal, cadena vacia.")


class ConsultaExtraida(BaseModel):
    paciente_mencionado: Optional[str] = Field(
        description="Nombre de la mascota si se dice en el audio, si no null."
    )
    propietario_mencionado: Optional[str] = Field(
        description="Nombre del propietario si se dice en el audio, si no null."
    )
    motivo: str = Field(description=f"Exactamente uno de: {', '.join(MOTIVOS)}")
    subjetivo: str = Field(
        description="Anamnesis: lo que relata el propietario, duracion de los signos, "
                    "medicamentos dados en casa, cambios de comportamiento/apetito. "
                    "TERCERA persona (regla 9): el sujeto es el tutor o el paciente, "
                    "nunca el veterinario. Ej: 'El tutor refiere que el paciente "
                    "vomita desde hace dos dias'."
    )
    objetivo: str = Field(
        description="Hallazgos del examen fisico dichos por el veterinario. "
                    "NO incluir los signos vitales numericos, esos van aparte. "
                    "PRIMERA persona (regla 9). Ej: 'Encuentro mucosas palidas y "
                    "dolor a la palpacion abdominal'."
    )
    interpretacion: str = Field(
        description="Diagnostico presuntivo o definitivo y diferenciales. "
                    "Si en el audio no se dice ninguno, cadena vacia. "
                    "PRIMERA persona (regla 9). Ej: 'Considero una gastroenteritis "
                    "aguda; descarto cuerpo extrano'."
    )
    diagnosticos_presuntivos: List[str] = Field(
        default_factory=list,
        description="Lista de diagnosticos presuntivos o diferenciales identificados en el audio (ej: ['Otitis externa', 'Gastroenteritis aguda'])."
    )
    plan: str = Field(
        description="Plan terapeutico, procedimientos, proximo control, recomendaciones. "
                    "Si no se dice, cadena vacia. "
                    "PRIMERA persona (regla 9). Ej: 'Indico meloxicam por tres dias "
                    "y cito a control en una semana'."
    )
    vitales: SignosVitales
    examen_sistemas: List[HallazgoSistema] = Field(
        description="SOLO los sistemas que se mencionan explicitamente en el audio. "
                    "Lista vacia si no se menciona ninguno. Los que no esten aqui "
                    "quedan como 'No evaluado' en el formulario."
    )
    terminos_normalizados: List[str] = Field(
        default_factory=list,
        description="Cada correccion hecha con el glosario (regla 8), en formato "
                    "'lo que se oyo -> termino correcto'. Lista vacia si no hubo."
    )
    revision_requerida: bool = Field(
        description="true si el audio es confuso, esta incompleto, o algo quedo dudoso."
    )
    notas_revision: str = Field(
        description="Que deberia revisar el veterinario antes de guardar. Vacio si nada."
    )


# --------------------------------------------------------------------------
# Prompt
# --------------------------------------------------------------------------

SYSTEM = f"""Eres un asistente clinico veterinario. Recibes la transcripcion automatica
del audio de una consulta veterinaria real, en espanol de Colombia, y la conviertes al
formato SOIP (Subjetivo / Objetivo / Interpretacion / Plan) para llenar la historia
clinica.

REGLAS QUE NO PUEDES ROMPER:

1. Solo puedes escribir lo que se dice en el audio. No completes, no deduzcas
   diagnosticos, no agregues dosis, no rellenes con lo tipico del caso. Este texto
   va a la historia clinica de un paciente real y lo firma un veterinario.

2. Signos vitales: escribe un numero SOLO si alguien lo dice explicitamente en la
   transcripcion. Si no se menciona, el valor va en null. No estimes a partir de la
   especie, del cuadro clinico ni de lo que seria normal. Un vital que nadie midio
   tiene que quedar en null.

3. Por cada vital con valor, copia en 'cita' el fragmento LITERAL de la transcripcion
   donde aparece, palabra por palabra, sin corregir la ortografia ni la gramatica.
   Esa cita se verifica automaticamente contra la transcripcion: si no coincide, el
   valor se descarta. Si no puedes citarlo textualmente, el valor debe ser null.

4. examen_sistemas: incluye unicamente los sistemas que el veterinario menciona haber
   revisado. No agregues los demas: los que falten quedan como "No evaluado".

5. La transcripcion viene de un audio grabado con el celular sobre la mesa y tiene
   errores de reconocimiento. Si una frase es ininteligible o ambigua, NO adivines:
   deja el campo como puedas, pon revision_requerida en true y explica en
   notas_revision que parte quedo dudosa.

6. La interpretacion y el plan son obligatorios en el formulario, pero si en el audio
   no se dicen, dejalos vacios y marca revision_requerida. Es preferible que el
   veterinario los escriba a que tu los inventes.

7. Escribe en espanol, en prosa clinica breve. No uses vinetas ni encabezados.

8. La transcripcion suele escribir MAL los nombres de medicamentos, productos y
   terminos clinicos (ej. "melo si can" por "meloxicam", "trau mil" por
   "Traumeel"). Al final tienes un GLOSARIO con los nombres correctos. Si una
   palabra de la transcripcion es foneticamente cercana a un termino del
   glosario Y el contexto clinico coincide, escribela con el nombre correcto y
   registra el cambio en terminos_normalizados como "lo que se oyo -> termino
   correcto". Si hay duda razonable entre dos terminos posibles, NO corrijas:
   deja lo que se oyo, marca revision_requerida y explicalo en notas_revision.
   El glosario sirve unicamente para reconocer lo que ya se dijo en el audio —
   nunca para agregar medicamentos, dosis o diagnosticos que no se
   mencionaron. Y las citas de los vitales siguen la regla 3: LITERALES,
   nunca corrijas el texto dentro de 'cita'.

9. PERSONA GRAMATICAL. Quien firma la historia clinica es el veterinario, asi que
   escribe como si el la estuviera redactando:
   - Objetivo, Interpretacion y Plan van en PRIMERA persona del singular, el
     veterinario hablando de lo que el mismo hizo, encontro o decidio:
     "Encuentro mucosas palidas", "Considero una gastroenteritis aguda",
     "Indico meloxicam por tres dias y cito a control en una semana".
     No escribas "se observa", "se recomienda" ni "el veterinario indica".
   - Subjetivo va en TERCERA persona, refiriendote al tutor y al paciente:
     "El tutor refiere que el paciente vomita desde hace dos dias y que le dio
     un medicamento en casa". El sujeto ahi nunca es el veterinario.
   - En el audio el veterinario y el tutor se tutean y hablan en desorden
     (segunda persona, plural, etc.). Reescribe lo que se dijo a la persona que
     corresponde a cada campo; eso es reformular, no inventar: el contenido
     sigue siendo unicamente lo que se dice en el audio (regla 1).
   - Si en el audio se dice el nombre de la mascota, usalo en el Subjetivo en
     vez de "el paciente". Si no se dice, escribe "el paciente" — no inventes
     un nombre.
   - Las citas literales de los vitales (regla 3) NO se tocan: van tal cual se
     oyeron, sin cambiar la persona.

Motivos validos (usa exactamente uno): {', '.join(MOTIVOS)}
Sistemas validos: {', '.join(SISTEMAS)}

--- GLOSARIO DE VOCABULARIO CLINICO (para la regla 8) ---
{glosario_para_llm()}"""


def construir_prompt(payload: dict) -> str:
    lineas = [
        "Transcripcion de la consulta.",
        f"Archivo de audio: {payload.get('archivo_audio', 'desconocido')}",
        f"Duracion: {payload.get('duracion_audio_seg', '?')} segundos",
        "",
        "--- TRANSCRIPCION ---",
        payload.get("texto", ""),
        "--- FIN ---",
        "",
        "Convierte esto al formato SOIP siguiendo las reglas.",
    ]
    return "\n".join(lineas)


# --------------------------------------------------------------------------
# Verificacion de citas
# --------------------------------------------------------------------------

def normalizar(texto: str) -> str:
    """Quita acentos, signos y espacios de mas para comparar de forma tolerante."""
    if not texto:
        return ""
    t = unicodedata.normalize("NFD", texto.lower())
    t = "".join(c for c in t if unicodedata.category(c) != "Mn")
    t = re.sub(r"[^a-z0-9 ]+", " ", t)
    return re.sub(r"\s+", " ", t).strip()


def cita_valida(cita: Optional[str], transcripcion_norm: str) -> bool:
    """
    La cita tiene que aparecer de verdad en la transcripcion. Es la unica defensa
    real contra un numero inventado: pedirle al modelo que no invente ayuda, pero
    no lo garantiza. Comprobarlo si.
    """
    if not cita or not cita.strip():
        return False
    c = normalizar(cita)
    if len(c) < 4:          # una cita de 2 caracteres coincide con cualquier cosa
        return False
    return c in transcripcion_norm


def depurar_vitales(consulta: ConsultaExtraida, transcripcion: str) -> List[str]:
    """
    Anula los vitales cuya cita no aparece en la transcripcion.
    Devuelve la lista de descartes para avisar al usuario.
    """
    trans_norm = normalizar(transcripcion)
    descartados = []
    for campo in ("temp", "fc", "fr", "crt", "pas", "pad", "pam"):
        vital = getattr(consulta.vitales, campo)
        if vital.valor is None:
            continue
        if not cita_valida(vital.cita, trans_norm):
            descartados.append(f"{campo}={vital.valor} (cita no verificable: {vital.cita!r})")
            vital.valor = None
            vital.cita = None
    return descartados


def depurar_sistemas(consulta: ConsultaExtraida) -> List[str]:
    """Descarta hallazgos con nombre de sistema o estado fuera del catalogo."""
    validos, descartados = [], []
    for h in consulta.examen_sistemas:
        if h.sistema not in SISTEMAS:
            descartados.append(f"sistema desconocido: {h.sistema!r}")
            continue
        if h.estado not in ("Normal", "Alterado"):
            descartados.append(f"estado invalido en {h.sistema}: {h.estado!r}")
            continue
        validos.append(h)
    consulta.examen_sistemas = validos
    return descartados


# --------------------------------------------------------------------------
# Extraccion
# --------------------------------------------------------------------------

def extraer(client: anthropic.Anthropic, payload: dict) -> tuple[Optional[ConsultaExtraida], List[str]]:
    avisos = []
    respuesta = client.messages.parse(
        model=MODELO,
        max_tokens=16000,
        system=SYSTEM,
        messages=[{"role": "user", "content": construir_prompt(payload)}],
        output_format=ConsultaExtraida,
    )

    if respuesta.stop_reason == "refusal":
        detalle = getattr(respuesta, "stop_details", None)
        categoria = getattr(detalle, "category", None) if detalle else None
        avisos.append(f"El modelo rechazo la solicitud (categoria: {categoria}).")
        return None, avisos

    if respuesta.stop_reason == "max_tokens":
        avisos.append("La respuesta se corto por max_tokens; puede estar incompleta.")

    consulta = respuesta.parsed_output
    if consulta is None:
        avisos.append("La respuesta no se pudo validar contra el esquema.")
        return None, avisos

    if consulta.motivo not in MOTIVOS:
        avisos.append(f"Motivo fuera del catalogo ({consulta.motivo!r}); se usa 'Otro'.")
        consulta.motivo = "Otro"

    descartes_v = depurar_vitales(consulta, payload.get("texto", ""))
    if descartes_v:
        avisos.append("Vitales descartados por cita no verificable: " + "; ".join(descartes_v))

    descartes_s = depurar_sistemas(consulta)
    if descartes_s:
        avisos.append("Hallazgos descartados: " + "; ".join(descartes_s))

    return consulta, avisos


def a_formato_formulario(consulta: ConsultaExtraida, payload: dict, avisos: List[str]) -> dict:
    """
    Estructura final. Las claves de 'campos' son los ids del Tablero sin el prefijo
    'tablero-soap-', que es el contrato con guardarConsulta() en index.html.
    """
    v = consulta.vitales
    return {
        "origen": {
            "archivo_audio": payload.get("archivo_audio"),
            "transcrito_en": payload.get("transcrito_en"),
            "modelo_transcripcion": payload.get("modelo"),
        },
        "extraido_en": datetime.now().isoformat(timespec="seconds"),
        "modelo_extraccion": MODELO,
        "paciente_mencionado": consulta.paciente_mencionado,
        "propietario_mencionado": consulta.propietario_mencionado,
        "campos": {
            "motivo": consulta.motivo,
            "s": consulta.subjetivo,
            "o": consulta.objetivo,
            "i": consulta.interpretacion,
            "diagnosticos_presuntivos": consulta.diagnosticos_presuntivos,
            "p": consulta.plan,
            # null = no evaluado. guardarConsulta() los guarda como null y no
            # dejan rastro en la consulta, que es justo lo que se pidio.
            "vital-temp": v.temp.valor,
            "vital-fc": v.fc.valor,
            "vital-fr": v.fr.valor,
            "vital-crt": v.crt.valor,
            "vital-pas": v.pas.valor,
            "vital-pad": v.pad.valor,
            "vital-pam": v.pam.valor,
        },
        "examen_sistemas": [
            {"sistema": h.sistema, "estado": h.estado, "detalle": h.detalle}
            for h in consulta.examen_sistemas
        ],
        "evidencia_vitales": {
            campo: getattr(v, campo).cita
            for campo in ("temp", "fc", "fr", "crt", "pas", "pad", "pam")
            if getattr(v, campo).valor is not None
        },
        # Correcciones hechas con el glosario de vocabulario_clinico.py
        # ("lo que se oyo -> termino correcto"), para que el veterinario
        # pueda auditar cada nombre que el modelo normalizo.
        "terminos_normalizados": consulta.terminos_normalizados,
        # Viaja como campo propio y no dentro de avisos_automaticos porque el
        # front lo pinta primero y en rojo: es lo que explica por que el resto
        # del borrador viene pobre, y perdido entre los demas avisos no se lee.
        "calidad_audio": payload.get("calidad_audio"),
        "revision_requerida": consulta.revision_requerida or bool(avisos) or bool(payload.get("calidad_audio")),
        "notas_revision": consulta.notas_revision,
        "avisos_automaticos": avisos,
    }


def aviso_calidad_audio(payload: dict) -> Optional[str]:
    """
    El aviso que vigilante.py dejo en el .json cuando el audio llego casi mudo
    (celular con la pantalla bloqueada durante la consulta). Viaja hasta
    'avisos_automaticos', que index.html ya pinta en la previsualizacion: sin
    esto el veterinario ve un borrador de dos frases y no sabe que el problema
    fue el microfono y no la consulta.
    """
    calidad = payload.get("calidad_audio")
    if not isinstance(calidad, dict) or not calidad.get("mensaje"):
        return None
    # Sin guion largo ni comillas tipograficas: este aviso tambien se imprime
    # por consola y en Windows sys.stdout es cp1252, donde esos caracteres
    # revientan con UnicodeEncodeError (y el puente marcaria la fila en error).
    return (
        "El microfono capto muy poco: " + calidad["mensaje"] +
        ". El borrador solo cubre esa parte; revisa toda la consulta antes de guardarla."
    )


def salida_sin_extraccion(payload: dict, avisos: List[str]) -> dict:
    """
    Resultado vacio pero VALIDO para un audio del que no hay nada que extraer.
    Hace falta porque puente_iris.py solo publica lo que encuentra en
    Consultas/: sin este .json la fila se quedaba en 'transcribiendo' para
    siempre y el navegador mostraba "Transcribiendo..." sin fin.
    """
    return {
        "origen": {
            "archivo_audio": payload.get("archivo_audio"),
            "transcrito_en": payload.get("transcrito_en"),
            "modelo_transcripcion": payload.get("modelo"),
        },
        "extraido_en": datetime.now().isoformat(timespec="seconds"),
        "modelo_extraccion": None,
        "paciente_mencionado": None,
        "propietario_mencionado": None,
        "campos": {
            "motivo": "Otro", "s": "", "o": "", "i": "",
            "diagnosticos_presuntivos": "", "p": "",
            "vital-temp": None, "vital-fc": None, "vital-fr": None,
            "vital-crt": None, "vital-pas": None, "vital-pad": None,
            "vital-pam": None,
        },
        "examen_sistemas": [],
        "evidencia_vitales": {},
        "terminos_normalizados": [],
        "calidad_audio": payload.get("calidad_audio"),
        "revision_requerida": True,
        "notas_revision": "No se pudo extraer nada del audio.",
        "avisos_automaticos": avisos,
    }


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def procesar_archivo(client, ruta: Path, rehacer: bool) -> bool:
    destino = CARPETA_CONSULTAS / ruta.name
    if destino.exists() and not rehacer:
        print(f"  [ya hecho] {ruta.name}")
        return False

    with open(ruta, "r", encoding="utf-8") as f:
        payload = json.load(f)

    aviso_audio = aviso_calidad_audio(payload)

    texto = (payload.get("texto") or "").strip()
    if len(texto) < 40:
        print(f"  [sin contenido] {ruta.name}: transcripcion demasiado corta ({len(texto)} caracteres)")
        avisos = [] if aviso_audio else [
            "El audio no trajo palabras suficientes para armar un borrador. "
            "Revisa que el microfono estuviera captando."
        ]
        CARPETA_CONSULTAS.mkdir(parents=True, exist_ok=True)
        with open(destino, "w", encoding="utf-8") as f:
            json.dump(salida_sin_extraccion(payload, avisos), f, ensure_ascii=False, indent=2)
        for a in ([aviso_audio] if aviso_audio else []) + avisos:
            print(f"    ! {a}")
        return True

    print(f"  Extrayendo SOIP de {ruta.name} ({len(texto)} caracteres)...")
    consulta, avisos = extraer(client, payload)
    if consulta is None:
        for a in avisos:
            print(f"    ! {a}")
        return False

    if aviso_audio:
        print(f"    ! {aviso_audio}")

    salida = a_formato_formulario(consulta, payload, avisos)
    CARPETA_CONSULTAS.mkdir(parents=True, exist_ok=True)
    with open(destino, "w", encoding="utf-8") as f:
        json.dump(salida, f, ensure_ascii=False, indent=2)

    vitales_con_valor = len(salida["evidencia_vitales"])
    print(f"    -> {destino.name}  [motivo: {salida['campos']['motivo']}, "
          f"{vitales_con_valor}/7 vitales, {len(salida['examen_sistemas'])} sistemas]")
    for t in salida["terminos_normalizados"]:
        print(f"    ~ Glosario: {t}")
    for a in avisos:
        print(f"    ! {a}")
    if salida["revision_requerida"]:
        print(f"    * Requiere revision: {salida['notas_revision'] or '(ver avisos)'}")
    return True


def main():
    parser = argparse.ArgumentParser(description="Transcripcion -> SOIP para IRIS")
    parser.add_argument("--rehacer", action="store_true",
                        help="Reprocesa tambien las transcripciones ya extraidas")
    parser.add_argument("--archivo", help="Procesa un solo .json de transcripcion")
    args = parser.parse_args()

    # Anthropic() NO falla al construirse sin credenciales: el error aparece
    # recien en la primera llamada, con un mensaje que no dice que falta la key.
    # Por eso se chequea aca de forma explicita.
    client = anthropic.Anthropic()
    if not client.api_key and not client.auth_token:
        print("Falta la credencial de la API de Anthropic.")
        print()
        print("Configura la variable de entorno ANTHROPIC_API_KEY con tu clave:")
        print('    setx ANTHROPIC_API_KEY "sk-ant-..."')
        print()
        print("Despues ABRE UNA TERMINAL NUEVA (setx no afecta a la que ya esta abierta)")
        print("y vuelve a ejecutar este script.")
        sys.exit(1)

    if args.archivo:
        rutas = [Path(args.archivo)]
    else:
        if not CARPETA_TRANSCRIPCIONES.exists():
            print(f"No existe {CARPETA_TRANSCRIPCIONES}. Corre primero vigilante.py.")
            sys.exit(1)
        rutas = sorted(CARPETA_TRANSCRIPCIONES.glob("*.json"))

    if not rutas:
        print("No hay transcripciones para procesar.")
        return

    print(f"Transcripciones: {CARPETA_TRANSCRIPCIONES}")
    print(f"Salida:          {CARPETA_CONSULTAS}")
    print(f"Modelo:          {MODELO}")
    print(f"{len(rutas)} archivo(s) a revisar.\n")

    hechos = 0
    for ruta in rutas:
        try:
            if procesar_archivo(client, ruta, args.rehacer):
                hechos += 1
        except anthropic.RateLimitError:
            print(f"  ! Limite de peticiones alcanzado en {ruta.name}. Reintenta mas tarde.")
            break
        except anthropic.APIStatusError as e:
            print(f"  ! Error de la API en {ruta.name} ({e.status_code}): {e.message}")
        except anthropic.APIConnectionError as e:
            print(f"  ! Sin conexion con la API en {ruta.name}: {e}")
            break
        except Exception as e:
            print(f"  ! Error inesperado en {ruta.name}: {e}")

    print(f"\nListo. {hechos} consulta(s) nueva(s) en {CARPETA_CONSULTAS}")


if __name__ == "__main__":
    main()
