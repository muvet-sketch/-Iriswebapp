-- ============================================================
-- CIERRE DE DÍA — base de caja y contado por método de pago
--
-- Dos cambios de modelo en el arqueo (Ventas > Ingresos y Egresos >
-- Cierre de caja), ambos aditivos:
--
-- 1. El día ya no arranca en cero. La plata que quedó contada en
--    efectivo al cerrar el día anterior es la base con la que se abre
--    el siguiente, así que el total de sistema del efectivo pasa a ser
--    `base + ingresos - egresos` y es contra ESE número que se compara
--    lo contado. `base_efectivo` guarda con cuánto se abrió y
--    `saldo_final_efectivo` con cuánto quedó — que es la base del día
--    siguiente. Solo aplica a efectivo: tarjeta/transferencia/débito no
--    se guardan en el cajón, su contado es el neto que reporta el banco
--    o el datáfono ese día.
--
-- 2. El valor contado se digita ahora por método de pago, no por cada
--    combinación Tipo+Forma de pago (la caja se cuenta una vez, no una
--    vez por concepto). `contado_por_metodo` es un mapa
--    {"Efectivo": 470000, "Transferencia": -2500000} — el valor puede
--    ser negativo cuando ese método tuvo más egresos que ingresos.
--
-- Las tres columnas son NULLABLE y NO se hace backfill a propósito:
-- null es exactamente la marca de "arqueo anterior a este cambio", que
-- traía el contado dentro de `filas` y no tenía base. El front los
-- reconstruye al vuelo (contadoPorMetodoDeArqueo /
-- saldoFinalEfectivoDeArqueo en index.html), así que los cierres ya
-- guardados se siguen viendo e imprimiendo igual. Un default no-null
-- borraría esa distinción.
--
-- Nada que revertir más allá de un drop column: no toca datos
-- existentes ni RLS (las policies de arqueos son por tabla, no por
-- columna).
-- ============================================================

alter table public.arqueos add column if not exists contado_por_metodo   jsonb;
alter table public.arqueos add column if not exists base_efectivo        numeric;
alter table public.arqueos add column if not exists saldo_final_efectivo numeric;
