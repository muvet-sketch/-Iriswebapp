-- ════════════════════════════════════════════════════════════════
-- Catálogo de Órdenes + categorías de productos: dos catálogos que
-- vivían SOLO en memoria y se perdían al refrescar.
--
-- 1) CATALOGO_PRODUCTOS_SERVICIOS (index.html) alimenta el dropdown
--    "Buscar y seleccionar..." que aparece en Consultorio > Órdenes al
--    elegir el tipo de orden. Arrancaba vacío, no había ninguna forma de
--    agregarle una entrada y no existía ninguna pantalla para
--    gestionarlo: el usuario elegía "Prueba/Examen" y se quedaba con un
--    "Sin resultados" del que no se podía salir.
--
-- 2) VENTAS_CATEGORIAS (Inventario > Categorías) sí se podía editar,
--    pero tampoco se guardaba en ninguna parte. El daño no era solo
--    "se pierde la categoría nueva": al recargar, la categoría real de
--    un producto ya no estaba en la lista del <select>, así que el
--    select quedaba en selectedIndex = -1 y el siguiente "Guardar"
--    escribía categoria = '' — borraba el dato en silencio. En
--    producción ya hay productos con la categoría vacía por esto.
--
-- Las dos cosas son listas de strings planos por establecimiento, que es
-- exactamente lo que `catalogos_custom` ya modela para Vacunas/
-- Desparasitaciones/Hospitalizaciones. Se reutiliza esa tabla en vez de
-- crear dos más casi idénticas: lo único que cambia es el valor de
-- `categoria`, igual que entre esos 3.
-- ════════════════════════════════════════════════════════════════

-- ── 1. Nuevos valores de `categoria` ─────────────────────────────
-- Los 4 `orden_*` son las 4 claves de CATALOGO_PRODUCTOS_SERVICIOS
-- (TIPOS_ORDEN.catalogKey depende de ellas, ver index.html); el 5º es la
-- lista de categorías de Inventario. El check se recrea completo porque
-- Postgres no sabe extender uno existente.
alter table public.catalogos_custom
  drop constraint if exists catalogos_custom_categoria_check;

alter table public.catalogos_custom
  add constraint catalogos_custom_categoria_check
  check (categoria in (
    'vacuna', 'desparasitacion', 'hospitalizacion',
    'orden_consultas_especialidad', 'orden_imagenes_diagnosticas',
    'orden_cirugias_procedimientos', 'orden_pruebas_examenes',
    'producto_categoria'
  ));

-- ── 2. UPDATE y DELETE ───────────────────────────────────────────
-- La tabla solo tenía policies de select e insert: alcanzaba para
-- "+Registrar vacuna", que solo agrega. Las dos pantallas nuevas
-- (Inventario > Catálogo de órdenes y > Categorías) renombran y
-- eliminan entradas, y sin estas policies esos UPDATE/DELETE afectarían
-- 0 filas EN SILENCIO — el cambio se vería aplicado en pantalla y
-- volvería al valor viejo en la próxima recarga (el mismo modo de falla
-- que ya documenta `fusionar_mascotas` para `mensajes`).
--
-- Se acotan a las 5 categorías nuevas a propósito: los catálogos de
-- Vacunas/Desparasitaciones/Hospitalizaciones siguen siendo solo-agregar
-- como hasta ahora. Abrirles borrado de paso, sin que ninguna pantalla
-- lo pida, sería ampliar la superficie sin motivo.
drop policy if exists "catalogos_custom_update_member" on public.catalogos_custom;
create policy "catalogos_custom_update_member"
  on public.catalogos_custom for update
  using (
    public.user_is_member_of(establecimiento_id)
    and categoria in (
      'orden_consultas_especialidad', 'orden_imagenes_diagnosticas',
      'orden_cirugias_procedimientos', 'orden_pruebas_examenes',
      'producto_categoria'
    )
  )
  with check (
    public.user_is_member_of(establecimiento_id)
    and categoria in (
      'orden_consultas_especialidad', 'orden_imagenes_diagnosticas',
      'orden_cirugias_procedimientos', 'orden_pruebas_examenes',
      'producto_categoria'
    )
  );

drop policy if exists "catalogos_custom_delete_member" on public.catalogos_custom;
create policy "catalogos_custom_delete_member"
  on public.catalogos_custom for delete
  using (
    public.user_is_member_of(establecimiento_id)
    and categoria in (
      'orden_consultas_especialidad', 'orden_imagenes_diagnosticas',
      'orden_cirugias_procedimientos', 'orden_pruebas_examenes',
      'producto_categoria'
    )
  );

-- ── 3. Backfill de las categorías que YA están en uso ────────────
-- No es cosmético: es lo que evita que la lista siga llegando incompleta
-- a las clínicas que ya tienen inventario. Las categorías reales de
-- producción (`Vacunas`, `Arena`, `Imagenes Diagnosticas`, `Sin
-- categoría`, …) las escribió la importación de Excel directo en
-- `productos.categoria` y no existen en ninguna lista; sin este insert,
-- editar cualquiera de esos productos volvería a vaciar su categoría.
--
-- index.html ADEMÁS deriva la lista de los productos cargados (unión con
-- lo persistido, ver cargarDatosClinicaDesdeSupabase) — las dos cosas
-- hacen falta: el backfill las hace editables/renombrables acá, y la
-- derivación cubre lo que entre por una importación futura.
insert into public.catalogos_custom (establecimiento_id, categoria, valor)
select distinct p.establecimiento_id, 'producto_categoria', trim(p.categoria)
from public.productos p
where p.categoria is not null and trim(p.categoria) <> ''
on conflict (establecimiento_id, categoria, valor) do nothing;
