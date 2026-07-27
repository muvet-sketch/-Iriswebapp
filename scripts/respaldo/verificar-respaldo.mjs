#!/usr/bin/env node
//
// Verifica que el respaldo recién generado sea utilizable y escribe
// $RESPALDO_DIR/manifest.json.
//
// El punto de esto: el modo de falla peligroso de un respaldo automático no es
// que truene (eso se nota), es que suba vacío o truncado durante meses sin que
// nadie lo revise. Acá se compara el volcado contra el conteo real de filas del
// servidor y se falla el job si algo no cuadra.
//
import { createReadStream } from 'node:fs';
import { readFile, stat, writeFile, appendFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { createInterface } from 'node:readline';

const RESPALDO_DIR = process.env.RESPALDO_DIR;
if (!RESPALDO_DIR) {
  console.error('[respaldo] Falta la variable de entorno RESPALDO_DIR');
  process.exit(1);
}

const DB_DIR = join(RESPALDO_DIR, 'base-de-datos');
const errores = [];
const advertencias = [];

// ── 1. Conteos reales del servidor ────────────────────────────────────
let conteos = [];
try {
  const tsv = await readFile(join(DB_DIR, 'conteos.tsv'), 'utf8');
  conteos = tsv
    .split('\n')
    .map(l => l.replace(/\r$/, ''))
    .filter(Boolean)
    .map(linea => {
      const [tabla, filas] = linea.split('\t');
      return { tabla, filas: Number(filas) };
    });
} catch (err) {
  errores.push(`No se pudo leer conteos.tsv: ${err.message}`);
}
if (conteos.length === 0) errores.push('conteos.tsv está vacío: el volcado no vio ninguna tabla');

// ── 2. Volcado binario (el que se usa para restaurar) ─────────────────
let tamanoDump = 0;
try {
  tamanoDump = (await stat(join(DB_DIR, 'public-completo.dump'))).size;
  if (tamanoDump < 10_000) errores.push(`public-completo.dump pesa solo ${tamanoDump} bytes: sospechosamente vacío`);
} catch {
  errores.push('Falta public-completo.dump — sin él no hay restauración completa posible');
}

// ── 3. INSERTs por tabla en el volcado plano vs. conteo real ──────────
const insertsPorTabla = new Map();
let tamanoDatosSql = 0;
try {
  tamanoDatosSql = (await stat(join(DB_DIR, 'public-datos.sql'))).size;
  const rl = createInterface({
    input: createReadStream(join(DB_DIR, 'public-datos.sql'), 'utf8'),
    crlfDelay: Infinity
  });
  const patron = /^INSERT INTO public\.("?)([A-Za-z0-9_]+)\1 /;
  for await (const linea of rl) {
    const m = patron.exec(linea);
    if (m) insertsPorTabla.set(m[2], (insertsPorTabla.get(m[2]) || 0) + 1);
  }
} catch (err) {
  errores.push(`No se pudo leer public-datos.sql: ${err.message}`);
}

const tablas = conteos.map(({ tabla, filas }) => {
  const inserts = insertsPorTabla.get(tabla) || 0;
  let estado = 'ok';
  if (filas > 0 && inserts === 0) {
    // Pérdida real: la tabla tiene datos en el servidor y ninguno quedó en el
    // respaldo.
    errores.push(`Tabla ${tabla}: ${filas} filas en el servidor y 0 INSERT en el respaldo`);
    estado = 'vacía-en-respaldo';
  } else if (filas !== inserts) {
    // Puede ser un falso positivo del conteo por línea (un texto con saltos de
    // línea que empiece igual que un INSERT), así que es advertencia, no error.
    advertencias.push(`Tabla ${tabla}: ${filas} filas en el servidor vs. ${inserts} INSERT en el respaldo`);
    estado = 'descuadre';
  }
  return { tabla, filasServidor: filas, insertsRespaldo: inserts, estado };
});

// ── 4. Archivos de Storage ────────────────────────────────────────────
let archivos = null;
try {
  archivos = JSON.parse(await readFile(join(RESPALDO_DIR, 'archivos-resumen.json'), 'utf8'));
  if (archivos.objetosDescargados !== archivos.objetosEsperados) {
    errores.push(`Storage: se descargaron ${archivos.objetosDescargados} de ${archivos.objetosEsperados} objetos`);
  }
} catch {
  errores.push('Falta archivos-resumen.json — no se respaldaron los archivos de Storage');
}

// ── 5. Volcados opcionales que hayan fallado ──────────────────────────
try {
  for (const f of await readdir(DB_DIR)) {
    if (f.endsWith('.error.log')) {
      advertencias.push(`Volcado opcional fallido: ${f.replace('.error.log', '')} (ver el log dentro del respaldo)`);
    }
  }
} catch { /* ya reportado arriba si el directorio no existe */ }

// ── 6. Manifiesto + resumen ───────────────────────────────────────────
const totalFilas = tablas.reduce((s, t) => s + t.filasServidor, 0);
const manifest = {
  generadoEn: new Date().toISOString(),
  proyectoSupabase: (process.env.SUPABASE_URL || '').replace(/^https?:\/\//, '').split('.')[0] || null,
  commit: process.env.GITHUB_SHA || null,
  ejecucion: process.env.GITHUB_RUN_ID ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}` : null,
  baseDeDatos: { tamanoDumpBytes: tamanoDump, tamanoDatosSqlBytes: tamanoDatosSql, totalFilas, tablas },
  archivos,
  advertencias,
  errores
};
await writeFile(join(RESPALDO_DIR, 'manifest.json'), JSON.stringify(manifest, null, 2));

const conDatos = tablas.filter(t => t.filasServidor > 0);
console.log(`[respaldo] ${conDatos.length} tablas con datos, ${totalFilas} filas en total`);
console.log(`[respaldo] dump binario: ${(tamanoDump / 1048576).toFixed(2)} MB`);
if (archivos) console.log(`[respaldo] archivos: ${archivos.objetosDescargados}/${archivos.objetosEsperados}`);
advertencias.forEach(a => console.warn(`[respaldo] AVISO: ${a}`));
errores.forEach(e => console.error(`[respaldo] ERROR: ${e}`));

if (process.env.GITHUB_STEP_SUMMARY) {
  const lineas = [
    '## Respaldo IRIS',
    '',
    `- Filas respaldadas: **${totalFilas}** en ${conDatos.length} tablas`,
    `- Volcado binario: **${(tamanoDump / 1048576).toFixed(2)} MB**`,
    archivos ? `- Archivos de Storage: **${archivos.objetosDescargados}/${archivos.objetosEsperados}** (${(archivos.bytesTotales / 1048576).toFixed(2)} MB)` : '- Archivos de Storage: **no respaldados**',
    '',
    '| Tabla | Filas en servidor | INSERT en respaldo |',
    '| --- | --: | --: |',
    ...conDatos.map(t => `| ${t.tabla} | ${t.filasServidor} | ${t.insertsRespaldo} |`)
  ];
  if (advertencias.length) lineas.push('', '### Advertencias', ...advertencias.map(a => `- ${a}`));
  if (errores.length) lineas.push('', '### Errores', ...errores.map(e => `- ${e}`));
  await appendFile(process.env.GITHUB_STEP_SUMMARY, lineas.join('\n') + '\n');
}

if (errores.length > 0) process.exit(1);
