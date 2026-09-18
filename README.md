# NatiIA

Secretaria virtual por WhatsApp para un consultorio médico de PAMI, construida
sobre **n8n**. Automatiza turnos, OCR de documentos (DNI, credencial PAMI,
recetas, medicamentos), recordatorios, lista de espera, triage básico, FAQ
24/7, escalamiento a un humano, renovación de recetas crónicas y verificación
de cobertura.

## Stack

- **WhatsApp:** [Evolution API](https://github.com/EvolutionAPI/evolution-api) (Baileys) — no oficial, sin necesidad de Meta Business verificado.
- **Orquestación:** [n8n](https://n8n.io) — los 11 flujos están en `n8n/workflows/`.
- **Base de datos:** [Supabase](https://supabase.com) (Postgres + Storage) — schema en `supabase/schema.sql`.
- **IA:** [Claude](https://www.anthropic.com) (Anthropic API) — clasificación de intención, agente conversacional, visión (OCR/HTR/clasificación de documentos).
- **Calendario:** Google Calendar (nodo nativo de n8n).

## Estructura del repo

```
n8n/workflows/            11 workflows de n8n (JSON importable), uno por función
supabase/schema.sql        Tablas de Postgres/Supabase
.env.example                Variables de entorno que necesita n8n
```

## Los 11 flujos

| Archivo | Qué hace |
|---|---|
| `00-router-maestro.json` | Punto de entrada único del webhook de WhatsApp. Normaliza el mensaje, identifica al paciente, clasifica la intención con Claude y despacha al sub-flujo correspondiente. |
| `01-onboarding-ocr-identidad.json` | Lee por visión una foto de DNI/credencial PAMI y crea o actualiza la ficha del paciente sin tipeo manual. |
| `02-gestion-turnos.json` | Ofrece turnos disponibles cruzando Google Calendar, y procesa la respuesta del paciente eligiendo una opción (multi-turno, vía `estado_conversacion`). |
| `03-recordatorios-lista-espera.json` | Cron: recordatorios 48h/24h antes del turno. Y bajo demanda: cancela turnos y ofrece el hueco liberado al primero en lista de espera. |
| `04-alertas-control.json` | Cron diario: avisa cuando corresponde un control crónico/preventivo. |
| `05-faq-soporte.json` | Responde preguntas frecuentes con RAG simple sobre una tabla de conocimiento; si no sabe, escala a un humano en vez de inventar. |
| `06-analisis-documentos.json` | Clasifica y digitaliza fotos de recetas manuscritas (HTR), medicamentos, y documentos con QR/código de barras. |
| `07-escalamiento-humano.json` | Resume la conversación con Claude y notifica a la secretaria/médico, marcando al paciente como atendido por humano. |
| `08-triage-sintomas.json` | Triage conversacional muy conservador: detecta señales de alarma y deriva a guardia/107 en vez de agendar un turno de rutina. |
| `09-recetas-repetitivas.json` | Pedido de renovación de medicación crónica, con aprobación del médico antes de avisarle al paciente. |
| `10-verificacion-pami.json` | Consulta si una práctica requiere autorización previa o coseguro de PAMI. |

Cada workflow tiene **notas (sticky notes) dentro del propio canvas** explicando
las partes menos obvias (por qué existe la rama, qué simplificaciones tiene,
qué falta conectar). Ábrilos en n8n para verlas.

## Cómo importarlos

1. **Base de datos:** correr `supabase/schema.sql` en el SQL editor de tu proyecto Supabase. Crear además un bucket de Storage llamado `documentos-pacientes` (privado).
2. **Variables de entorno:** copiar `.env.example` y completar con tus credenciales reales (Evolution API, Anthropic, Supabase, Google Calendar, STT, número de staff).
3. **Credencial de Google Calendar:** crear en n8n (Credentials → Google Calendar OAuth2 API) y conectarla en cada nodo "Google Calendar" de los flujos 02 y 03 (quedaron con un placeholder de credencial que hay que re-seleccionar).
4. **Importar los 11 JSON** en n8n (Import from File), idealmente empezando por `00-router-maestro.json`.
5. **Re-vincular los nodos "Execute Workflow"**: como los IDs de workflow los asigna n8n recién al importar, cada nodo `Ejecutar Flujo NN (...)` queda con un placeholder. Abrí cada uno de esos nodos y elegí el workflow correcto desde el dropdown (el nombre destino está en la nota del nodo).
6. **Configurar el webhook de Evolution API** para que apunte a la URL del nodo Webhook del Flujo 00 (`/webhook/whatsapp-in`).
7. **Activar** los flujos 00, 03 y 04 (los que tienen triggers propios: webhook y cron). Los demás no necesitan activarse porque solo se invocan vía "Execute Workflow".

## Cosas a revisar/ajustar después de importar (honestidad ante todo)

Estos JSON se armaron a mano siguiendo el schema de n8n, sin una instancia
corriendo para probarlos end-to-end. Lo más probable es que necesites:

- **Nodos IF/Switch:** si alguna condición aparece en rojo al abrir el nodo, es un desfasaje menor de versión de n8n — solo hay que volver a seleccionar la condición desde el desplegable, se autocorrige.
- **Nodo "Descargar imagen"** (Flujos 01 y 06): configurar `Response Format = File` para que la imagen quede en binario.
- **Body de Evolution API** (`wa_send`): el nombre exacto de los campos (`number`/`text` vs `textMessage.text`) varía según la versión de Evolution API que uses — ajustar en los nodos de envío.
- **Google Calendar:** los nombres exactos de parámetros de "listar eventos" (rango de fechas) y "crear evento" pueden variar levemente según la versión del nodo — revisar tras importar.
- **QR/código de barras** (Flujo 06): no hay una librería de decodificación en el sandbox estándar de n8n. Hay que sumar un nodo comunitario (ej. de lectura de barcode/QR) o un microservicio propio — quedó documentado como pendiente en el propio nodo.
- **Transcripción de audio** (Flujo 00): Claude no transcribe voz. Hay que conectar un proveedor de Speech-to-Text (Whisper, Groq, Deepgram) vía `STT_API_URL`/`STT_API_KEY`.
- **Aprobación de recetas por el médico** (Flujo 09): requiere agregar una regla chica en el clasificador del Router (Flujo 00) para reconocer mensajes del número de staff que empiecen con "APROBAR" y enrutarlos al segundo trigger del Flujo 09, en vez de pasarlos por el clasificador de intención normal.
- **Cascada automática de lista de espera** (Flujo 03): hoy ofrece el turno liberado a un solo candidato; si no responde, no pasa automáticamente al siguiente. Se puede sumar un Cron que revise ofertas "ofrecidas" hace más de 15 minutos y las descarte/reoferte.

## Función pendiente (no incluida en esta tanda)

Quedó diseñada pero no implementada: **Flujo 11 - Seguimiento post-consulta y
encuestas de satisfacción/adherencia** (Cron diario post-turno + encuesta NPS
+ escalamiento si la nota es baja). Se puede sumar cuando lo necesites.
