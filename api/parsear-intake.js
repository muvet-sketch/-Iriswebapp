// Vercel Serverless Function (Node.js) — POST /api/parsear-intake
//
// Respaldo del parser por etiquetas de "Importar desde WhatsApp" (index.html).
// Recibe el texto crudo que el tutor respondió por WhatsApp y devuelve los
// datos del tutor y de sus mascotas ya separados en campos. Solo se llama
// cuando el parser determinista del navegador NO reconoció lo suficiente
// (respuesta en prosa, campos desordenados, plantilla no respetada); si el
// cliente llenó la plantilla tal cual, esto nunca se invoca.
//
// El resultado NO se guarda en ninguna parte: viaja de vuelta al navegador y
// precarga los mismos formularios de registro de siempre, que un humano
// revisa y confirma. Ver la sección "Importar tutor + mascotas desde WhatsApp"
// de CLAUDE.md.
//
// Usa fetch nativo de Node 18+, sin dependencias — mismo patrón que
// api/send-email.js. La salida estructurada se fuerza con tool use
// (tool_choice), que es el equivalente sin SDK de messages.parse(...) que usa
// scripts/transcripcion/extraer_soip.py.

const ANTHROPIC_ENDPOINT = 'https://api.anthropic.com/v1/messages';
const ANTHROPIC_VERSION = '2023-06-01';

// Sonnet alcanza de sobra para separar en campos un mensaje de WhatsApp corto.
// extraer_soip.py usa Opus porque aquello es una historia clínica; esto son
// datos de contacto que además un humano revisa antes de guardarlos.
const MODELO_POR_DEFECTO = 'claude-sonnet-5';

// Un mensaje de intake normal ronda los 400 caracteres. El tope está para que
// pegar un chat entero por accidente no se convierta en una factura.
const MAX_CARACTERES = 8000;

// El esquema es deliberadamente "crudo": cada campo es el texto TAL COMO lo
// escribió el cliente. La conversión a los valores exactos de los <select> del
// formulario (Canino/Felino, Hembra/Macho, Esterilizado/...) la hace el
// navegador con los normalizadores intakeNormalizar*, que son los mismos que
// usa el parser por etiquetas — un solo lugar de verdad para esa tabla.
const ESQUEMA_INTAKE = {
  type: 'object',
  properties: {
    tutor: {
      type: 'object',
      description: 'Datos de la persona responsable. null en cada campo que el mensaje no diga.',
      properties: {
        nombre: { type: ['string', 'null'], description: 'Nombre completo de la persona (no de la mascota)' },
        doc_tipo: { type: ['string', 'null'], description: 'Tipo de documento si se menciona: C.C., C.E., NIT, T.I., Pasaporte, PEP' },
        doc_numero: { type: ['string', 'null'], description: 'Número de cédula o documento, solo los dígitos tal como aparecen' },
        movil: { type: ['string', 'null'], description: 'Teléfono celular / WhatsApp tal como aparece en el mensaje' },
        email: { type: ['string', 'null'], description: 'Correo electrónico' },
        direccion: { type: ['string', 'null'], description: 'Dirección de residencia' },
        ciudad: { type: ['string', 'null'], description: 'Ciudad o municipio' }
      },
      required: ['nombre', 'doc_tipo', 'doc_numero', 'movil', 'email', 'direccion', 'ciudad']
    },
    mascotas: {
      type: 'array',
      description: 'Una entrada por cada animal mencionado. Array vacío si el mensaje no habla de ninguno.',
      items: {
        type: 'object',
        properties: {
          nombre: { type: ['string', 'null'], description: 'Nombre del animal' },
          especie: { type: ['string', 'null'], description: 'Especie tal como la escribió el cliente (perro, gato, conejo...)' },
          raza: { type: ['string', 'null'], description: 'Raza. null si el cliente no la dice — NO la deduzcas de la especie' },
          color: { type: ['string', 'null'], description: 'Color del pelaje' },
          peso_kg: { type: ['string', 'null'], description: 'Peso tal como aparece, con su unidad si la trae' },
          fecha_nacimiento: { type: ['string', 'null'], description: 'Fecha de nacimiento tal como aparece en el mensaje' },
          edad_texto: { type: ['string', 'null'], description: 'Edad tal como aparece (ej. "3 años", "8 meses"). Independiente de fecha_nacimiento' },
          sexo: { type: ['string', 'null'], description: 'Sexo tal como aparece. null si no se dice — NO lo deduzcas del nombre' },
          esterilizado: { type: ['string', 'null'], description: 'Respuesta sobre esterilización/castración tal como aparece' },
          microchip: { type: ['string', 'null'], description: 'Número de microchip, o la respuesta sí/no tal como aparece' },
          alergias: { type: ['string', 'null'], description: 'Alergias mencionadas' },
          antecedentes: { type: ['string', 'null'], description: 'Antecedentes médicos, cirugías o enfermedades mencionadas' }
        },
        required: ['nombre', 'especie', 'raza', 'color', 'peso_kg', 'fecha_nacimiento',
                   'edad_texto', 'sexo', 'esterilizado', 'microchip', 'alergias', 'antecedentes']
      }
    }
  },
  required: ['tutor', 'mascotas']
};

