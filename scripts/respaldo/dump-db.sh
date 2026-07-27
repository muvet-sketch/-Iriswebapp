#!/usr/bin/env bash
#
# Vuelca la base de datos de Supabase a $RESPALDO_DIR/base-de-datos/.
#
# Requiere:
#   SUPABASE_DB_URL  URI de conexión (Dashboard > Connect > Session pooler).
#   RESPALDO_DIR     carpeta destino (se crea si no existe).
#
# Requiere pg_dump/psql de PostgreSQL **17** en el PATH: pg_dump aborta si su
# versión es menor que la del servidor, y el servidor es 17.x.
#
set -euo pipefail

: "${SUPABASE_DB_URL:?Falta SUPABASE_DB_URL (Dashboard > Connect > Session pooler)}"
: "${RESPALDO_DIR:?Falta RESPALDO_DIR}"

DEST="$RESPALDO_DIR/base-de-datos"
mkdir -p "$DEST"

echo "==> Versión del servidor"
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -Atc 'select version()' \
  | tee "$DEST/version-servidor.txt"

# Conteo EXACTO de filas por tabla (no n_live_tup, que es una estimación del
# planner). Es la referencia contra la que verificar-respaldo.mjs comprueba que
# el volcado no salió vacío ni truncado — un respaldo vacío que se sube sin
# error es peor que no tener respaldo.
echo "==> Conteo exacto de filas por tabla (schema public)"
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -At -F $'\t' -c "
select table_name,
       (xpath('/row/c/text()',
              query_to_xml(format('select count(*) as c from public.%I', table_name),
                           false, true, '')))[1]::text::bigint
  from information_schema.tables
 where table_schema = 'public' and table_type = 'BASE TABLE'
 order by table_name;
" > "$DEST/conteos.tsv"
echo "    tablas contadas: $(wc -l < "$DEST/conteos.tsv")"

# Inventario de archivos de Storage. Los archivos NO viven en Postgres (están
# en S3), así que pg_dump por sí solo no los respalda: esta lista es la entrada
# de descargar-storage.mjs, que sí baja el contenido.
echo "==> Inventario de objetos de Storage"
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -At -F $'\t' -c "
select bucket_id, name from storage.objects order by bucket_id, name;
" > "$RESPALDO_DIR/archivos-lista.tsv"
echo "    objetos listados: $(wc -l < "$RESPALDO_DIR/archivos-lista.tsv")"

# 1) Volcado binario de public (estructura + datos). Es el que se usa para una
#    restauración completa con pg_restore, y el único que conserva tipos,
#    índices, constraints y funciones tal como están HOY en el servidor —
#    importante porque supabase/schema.sql está incompleto (le faltan
#    formulas_medicas, ventas_facturas y ventas_cotizaciones).
#
#    Se usa --no-owner (el dueño de las tablas cambia entre proyectos) pero NO
#    --no-privileges: los GRANT a anon/authenticated son justamente lo que
#    permite que PostgREST lea las tablas, y los revoke/grant de las funciones
#    red_* son parte del modelo de seguridad (ver CLAUDE.md). Sin ellos, un
#    proyecto restaurado tendría todos los datos y la app los vería vacíos.
echo "==> pg_dump public (formato custom, estructura + datos)"
pg_dump "$SUPABASE_DB_URL" \
  --schema=public --no-owner \
  --format=custom --compress=9 \
  --file="$DEST/public-completo.dump"

# 2) Los mismos datos en SQL plano con un INSERT por fila y nombres de columna
#    explícitos: permite recuperar UNA tabla o UNA fila puntual sin restaurar
#    todo, y abrir el respaldo con un editor de texto para leerlo a ojo.
#    NO sirve para restaurar la base entera de una sola pasada: un volcado
#    --data-only no garantiza el orden entre tablas con llaves foráneas. Para
#    eso está public-completo.dump, donde pg_restore crea las FK después de
#    cargar los datos.
echo "==> pg_dump public (datos en SQL plano, un INSERT por fila)"
pg_dump "$SUPABASE_DB_URL" \
  --schema=public --data-only --column-inserts \
  --file="$DEST/public-datos.sql"

# 3) Estructura sola, legible — para diferenciarla contra supabase/schema.sql.
echo "==> pg_dump public (solo estructura)"
pg_dump "$SUPABASE_DB_URL" \
  --schema=public --schema-only --no-owner \
  --file="$DEST/public-estructura.sql"

# 4) Cuentas de usuario (auth) y metadatos de Storage.
#    Best-effort a propósito: el rol del pooler puede no tener lectura sobre
#    esos schemas según cómo esté configurado el proyecto, y en ese caso NO se
#    aborta el respaldo porque lo crítico (public + los archivos) ya está.
#    El fallo queda registrado en un .error.log y verificar-respaldo.mjs lo
#    reporta como advertencia.
dump_opcional() {
  local etiqueta="$1"; shift
  local salida="$1"; shift
  echo "==> pg_dump opcional: $etiqueta"
  if pg_dump "$SUPABASE_DB_URL" --no-owner --no-privileges "$@" \
       --file="$salida" 2> "$salida.error.log"; then
    rm -f "$salida.error.log"
  else
    echo "    !! falló ($etiqueta) — queda $(basename "$salida").error.log" >&2
    rm -f "$salida"
  fi
}

dump_opcional "cuentas de auth" "$DEST/auth-cuentas.sql" \
  --data-only --table=auth.users --table=auth.identities

dump_opcional "metadatos de storage" "$DEST/storage-metadatos.sql" \
  --data-only --table=storage.buckets --table=storage.objects

echo "==> Base de datos volcada en $DEST"
ls -l "$DEST"
