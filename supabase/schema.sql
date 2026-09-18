-- ============================================================================
-- NatiIA - Esquema de base de datos (Supabase / Postgres)
-- Secretaria virtual por WhatsApp para consultorio medico (PAMI)
-- ============================================================================

create extension if not exists "pgcrypto";
create extension if not exists "pg_trgm";

-- ----------------------------------------------------------------------------
-- pacientes
-- ----------------------------------------------------------------------------
create table if not exists pacientes (
  id uuid primary key default gen_random_uuid(),
  telefono text not null unique,               -- numero de WhatsApp, formato E.164 sin '+'
  nombre_completo text,
  dni text,
  fecha_nacimiento date,
  nro_afiliado_pami text,
  onboarding_completo boolean not null default false,
  en_manos_de_humano boolean not null default false,
  estado_conversacion jsonb not null default '{}'::jsonb, -- estado efimero multi-turno (ej: turno ofrecido, esperando respuesta)
  visitas_totales int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_pacientes_dni on pacientes (dni);

-- ----------------------------------------------------------------------------
-- conversaciones (log de mensajes, auditoria + memoria corta)
-- ----------------------------------------------------------------------------
create table if not exists conversaciones (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid references pacientes(id) on delete set null,
  telefono text not null,
  direccion text not null check (direccion in ('entrante','saliente')),
  tipo_mensaje text not null default 'texto',   -- texto | imagen | audio | ubicacion | boton
  contenido text,
  intent text,                                   -- clasificacion del router (turno_nuevo, pregunta_general, etc.)
  confidence numeric,
  flujo text,                                     -- que sub-flujo atendio el mensaje
  created_at timestamptz not null default now()
);
create index if not exists idx_conversaciones_paciente on conversaciones (paciente_id, created_at desc);
create index if not exists idx_conversaciones_telefono on conversaciones (telefono, created_at desc);

-- ----------------------------------------------------------------------------
-- turnos
-- ----------------------------------------------------------------------------
create table if not exists turnos (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references pacientes(id) on delete cascade,
  google_event_id text,
  profesional text not null default 'default',
  tipo_consulta text not null default 'consulta_general',
  fecha_hora timestamptz not null,
  duracion_minutos int not null default 20,
  estado text not null default 'confirmado' check (estado in ('confirmado','cancelado','atendido','ausente')),
  motivo text,
  recordatorio_48h_enviado boolean not null default false,
  recordatorio_24h_enviado boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists idx_turnos_paciente on turnos (paciente_id);
create index if not exists idx_turnos_fecha on turnos (fecha_hora);
create index if not exists idx_turnos_estado on turnos (estado);

-- ----------------------------------------------------------------------------
-- lista_espera
-- ----------------------------------------------------------------------------
create table if not exists lista_espera (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references pacientes(id) on delete cascade,
  profesional text not null default 'default',
  tipo_consulta text not null default 'consulta_general',
  preferencia text,                               -- ej: "martes por la tarde"
  estado text not null default 'esperando' check (estado in ('esperando','ofrecido','tomado','descartado')),
  created_at timestamptz not null default now()
);
create index if not exists idx_lista_espera_estado on lista_espera (estado, profesional);

-- ----------------------------------------------------------------------------
-- documentos (fotos clasificadas: DNI, ordenes, recetas, medicamentos, etc.)
-- ----------------------------------------------------------------------------
create table if not exists documentos (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid references pacientes(id) on delete set null,
  tipo_documento text not null,                    -- identidad | orden_laboratorio | derivacion | receta | medicamento | certificado | otro
  storage_path text,
  datos_extraidos jsonb not null default '{}'::jsonb,
  turno_id uuid references turnos(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists idx_documentos_paciente on documentos (paciente_id, tipo_documento);

-- ----------------------------------------------------------------------------
-- medicamentos_cronicos
-- ----------------------------------------------------------------------------
create table if not exists medicamentos_cronicos (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references pacientes(id) on delete cascade,
  droga text not null,
  marca text,
  mg text,
  cantidad_comprimidos text,
  ultima_receta_documento_id uuid references documentos(id) on delete set null,
  activo boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists idx_medicamentos_paciente on medicamentos_cronicos (paciente_id, activo);

-- ----------------------------------------------------------------------------
-- pedidos_receta (cola de aprobacion del medico para renovaciones)
-- ----------------------------------------------------------------------------
create table if not exists pedidos_receta (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references pacientes(id) on delete cascade,
  medicamento_cronico_id uuid references medicamentos_cronicos(id) on delete set null,
  estado text not null default 'pendiente' check (estado in ('pendiente','aprobada','rechazada','entregada')),
  created_at timestamptz not null default now(),
  resuelto_at timestamptz
);
create index if not exists idx_pedidos_receta_estado on pedidos_receta (estado);

-- ----------------------------------------------------------------------------
-- controles_cronicos (para alertas de control preventivo periodico)
-- ----------------------------------------------------------------------------
create table if not exists controles_cronicos (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references pacientes(id) on delete cascade,
  tipo_control text not null,                      -- ej: "control cardiologico", "PAP", "glucemia"
  frecuencia_meses int not null default 6,
  ultima_fecha date,
  alerta_enviada boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists idx_controles_paciente on controles_cronicos (paciente_id);

-- ----------------------------------------------------------------------------
-- nomenclador_pami (que practicas requieren autorizacion previa / coseguro)
-- ----------------------------------------------------------------------------
create table if not exists nomenclador_pami (
  id uuid primary key default gen_random_uuid(),
  practica text not null,
  requiere_autorizacion boolean not null default false,
  requiere_coseguro boolean not null default false,
  instrucciones text,
  created_at timestamptz not null default now()
);
create index if not exists idx_nomenclador_practica on nomenclador_pami using gin (practica gin_trgm_ops);

-- ----------------------------------------------------------------------------
-- base_conocimiento (FAQ / soporte 24hs)
-- ----------------------------------------------------------------------------
create table if not exists base_conocimiento (
  id uuid primary key default gen_random_uuid(),
  categoria text not null default 'general',
  pregunta text not null,
  respuesta text not null,
  search tsvector generated always as (to_tsvector('spanish', coalesce(pregunta,'') || ' ' || coalesce(respuesta,''))) stored,
  created_at timestamptz not null default now()
);
create index if not exists idx_base_conocimiento_search on base_conocimiento using gin (search);

-- ----------------------------------------------------------------------------
-- escalamientos (casos derivados a un humano)
-- ----------------------------------------------------------------------------
create table if not exists escalamientos (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid references pacientes(id) on delete set null,
  motivo text not null,                            -- confianza_baja | pedido_explicito | urgencia_triage | encuesta_negativa
  resumen text,
  estado text not null default 'abierto' check (estado in ('abierto','cerrado')),
  created_at timestamptz not null default now(),
  cerrado_at timestamptz
);
create index if not exists idx_escalamientos_estado on escalamientos (estado);

-- ----------------------------------------------------------------------------
-- trigger generico para updated_at en pacientes
-- ----------------------------------------------------------------------------
create or replace function set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_pacientes_updated_at on pacientes;
create trigger trg_pacientes_updated_at
before update on pacientes
for each row execute function set_updated_at();
