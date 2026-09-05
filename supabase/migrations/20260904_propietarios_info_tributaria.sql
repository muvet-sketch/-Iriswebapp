-- ─────────────────────────────────────────────────────────────────────
-- Información tributaria del cliente — persistencia
--
-- El panel "Información tributaria del cliente" (Facturación > Estado de
-- cuenta y el modal de Cotización/Factura) escribía sus campos sobre
-- VENTAS_CLIENTES, que es un ESPEJO EN MEMORIA reconstruido en cada
-- sesión a partir de `propietarios` (ver getVentasClienteIdDePropietario
-- en index.html). Resultado: el tipo de organización se perdía al
-- recargar y la validación de guardarDocVenta()/confirmarCerrarCuenta()
-- volvía a exigirlo en cada factura nueva y en cada edición.
--
-- La fuente de verdad de un cliente es `propietarios`, así que la
-- información tributaria vive acá. Los campos que ya tenían columna
-- propia (documento, teléfono, correo, dirección) NO se duplican: el
-- panel escribe sobre doc_tipo/doc_numero/movil/email/direccion.
-- ─────────────────────────────────────────────────────────────────────

alter table public.propietarios
  add column if not exists trib_tipo_organizacion text,
  add column if not exists trib_razon_social      text,
  add column if not exists trib_pais              text,
  add column if not exists trib_municipio         text,
  add column if not exists trib_regimen           text,
  add column if not exists trib_obligaciones      text,
  add column if not exists trib_detalles          text;

comment on column public.propietarios.trib_tipo_organizacion is
  'Persona Natural / Persona Jurídica. Es el único campo tributario que hoy BLOQUEA guardar o cerrar una factura.';
comment on column public.propietarios.trib_razon_social is
  'Razón social para facturación electrónica; puede diferir del nombre del tutor.';
comment on column public.propietarios.trib_regimen is
  'Responsable / No responsable de IVA.';
comment on column public.propietarios.trib_detalles is
  'Detalles tributarios (autorretenedor, gran contribuyente, etc.).';

-- Sin cambios de RLS: las policies de `propietarios` ya cubren estas
-- columnas. Nota heredada: propietarios_update_member exige
-- red_vinculado, así que un tutor sin vincular no puede guardar su
-- información tributaria — el front lo detecta con .select('id') y el
-- update afectando 0 filas (mismo patrón que persistirEstablecimientoConfig).
