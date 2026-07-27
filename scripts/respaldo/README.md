# Respaldos de IRIS

Hay dos mecanismos, uno automático y uno manual. No se reemplazan entre sí.

| | Qué respalda | Cuándo | Dónde queda |
|---|---|---|---|
| **Respaldo automático** (este directorio + `.github/workflows/respaldo-supabase.yml`) | **Toda** la base de datos (las 37 tablas, estructura + datos + políticas RLS + funciones) y **todos** los archivos de Storage (PDFs, firmas, fotos, logos) | Diario 02:10 Colombia, o a demanda | Artifact cifrado del run de GitHub Actions, 90 días |
| **Botón "Descargar respaldo" en la app** (Admin › Respaldo de datos) | Los datos **de un establecimiento** en un `.json` legible (sin los archivos binarios) | Cuando alguien lo pulsa | El PC de quien lo pulsa |

> **Contexto importante:** la organización de Supabase está en plan **free**, que
> **no incluye ningún respaldo administrado** (ni diario ni PITR). Mientras siga
> en free, esto es la única red de seguridad que existe. El plan Pro agrega
> respaldos diarios propios de Supabase con 7 días de retención y quita la pausa
> del proyecto por inactividad.

---

## 1. Configuración inicial (una sola vez)

En GitHub: **Settings › Secrets and variables › Actions › New repository secret**.
Los tres son obligatorios; sin cualquiera de ellos el workflow falla en el
primer paso a propósito, en vez de generar un respaldo a medias.

### `SUPABASE_DB_URL`

Dashboard de Supabase › proyecto **Iriswebapp** › botón **Connect** ›
pestaña **Session pooler** › copiar el URI completo y reemplazar
`[YOUR-PASSWORD]` por la contraseña de la base de datos.

Se usa el *Session pooler* y no la conexión directa porque en el plan free la
conexión directa solo resuelve por IPv6 y los runners de GitHub son IPv4.

Si no recuerdas la contraseña de la base: **Settings › Database › Reset database
password**. Ojo, eso rompe cualquier otra cosa que use esa contraseña (el app
usa la anon key, no esta, así que en principio no afecta a la webapp).

### `SUPABASE_SERVICE_ROLE_KEY`

Dashboard › **Settings › API Keys › service_role**. Hace falta porque los cinco
buckets (`pdfs`, `firmas`, `fotos-mascotas`, `avatars`, `logos-clinica`) son
privados. **Nunca** pongas esta llave en `index.html` ni en ningún archivo del
repo: salta la RLS por completo.

### `BACKUP_GPG_PASSPHRASE`

La inventas tú. Es la contraseña con la que se cifra cada respaldo, y **es la
única forma de abrirlo**: si se pierde, los respaldos son basura irrecuperable.
Guárdala en un gestor de contraseñas, no solo en GitHub.

Genera una larga, por ejemplo:

```bash
openssl rand -base64 32
```

### Verificar que quedó bien

Actions › **Respaldo Supabase (diario)** › **Run workflow**. El resumen del run
muestra la tabla de filas respaldadas sin necesidad de descifrar nada.

---

## 2. Mantenimiento — las tres trampas

1. **Retención de 90 días.** Los artifacts se borran solos a los 90 días. Baja
   una copia cada 2–3 meses y guárdala fuera de GitHub (disco externo, Drive)
   si quieres archivo histórico de largo plazo. Para datos clínicos con
   obligación legal de conservación, esto no es opcional.
2. **GitHub desactiva los cron tras 60 días sin commits** en el repositorio.
   Llega un correo de aviso antes; si pasa, hay que reactivar el workflow a mano
   desde la pestaña Actions. Si el repo tiene semanas quietas, revisa que el
   respaldo siga corriendo.
3. **Fallos silenciosos.** GitHub envía correo al dueño del repo cuando un
   workflow programado falla (Settings › Notifications › *Actions*). Revisa que
   esté activo: un respaldo que dejó de correr y nadie notó es el escenario que
   todo esto intenta evitar.

---

## 3. Restaurar

### Abrir un respaldo

```bash
gpg --output respaldo.zip --decrypt iris-respaldo-20260727-0710.zip.gpg
unzip respaldo.zip
```

Dentro:

```
iris-respaldo-20260727-0710/
├─ manifest.json                    ← filas por tabla, archivos, advertencias
├─ archivos-lista.tsv               ← inventario bucket + ruta
├─ archivos-resumen.json
├─ archivos/<bucket>/<ruta>         ← los archivos reales
└─ base-de-datos/
   ├─ public-completo.dump          ← restauración completa (pg_restore)
   ├─ public-datos.sql              ← un INSERT por fila (recuperación puntual)
   ├─ public-estructura.sql         ← solo estructura, legible
   ├─ conteos.tsv                   ← filas por tabla en el servidor
   ├─ auth-cuentas.sql              ← auth.users / auth.identities (si se pudo)
   └─ storage-metadatos.sql         ← storage.buckets / storage.objects
```

### Caso A — recuperar una fila o una tabla borrada por error

Lo normal. Busca en `public-datos.sql` los `INSERT INTO public.<tabla>` que
necesites y ejecútalos contra la base (SQL Editor del dashboard o `psql`).
Cada fila es un INSERT independiente con los nombres de columna explícitos, así
que se puede copiar una sola.

### Caso B — la base entera se perdió o se corrompió

```bash
# Con la base vigente vacía o recién creada:
pg_restore --dbname "$SUPABASE_DB_URL" \
  --no-owner --clean --if-exists \
  --exit-on-error \
  base-de-datos/public-completo.dump
```

`pg_restore` carga los datos y **después** crea índices y llaves foráneas, así
que no hay problemas de orden entre tablas. Quita `--exit-on-error` si aparecen
errores en objetos que ya existen y quieres continuar de todos modos.

Los GRANT a `anon`/`authenticated` van dentro del dump: sin ellos la app se
conectaría bien y vería todo vacío.

### Caso C — proyecto nuevo desde cero

1. Crear el proyecto en Supabase y apuntar `SUPABASE_URL` / `SUPABASE_ANON_KEY`
   de `index.html` al nuevo.
2. Restaurar como en el caso B.
3. Recrear los buckets (`storage-metadatos.sql` tiene los nombres y su
   configuración) y volver a subir `archivos/<bucket>/...` con la misma ruta
   relativa — la ruta es lo que guardan `documentos.pdf_path`,
   `mascotas.foto_path`, `establecimientos.logo_path`, etc.
4. Las cuentas de usuario son el punto flojo: `auth-cuentas.sql` trae
   `auth.users`, pero recrear la autenticación de un proyecto a otro no es un
   simple INSERT. Si hay que llegar a esto, lo práctico es que los 3 usuarios
   se registren de nuevo y luego apuntar `memberships.user_id` y
   `profiles.id` a los uuid nuevos.

### Probar la restauración antes de necesitarla

Un respaldo no verificado no es un respaldo. Crea un proyecto Supabase gratis
aparte, restaura ahí el último dump y confirma que la app carga contra él.
Media hora una vez vale más que los 90 respaldos que nunca abriste.

---

## 4. Correrlo desde tu PC

Necesitas `pg_dump`/`psql` **17** y Node 18+. En Git Bash:

```bash
export SUPABASE_DB_URL='postgresql://postgres.ayyggymsblvxrrzfjhmw:...@aws-0-us-east-1.pooler.supabase.com:5432/postgres'
export SUPABASE_URL='https://ayyggymsblvxrrzfjhmw.supabase.co'
export SUPABASE_SERVICE_ROLE_KEY='...'
export RESPALDO_DIR="$HOME/respaldos-iris/iris-respaldo-$(date -u +%Y%m%d-%H%M)"

mkdir -p "$RESPALDO_DIR"
bash scripts/respaldo/dump-db.sh
node scripts/respaldo/descargar-storage.mjs
node scripts/respaldo/verificar-respaldo.mjs
```

Elige un `RESPALDO_DIR` **fuera** del repositorio. Si queda adentro, un
`git add .` distraído publica historia clínica en un repo público.

---

## 5. Qué no cubre

- **Archivos borrados entre dos respaldos.** La ventana de pérdida es de hasta
  24 h. Cerrarla requiere PITR, que es plan Pro + add-on.
- **`profiles.foto_url` / `firma_url`** guardan URL, no ruta de bucket; los
  archivos igual se respaldan porque el volcado recorre todos los objetos de
  Storage, no las columnas.
- **Configuración del proyecto Supabase** (plantillas de correo, proveedores de
  auth, secretos de Edge Functions) no está en el dump. Es poca cosa, pero
  anótala aparte si la cambias.
