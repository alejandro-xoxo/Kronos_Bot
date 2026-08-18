# Kronos Bot — Contexto del proyecto

## Qué es esto

Sistema de copiado automático de señales de trading desde un grupo de
Telegram ("VIP SIGNALS FX - ESPAÑA") hacia una cuenta MT4 en VT Markets,
orquestado con n8n. El usuario no es admin del grupo, así que la captura
de mensajes se hace vía Telethon (cuenta de usuario, MTProto), no con un
bot de Telegram.

**Antes de tocar cualquier lógica de negocio (interpretación de señales,
cálculo de lotaje, validaciones de precio, protocolos de reintento),
lee `PROTOCOLOS_KRONOS_BOT.md` en la raíz de este repo.** Ese documento
es la fuente única de verdad de las reglas — no debe contradecirse ni
reinterpretarse libremente.

## Stack técnico

- **n8n** (Docker) — orquestador central: recibe webhooks, corre la
  lógica, llama a Gemini, escribe en la base de datos, notifica por
  Telegram.
- **Telethon** (Python, Docker) — microservicio que escucha el grupo de
  Telegram con la cuenta personal del usuario y reenvía cada mensaje a
  un webhook de n8n.
- **Postgres** — base de datos de señales, modificaciones, y
  configuración (`signals`, `signal_modifications`, `settings`).
- **Gemini API** (capa gratuita) — interpreta instrucciones de
  seguimiento con redacción variable (mover SL, BE, cerrar). Las
  señales nuevas con formato fijo se parsean por regex, sin usar IA.
- **MT4 + EA puente** (Wine, en el EliteBook) — ejecución real en la
  cuenta de VT Markets. EA compilado y corriendo; falta el nodo n8n
  que lee los resultados (ver `STATUS.md`).
- **Google Sheets** — registro de resultados y de señales rechazadas.

Todo corre local en el EliteBook (CachyOS) por ahora — no hay VPS ni
IA de pago todavía. Eso se evalúa después de validar que el sistema
es rentable en modo semi-automático.

## Seguridad — reglas no negociables

- **Nunca crear, mostrar, imprimir, loggear, ni commitear el contenido
  de `.env`.** Ya hubo un incidente real de exposición de credenciales
  en este repo (rotadas después). El `.gitignore` debe seguir
  protegiendo `.env`, `*.session`, y `telethon-service/session/`.
- Antes de cualquier commit, verificar que no se está agregando ningún
  archivo con secretos, tokens, o la sesión de Telegram.
- El cálculo de capital para lotaje **nunca** debe usar `AccountBalance()` solo (puede incluir crédito del bróker). Se calcula automáticamente en el EA como `AccountBalance() - AccountCredit()`, y el EA lo reporta a n8n para actualizar `capital_real` en la tabla `settings`. No requiere edición manual en operación normal.
- **`mt4-bridge/orders/pending/` y `mt4-bridge/orders/results/` son symlinks locales** en las máquinas donde MT4 ya está instalado (vía `scripts/setup-mt4.sh`), apuntando a la carpeta `Common/Files/orders/` del prefijo de Wine de esa máquina específica (ej. `~/.wine-mt4/drive_c/users/<usuario>/AppData/Roaming/MetaQuotes/Terminal/Common/Files/orders/`). Esa ruta es específica del usuario/máquina — **nunca se debe commitear** ese symlink ni el contenido que apunta a Wine. `git status` va a mostrar los `.gitkeep` originales como "borrados" y los symlinks como "sin seguimiento" — es el estado local esperado, no se stagea (nunca usar `git add -A` en este repo, y menos en `mt4-bridge/`). Los `.gitkeep` siguen versionados en el repo porque son necesarios para el estado por defecto de un clone nuevo, antes de correr el setup de Wine.

## MVP actual — Fase 1: señal del grupo → confirmación → ejecución en MT4