// Mismas reglas duras del SYSTEM de scripts/transcripcion/extraer_soip.py: en
// un flujo de intake, un dato inventado es peor que un campo vacío — el campo
// vacío se ve y se pregunta, el inventado se guarda y queda como identidad.
const SYSTEM = `Eres un asistente de una clínica veterinaria en Colombia. Recibes el mensaje
de WhatsApp con el que un tutor responde al formulario de registro, y lo separas en campos.

Reglas que no puedes romper:
1. NO inventes ningún dato. Si el mensaje no lo dice, el campo va en null.
2. Copia los valores TAL COMO los escribió el cliente. No corrijas, no traduzcas,
   no conviertas unidades ni formatos de fecha. Otra parte del sistema se encarga de eso.
3. No deduzcas la raza a partir de la especie, ni el sexo a partir del nombre del animal
   o de la terminación de una palabra. Si no está escrito, es null.
4. El nombre del tutor es el de la persona; el nombre de la mascota es el del animal.
   No los mezcles aunque el mensaje sea confuso.
5. Si el mensaje habla de varios animales, devuelve una entrada por cada uno.
   Si habla de uno solo, devuelve un array de un elemento.
6. Si el mensaje es la plantilla en blanco (etiquetas sin valores), devuelve todo en null
   y el array de mascotas vacío.
7. Un dato dudoso va en null. Un campo vacío se pregunta; un dato inventado se guarda.`;

function textoDelMensaje(body) {
  const texto = body && typeof body.texto === 'string' ? body.texto : '';
  return texto.trim();
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') {
    res.status(405).json({ ok: false, error: 'Método no permitido, usa POST' });
    return;
  }

  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    // El navegador degrada a lo que sacó el parser por etiquetas — no se
    // bloquea el registro por esto.
    res.status(500).json({ ok: false, error: 'ANTHROPIC_API_KEY no está configurada en las variables de entorno' });
    return;
  }

  const texto = textoDelMensaje(req.body);
  if (!texto) {
    res.status(400).json({ ok: false, error: 'Falta el texto del mensaje' });
    return;
  }
  if (texto.length > MAX_CARACTERES) {
    res.status(413).json({ ok: false, error: `El texto supera los ${MAX_CARACTERES} caracteres — pega solo la respuesta del tutor, no la conversación completa` });
    return;
  }

  const modelo = process.env.IRIS_MODELO_INTAKE || MODELO_POR_DEFECTO;

  try {
    const respuesta = await fetch(ANTHROPIC_ENDPOINT, {
      method: 'POST',
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': ANTHROPIC_VERSION,
        'content-type': 'application/json'
      },
      body: JSON.stringify({
        model: modelo,
        max_tokens: 2000,
        temperature: 0,
        system: SYSTEM,
        tools: [{
          name: 'registrar_intake',
          description: 'Entrega los datos del tutor y de sus mascotas separados en campos.',
          input_schema: ESQUEMA_INTAKE
        }],
        // Fuerza la herramienta: garantiza salida estructurada sin tener que
        // parsear texto libre ni pedirle al modelo que "responda solo JSON".
        tool_choice: { type: 'tool', name: 'registrar_intake' },
        messages: [{
          role: 'user',
          content: `Mensaje recibido del tutor:\n\n<mensaje>\n${texto}\n</mensaje>`
        }]
      })
    });

    const data = await respuesta.json();
    if (!respuesta.ok) {
      const detalle = data && data.error && data.error.message ? data.error.message : 'error de la API';
      res.status(respuesta.status).json({ ok: false, error: detalle });
      return;
    }

    const bloque = Array.isArray(data.content)
      ? data.content.find(c => c.type === 'tool_use' && c.name === 'registrar_intake')
      : null;
    if (!bloque || !bloque.input) {
      res.status(502).json({ ok: false, error: 'La interpretación no devolvió datos utilizables' });
      return;
    }

    const datos = bloque.input;
    res.status(200).json({
      ok: true,
      datos: {
        tutor: datos.tutor || {},
        mascotas: Array.isArray(datos.mascotas) ? datos.mascotas : []
      },
      modelo
    });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
};
