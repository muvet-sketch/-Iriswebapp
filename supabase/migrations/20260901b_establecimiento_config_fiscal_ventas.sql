-- Configuración de la veterinaria: pestañas "Perfil fiscal", "Ventas e
-- inventario", "Sala de espera" y "Sedes vinculadas" (Admin > Configuración
-- de la veterinaria). Segunda tanda de columnas sobre `establecimientos`;
-- la primera (Localización y servicios + Agenda y disponibilidad) está en
-- 20260901_establecimiento_config.sql y ya fue aplicada, por eso esto va en
-- un archivo aparte en vez de crecer aquel.
--
-- Mismo criterio que aquel: todo nullable o con default (cambio aditivo, no
-- destructivo), la policy establecimientos_update_admin ya las cubre a nivel
-- de fila y la query de sesión (`memberships` con `establecimientos(*)`) las
-- trae sola, sin tocar ninguna lectura.

-- ── Perfil fiscal ─────────────────────────────────────────────────
-- Datos con los que la clínica se identifica ante la DIAN / el proveedor
-- de facturación electrónica. Son DISTINTOS de los de "Información
-- general" (nombre comercial, NIT abreviado, teléfono de contacto): una
-- clínica puede facturar a nombre de otra razón social o de una persona
-- natural. Alimentan la tarjeta "Datos fiscales de la clínica" de
-- Ventas > Configuración de facturación (ver
-- sincronizarDatosFiscalesFacturacion en index.html), que hasta ahora
-- solo podía caer a CLINIC_INFO.
alter table public.establecimientos add column if not exists fiscal_tipo_persona text;
alter table public.establecimientos add column if not exists fiscal_tipo_identificacion text;
-- Sin dígito de verificación: ese va aparte, igual que en la DIAN.
alter table public.establecimientos add column if not exists fiscal_numero_identificacion text;
alter table public.establecimientos add column if not exists fiscal_digito_verificacion text;
alter table public.establecimientos add column if not exists fiscal_razon_social text;
alter table public.establecimientos add column if not exists fiscal_apellidos text;
alter table public.establecimientos add column if not exists fiscal_regimen_iva text;
-- fiscal_responsabilidades: array de códigos DIAN, ej. ["O-13","O-15"]
alter table public.establecimientos add column if not exists fiscal_responsabilidades jsonb not null default '[]'::jsonb;
alter table public.establecimientos add column if not exists fiscal_telefono text;
alter table public.establecimientos add column if not exists fiscal_correo text;
alter table public.establecimientos add column if not exists fiscal_direccion text;
alter table public.establecimientos add column if not exists fiscal_requiere_fe boolean not null default false;

-- ── Ventas e inventario ───────────────────────────────────────────
-- Interruptores de la operación comercial. Los tres de facturación
-- (fact_*) son el ESPEJO de lo que ya se configura en detalle en
-- Ventas > Configuración de facturación: acá se prende/apaga el método y
-- se salta allá con un botón, no se duplican credenciales ni
-- resoluciones.
alter table public.establecimientos add column if not exists ventas_habilitar boolean not null default true;
alter table public.establecimientos add column if not exists fact_software_propio boolean not null default false;
alter table public.establecimientos add column if not exists fact_siigo boolean not null default false;
alter table public.establecimientos add column if not exists fact_pos_habilitar boolean not null default false;
alter table public.establecimientos add column if not exists ventas_usar_turnos boolean not null default false;
alter table public.establecimientos add column if not exists recibos_prevenir_cierre_saldo boolean not null default false;
alter table public.establecimientos add column if not exists recibos_impresion_tirilla boolean not null default false;
-- Pie de página de los documentos de venta. NO es el "Mensaje
-- predeterminado de observaciones" de Ventas > Configuración de
-- facturación (ese vive en localStorage y precarga un campo editable de
-- cada factura): esto es el texto fijo al pie del documento impreso.
alter table public.establecimientos add column if not exists recibos_notas text;
alter table public.establecimientos add column if not exists inv_permitir_sobreventa boolean not null default false;
alter table public.establecimientos add column if not exists inv_confirmacion_picking boolean not null default false;
-- facturacion_modulos_vinculados: array de claves de módulo clínico
-- (["consultas","vacunaciones",...]) cuyos registros deben proponer
-- cargos en la cuenta del tutor.
alter table public.establecimientos add column if not exists facturacion_modulos_vinculados jsonb not null default '[]'::jsonb;

-- ── Sala de espera ────────────────────────────────────────────────
-- Pantalla pública (la que se proyecta en el televisor de recepción) con
-- los pacientes en turno del día. Los "mostrar_*" son de privacidad, no
-- estéticos: el nombre del tutor y el del profesional se ven desde la
-- sala, así que cada clínica decide qué expone.
alter table public.establecimientos add column if not exists sala_espera_habilitar boolean not null default false;
alter table public.establecimientos add column if not exists sala_espera_titulo text;
alter table public.establecimientos add column if not exists sala_espera_mensaje text;
alter table public.establecimientos add column if not exists sala_espera_mostrar_paciente boolean not null default true;
alter table public.establecimientos add column if not exists sala_espera_mostrar_tutor boolean not null default false;
alter table public.establecimientos add column if not exists sala_espera_mostrar_profesional boolean not null default true;
alter table public.establecimientos add column if not exists sala_espera_mostrar_hora boolean not null default true;
alter table public.establecimientos add column if not exists sala_espera_refresco_seg integer not null default 30;
alter table public.establecimientos add column if not exists sala_espera_sonido boolean not null default true;

-- ── Sedes vinculadas ──────────────────────────────────────────────
-- Registro de las otras sedes de la misma organización, como
-- [{"id": "<uuid>", "nombre": "..."}]. Es DIRECTORIO, no permiso: el
-- acceso a historias clínicas entre establecimientos sigue pasando
-- exclusivamente por la Red IRIS (red_solicitudes + policies
-- *_select_red). Vincular una sede acá no abre ni una fila, y por eso no
-- hace falta ninguna policy nueva.
alter table public.establecimientos add column if not exists sedes_vinculadas jsonb not null default '[]'::jsonb;
