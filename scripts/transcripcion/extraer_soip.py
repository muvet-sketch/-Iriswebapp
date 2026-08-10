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
# Espeja CATALOGO_ESPECIALIDADES en index.html. Es una lista de referencia, no
# una restriccion: el multiselect del Plan acepta escribir una personalizada, y
# aca tampoco se descarta una especialidad fuera de la lista.
ESPECIALIDADES = [
    "Gastroenterología", "Dermatología", "Ortopedia", "Neurología", "Etología",
    "Cardiología", "Oftalmología", "Oncología", "Medicina interna",
    "Nefrología/Urología", "Endocrinología", "Reproducción", "Odontología",
    "Anestesiología", "Fisioterapia y rehabilitación", "Imagenología",
]

# A que campo del formulario apunta cada duda pendiente (ver Verificacion).
# 'paciente' no es un campo del Tablero: marca la verificacion de identidad,
# que se resuelve mirando la ficha abierta, no escribiendo en un input.
CAMPOS_VERIFICABLES = [
    "motivo", "s", "o", "i", "p",
    "vital-temp", "vital-fc", "vital-fr", "vital-crt",
    "vital-pas", "vital-pad", "vital-pam",
    "diagnosticos", "examen-sistemas", "problemas",
    "examenes", "especialidad", "paciente",
]

# 'bloqueante' = sin resolverlo no se deberia cerrar la consulta.
SEVERIDADES = ["bloqueante", "importante", "menor"]
GRAVEDADES = ["critico", "mayor", "menor"]

# Como maximo esto en una consulta: una lista de 20 preguntas no se revisa,
# se ignora entera. Si sobran, se recortan por severidad (ver depurar_verificaciones).
MAX_VERIFICACIONES = 8


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


# Todo lo que quedo dudoso sale POR ACA, nunca dentro del texto clinico. Es el
# canal que reemplaza a las frases tipo "no se entiende con claridad" que antes
# terminaban escritas en la historia (ver regla 5). El front las pinta como una
# lista accionable al lado del formulario: por eso 'campo' tiene que apuntar al
# input concreto que hay que revisar, y no vale un valor inventado.

class Verificacion(BaseModel):
    campo: str = Field(
        description=f"A que campo del formulario apunta la duda. Uno de: {', '.join(CAMPOS_VERIFICABLES)}"
    )
    pregunta: str = Field(
        description="Que tiene que confirmar el veterinario, en imperativo y en una linea. "
                    "Ej: 'Confirmar el nombre del medicamento indicado para la piel'. "
                    "NO menciones el audio, la grabacion ni la transcripcion."
    )
    contexto: str = Field(
        description="Lo que si quedo claro y ayuda a resolverlo, en pocas palabras. "
                    "Aca SI puedes citar entre comillas lo que se oyo, porque este texto "
                    "no entra a la historia clinica. Cadena vacia si no aporta nada."
    )
    opciones: List[str] = Field(
        default_factory=list,
        description="Hasta 4 respuestas concretas que se puedan aplicar TAL CUAL al campo, si las "
                    "hay (dos medicamentos del glosario foneticamente parecidos, el numero que "
                    "creiste oir en un vital, una opcion del catalogo de motivos). Vacia si no hay."
    )
    severidad: str = Field(
        description=f"Uno de: {', '.join(SEVERIDADES)}. 'bloqueante' solo si sin resolverlo no se "
                    "puede cerrar la consulta (interpretacion o plan vacios, identidad del "
                    "paciente sin confirmar, un vital que puede estar mal asignado)."
    )


