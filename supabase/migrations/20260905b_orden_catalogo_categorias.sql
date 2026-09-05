-- ════════════════════════════════════════════════════════════════
-- Conexión entre Inventario > Productos y servicios y el Catálogo de
-- Órdenes, POR CATEGORÍA.
--
-- El problema: muchos ítems de tipo servicio del inventario son
-- literalmente lo mismo que se elige en Consultorio > Órdenes
-- ("Ecografía abdominal", "Hemograma completo"). Con los dos catálogos
-- separados había que escribirlos dos veces, y en producción ya hay 508
-- servicios en una sola categoría — transcribirlos a mano al catálogo de
-- órdenes no es una opción.
--
-- Se vincula por CATEGORÍA y no ítem por ítem: la categoría es el dato
-- que ya agrupa esos servicios (`Servicios médicos`, `Imagenes
-- Diagnosticas`, `Pruebas`), así que una categoría vinculada arrastra
-- todos sus ítems, incluidos los que se registren después. Vincular
-- 2000 productos de a uno sería el mismo trabajo manual que se quiere
-- evitar.
--
-- Forma: { "<catalogKey>": ["Categoría A", "Categoría B"], ... } donde
-- catalogKey es una de las 4 claves de CATALOGO_PRODUCTOS_SERVICIOS
-- (ver CATALOGO_ORDENES_DB_CATEGORIA en index.html). Va en
-- `establecimientos` y no en una tabla nueva porque es configuración de
-- la clínica —una fila, un update atómico— y así entra sola por
-- `establecimientos(*)` en la query de sesión, sin tocar ninguna
-- lectura (ver "Configuración de la veterinaria" en CLAUDE.md).
--
-- El default '{}' es "ninguna categoría vinculada": el catálogo de
-- órdenes sigue mostrando solo sus propias entradas hasta que alguien
-- vincule algo. No se vincula nada por defecto a propósito — adivinar
-- qué categoría es "de imágenes" por el nombre acertaría en unas
-- clínicas y en otras metería alimentos en el dropdown de una orden.
-- ════════════════════════════════════════════════════════════════

alter table public.establecimientos
  add column if not exists orden_catalogo_categorias jsonb not null default '{}'::jsonb;

comment on column public.establecimientos.orden_catalogo_categorias is
  'Categorías de productos/servicios que alimentan cada grupo del Catálogo de Órdenes: {"<catalogKey>": ["Categoría", ...]}. Ver CATALOGO_ORDENES_DB_CATEGORIA en index.html.';