**El MVP es el ciclo completo semi-automático**: detectar la señal en
el grupo, esperar confirmación humana por Telegram, y ejecutarla de
verdad en MT4. No termina en la notificación — la ejecución real
(EA puente) es parte de este MVP, no una fase posterior. (Corregido:
una versión anterior de este documento la marcaba como "fuera de
alcance"; fue un error de alcance, no una decisión de producto.)

**Alcance de este MVP:**

1. El webhook de n8n recibe el payload de Telethon
   (`message_id`, `chat_id`, `sender`, `text`, `timestamp`,
   `reply_to_message_id`).
2. Un nodo de n8n (Function/Code) detecta si el texto coincide con el
   formato fijo de señal nueva: `INSTRUMENTO`, `BUY`/`SELL`,
   `[LIMIT]` opcional, `TP`, `SL`.
3. Si coincide, extraer por regex: instrumento, dirección, tipo de
   ejecución (market/limit), precio de entrada, SL, y **todos los TP**
   que traiga la señal (según protocolo, sección 4.2 regla 6,
   actualizada — **sin tope**, corrige una versión anterior de este
   documento que limitaba a 2): cada TP genera su propia
   **sub-señal independiente** (misma señal original, mismo
   instrumento/dirección/entrada/SL, solo el TP difiere), con sufijo
   `A`, `B`, `C`... (y `AA`, `AB`... si hiciera falta pasar de `Z`).
   Si solo hay 1 TP, se genera una única sub-señal (comportamiento sin
   cambios).
4. Validar antigüedad: si `ahora - signal_timestamp > 5 minutos`,
   descartar (status `EXPIRED`), sin excepciones. La validación de
   antigüedad aplica igual a cada sub-señal.
5. Por cada sub-señal válida, insertar una fila **independiente** en
   `signals` con `status = PENDING_CONFIRMATION`,
   `interpreted_by = 'REGEX'`, y su propio `signal_uid`.
6. Enviar una notificación a Telegram **por cada sub-señal** (chat
   privado del usuario), cada una con sus propios botones
   Confirmar/Rechazar independientes — confirmar o rechazar una no
   afecta a la otra.
7. Al confirmar, n8n escribe la orden en `mt4-bridge/orders/pending/`
   (formato en `mt4-bridge/FORMATO_ARCHIVOS.md`); el EA puente
   (`mt4-bridge/ea/KronosBridgeEA.mq4`) la ejecuta en MT4 con lotaje
   fijo `0.01` y escribe el resultado en `mt4-bridge/orders/results/`.
8. n8n lee ese resultado, actualiza `signals.mt4_ticket`/`status` en
   Postgres, y notifica el resultado real (ticket, precio de
   ejecución o motivo de fallo) por Telegram.

**Explícitamente fuera de este MVP** (no implementar todavía):
- Interpretación por Gemini de instrucciones de seguimiento (mover
  SL, BE, cerrar) — es la siguiente fase.
- Cálculo de lotaje por slots (80/20) — puede dejarse como función
  aislada y probada, pero no conectada al flujo de ejecución real
  todavía. Ambas sub-señales de una misma señal usan el lotaje fijo
  `0.01` sin ningún mecanismo de "competencia por slot" entre ellas.

## Ejemplos reales de mensajes del grupo (para calibrar el regex)

**Señal nueva (formato fijo, siempre parseable por regex):**
```
XAUUSD BUY 4372  TP 4376  SL 4347
XAUUSD SELL LIMIT 3348 TP1 3346 TP2 3344 TP3 3340 SL 3357
```
Variaciones observadas: espacios múltiples entre campos, a veces
"TP1/TP2/TP3" en vez de solo "TP", a veces "LIMIT" explícito.

**Instrucciones de seguimiento (van a Gemini, NO a regex — redacción
variable, siempre como reply a la señal original):**
```
"MOVER el sl a be"                    → modification_type: SL_TO_BE
"Cerrar a 4366 -60PIPS"                → modification_type: CLOSE_AT_PRICE
"CERRAR A 4374, +20 PIPS"              → modification_type: CLOSE_AT_PRICE
"TP, +80PIPS" / "TP +40PIPS"           → informativo, la operación ya
                                          cerró por TP alcanzado en el
                                          bróker; no requiere acción,
                                          solo actualizar status si el
                                          EA no lo reportó aún
"Modificar el punto de entrada a X"    → modification_type: ENTRY_CHANGE
"Eliminar esta operación"              → modification_type: CANCEL
```

**Nota importante:** `CLOSE_AT_PRICE` es un tipo de modificación que
NO estaba en el diseño original de `PROTOCOLOS_KRONOS_BOT.md` —
agregar a la lista de `modification_type` junto a `ENTRY_CHANGE`,
`SL_CHANGE`, `SL_TO_BE`, `CANCEL`, `TP_UPDATE`. Representa un cierre
manual del caller en un punto intermedio (ni el TP ni el SL original),
y debe ejecutarse como cierre a mercado inmediato del ticket
correspondiente, sin loop de reintento de precio (a diferencia de
SL_TO_BE) — es una orden de cierre directo, no de modificación de
niveles, así que el riesgo de "condición de carrera" del protocolo
de la sección 8 no aplica de la misma forma (cerrar a mercado casi
siempre se acepta, salvo error de conexión).

El schema real (`db/schema.sql`, tabla `signal_modifications`) agrega
además `CLOSE_ALL_TO_BE` (mover a BE todas las sub-señales de una
misma señal original, ej. una instrucción de seguimiento que aplica a
la señal completa y no a una sub-señal puntual) y `UNCLASSIFIED`
(cuando Gemini no logra interpretar la instrucción — cae a
`PENDING_MANUAL`, ver Fase 4). Lista completa de
`modification_type`: `ENTRY_CHANGE`, `SL_CHANGE`, `SL_TO_BE`,
`CANCEL`, `TP_UPDATE`, `CLOSE_AT_PRICE`, `CLOSE_ALL_TO_BE`,
`UNCLASSIFIED`.

## Flujo de trabajo con git — Git Flow

Trabajar siempre sobre ramas, nunca commitear directo a `main`.

- `main` — solo código estable, probado. Se llega aquí por PR desde
  `develop`.
- `develop` — rama de integración. Cada feature se fusiona aquí
  primero.
- `feature/<nombre-corto>` — una rama por unidad de trabajo concreta.
  Ejemplos: `feature/regex-parser`, `feature/webhook-n8n`,
  `feature/db-schema`.

**Reglas para Claude Code en este repo:**

1. Antes de empezar cualquier tarea nueva, crear una rama
   `feature/<nombre-descriptivo>` desde `develop` actualizado.
2. Hacer commits pequeños y descriptivos en español, en el mismo
   idioma que el resto del proyecto (ej: `feat: agregar parser regex
   de señales nuevas`).
3. Al terminar una unidad de trabajo funcional, dejarla lista para
   pull request hacia `develop` — no fusionar directo sin que el
   usuario lo revise, salvo que se indique explícitamente lo
   contrario.
4. Nunca hacer force push a `main` ni a `develop`.
5. Si una tarea requiere modificar `docker-compose.yml` o el schema
   de la base de datos, señalarlo explícitamente antes de aplicar el
   cambio — son piezas compartidas que afectan todo el sistema.

### Regla no negociable: qué código puede llegar al stack de producción

**El stack de PRODUCCIÓN (`docker-compose.yml`, la instancia real de
n8n, el EA en `~/.wine-mt4`) SOLO se actualiza con código que ya está
en la rama `main`.** Nunca se sube a producción código de `develop` ni
de ninguna rama `feature/*`, sin importar cuán probado esté en el
stack dev.

El flujo correcto:

```
feature/*  →  develop  →  main  →  producción
```

- `feature/*` → `develop`: una vez lista la unidad de trabajo (regla 3
  de arriba).
- `develop` → probarse en el **stack dev** (`docker-compose.dev.yml`,
  ver `DEV_SETUP.md`), con cuenta demo — es precisamente el lugar
  seguro para esto, sin restricción de qué rama corre ahí.
- `develop` → `main`: solo cuando el usuario aprueba explícitamente el
  paso a producción.
- `main` → producción: recién ahí se sube el workflow a la instancia
  real de n8n (`PUT /api/v1/workflows/{id}`) y se recompila el EA de
  producción (`~/.wine-mt4`) — nunca antes.

El stack dev (`docker-compose.dev.yml`) puede correr desde `develop` o
cualquier `feature/*` sin restricción. La restricción de "solo desde
`main`" aplica **únicamente** al stack de producción.

## Estado actual del proyecto

- ✅ Fase 0: credenciales de Telegram, estructura de carpetas.
- ✅ Fase 1: microservicio Telethon funcionando, capturando mensajes
  del grupo y enviándolos al webhook de n8n.
- ✅ Fase 2: base de datos Postgres (`signals`, `signal_modifications`,
  `settings`) — schema implementado en `db/schema.sql`, montado como
  init script del contenedor de Postgres (`docker-entrypoint-initdb.d`)
  para que se auto-ejecute si el volumen se recrea desde cero.
- ✅ Fase 3: webhook + parser regex en n8n — **verificado end-to-end**:
  Telethon → webhook → parser regex (una sub-señal por cada TP,
  sin tope, protocolo sección 4.2 regla 6) → inserción en Postgres
  (`signal_uid` por sub-señal) → notificación por Telegram con botones.
- ✅ Fase 5: botones de confirmar/rechazar — **funcionales y
  verificados**: callback vía `Trigger Callback Telegram`, `UPDATE`
  idempotente (no reprocesa doble clic), mensaje de confirmación
  visible en el chat además del toast. Se implementó antes que la
  Fase 4 (Gemini), fuera de orden respecto a la numeración original,
  porque era la pieza que faltaba para validar el flujo completo de
  confirmación humana antes de tocar MT4.
- 🔶 Fase 4: interpretación por Gemini de instrucciones de seguimiento
  — código implementado y mergeado a `develop`
  (`feature/fase4-seguimiento`), pero BLOQUEADO explícitamente por
  decisión del usuario: el diseño se construyó sin su aprobación paso
  a paso, a diferencia del resto del sistema. NO se sube a producción
  ni se continúa desarrollando hasta rediseñar el árbol de decisión en
  conjunto con el usuario, punto por punto. Ver `STATUS.md` para el
  detalle completo.
- 🔶 Fase 6: EA puente en MT4 — **en progreso, ver detalle completo y
  próximos pasos en `STATUS.md`.** Resumen: Wine + MT4 instalados,
  formato de archivos y symlinks a `Common/Files` verificados, EA en
  MQL4 escrito y revisado — falta compilar con MetaEditor (requiere
  interfaz gráfica) y los nodos de n8n que escriben la orden y leen el
  resultado (Etapas 4 y 5 de esta fase, no confundir con las Fases 4/5
  de arriba).
- 🔲 Fase 7: ciclo de cierre y registro en Google Sheets.
- 🔲 Fase 8: pasar a ejecución 100% automática (futuro).

**Estado técnico detallado y próximos pasos inmediatos: ver `STATUS.md`**
(se actualiza en cada etapa, pensado para poder pegarse a una sesión
nueva de Claude Code sin depender de memoria de conversación previa).
