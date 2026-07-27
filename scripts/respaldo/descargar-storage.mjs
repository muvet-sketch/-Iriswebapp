#!/usr/bin/env node
//
// Descarga el CONTENIDO de todos los objetos de Supabase Storage a
// $RESPALDO_DIR/archivos/<bucket>/<ruta>.
//
// pg_dump no cubre esto: los archivos (PDFs de documentos, firmas, fotos de
// mascotas, logos) viven en S3, no en Postgres. Sin este paso el respaldo
// tendría las filas que apuntan a los archivos pero no los archivos.
//
// Requiere:
//   RESPALDO_DIR                  carpeta del respaldo, con archivos-lista.tsv
//                                 ya generado por dump-db.sh
//   SUPABASE_URL                  https://<ref>.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY     todos los buckets son privados
//
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';

const RESPALDO_DIR = process.env.RESPALDO_DIR;
const SUPABASE_URL = (process.env.SUPABASE_URL || '').replace(/\/+$/, '');
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

for (const [nombre, valor] of Object.entries({ RESPALDO_DIR, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY: SERVICE_KEY })) {
  if (!valor) {
    console.error(`[respaldo] Falta la variable de entorno ${nombre}`);
    process.exit(1);
  }
}

const listaPath = join(RESPALDO_DIR, 'archivos-lista.tsv');
let lista;
try {
  lista = await readFile(listaPath, 'utf8');
} catch {
  console.error(`[respaldo] No existe ${listaPath} — corre primero dump-db.sh`);
  process.exit(1);
}

const objetos = lista
  .split('\n')
  .map(l => l.replace(/\r$/, ''))
  .filter(Boolean)
  .map(linea => {
    const sep = linea.indexOf('\t');
    return { bucket: linea.slice(0, sep), ruta: linea.slice(sep + 1) };
  })
  .filter(o => o.bucket && o.ruta);

console.log(`[respaldo] ${objetos.length} objetos por descargar`);

const destinoRaiz = resolve(join(RESPALDO_DIR, 'archivos'));
await mkdir(destinoRaiz, { recursive: true });

// Las rutas vienen de la base de datos, así que se tratan como entrada no
// confiable: un nombre con ".." escribiría fuera de la carpeta del respaldo.
function destinoSeguro(bucket, ruta) {
  const destino = resolve(join(destinoRaiz, bucket, ruta));
  if (destino !== destinoRaiz && !destino.startsWith(destinoRaiz + (process.platform === 'win32' ? '\\' : '/'))) {
    return null;
  }
  return destino;
}

function urlDeObjeto(bucket, ruta) {
  const rutaCodificada = ruta.split('/').map(encodeURIComponent).join('/');
  return `${SUPABASE_URL}/storage/v1/object/${encodeURIComponent(bucket)}/${rutaCodificada}`;
}

const espera = ms => new Promise(r => setTimeout(r, ms));

async function descargar(bucket, ruta) {
  const destino = destinoSeguro(bucket, ruta);
  if (!destino) throw new Error(`ruta sospechosa, no se descarga: ${bucket}/${ruta}`);

  let ultimoError;
  for (let intento = 1; intento <= 3; intento++) {
    try {
      const res = await fetch(urlDeObjeto(bucket, ruta), {
        headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` }
      });
      if (!res.ok) throw new Error(`HTTP ${res.status} ${res.statusText}`);
      const bytes = Buffer.from(await res.arrayBuffer());
      if (bytes.length === 0) throw new Error('respuesta vacía (0 bytes)');
      await mkdir(dirname(destino), { recursive: true });
      await writeFile(destino, bytes);
      return bytes.length;
    } catch (err) {
      ultimoError = err;
      if (intento < 3) await espera(intento * 1500);
    }
  }
  throw ultimoError;
}

let ok = 0;
let bytesTotales = 0;
const fallidos = [];

for (const { bucket, ruta } of objetos) {
  try {
    bytesTotales += await descargar(bucket, ruta);
    ok++;
  } catch (err) {
    fallidos.push({ bucket, ruta, error: String(err.message || err) });
    console.error(`[respaldo] FALLÓ ${bucket}/${ruta}: ${err.message || err}`);
  }
}

const resumen = {
  generadoEn: new Date().toISOString(),
  objetosEsperados: objetos.length,
  objetosDescargados: ok,
  bytesTotales,
  fallidos
};
await writeFile(join(RESPALDO_DIR, 'archivos-resumen.json'), JSON.stringify(resumen, null, 2));

console.log(`[respaldo] descargados ${ok}/${objetos.length} objetos (${(bytesTotales / 1048576).toFixed(2)} MB)`);

// Un archivo que no se pudo bajar es pérdida real de información en el
// respaldo: se falla el job para que llegue la notificación, en vez de dejar
// un respaldo incompleto que parece correcto.
if (fallidos.length > 0) {
  console.error(`[respaldo] ${fallidos.length} objeto(s) no se pudieron descargar`);
  process.exit(1);
}