class Problema(BaseModel):
    texto: str = Field(
        description="El problema clinico en 2-6 palabras, como se escribe en un listado de "
                    "problemas. Ej: 'Hiporexia de dos semanas', 'Dolor abdominal en mesogastrio', "
                    "'Hipertension arterial'. Es un problema, NO un diagnostico deducido."
    )
    gravedad: str = Field(
        description="'critico' si compromete la vida del paciente ahora, 'mayor' si es "
                    "relevante pero no compromete la vida de inmediato, 'menor' el resto."
    )


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
                    "Prosa clinica, redactada por el veterinario. Prohibido mencionar el audio."
    )
    objetivo: str = Field(
        description="Hallazgos del examen fisico dichos por el veterinario. "
                    "NO incluir los signos vitales numericos, esos van aparte. "
                    "Prosa clinica, redactada por el veterinario. Prohibido mencionar el audio."
    )
    interpretacion: str = Field(
        description="Diagnostico presuntivo o definitivo y diferenciales. "
                    "Si no se dice ninguno, cadena vacia — nunca un texto explicando por que."
    )
    diagnosticos_presuntivos: List[str] = Field(
        default_factory=list,
        description="Lista de diagnosticos presuntivos o diferenciales identificados en el audio (ej: ['Otitis externa', 'Gastroenteritis aguda'])."
    )
    plan: str = Field(
        description="Plan terapeutico, procedimientos, proximo control, recomendaciones. "
                    "Si no se dice, cadena vacia. Los examenes solicitados y la remision a "
                    "especialidad van ADEMAS en sus campos propios."
    )
    examenes_solicitados: List[str] = Field(
        default_factory=list,
        description="Examenes de laboratorio o imagenes diagnosticas que se piden en la consulta, "
                    "uno por elemento (ej: ['Hemograma completo', 'Uroanalisis']). Lista vacia si no se pide ninguno."
    )
    especialidades_indicadas: List[str] = Field(
        default_factory=list,
        description=f"Especialidad(es) a la(s) que se remite al paciente, si se menciona alguna. "
                    f"Preferir estos nombres: {', '.join(ESPECIALIDADES)}. Lista vacia si no hay remision."
    )
    problemas: List[Problema] = Field(
        default_factory=list,
        description="Listado de problemas del paciente, ORDENADO de mayor a menor compromiso "
                    "vital: el primero es el que mas compromete la vida. Solo signos y hallazgos "
                    "realmente dichos en la consulta. Lista vacia si no hay ninguno claro."
    )
    verificaciones: List[Verificacion] = Field(
        default_factory=list,
        description="Un elemento por cada dato que quedo dudoso o que hay que confirmar. "
                    "Este es el UNICO lugar donde se registra una duda: nunca dentro de S/O/I/P."
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

0. EN 'subjetivo', 'objetivo', 'interpretacion' Y 'plan' NO EXISTE LA GRABACION.
   Esos cuatro campos se imprimen en la historia clinica de un paciente real y los
   firma un veterinario. Escribelos como los escribiria el veterinario despues de
   la consulta, no como alguien que escucho un audio. Quien los lee es un colega
   dentro de un ano que no sabe que hubo una grabacion.
   Prohibido dentro de esos cuatro campos:
     - las palabras audio, grabacion, transcripcion, microfono, ininteligible;
     - las formulas "se oye", "se escucha", "no se entiende", "no se alcanza a",
       "no queda claro", "no se precisa", "no permite precisar";
     - citar entre comillas lo que sono en la grabacion;
     - frases de relleno como "sin contenido", "no se menciona", "no se registro
       informacion". Si no hay contenido, el campo va como cadena VACIA.
   Lo que no entendiste NO se menciona en el texto clinico: se OMITE del texto y
   se emite como un elemento de 'verificaciones'. Ese es el unico canal para la
   duda. Ejemplo de lo que NO debes escribir: "presenta un episodio que en el
   audio no se entiende con claridad ('narrea narrea')". Lo correcto es escribir
   la parte que si entendiste ("presenta un episodio al orinar en la arena") y
   abrir una verificacion preguntando que tipo de episodio fue.

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
   errores de reconocimiento. Si una frase es ininteligible o ambigua, NO adivines
   y NO la describas: omitela del texto clinico (regla 0) y abre una verificacion
   con la pregunta concreta que resuelve la duda. Ademas pon revision_requerida en
   true y resume en notas_revision en UNA linea.

6. La interpretacion y el plan son obligatorios en el formulario, pero si en el audio
   no se dicen, dejalos como cadena VACIA (nunca un texto explicando que faltan) y
   abre una verificacion de severidad 'bloqueante' en el campo 'i' o 'p'. Es
   preferible que el veterinario los escriba a que tu los inventes.

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

9. PRESION ARTERIAL. Cuando se dicten varios valores de presion seguidos, la
   sistolica (PAS) es SIEMPRE el valor mas alto, la diastolica (PAD) el mas bajo y
   la media (PAM) el intermedio. Nunca al reves: ese orden lo impone la mecanica de
   fluidos del sistema cardiovascular y no admite excepciones. Ante "las presiones
   estan en 150 125 100", asigna pas=150, pam=125, pad=100 aunque no se diga cual es
   cual. Con solo dos valores, el mayor es pas y el menor pad; no inventes la media.

10. 'verificaciones': un elemento por cada dato que el veterinario tenga que
   confirmar o completar. 'pregunta' se escribe como pregunta o instruccion clinica
   directa ("Precisar que tipo de dificultad presenta al orinar"), NUNCA como reporte
   de la grabacion ("no se entiende que tipo de dificultad"). En 'contexto' si puedes
   citar entre comillas lo que sono, porque ese texto no entra a la historia clinica.
   Maximo {MAX_VERIFICACIONES} elementos: prioriza por severidad.

11. 'problemas': el listado de problemas del paciente, ORDENADO de mayor a menor
   compromiso vital. El primero tiene que ser el que puede matarlo hoy; el ultimo el
   menos urgente. Son problemas (signos, hallazgos, alteraciones), no diagnosticos
   deducidos: "Hiporexia de dos semanas" si, "Insuficiencia renal cronica" solo si el
   veterinario la nombro. Lista vacia si el audio no permite listar ninguno con
   claridad.

12. 'examenes_solicitados' y 'especialidades_indicadas': unicamente lo que se pide de
   forma explicita en la consulta. Nunca sugieras un examen ni una remision que nadie
   menciono. Si se pide "muestra de sangre y de orina", eso son dos examenes.

Motivos validos (usa exactamente uno): {', '.join(MOTIVOS)}
Sistemas validos: {', '.join(SISTEMAS)}
Campos a los que puede apuntar una verificacion: {', '.join(CAMPOS_VERIFICABLES)}
Severidades validas: {', '.join(SEVERIDADES)}
Gravedades validas de un problema: {', '.join(GRAVEDADES)}
Especialidades sugeridas (puedes salir de la lista si se nombra otra): {', '.join(ESPECIALIDADES)}

--- GLOSARIO DE VOCABULARIO CLINICO (para la regla 8) ---
{glosario_para_llm()}"""


def construir_prompt(payload: dict) -> str:
    # A proposito NO se pasan el nombre del archivo ni la duracion del audio.
    # Encuadraban la tarea como "estas leyendo una grabacion" y era parte de por
    # que el modelo terminaba narrando la grabacion dentro del texto clinico
    # (ver regla 0). El nombre del archivo ya viaja por el stem del fichero, que
    # es el contrato con puente_iris.py — el modelo no necesita verlo.
    lineas = [
        "Lo que se hablo durante la consulta:",
        "",
        "--- INICIO ---",
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


def ordenar_presiones(consulta: ConsultaExtraida) -> List[str]:
    """
    Deja PAS >= PAM >= PAD reasignando por MAGNITUD.

    La sistolica es siempre la mas alta, la diastolica la mas baja y la media la
    intermedia: lo impone la mecanica de fluidos del sistema cardiovascular y no
    se invierte nunca. Pero al dictar se dicen los tres numeros seguidos y sin
    rotulo ("las presiones estan en 150 125 100"), asi que el modelo reparte a
    ciegas. Antes de esto quedaba PAS 150 y las otras dos vacias.

    Corre DESPUES de depurar_vitales(): los valores sin cita verificable ya son
    None y no participan.

    Invariante: la cita viaja con el VALOR, no con la casilla. Si el 100 se mueve
    de pas a pad, se lleva su cita — la cita es lo que prueba que ese numero se
    dijo, y dejarla en la casilla vieja convertiria la verificacion en decorado.
    """
    v = consulta.vitales
    presentes = [c for c in ("pas", "pam", "pad") if getattr(v, c).valor is not None]
    if len(presentes) < 2:
        return []

    # Orden canonico descendente, restringido a las casillas que traen valor.
    destinos = [c for c in ("pas", "pam", "pad") if c in presentes]
    antes = {c: getattr(v, c).valor for c in destinos}
    valores = sorted(
        ((getattr(v, c).valor, getattr(v, c).cita) for c in destinos),
        key=lambda par: par[0],
        reverse=True,
    )
    for campo, (valor, cita) in zip(destinos, valores):
        vital = getattr(v, campo)
        vital.valor = valor
        vital.cita = cita

    if all(antes[c] == getattr(v, c).valor for c in destinos):
        return []

    detalle = " · ".join(f"{c.upper()} {getattr(v, c).valor}" for c in destinos)
    return [f"Presiones reasignadas por magnitud (la mas alta es la sistolica): {detalle}."]


def ordenar_problemas(consulta: ConsultaExtraida) -> None:
    """
    Red de seguridad del orden por compromiso vital. El prompt ya pide la lista
    ordenada, pero el orden es justamente lo que el cliente necesita que sea
    correcto siempre, asi que se reordena por gravedad con un sort ESTABLE: dentro
    de una misma gravedad manda el criterio del modelo. Gravedad desconocida al final.
    """
    consulta.problemas.sort(
        key=lambda p: GRAVEDADES.index(p.gravedad) if p.gravedad in GRAVEDADES else len(GRAVEDADES)
    )


# Rastros de la grabacion que nunca pueden quedar en la historia clinica. El
# prompt (regla 0) los prohibe, pero pedirselo al modelo ayuda y no garantiza:
# esto es lo que lo garantiza. Mismo criterio que intakeVerificarContraTexto()
# en index.html — la instruccion propone, la comprobacion dispone.
RE_META_AUDIO = re.compile(
    r"\b("
    r"audios?|grabaci|transcri|micr[oó]fonos?|inintelig|inaudible"
    r"|se (?:oye|escucha|alcanza)|no se (?:oye|escucha|entiende|entienden|precisa|alcanza)"
    r"|no queda claro|no permite precisar|sin contenido|no se menciona"
    r"|no se registr|no se especifica"
    r")",
    re.IGNORECASE,
)

# Corta en el punto final, conservando el separador para poder recomponer.
RE_ORACION = re.compile(r"[^.;]+[.;]?\s*")

# El comentario sobre la grabacion suele venir entre parentesis, colgado de un
# hallazgo que SI es clinico: "compromiso en mesogastrio (en el audio se oye
# 'prensa abdominal', no se entiende si es dolor o tension)". Quitar el
# parentesis salva el hallazgo; tirar la oracion entera lo perderia.
RE_PARENTESIS = re.compile(r"\s*\(([^()]*)\)")


def limpiar_prosa_clinica(texto: str) -> tuple[str, List[str]]:
    """
    Devuelve (texto limpio, fragmentos quitados).

    Dos pasadas, en este orden y por este motivo:
      1. Se quitan los PARENTESIS que hablan de la grabacion. Es el envase
         habitual de la meta-narracion y casi siempre cuelga de un hallazgo
         clinico valido que hay que conservar.
      2. De lo que queda se descartan las ORACIONES todavia contaminadas (el
         comentario venia incrustado en la sintaxis y no se puede separar).
    Trabajar por oracion y no por campo evita que una frase mala cueste todo el
    contenido bueno que la acompana. Si no sobrevive nada, devuelve cadena vacia
    — que es lo que pide la regla 0 para un campo sin contenido, en vez de un
    "no se registro informacion".

    Los fragmentos quitados NO se tiran: alimentan el 'contexto' de la
    verificacion, que es donde el veterinario si puede leerlos.
    """
    if not texto or not texto.strip():
        return "", []

    quitados = []

    def _parentesis(m):
        if RE_META_AUDIO.search(m.group(1)):
            quitados.append(m.group(1).strip())
            return ""
        return m.group(0)

    texto = RE_PARENTESIS.sub(_parentesis, texto)

    oraciones = RE_ORACION.findall(texto) or [texto]
    limpias = []
    for oracion in oraciones:
        if RE_META_AUDIO.search(oracion):
            quitados.append(oracion.strip())
            continue
        limpias.append(oracion)

    limpio = re.sub(r"\s+", " ", "".join(limpias)).strip()
    # Un parentesis quitado deja " ." o " ,": se pega la puntuacion al texto.
    limpio = re.sub(r"\s+([.,;])", r"\1", limpio)
    return limpio, [q for q in quitados if q]


def depurar_prosa(consulta: ConsultaExtraida) -> List[str]:
    """
    Aplica limpiar_prosa_clinica() a los 4 campos que se imprimen y abre una
    verificacion por cada campo tocado: si se quito una frase, ahi habia una duda
    real que el veterinario tiene que resolver — solo que no puede quedar escrita.
    """
    etiquetas = {"subjetivo": ("s", "Subjetivo"), "objetivo": ("o", "Objetivo"),
                 "interpretacion": ("i", "Interpretacion"), "plan": ("p", "Plan")}
    avisos = []
    for atributo, (campo, label) in etiquetas.items():
        original = getattr(consulta, atributo) or ""
        limpio, quitados = limpiar_prosa_clinica(original)
        if not quitados and limpio == original.strip():
            continue
        setattr(consulta, atributo, limpio)
        avisos.append(f"{label}: se quito texto que hablaba de la grabacion.")
        consulta.verificaciones.append(Verificacion(
            campo=campo,
            pregunta=f"Completar {label}: hay un dato que quedo sin precisar.",
            # Lo quitado se le muestra al veterinario ACA y solo aca: es lo que
            # le permite resolver la duda sin volver a escuchar el audio, y este
            # texto no entra a la historia clinica.
            contexto=" / ".join(quitados)[:400],
            opciones=[],
            severidad="bloqueante" if campo in ("i", "p") and not limpio else "importante",
        ))
    return avisos


def depurar_verificaciones(consulta: ConsultaExtraida) -> List[str]:
    """
    Valida, deduplica y recorta la lista de verificaciones.

    Corre AL FINAL de la cadena de depuracion: los pasos anteriores (prosa,
    presiones) agregan elementos y este es el que los ve todos.
    """
    descartados, vistas, validas = [], set(), []
    for ver in consulta.verificaciones:
        if ver.campo not in CAMPOS_VERIFICABLES:
            descartados.append(f"campo desconocido: {ver.campo!r}")
            continue
        if not ver.pregunta or not ver.pregunta.strip():
            continue
        if ver.severidad not in SEVERIDADES:
            ver.severidad = "importante"
        # La pregunta tampoco puede narrar la grabacion: se lee en pantalla al
        # lado del formulario y es lo primero que ve el veterinario.
        if RE_META_AUDIO.search(ver.pregunta):
            ver.pregunta = limpiar_prosa_clinica(ver.pregunta)[0] or "Revisar y completar este dato."
        clave = (ver.campo, normalizar(ver.pregunta))
        if clave in vistas:
            continue
        vistas.add(clave)
        ver.opciones = [o.strip() for o in ver.opciones if o and o.strip()][:4]
        validas.append(ver)

    validas.sort(key=lambda v: SEVERIDADES.index(v.severidad))
    if len(validas) > MAX_VERIFICACIONES:
        descartados.append(f"{len(validas) - MAX_VERIFICACIONES} verificaciones de menor severidad")
        validas = validas[:MAX_VERIFICACIONES]
    consulta.verificaciones = validas
    return descartados


def depurar_listas_plan(consulta: ConsultaExtraida) -> None:
    """
    Normaliza examenes y especialidades: sin espacios de mas, sin duplicados
    (ignorando mayusculas y acentos) y con un tope razonable. NO se filtra contra
    el catalogo: un examen dicho en la consulta que no este en la lista sigue
    siendo valido, y el multiselect del Plan acepta valores personalizados.
    """
    def limpiar(items: List[str]) -> List[str]:
        salida, vistos = [], set()
        for it in items:
            texto = re.sub(r"\s+", " ", (it or "")).strip()
            if not texto:
                continue
            clave = normalizar(texto)
            if clave in vistos:
                continue
            vistos.add(clave)
            salida.append(texto)
        return salida[:10]

    consulta.examenes_solicitados = limpiar(consulta.examenes_solicitados)
    consulta.especialidades_indicadas = limpiar(consulta.especialidades_indicadas)

    validos = []
    for p in consulta.problemas:
        texto = re.sub(r"\s+", " ", (p.texto or "")).strip()
        if not texto:
            continue
        p.texto = texto
        if p.gravedad not in GRAVEDADES:
            p.gravedad = "menor"
        validos.append(p)
    consulta.problemas = validos[:12]


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

    # El orden de esta cadena importa y no es intercambiable:
    #   1. depurar_vitales   descarta los numeros sin cita verificable
    #   2. ordenar_presiones despues, para no reordenar numeros que van a morir
    #   3. depurar_prosa     puede AGREGAR verificaciones
    #   4. depurar_verificaciones al FINAL: es quien deduplica y recorta, y tiene
    #      que ver tambien las que agregaron los pasos anteriores.
    descartes_v = depurar_vitales(consulta, payload.get("texto", ""))
    if descartes_v:
        avisos.append("Vitales descartados por cita no verificable: " + "; ".join(descartes_v))

    reasignadas = ordenar_presiones(consulta)
    if reasignadas:
        avisos.extend(reasignadas)
        # Reasignar por magnitud es una conjetura solida, no un hecho dicho en la
        # consulta: va al canal de verificacion como todo lo demas.
        consulta.verificaciones.append(Verificacion(
            campo="vital-pas",
            pregunta="Confirmar la asignacion de las presiones (sistolica, media y diastolica).",
            contexto=reasignadas[0],
            opciones=[],
            severidad="importante",
        ))

    descartes_s = depurar_sistemas(consulta)
    if descartes_s:
        avisos.append("Hallazgos descartados: " + "; ".join(descartes_s))

    avisos.extend(depurar_prosa(consulta))
    depurar_listas_plan(consulta)
    ordenar_problemas(consulta)

    descartes_ver = depurar_verificaciones(consulta)
    if descartes_ver:
        avisos.append("Verificaciones descartadas: " + "; ".join(descartes_ver))

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
        # formato 2 = con verificaciones/problemas estructurados. El front sigue
        # aceptando los .json de formato 1 (los que ya estan en la carpeta de la
        # oficina) cayendo a notas_revision.
        "formato": 2,
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
            # Campos propios del recuadro del Plan (multiselect de chips), mismo
            # criterio que diagnosticos_presuntivos: son campos del formulario.
            "examenes_solicitados": consulta.examenes_solicitados,
            "especialidades_indicadas": consulta.especialidades_indicadas,
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
        # Listado de problemas, YA priorizado por compromiso vital (el primero es
        # el que mas compromete la vida). No va dentro de "campos" porque no es un
        # campo del formulario de consulta: alimenta la Lista de problemas del
        # paciente, que es un registro aparte y persistente.
        "problemas": [
            {"texto": p.texto, "gravedad": p.gravedad}
            for p in consulta.problemas
        ],
        # El unico canal de la duda. Todo lo que antes se colaba en el texto
        # clinico ("no se entiende con claridad...") sale por aca, apuntando al
        # campo del formulario que hay que revisar.
        "verificaciones": [
            {
                "campo": ver.campo,
                "pregunta": ver.pregunta,
                "contexto": ver.contexto,
                "opciones": ver.opciones,
                "severidad": ver.severidad,
            }
            for ver in consulta.verificaciones
        ],
        "revision_requerida": consulta.revision_requerida or bool(avisos) or bool(consulta.verificaciones),
        "notas_revision": consulta.notas_revision,
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

    texto = (payload.get("texto") or "").strip()
    if len(texto) < 40:
        print(f"  [omitido] {ruta.name}: transcripcion demasiado corta ({len(texto)} caracteres)")
        return False

    print(f"  Extrayendo SOIP de {ruta.name} ({len(texto)} caracteres)...")
    consulta, avisos = extraer(client, payload)
    if consulta is None:
        for a in avisos:
            print(f"    ! {a}")
        return False

    salida = a_formato_formulario(consulta, payload, avisos)
    CARPETA_CONSULTAS.mkdir(parents=True, exist_ok=True)
    with open(destino, "w", encoding="utf-8") as f:
        json.dump(salida, f, ensure_ascii=False, indent=2)

    vitales_con_valor = len(salida["evidencia_vitales"])
    bloqueantes = sum(1 for v in salida["verificaciones"] if v["severidad"] == "bloqueante")
    print(f"    -> {destino.name}  [motivo: {salida['campos']['motivo']}, "
          f"{vitales_con_valor}/7 vitales, {len(salida['examen_sistemas'])} sistemas, "
          f"{len(salida['problemas'])} problemas, "
          f"{len(salida['verificaciones'])} verificaciones ({bloqueantes} bloqueantes)]")
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
