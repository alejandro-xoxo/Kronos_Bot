# Kronos Bot — Estado actual

> Snapshot técnico del proyecto al 2026-08-18, rama `develop`. Pensado
> para poder pegarse completo a una sesión nueva de Claude Code (o de
> cualquier asistente) sin depender de memoria de conversación previa.
> Para reglas de negocio detalladas ver `PROTOCOLOS_KRONOS_BOT.md`; para
> contexto general y reglas de trabajo, `CLAUDE.md`; para el detalle de
> alcance de v1 (qué incluye y qué queda afuera a propósito),
> `docs/versions/v1.md`.

## Experimento de auto-confirmación con límite y lotaje sobre capital total (2026-08-28)

**Decisión explícita del usuario, SOLO stack dev por ahora.** Contradice
dos reglas previas del sistema — documentado acá para que quede
explícito, no accidental:

1. **Capital para lotaje ahora incluye crédito del bróker.** Reemplaza
   la regla anterior de `CLAUDE.md` sección "Seguridad" y de
   `PROTOCOLOS_KRONOS_BOT.md` sección 5.1/12.2 (que excluía el crédito
   restando `AccountCredit()`). El EA (`KronosBridgeEA.mq4`) ahora
   reporta `capital_real = AccountBalance()` completo. La fórmula de
   lotaje en sí no cambió: `floor(capital_real / 100) * 0.01` (mismo
   divisor 100 ya documentado en sección 5.2 del protocolo), solo
   cambió qué significa `capital_real`.
2. **Auto-confirmación de señales nuevas, con límite de 2 operaciones
   OPEN simultáneas — solo en `n8n-workflows/split-dev/`.** Contradice
   el principio no negociable #3 del protocolo (confirmación humana
   obligatoria) — a propósito, y únicamente para el stack dev, para
   poder probar el ciclo completo sin depender de tocar botones cada
   vez. Implementado en
   `split-dev/02-señal-nueva-parseo-confirmado.json`: tras insertar la
   señal, se cuenta cuántas señales están `OPEN`; si son menos de 2, se
   auto-confirma (mismo `UPDATE ... WHERE status='PENDING_CONFIRMATION'`
   idempotente que usa el flujo manual) y se dispara la ejecución en
   MT4 sin esperar botones; si ya hay 2 o más, cae a la rama manual de
   siempre (Confirmar/Rechazar). **No aplicado a `split-mvp/` ni a
   producción — el flujo de producción sigue exigiendo confirmación
   manual sin excepción.**

**Pendiente de probar** — mercado cerrado al momento de implementar
esto, no se pudo probar en real todavía. Falta: (a) subir
`split-dev/02-señal-nueva-parseo-confirmado.json` a la instancia dev
vía API, (b) probar con una señal real o simulada que efectivamente
auto-confirme cuando hay <2 OPEN y que respete el límite cuando hay 2,
(c) verificar que el `capital_real` que llega ahora a `settings`
refleja el balance completo (con crédito) tras el próximo ciclo de
`WritePositionsStatus()` del EA — requiere recompilar el `.ex4` en la
máquina real (ver "Cómo se despliega de verdad un cambio del EA a
producción" más abajo, mismo proceso manual).

**Confirmado con el usuario (2026-08-28): el lotaje NO se reparte entre
las 2 operaciones simultáneas por ahora, queda así a propósito.** Cada
señal que se confirma (auto o manual) calcula `floor(capital_real/100)
*0.01` de forma independiente contra el capital total, sin descontar
lo ya usado por otra operación abierta — el límite de 2 solo controla
cuántas pueden estar abiertas a la vez, no divide el capital entre
ellas. **La idea a futuro es que el lotaje disponible SÍ se reparta**
entre las operaciones simultáneas — esto es, en esencia, el mismo
diseño de slots ya descrito en la sección 5.3 del protocolo (hoy
diseñado pero no implementado, pensado para tope de 3 operaciones),
ahora aplicado sobre capital que incluye crédito y con el nuevo tope
de 2. No implementar todavía — dejar anotado como el siguiente paso
natural de este experimento cuando se retome.

**Circuit breaker diario del 6% de ganancia (implementado 2026-08-28,
decisión explícita del usuario, SOLO stack dev).** Si la cuenta ya
subió ≥6% respecto al capital del inicio del día en curso, se deja de
auto-confirmar señales nuevas hasta el día siguiente — caen a
confirmación manual (mismos botones Confirmar/Rechazar de siempre).
**Las posiciones ya abiertas no se tocan**, siguen su curso normal con
su SL/TP; esto solo bloquea la auto-confirmación de señales nuevas.

- Requiere dos columnas nuevas en `settings`: `day_start_capital` y
  `day_start_date` (agregadas a `db/schema.sql`, con nota de
  despliegue — **una base ya existente necesita
  `ALTER TABLE settings ADD COLUMN ...` a mano**, el `CREATE TABLE IF
  NOT EXISTS` no las agrega solo a una tabla que ya existe).
- Implementado en
  `split-dev/02-señal-nueva-parseo-confirmado.json`: nodo `Chequear
  ganancia del día (Postgres)` resetea `day_start_capital` a
  `capital_real` automáticamente cuando cambia la fecha (nuevo día =
  nueva base 0%), y el IF `¿Ganancia del día <6%?` corta a la rama
  manual si ya se llegó al límite — corre **antes** del chequeo de
  <2 operaciones OPEN, en la misma cadena.
- **No aplicado a `split-mvp/` ni a producción.**
- Pendiente de probar (mismo bloqueo que el resto del experimento:
  mercado cerrado) — falta aplicar el `ALTER TABLE` en la base dev,
  subir el workflow, y verificar que efectivamente resetea la base al
  cambiar de día y bloquea al llegar al 6%.

## Descubrimiento y fix real — "Kronos Dev 08 - Resumen diario" existía en n8n y nunca se sincronizó al repo (2026-08-28)

Mientras se armaba el recap para PVG_kronos, salió a la luz que
**ya existe un workflow en la instancia dev de n8n** (`oQgOomA3Qhe26i3m`,
"Kronos Dev 08 - Resumen diario") que corre todos los días a las 11am
y manda exactamente el mensaje de recap ("📊 Resumen del día...") que
el usuario reportó — **nunca estuvo commiteado en el repo**, mismo
patrón de drift ya documentado antes para otros workflows. Se
sincronizó a `n8n-workflows/split-dev/08-resumen-diario.json`.

**Bug real encontrado y corregido, mismo patrón que el bug histórico
de `signals_archive_summary`:** la query original agregaba en vivo
contra `signals` (`WHERE close_timestamp::date = CURRENT_DATE`) — si
`compact_old_signals()` (tope de 20 filas) archivaba una señal cerrada
más temprano el mismo día, esa operación desaparecía del resumen de
las 11am sin ningún aviso. Corregido para que lea de `daily_pnl` en
vez de `signals` (con un `LEFT JOIN` contra `(SELECT 1)` para seguir
notificando "0 operaciones" si no hubo cierres, igual que antes).
**Ya subido y probado en la instancia real de n8n dev** (`PUT
/api/v1/workflows/oQgOomA3Qhe26i3m`, verificado corriendo la query
final contra la base dev real: `total=5, wins=4, losses=1,
total_pl=96.12, win_rate=80.0%`, coincide con el mensaje real que
mandó el bot).

## Integración de PVG_kronos — backend del recap diario (2026-08-28)

**Primera pieza real (no demo) de la integración de `PVG_kronos` como
herramienta externa** (ver `PVG_kronos/docs/INTEGRACION_KRONOS_BOT.md`).
La tabla `daily_pnl` y el trigger que la llena **ya se aplicaron a la
base dev real** (no solo a un Postgres descartable) — ver sección de
arriba, que reutiliza esta misma tabla para el fix del workflow `08`.
`dashboard/static/` sigue sin tocarse, así que el dashboard en uso
real con dinero no cambió de comportamiento.

- **Tabla `daily_pnl`** (`db/schema.sql`): `date` (PK), `profit_loss`,
  `operable`. Se llena **en tiempo real vía trigger** (`update_daily_pnl`,
  disparado por `AFTER UPDATE ON signals`) cuando una señal transiciona
  a un status de cierre real (`TP_REACHED`, `SL_REACHED`,
  `CLOSED_MANUAL`, `CLOSED_BY_PRICE_RACE`) — no depende de un job batch
  de n8n, así que no se pierde nada aunque `compact_old_signals()` borre
  el detalle de `signals` más adelante. Probado con inserciones y
  cierres de prueba: suma correctamente, y un `UPDATE` redundante sobre
  una señal ya cerrada no vuelve a sumar (usa
  `OLD.status IS DISTINCT FROM NEW.status`).
- **"Operable" = hubo al menos un cierre real ese día** (decisión
  explícita del usuario, 2026-08-28: no es lunes-a-viernes fijo, pueden
  operarse domingos según el instrumento).
- **Columna nueva `settings.capital_inicial_plan`**: ancla manual de una
  sola vez (a diferencia de `capital_real`, que sí es automático) —
  mismo concepto que "Capital inicial" en la sección Crecimiento de
  PVG_kronos. Sin este valor cargado a mano, `GET /api/registros`
  devuelve `registros: []`.
- **Endpoint nuevo `GET /api/registros`** (`dashboard/main.py`):
  reconstruye el capital de cada día como `capital_inicial_plan + suma
  acumulada de profit_loss hasta esa fecha` (ventana SQL
  `SUM(...) OVER (ORDER BY date ASC)`, probada con datos de ejemplo),
  en el shape exacto que espera `growth.js` de PVG_kronos
  (`{id, fecha, tipo: 'capital', valor, operable, nota}`). Ya queda
  cubierto por el `@app.before_request` de autenticación básica
  existente, sin cambios adicionales de seguridad.
- **Nota de despliegue** (mismo patrón que el resto de columnas nuevas
  de esta sesión): en una base ya existente hace falta
  `ALTER TABLE settings ADD COLUMN capital_inicial_plan REAL;` y crear
  a mano la tabla `daily_pnl` + la función/trigger `update_daily_pnl`
  (`docker-entrypoint-initdb.d` solo corre en un volumen nuevo).

**Ya aplicado a la base dev real (2026-08-28), no solo probado en
Postgres descartable:**
- `ALTER TABLE` de `daily_pnl` (wins/losses/instruments) y `settings`
  (`day_start_capital`, `day_start_date`, `capital_inicial_plan`).
- Backfill de las 5 señales ya cerradas hoy en dev (`daily_pnl` con
  fecha `2026-08-28`, `capital_inicial_plan` calculado hacia atrás
  desde `capital_real` actual).
- Workflow `08` corregido, subido y verificado contra la instancia
  real de n8n dev.

**Actualizado 2026-08-29 — dashboard real ya reemplazado (en paralelo,
por un fork) y las dos piezas que faltaban ya están resueltas:**

- `dashboard/static/` ya fue reemplazado por el frontend completo de
  PVG_kronos, con el Panel de control conectado a los endpoints reales
  (`/api/positions`, BE/Cerrar) — commit `b6d9045`, solo en el stack
  dev, producción sin tocar.
- **`dashboard/static/js/growth.js` ahora sincroniza con el backend**:
  al iniciar, hace `fetch('/api/registros')`; si responde, usa
  `capital_inicial_plan` y los registros reales en vez de
  `localStorage`, deshabilita la carga/edición manual (los datos se
  generan solos desde `daily_pnl`), y persiste en `Store` para que
  `calendar.js` (que lee `localStorage` directo) también los vea. Si
  el fetch falla (ej. demo estática en GitHub Pages sin backend), seguía
  funcionando 100% con `localStorage` como siempre — comportamiento
  híbrido tal como describe
  `PVG_kronos/docs/INTEGRACION_KRONOS_BOT.md`. Probado contra el
  endpoint real (`curl` con auth básica): responde
  `{"capital_inicial_plan":676.1,"registros":[...]}`.
- **Workflow nuevo `Kronos Dev 09 - Sync capital_real`**
  (`n8n-workflows/split-dev/09-sync-capital-real.json`): lee
  `orders/status.json` cada 5s y actualiza `settings.capital_real` —
  cierra el hueco de prioridad alta que estaba anotado desde antes de
  esta sesión (punto 17 de errores persistentes, más abajo). **Subido,
  activado y verificado en la instancia real de n8n dev**: pasó de
  `772.22` (desactualizado) a `868.34` (valor real leído de
  `orders/status.json`), 3 ejecuciones consecutivas sin error.
- **Hallazgo real en el camino**: los archivos `split-dev/*.json` del
  repo (02 a 07) referencian una credencial Postgres obsoleta
  (`zZQ5m2frFb94qTh2`, "Postgres dev") que **ya no existe** en la
  instancia — la real y activa es `vlp8K6c3mIwlQfkI` ("Postgres
  account"), confirmado contra el workflow `02` que sí corre en vivo
  con ese id correcto. Es el mismo patrón ya documentado de
  "credenciales recreadas por corrupción, nunca resincronizadas al
  repo". **Sin corregir todavía en los archivos existentes** (02-07)
  — solo se corrigió en el workflow nuevo (`09`). Cualquier intento de
  subir 02-07 tal como están hoy al repo fallaría con "Credential...
  does not exist" hasta arreglar ese id.

**Sigue pendiente:**
1. Corregir el id de credencial Postgres obsoleto en
   `split-dev/02-07*.json` antes de subirlos (ver hallazgo arriba).
2. Eliminar la sección de historial de señales del dashboard actual
   una vez confirmado que el Calendario de PVG la reemplaza del todo.
3. Llevar los workflows `08` y `09` (y sus fixes) también a
   `split-mvp/` y a producción cuando corresponda, siguiendo el flujo
   normal (`feature/* → develop → main → producción`) — hoy solo
   existen en la instancia dev real y en `split-dev/` del repo.

## Reporte — primera prueba con tráfico real del grupo, stack dev + MT4 demo (2026-08-28)

Sesión larga (madrugada del 27 al 28/08) probando el ciclo completo con
**mensajes reales** del grupo de Telegram, redirigidos temporalmente
del Telethon de producción hacia el stack dev, ejecutando contra la
cuenta **demo** de MT4 (`911260411`). Detalle completo del
procedimiento de redirección (nodo Webhook temporal + credencial
Header Auth, aplicado solo en la instancia de n8n dev, nunca en el
repo) en el historial de conversación — acá solo el resultado.

### Resultado: el ciclo completo funciona de punta a punta

Grupo real → Telethon → webhook temporal → parser regex → inserción en
Postgres → auto-confirmación (mecanismo temporal, solo para esta
prueba, no forma parte del MVP) → ejecución real en MT4 demo → lectura
de resultado → notificación por Telegram. Verificado con tickets
reales: `#204144208`, `#204145069`, `#204146047`, `#204150530`,
`#204153921` (aperturas y cierres reales, incluida una orden `LIMIT`
por desfasaje de precio, y un cierre manual vía instrucción de
seguimiento real).

### 5 bugs reales encontrados y corregidos (solo en n8n dev, vía API — nunca se tocó el repo ni producción)

Todos comparten el mismo patrón: una expresión `$('NombreDeNodo')`
que referencia un nodo que existe en **otro** workflow (típicamente
`01`), rota porque cada pieza del split (`n8n-workflows/split-mvp/` y
`split-dev/`) corre como ejecución independiente sin acceso a los
nodos del workflow que la llamó. El fix siempre es el mismo patrón:
cambiar la referencia cruzada por `$json` o por
`$('Recibido de otro workflow').item.json` (el nodo trigger local del
propio sub-workflow, en modo `passthrough`).

1. **Workflow `02`** (`Notificar Telegram`) — nunca había funcionado
   la notificación de "nueva señal detectada", ni antes de esta
   sesión. Referenciaba `$('Parsear señal (regex)')` (nodo de `01`).
2. **Workflow `04`** (`Obtener señal confirmada`) — sin este fix,
   **ninguna** ejecución en MT4 funciona, ni con confirmación manual.
   Referenciaba `$('Parsear callback')` (nodo de `03`).
3. **Workflow `06`** (`¿Se actualizó cierre ahora?`) — la rama sin
   match borraba el archivo de cierre del EA sin notificar,
   perdiéndolo para siempre. No era referencia cruzada, era lógica de
   reintento faltante: se corrigió para que esa rama no borre el
   archivo y se reintente en el próximo ciclo del scheduler.
4. **Workflow `07`, pieza 7a** (`Buscar señal referenciada`) —
   referenciaba `$('¿Señal válida?')` (nodo de `01`). Sin este fix,
   **todo** el camino de seguimiento fallaba antes de llegar al
   regex — ninguna instrucción de seguimiento se procesaba nunca.
5. **Workflow `07`** (`¿Tiene acción EA?`, `Preparar acción EA (JSON)`,
   `Escribir acción EA (MT4)`, y los dos nodos `Avisar en chat`) — el
   más grave: `Insertar modificación (Postgres)` pisa `$json` con
   `RETURNING id`, así que `ea_action`/`mt4_ticket`/etc. se perdían.
   **`CLOSE_AT_PRICE`, `CANCEL` y cualquier modificación con acción
   real en el EA quedaban "registradas" en Postgres pero nunca se
   ejecutaban de verdad en MT4** — el sistema reportaba "sin acción
   automática" como si fuera el comportamiento esperado. Ya estaba
   anotado como riesgo conocido en una nota del propio nodo
   `¿Tiene acción EA?` (dejada por una sesión anterior), confirmado y
   corregido en esta.

### Otros hallazgos (documentados, algunos corregidos solo en dev)

- **Modelo de Gemini deprecado**: `gemini-1.5-flash` (404, retirado) →
  se probó `gemini-2.5-flash` (también retirado, Google recomienda
  `gemini-3.6-flash` en el mensaje de error) → se fijó en
  **`gemini-flash-latest`** (alias estable, apunta siempre al flash
  vigente). Corregido en los 3 nodos HTTP de Gemini del workflow `07`
  dev. Ver disponibilidad de modelos reales con
  `GET https://generativelanguage.googleapis.com/v1beta/models?key=...`
  antes de fijar un nombre de modelo a mano en el futuro.
- **`settings.capital_real` nunca se escribe** desde ningún workflow
  de n8n (ni dev ni `split-mvp`) — se sembró a mano en dev
  (`INSERT INTO settings (capital_real) VALUES (772.22)`) para poder
  probar. En producción debe estar cargado a mano en algún momento —
  no hay automatismo real pese a lo que sugiere `CLAUDE.md`. Sin
  resolver.
- **Discrepancia lotaje MVP vs código real**: `04-ejecución-en-mt4.json`
  (dev y `split-mvp`) ya calcula lotaje dinámico
  (`floor(capital_real/100)*0.01`), no el lotaje fijo `0.01` que
  describe el alcance documentado del MVP. Sin resolver, requiere
  decisión del usuario.
- **Faltaban carpetas en el prefijo Wine demo** (`orders/closed/`,
  `orders/actions/`) — `DEV_SETUP.md` las menciona pero no se habían
  creado. Creadas manualmente.
- **`account_mismatch` del EA** bloqueaba `ProcessPendingOrders()`
  contra la cuenta demo (el EA esperaba el perfil `PROD_STD`, cuenta
  `23096429`) — resuelto escribiendo `orders/config.json` con
  `{"profile": "DEMO_VIP"}` (mecanismo ya existente en el EA, sin
  recompilar).
- **Ejecuciones de n8n dev con retención muy agresiva** — el stack
  dev tiene `EXECUTIONS_DATA_PRUNE`/similar configurado de forma que
  los schedulers de 1-2s (`05`, `06`) saturan rápido el historial
  global de ejecuciones, "empujando" ejecuciones raras (como las del
  workflow `07`) fuera de la retención en segundos. Dificultó el
  debugging esta noche. Sin resolver, no es bloqueante pero vale la
  pena revisar la config de retención de `docker-compose.dev.yml`.
- **Credenciales de n8n corrompidas al guardar desde la UI** — pasó
  dos veces (la de `Header Auth` para el webhook temporal, y
  aparentemente algo similar con la de Telegram, aunque en este caso
  el problema real terminó siendo que el usuario le escribía a un bot
  distinto al configurado). El fix que funcionó ambas veces fue
  **recrear la credencial desde cero por API** en vez de editar el
  valor de la existente.

### Decisiones de producto registradas esta sesión (ver rama
`feature/docs-fase8-lotaje-capital`, no mezclada acá)

- Fórmula de lotaje para el modo 100% automático (Fase 8, futuro):
  `floor(capital/500)*0.01`, capital = `AccountBalance()` completo
  (con crédito), tope fijo de 2 operaciones simultáneas.
- Invalidación de órdenes `LIMIT` sin llenar a los 4 minutos — solo
  aplica al modo 100% automático, sin implementar.

### Pendiente / no bloqueante

- Notificación de Telegram: resuelta durante esta sesión (era el bot
  equivocado, no un bug de configuración).
- Camino de confirmación manual por botones (workflow `03`) — no se
  probó esta sesión, se usó un auto-confirmador temporal para saltarlo.
- Tipos de modificación sin probar: `TP_NO_EXISTE`,
  `TP_UPDATE_SIN_VALOR`, `SL_CHANGE`, `TP_UPDATE`, `CLOSE_ALL_TO_BE`.
- Llevar los 5 fixes de bugs a `n8n-workflows/split-mvp/*.json` y a
  producción, siguiendo el flujo normal (`feature/* → develop → main`)
  — **no aplicado todavía a ningún archivo del repo, solo a la
  instancia de n8n dev en caliente.**

## Excepción registrada: acceso remoto al dashboard (commit directo a `main`)

**2026-08-21** — cambio de infraestructura aplicado directo sobre
`main`/producción, autorizado explícitamente por el usuario como
excepción al flujo normal `feature/* → develop → main` (misma
excepción ya usada antes para el cambio LIMIT/MERCADO). Motivo: poder
controlar posiciones abiertas (BE, BE inverso, Cerrar) desde el
celular vía una URL pública, sin depender de estar en la LAN.

Cambios:

- **Túnel ngrok compartido**: se agregó un servicio `caddy` (Caddyfile
  en `proxy/Caddyfile`) delante de `n8n` y `dashboard`. `ngrok` ahora
  apunta a `caddy:8080` en vez de `n8n:5678` directo. `caddy` rutea
  `/webhook/*` → `n8n:5678` (necesario para que Telegram siga
  entregando los callbacks de los botones Confirmar/Rechazar, y para
  el webhook de Telethon) y todo lo demás → `dashboard:8080`. El
  webhook interno Telethon → n8n (`http://n8n:5678/...`, red interna
  `trading_net`) no se tocó.
- **Login básico en el dashboard**: `dashboard/main.py` ahora exige
  HTTP Basic Auth en `@app.before_request` (todas las rutas, sin
  excepciones) usando `DASHBOARD_USER`/`DASHBOARD_PASSWORD` (nuevas
  vars en `.env`, agregadas vacías — hay que completarlas a mano antes
  de levantar el stack). Antes el dashboard no tenía ninguna
  autenticación y confiaba en no estar expuesto por ngrok.
- **Botones táctiles**: los botones de acción por posición (BE, BE
  inverso, Cerrar — ya existían y funcionaban, ver sección "Qué
  funciona probado de punta a punta") ahora tienen un breakpoint
  móvil (`@media max-width: 640px` en `dashboard/static/index.html`)
  que los agranda a tamaño táctil (min 44px) y los apila en columna.
  Se agregó además un `confirm()` de JS antes de encolar `CLOSE`
  (`dashboard/static/app.js`) — es la única acción irreversible de
  las tres, y antes se disparaba con un solo tap sin confirmación.

**Pendiente para que esto funcione en producción:** completar
`DASHBOARD_USER`/`DASHBOARD_PASSWORD` en `.env` del EliteBook (no se
generan ni se muestran automáticamente — regla de seguridad de
`CLAUDE.md`) y recrear el stack (`docker compose up -d --build`) para
que tome el nuevo servicio `caddy` y el cambio de destino de `ngrok`.

## Sync inverso: EA (`KronosBridgeEA.mq4`) de `develop` → `main`

**2026-08-21** — `main` tenía la versión VIEJA del EA hasta este
commit (`fix: sincronizar KronosBridgeEA.mq4 con el sistema de
perfiles ya validado en develop`, rama `feature/sync-ea-perfiles-main`,
mergeada por fast-forward a `main`, pusheada a `origin/main`). Mismo
patrón que ya se dio con el dashboard y con Fase 4/cierre TP-SL:
trabajo real hecho en `develop` que nunca se formalizó hacia `main`.

Diagnóstico completo antes de aplicar (ver detalle en la conversación
de esta fecha, resumen acá):

- La versión de `main` que corrió en producción hoy (con tickets
  reales, `XAUUSD-STD`, cuenta `23096429`) **era funcional pero sin
  ninguna validación de cuenta** — el sufijo de símbolo dependía de
  un input de texto libre (`InpSymbolSuffix`) configurado a mano en
  Properties > Inputs de MT4, sin relación forzada con la cuenta
  realmente conectada. `config.json` en disco ya tenía el formato
  nuevo (`{"profile": "PROD_STD"}`, escrito por el resto del stack),
  pero el EA viejo lo ignoraba en silencio (solo reconocía la clave
  vieja `"symbol_suffix"`).
- La versión de `develop` agrega: `ValidateAccountProfile()`
  (bloquea ejecución si `AccountNumber()` no coincide con el perfil
  activo, revalidado en cada ciclo del timer, no solo al arrancar),
  `STALE_SIGNAL` en el propio EA (descarta señales de apertura con
  más de `InpMaxSignalAgeMinutes` de antigüedad, no solo la
  validación que ya hacía n8n antes de confirmar), y
  `DetectClosedPositions` (reporta cierres por TP/SL/manual a
  `orders/closed/` para que n8n actualice Postgres solo).
- **Verificado que no cambia nada de lo ya probado en real hoy**: el
  fix de duplicados (`FileMove` a `.processing`) y la decisión
  LIMIT/mercado por precio actual vs `entry_price` quedaron
  byte a byte idénticos entre ambas versiones — confirmado con diff
  línea a línea antes de aplicar el sync, no solo de nombre de
  función.
- Alcance del commit verificado con `git diff --stat`: únicamente
  `mt4-bridge/ea/KronosBridgeEA.mq4` (337 inserciones, 40
  eliminaciones) — nada de `n8n-workflows/` ni del dashboard se coló,
  a pesar de que el commit original en `develop` donde nació el
  enum de perfiles (`2160713`) sí tocaba esos archivos también.

**Pendiente — NO se recompiló el `.ex4` en esta sesión.** Queda para
cuando el usuario reabra MT4 manualmente: compilar con F7,
configurar el nuevo input `InpProfile = PROD_STD` en Properties
(reemplaza a `InpSymbolSuffix`, que ya no existe en el código),
verificar en la pestaña Experts que no aparece `ACCOUNT MISMATCH`,
confirmar que solo hay **una** instancia del EA cargada en un
gráfico (bug de instancias triplicadas visto hoy en el log,
`20260821.log`, sigue sin resolverse — no es parte de este sync) y
recién entonces reactivar AutoTrading.

## Excepción registrada: acceso remoto al dashboard (commit directo a `main`)

**2026-08-21** — cambio de infraestructura aplicado directo sobre
`main`/producción, autorizado explícitamente por el usuario como
excepción al flujo normal `feature/* → develop → main` (misma
excepción ya usada antes para el cambio LIMIT/MERCADO). Motivo: poder
controlar posiciones abiertas (BE, BE inverso, Cerrar) desde el
celular vía una URL pública, sin depender de estar en la LAN.

Cambios:

- **Túnel ngrok compartido**: se agregó un servicio `caddy` (Caddyfile
  en `proxy/Caddyfile`) delante de `n8n` y `dashboard`. `ngrok` ahora
  apunta a `caddy:8080` en vez de `n8n:5678` directo. `caddy` rutea
  `/webhook/*` → `n8n:5678` (necesario para que Telegram siga
  entregando los callbacks de los botones Confirmar/Rechazar, y para
  el webhook de Telethon) y todo lo demás → `dashboard:8080`. El
  webhook interno Telethon → n8n (`http://n8n:5678/...`, red interna
  `trading_net`) no se tocó.
- **Login básico en el dashboard**: `dashboard/main.py` ahora exige
  HTTP Basic Auth en `@app.before_request` (todas las rutas, sin
  excepciones) usando `DASHBOARD_USER`/`DASHBOARD_PASSWORD` (nuevas
  vars en `.env`, agregadas vacías — hay que completarlas a mano antes
  de levantar el stack). Antes el dashboard no tenía ninguna
  autenticación y confiaba en no estar expuesto por ngrok.
- **Botones táctiles**: los botones de acción por posición (BE, BE
  inverso, Cerrar — ya existían y funcionaban, ver sección "Qué
  funciona probado de punta a punta") ahora tienen un breakpoint
  móvil (`@media max-width: 640px` en `dashboard/static/index.html`)
  que los agranda a tamaño táctil (min 44px) y los apila en columna.
  Se agregó además un `confirm()` de JS antes de encolar `CLOSE`
  (`dashboard/static/app.js`) — es la única acción irreversible de
  las tres, y antes se disparaba con un solo tap sin confirmación.

**Pendiente para que esto funcione en producción:** completar
`DASHBOARD_USER`/`DASHBOARD_PASSWORD` en `.env` del EliteBook (no se
generan ni se muestran automáticamente — regla de seguridad de
`CLAUDE.md`) y recrear el stack (`docker compose up -d --build`) para
que tome el nuevo servicio `caddy` y el cambio de destino de `ngrok`.

## ⚠️ El gap operativo más importante ahora mismo

**Actualizado 2026-08-28 — el diseño/desarrollo de Fase 4 (Gemini) ya
se dio por terminado en `develop`**, con más alcance del que reflejaba
una versión anterior de esta sección (auditoría de código confirmó
15+ commits de piezas de Fase 4 posteriores a la supuesta pausa por
falta de aprobación — el usuario siguió iterando el diseño igual).
El árbol de decisión completo (regex + fallback a Gemini con
`responseSchema` estructurado) está en
`n8n-workflows/split-mvp/07-seguimiento-gemini.json` (y su par en
`split-dev/`), cubriendo `CANCEL`, `CLOSE_ALL_TO_BE`, `CLOSE_AT_PRICE`,
`TP_UPDATE`, `SL_TO_BE`, `UNCLASSIFIED`. Confirmado: el diseño ya no
está bloqueado, ya no aplica el punto 9 de "errores persistentes" tal
como estaba redactado.

**Estado actualizado 2026-08-28 (sesión de fix aplicado al repo):**

1. **RESUELTO en el repo — bug de campos perdidos tras el INSERT en la
   rama Gemini.** El retry de Gemini en sí (`retryOnFail`,
   `maxTries: 2`, `onError: continueErrorOutput` → `PENDING_MANUAL`)
   **ya existía** en el JSON — un comentario obsoleto dentro de
   `Parsear respuesta Gemini` decía lo contrario, ya corregido. El bug
   real (anotado en la nota histórica de `¿Tiene acción EA?`) era que
   `Insertar modificación (Postgres)` con `RETURNING id` pisaba
   `$json`, perdiendo `ea_action`/`mt4_ticket`/`signal_id`/etc. para
   los 4 nodos siguientes (tanto en la rama regex como en la rama
   Gemini). Se agregó un nodo `Recuperar contexto (post-INSERT)` que
   reconstruye esos campos desde `Expandir targets` o `Parsear
   respuesta Gemini` usando `pairedItem.item` (mismo patrón ya usado
   para el bug análogo del workflow `05`), en
   `n8n-workflows/split-mvp/07-seguimiento-gemini.json` y su par en
   `split-dev/`. **Corregido solo en el repo — todavía no aplicado a
   ninguna instancia real de n8n (ni dev ni producción).**
2. **Paso a producción, aún no hecho.** El workflow que corre en vivo
   (`QxXebyoPgTGmGH2B`, cuenta real VT Markets) sigue siendo el que no
   incluye esta rama ni el fix del punto 1. Falta: (a) agregar
   `GEMINI_API_KEY` a `.env` y a `docker-compose.yml` de producción —
   hoy solo está en `docker-compose.dev.yml`, confirmado por grep
   vacío en el compose de prod — y reiniciar el contenedor de n8n;
   (b) subir el workflow `07` corregido (idealmente probarlo primero
   en el stack dev con una instrucción de seguimiento real) vía
   `PUT /api/v1/workflows/{id}`. Plan de subida completo, con riesgos
   de merge de JSON de n8n y comandos exactos, en `MERGE_PLAN.md`
   (raíz del repo, sin commitear — documento de trabajo, no artefacto
   del repo).

Mientras tanto, sigue siendo **100% responsabilidad manual del
usuario** aplicar SL/BE/cierres vía los botones del dashboard
(`localhost:8088`).

## Cómo se despliega de verdad un cambio del EA a producción (manual, sin automatización)

**No hay ningún mecanismo automático** (sin cron, sin systemd timer, sin
git hook) que compile o sincronice el EA de producción. El flujo real,
confirmado el 2026-08-19 revisando el sistema en vivo, son 3 pasos que
hace el usuario a mano:

1. `git pull`/`git reset` en `Kronos_Bot-prod` — el checkout **separado**
   (no es este directorio) que vive en
   `~/Proyectos/Kronos_Bot-prod`, en rama `main`, y del que cuelga el
   symlink real `MQL4/Experts/KronosBridgeEA.mq4` dentro del prefijo de
   Wine (`~/.wine-mt4/...MQL4/Experts/`).
2. Editar el `.mq4` a mano ahí mismo si hace falta un ajuste puntual
   antes de aprobarlo formalmente vía PR.
3. Abrir MetaEditor dentro de Wine y compilar (F7) — regenera el `.ex4`
   que el terminal MT4 ya tiene cargado.

**⚠️ NUNCA hacer `git reset`/`git pull` en `Kronos_Bot-prod` sin antes
verificar si hay cambios sin commitear en el `.mq4`** (correr
`git diff mt4-bridge/ea/KronosBridgeEA.mq4` ahí antes de resetear) — ya
pasó una vez (2026-08-19) que un fix funcional real (comparación de
precio actual vs `entry_price` en `ExecuteOrder()`, ver sección más
abajo) quedó aplicado solo como edición manual sin commitear en ese
checkout, corriendo en producción real, sin estar en ningún commit de
`main` ni `develop` — un reset sin este chequeo lo habría borrado en
silencio, sin ningún aviso, y el bug original habría vuelto a producción
sin que nadie lo notara hasta la próxima señal real mal ejecutada.

## Cómo se despliega de verdad un cambio del EA a producción (manual, sin automatización)

**No hay ningún mecanismo automático** (sin cron, sin systemd timer, sin
git hook) que compile o sincronice el EA de producción. El flujo real,
confirmado el 2026-08-19 revisando el sistema en vivo, son 3 pasos que
hace el usuario a mano:

1. `git pull`/`git reset` en `Kronos_Bot-prod` — el checkout **separado**
   (no es este directorio) que vive en
   `~/Proyectos/Kronos_Bot-prod`, en rama `main`, y del que cuelga el
   symlink real `MQL4/Experts/KronosBridgeEA.mq4` dentro del prefijo de
   Wine (`~/.wine-mt4/...MQL4/Experts/`).
2. Editar el `.mq4` a mano ahí mismo si hace falta un ajuste puntual
   antes de aprobarlo formalmente vía PR.
3. Abrir MetaEditor dentro de Wine y compilar (F7) — regenera el `.ex4`
   que el terminal MT4 ya tiene cargado.

**⚠️ NUNCA hacer `git reset`/`git pull` en `Kronos_Bot-prod` sin antes
verificar si hay cambios sin commitear en el `.mq4`** (correr
`git diff mt4-bridge/ea/KronosBridgeEA.mq4` ahí antes de resetear) — ya
pasó una vez (2026-08-19) que un fix funcional real (comparación de
precio actual vs `entry_price` en `ExecuteOrder()`, ver sección más
abajo) quedó aplicado solo como edición manual sin commitear en ese
checkout, corriendo en producción real, sin estar en ningún commit de
`main` ni `develop` — un reset sin este chequeo lo habría borrado en
silencio, sin ningún aviso, y el bug original habría vuelto a producción
sin que nadie lo notara hasta la próxima señal real mal ejecutada.

## Qué funciona probado de punta a punta (no solo diseñado)

**Ejecución real en MT4 — verificada con tickets reales de VT Markets**,
no solo en teoría. Ejemplo: señal `9641-A` (XAUUSD BUY, entrada 4398.57,
TP 4402, SL 4370) → confirmada por Telegram → ticket real `24827753`,
abierta y visible en el dashboard con precio en vivo. Desde entonces
corrieron más señales reales (`9644-A/B`, `9646-A/B`), todas con tickets
reales de la cuenta `23096429`.

Flujo completo verificado con señales reales del grupo de Telegram:

```
Telegram (grupo VIP SIGNALS FX)
   → Telethon (microservicio Python, captura el mensaje)
   → Webhook n8n (POST /webhook/kronos-telethon-signal)
   → Parsear señal (regex)
   → ¿Señal válida? (IF: matched=true, status=PENDING_CONFIRMATION)
   → Insertar señal (Postgres) — INSERT ... RETURNING id
   → Notificar Telegram (mensaje + botones Confirmar/Rechazar)
   → [usuario presiona un botón]
   → Trigger Callback Telegram → Parsear callback → ¿Confirmar o rechazar?
   → Actualizar status (Postgres, idempotente) → Responder callback → Avisar en chat
```

Puntos ya verificados en ejecución real (no solo revisados en código):

1. **Captura y parseo.** Telethon reenvía el mensaje real, el parser regex
   lo matchea correctamente, incluyendo el bug histórico ya corregido de
   que el payload llega anidado en `item.json.body`, no en la raíz.
2. **Multi-TP → sub-señales independientes** (protocolo sección 4.2 regla
   6, cambio de diseño reciente): si el mensaje trae 2+ TP, el parser
   genera **hasta 2 items** de salida (`signal_uid` = `{message_id}-A` /
   `-B`), cada uno con su propio TP, mismo instrumento/dirección/entrada/
   SL. TP3 en adelante se ignora. Cada sub-señal se inserta, valida y
   notifica **por separado** — 2 filas en `signals`, 2 notificaciones de
   Telegram con botones independientes.
3. **BIGINT para IDs de Telegram.** `chat_id`, `message_id` y
   `reply_to_message_id` son `BIGINT` en el schema — un `chat_id` real
   negativo grande (`-5523530567`) rompía con `INTEGER`, ya corregido y
   verificado insertando esa fila real.
4. **Botones de confirmar/rechazar funcionales.** No son informativos:
   - `callback_data` usa el `id` real de Postgres (vía `RETURNING id` del
     INSERT), no el `message_id` de Telegram.
   - El `UPDATE` de status es **idempotente**: usa un CTE
     (`WHERE status = 'PENDING_CONFIRMATION'`) que siempre devuelve
     `updated_count` y `current_status`, así un doble clic no reprocesa
     la señal ni duplica el mensaje — responde "ya fue procesada".
   - Además del toast de `answerCallbackQuery` (fácil de perder, se
     desvanece solo), se manda un **mensaje real al chat** confirmando o
     rechazando, para que quede visible en el historial.
5. **Auto-init de la base de datos.** `db/schema.sql` está montado como
   `docker-entrypoint-initdb.d/schema.sql` en el servicio `postgres` de
   `docker-compose.yml` — si se recrea el volumen `postgres_data` desde
   cero, el schema se aplica solo, sin pasos manuales.

## Infraestructura Docker — corriendo y verificada

`docker-compose.yml`, servicios en la red `trading_net`:

- **`n8n`** — imagen oficial, puerto 5678. Variables clave agregadas
  durante esta fase: `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` (sin esto,
  `$env` no se resuelve dentro de expresiones de nodos) y
  `TELEGRAM_USER_CHAT_ID` (sin esto, el nodo de notificación mandaba
  `chat_id` vacío). Volumen de datos en `/home/node/.n8n`, persistencia
  verificada.
- **`postgres`** — `postgres:16-alpine`, volumen `postgres_data` +
  bind-mount de `db/schema.sql` en `docker-entrypoint-initdb.d/`. Se
  recreó el volumen limpio al menos dos veces durante esta fase (fixes de
  schema) y el auto-init funcionó ambas veces sin intervención manual.
- **`ngrok`** — expone n8n a un dominio fijo (`N8N_HOST`) para que
  Telegram le llegue.
- **`telethon`** — build local, apunta a
  `http://n8n:5678/webhook/kronos-telethon-signal`.

**Reorganización visual del workflow (sin commitear):** el JSON de
`n8n-workflows/webhook-mvp-workflow.json` en el working tree tiene 5
notas adhesivas nuevas (`stickyNote`) agrupando el canvas en secciones
(1. Captura y parseo, 2. Confirmación Telegram, 3. Seguimiento/Fase 4,
4. Ejecución en MT4, 5. Detección de cierres TP/SL) y varios nodos
reposicionados para que coincidan visualmente con esos grupos. Es solo
reordenamiento/documentación del canvas — no cambia tipos de nodo, no
agrega ni quita lógica (mismo conteo de nodos funcionales antes y
después del diff).

**Modificación manual de workflows vía API de n8n:** durante esta fase se
detectó que el JSON de `n8n-workflows/webhook-mvp-workflow.json` en el
repo y el workflow cargado en la instancia real de n8n son **copias
independientes** — editar el archivo no actualiza automáticamente lo que
corre en n8n, hay que reimportar. Varias veces se aplicaron fixes
directo contra la instancia viva vía `PUT /api/v1/workflows/{id}` (con
`N8N_API_KEY` en `.env`) para evitar depender de la UI, y después se
sincronizó el JSON del repo bajándolo de vuelta vía `GET`. **Riesgo real
ya observado:** si el navegador tiene el editor de n8n abierto con un
borrador viejo y se guarda/publica desde la UI, sobrescribe cambios
hechos por API — pasó al menos una vez y se perdió el guard de
idempotencia temporalmente, hubo que reconstruirlo. Recomendación:
cerrar y reabrir la pestaña del editor antes de tocar la UI después de
un cambio por API.

## Etapa 6 — EA puente en MT4 (en progreso)

Sub-etapas de esta fase, con estado individual:

### 1. Wine + MT4 instalado — ✅ completo, con sesión real activa

- `scripts/setup-mt4.sh` (Linux, cualquier distro Arch-based — verifica
  `pacman`, no asume CachyOS) instala `wine`/`winetricks`, crea el
  prefijo dedicado `~/.wine-mt4`, crea `mt4-bridge/orders/{pending,
  results}/`.
- `scripts/setup-mt4.ps1` — equivalente para Windows nativo (sin Wine).
- **Fix real durante la ejecución:** `WINEARCH=win32` ya no es válido en
  Wine 7+ (modo `wow64` combinado) — el script fallaba con
  `"WINEARCH is set to 'win32' but this is not supported in wow64 mode"`
  en Wine 11.15. Se quitó esa variable, el prefijo por defecto corre MT4
  (32 bits) sin problema.
- **MT4 se instaló con el instalador real de VT Markets**
  (`vtmarkets4setup.exe`, descargado de vtmarkets.com) — no con el
  genérico de metatrader4.com como se había asumido inicialmente; VT
  Markets sí distribuye su propio instalador.
- Instalado correctamente en `~/.wine-mt4` (confirmado: carpeta
  `MetaQuotes/Terminal/<ID>/` con `MQL4/`, `config/`, etc.)
- Sesión real iniciada (cuenta `23096429`, servidor de VT Markets),
  terminal corriendo (`terminal.exe` bajo Wine, verificado con `ps`).

### 2. Formato de archivos + symlinks a Common/Files — ✅ completo y verificado

- `mt4-bridge/FORMATO_ARCHIVOS.md` define el contrato exacto:
  - Orden pendiente: `mt4-bridge/orders/pending/{signal_id}.json`
    (`signal_id`, `signal_uid`, `instrument`, `direction`,
    `execution_type`, `entry_price`, `sl`, `tp`, `lot` fijo `0.01`,
    `created_at`).
  - Resultado: `mt4-bridge/orders/results/{signal_id}.json` (`success`,
    `ticket`, `executed_price`, `executed_at`, `error_code`,
    `error_message`).
  - `signal_id` reutiliza el `id` numérico de Postgres, ya usado en los
    botones de Telegram — no se inventó un segundo identificador.
- **Descubrimiento técnico clave:** MQL4 no permite acceso a rutas de
  archivo arbitrarias (ni con Wine) — las funciones nativas `FileOpen`/
  `FileWrite` están sandboxeadas a `MQL4\Files\` del terminal, salvo que
  se use la bandera `FILE_COMMON`, que redirige a una carpeta compartida
  fija: `.../MetaQuotes/Terminal/Common/Files/` (no depende del ID del
  terminal, a diferencia de la carpeta específica de cada instalación).
- **Ruta real confirmada en esta máquina:**
  ```
  ~/.wine-mt4/drive_c/users/<usuario>/AppData/Roaming/MetaQuotes/Terminal/Common/Files/
  ```
- `mt4-bridge/orders/pending/` y `mt4-bridge/orders/results/` en el repo
  son **symlinks locales** hacia
  `Common/Files/orders/{pending,results}/` de ese prefijo de Wine.
  Verificado con una escritura de prueba: un archivo creado del lado del
  repo aparece instantáneamente del lado de `Common/Files`.
- **Estos symlinks son específicos de esta máquina/usuario y NUNCA se
  commitean.** `git status` en este repo va a mostrar permanentemente,
  en cualquier máquina con Wine configurado:
  - `borrados: mt4-bridge/orders/pending/.gitkeep` y `results/.gitkeep`
  - `sin seguimiento: mt4-bridge/orders/pending` y `results` (los
    symlinks)

  Esto es el estado local esperado, igual que `.env` — **nunca usar
  `git add -A` en este repo**, y menos dentro de `mt4-bridge/`. Los
  `.gitkeep` siguen versionados porque son necesarios para que un clone
  nuevo (sin Wine configurado todavía) tenga las carpetas reales antes
  de correr el setup.
- **Intento de cambio en `.gitignore` — revertido, ya no es tema
  pendiente.** Hubo un cambio local sin commitear que reemplazaba el
  patrón de ignorar el *contenido* de las carpetas
  (`mt4-bridge/orders/pending/*` / `results/*`, con excepción explícita
  de los `.gitkeep`) por ignorar directamente las rutas completas
  (sin excepción de `.gitkeep`) — eso habría dejado a los `.gitkeep`
  fuera del tracking la próxima vez que se tocara ese archivo, algo
  que el usuario confirmó explícitamente que nunca quiso. Se revirtió
  con `git checkout -- .gitignore`. El patrón vigente sigue siendo el
  original: ignora contenido, con excepción explícita para los
  `.gitkeep`, que siguen versionados tal como exige `CLAUDE.md`.

### 3. EA en MQL4 — ✅ compilado y ejecutando órdenes reales

- `mt4-bridge/ea/KronosBridgeEA.mq4` — Expert Advisor que:
  - Usa `OnTimer` (no `OnTick`) para hacer polling de
    `orders/pending/*.json` cada `InpPollIntervalSeconds` (default 2s).
  - Parser JSON manual minimalista (`JsonGetValue`) — MQL4 no trae uno
    nativo; suficiente porque el schema es plano y fijo, sin anidamiento.
  - Valida cada campo antes de intentar `OrderSend` (tipos, presencia,
    rangos > 0) — si el JSON es inválido, nunca llega a ejecutar nada.
  - Lee/escribe archivos en modo `FILE_BIN` (no `FILE_TXT` — en MQL4
    `FileReadString` en modo texto tokeniza por espacios y rompería el
    JSON), decodificando/codificando UTF-8 a mano.
  - Todas las operaciones de archivo usan `FILE_COMMON`.
  - Decide `OP_BUY`/`OP_SELL`/`OP_BUYLIMIT`/`OP_BUYSTOP`/`OP_SELLLIMIT`/
    `OP_SELLSTOP` según `execution_type` y dónde quedó el precio actual
    respecto a `entry_price`.
  - **Fix aplicado tras revisión externa (protocolo sección 4.2 regla
    3):** si `execution_type` es `LIMIT` pero el precio actual ya
    alcanzó/cruzó `entry_price`, se ejecuta como `MARKET` (con el precio
    actual), no como orden pendiente — antes de este fix, siempre creaba
    una orden pendiente aunque el nivel ya se hubiera alcanzado.
  - Borra el archivo de `pending/` tras procesarlo (éxito o JSON
    inválido); si no pudo **leer** el archivo (posible escritura a medias
    de n8n), no lo borra, reintenta en el siguiente ciclo.
  - Escribe siempre un resultado en `results/{signal_id}.json`, tanto en
    éxito como en fallo (con `error_code`/`error_message` de MQL4).
  - Logging con `Print()` en cada paso clave, visible en la pestaña
    **Experts** de MT4.
  - `WritePositionsStatus()` reporta `account.balance`, `account.equity`
    y **`account.capital_real`** (`AccountBalance() - AccountCredit()`,
    protocolo sección 5.2 / regla no negociable de `CLAUDE.md`: nunca
    usar `AccountBalance()` solo para capital, puede incluir crédito
    del bróker) — pensado para que n8n actualice `settings.capital_real`
    sin edición manual. **Cambio local sin commitear todavía** (no
    subido a `develop` ni a producción); falta el lado de n8n que lo
    consuma (el nodo `Obtener capital real (settings)` de las ramas de
    `MERGE_PLAN.md` lee de la tabla `settings`, no de este campo del
    EA directamente — falta conectar ambos).
- Revisado en conjunto con el usuario (vía archivo enviado, no pegado en
  terminal — pegarlo corrompía el código).
- **Compilado con MetaEditor** (`KronosBridgeEA.ex4` presente en
  `MQL4/Experts/`) y **adjuntado a gráficos reales** (XAUUSD-STD,
  EURUSD-STD) — verificado vía log de MT4 (`MQL4/Logs/`), incluyendo el
  polling de `orders/pending/*.json`, la actualización en caliente del
  sufijo de símbolo desde `orders/config.json`, y errores reales de
  permisos de escritura ya resueltos.
- **Fix real post-compilación:** al abrir 2 sub-señales del mismo
  instrumento casi simultáneas (multi-TP), el bróker devolvía error
  4109 (trade context busy) en la segunda `OrderSend` — se agregó una
  pausa corta entre órdenes consecutivas.

### 4 y 5 — Nodos de n8n para el puente con MT4

- **Etapa 4 — ✅ implementada y verificada end-to-end con dinero real.**
  Confirmar una señal real en Telegram escribe la orden, el EA la
  levanta y ejecuta, y vuelve un ticket real (ver arriba). En la
  rama `feature/n8n-mt4-order-bridge`:
  - **Bloqueo de infraestructura resuelto:** n8n corre en Docker y no
    tenía acceso al filesystem del host donde vive `mt4-bridge/orders/`
    (symlinks a Wine). Se agregó a `docker-compose.yml` un bind mount
    nuevo: `${MT4_ORDERS_HOST_PATH}:/mt4-bridge/orders` en el servicio
    `n8n`, más `MT4_ORDERS_DIR=/mt4-bridge/orders` como env var interna.
    `MT4_ORDERS_HOST_PATH` se agregó a `.env` (no versionado, específico
    de esta máquina) apuntando directo a
    `~/.wine-mt4/.../MetaQuotes/Terminal/Common/Files/orders` — se monta
    el destino real, no el symlink del repo (Docker no puede resolver
    symlinks que apuntan fuera del árbol montado). Verificado con una
    escritura de prueba desde dentro del contenedor, visible del lado
    de Wine.
  - Tres nodos nuevos en el workflow, en la rama `CONFIRMED` del flujo
    (contenido histórico de esta sección, aún vigente):
    de callback (paralelo a `Responder callback: Confirmada`, no lo
    reemplaza): **`Obtener señal confirmada`** (Postgres `SELECT`, ya
    que el `UPDATE` de `Actualizar status: CONFIRMED` solo devuelve
    `updated_count`/`current_status`, no la fila completa) →
    **`Preparar orden pending (JSON)`** (Code, arma el JSON exacto de
    `FORMATO_ARCHIVOS.md`, lotaje fijo `0.01`) → **`Escribir orden
    pending (MT4)`** (`n8n-nodes-base.readWriteFile`, escribe en
    `{{ $env.MT4_ORDERS_DIR }}/pending/{{ signal_id }}.json`).
  - Ya subido vía API a la instancia real de n8n (workflow activo
    `QxXebyoPgTGmGH2B`) y sincronizado de vuelta al JSON del repo.
  - **Prueba end-to-end real disparada y verificada** (ver el ejemplo
    de `9641-A`/ticket `24827753` al inicio de este documento).
- **Etapa 5 — ✅ implementada y verificada end-to-end.** Rama
  `feature/n8n-read-mt4-results`. Seis nodos nuevos, en paralelo al
  flujo de confirmación (no tocan los nodos existentes):
  **`Trigger: leer resultados MT4`** (`scheduleTrigger`, cada 5s) →
  **`Leer resultados (MT4)`** (`readWriteFile`, operation `read`,
  `fileSelector = {{ $env.MT4_ORDERS_DIR }}/results/*.json`, soporta
  glob, 0 items si no hay archivos — no falla) → **`Parsear resultado
  (MT4)`** (Code) → **`Actualizar status: OPEN/PENDING_MANUAL`**
  (Postgres, `UPDATE` idempotente `WHERE status = 'CONFIRMED'`,
  `status` final `OPEN` si `success=true` o `PENDING_MANUAL` si
  `success=false`) → **`¿Se actualizó ahora?`** (IF sobre
  `updated_count`) → rama `true`: **`Avisar en chat: Resultado MT4`**
  (Telegram, texto distinto para éxito/fallo) → ambas ramas confluyen
  en **`Borrar archivo de resultado`** (Code, `fs.promises.unlink`,
  se ejecuta siempre haya o no notificado).
  - **Detalle técnico no obvio, encontrado en esta etapa:** esta
    versión de n8n usa modo de binarios `filesystem-v2`
    (`settings.binaryMode: "separate"`) — el contenido del archivo
    leído por `readWriteFile` **no** viaja en base64 dentro de
    `item.binary.data.data` (ahí solo hay el string literal
    `"filesystem-v2"`, un marcador). Hay que leer el contenido real
    con `await this.helpers.getBinaryDataBuffer(i, 'data')` dentro
    del Code node. Intentar `Buffer.from(item.binary.data.data,
    'base64')` como en versiones más viejas de n8n rompe con
    `SyntaxError: ... is not valid JSON` (el string `"filesystem-v2"`
    decodificado de "base64" da bytes basura).
  - **Segundo detalle no obvio:** el nodo Postgres intermedio
    reemplaza `item.json` por las columnas devueltas por la query, así
    que el nodo de borrado no puede leer `$json.fileName` directo —
    hay que recuperarlo del nodo `Parsear resultado (MT4)` usando el
    `pairedItem` del item actual (`$('Parsear resultado (MT4)').all()
    [idx].json.fileName`, con `idx` sacado de `item.pairedItem.item`)
    para que el índice sea correcto incluso si el IF divide en dos
    ramas.
  - Requiere `NODE_FUNCTION_ALLOW_BUILTIN=fs` en el servicio `n8n` de
    `docker-compose.yml` (n8n restringe qué módulos built-in de Node
    puede usar un Code node) — agregado.
  - **Probado en real:** al implementar esto había 5 archivos de
    `results/` acumulados de pruebas manuales previas de la Etapa 6
    (EA) que nunca se habían consumido (`7.json`...`11.json`) — el
    trigger nuevo los procesó todos en el primer ciclo, actualizó
    Postgres (`7` y `8` a `PENDING_MANUAL` por error real del EA, `9`,
    `10`, `11` a `OPEN` con tickets reales de VT Markets) y los borró.
    Además se probó manualmente un archivo `999999.json` con
    `signal_id` inexistente en Postgres: `updated_count` dio `0`
    (sin error), no se mandó notificación (la señal nunca estuvo en
    `CONFIRMED`), y el archivo igual se borró — comportamiento
    idempotente correcto.
  - Workflow sincronizado de vuelta a
    `n8n-workflows/webhook-mvp-workflow.json` tras subir los nodos vía
    `PUT /api/v1/workflows/{id}`.

### Análisis de riesgo — bajar `Trigger: leer resultados MT4` de 5s a 1-2s

Pendiente de aplicar (no aplicado todavía — requiere aprobación
explícita del usuario y probarse primero en el stack dev, según
exige `CLAUDE.md`). Contexto: se identificó en la auditoría de
latencia que este trigger (`scheduleTrigger`, `secondsInterval: 5`,
ver detalle de la Etapa 5 arriba) es el cuello de botella principal
del ciclo de confirmación → ejecución → notificación, ya que el EA
hace polling a ~1s pero el resultado no se lee hasta el próximo tick de
n8n (hasta 5s de espera adicional en el peor caso).

En una sesión anterior se mencionó un incidente de "100+
ejecuciones/minuto" en dev al bajar un intervalo similar — no se
encontró documentado en este archivo, en `CLAUDE.md`, ni en mensajes
de commit (búsqueda por "100", "ejecuciones", "incidente", "bucle",
"saturad", "polling excesivo", "CPU"). No se puede confirmar la causa
puntual de ese incidente. El análisis que sigue es evaluación técnica
propia a partir de cómo está construido el flujo actual, no una
comparación directa contra ese incidente.

**Por qué este cambio es de bajo riesgo, estructuralmente distinto
de un posible patrón de sobrecarga:**

- El nodo `Leer resultados (MT4)` (`readWriteFile`, `operation: read`,
  glob `results/*.json`) no dispara ninguna query a Postgres si no
  hay archivos — devuelve 0 items y el resto de la rama no corre.
  Bajar el intervalo a 1-2s multiplica la frecuencia de un `readdir`
  sobre una carpeta local (bind mount, no red), no la frecuencia de
  queries a Postgres. El `UPDATE` a Postgres solo ocurre por archivo
  de resultado real presente — está acotado por el volumen real de
  señales ejecutadas por el EA, no por la frecuencia del trigger.
- El volumen real de archivos en `results/` es bajísimo (unidades por
  señal confirmada, no un stream continuo) — un `readdir` cada 1-2s
  sobre una carpeta casi siempre vacía es una operación de
  filesystem local trivial, muy por debajo de cualquier límite
  razonable de CPU/IO en el EliteBook.
- Un patrón de "100+ ejecuciones/minuto" descontrolado típicamente
  viene de un trigger que SIEMPRE produce trabajo downstream en cada
  tick (ej. una query que siempre devuelve filas, o un loop que se
  re-dispara a sí mismo) — no es la forma de este nodo, que es
  idempotente y de costo ~0 cuando no hay archivos (caso normal).
- Riesgo residual a vigilar, no bloqueante: si el volumen de señales
  simultáneas creciera mucho (ej. muchos TPs en paralelo con EA
  lento en vaciar `results/`), un intervalo de 1s podría solapar
  ejecuciones del trigger antes de que la anterior termine — mitigar
  probando en dev primero con carga realista (varias sub-señales a
  la vez) antes de subir a producción, tal como exige `CLAUDE.md`.

**Recomendación:** bajar a 2s (no 1s) como punto intermedio razonable
entre latencia y margen de seguridad, probar en el stack dev con una
señal multi-TP real, y solo entonces evaluar producción. No aplicar
todavía sin luz verde explícita del usuario.

### Pendiente — split del workflow en 7 workflows aislados por canal

**Bloqueado (2026-08-21): el usuario no puede abrir n8n ahora mismo.
No se tocó ni se importó nada en la instancia real — el workflow
`develop`/producción sigue funcionando exactamente como hasta hoy,
sin cambios.** Lo que existe es solo una propuesta en archivos locales,
sin aplicar:

- `n8n-workflows/split-mvp/` y `n8n-workflows/split-dev/` — el
  workflow monolítico partido en 7 workflows independientes (entrada,
  señal nueva, confirmación Telegram, ejecución MT4, scheduler
  resultados, scheduler cierres, seguimiento/Gemini), conectados entre
  sí con nodos Execute Workflow en modo fire-and-forget
  (`waitForSubWorkflow: false`) para que un canal saturado (ej. Gemini
  lento) no bloquee ni comparta cola con los demás.
- Dentro de esos archivos de split (no en los originales
  `webhook-mvp-workflow.json` / `webhook-dev-workflow.json`, que
  quedaron intactos) también se bajó el `scheduleTrigger` de
  resultados/cierres MT4 de 5s a 1s — ver análisis de riesgo arriba
  (ahí la recomendación fue 2s; en el split quedó en 1s, a revisar
  cuál de los dos valores usar cuando esto se retome).
- Falta, una vez que n8n esté accesible de nuevo: importar los 7
  archivos en el stack **dev**, reseleccionar manualmente el workflow
  destino en cada nodo `Ejecutar: ...` (el ID no existe hasta
  importar — ver `n8n-workflows/split-mvp/README.md`), probar el ciclo
  completo ahí, y solo después evaluar pasar el split a producción.
  **No aplicar a producción sin aprobación explícita.**

## Documentación de instalación — completa hasta esta etapa

- `docs/INSTALL_LINUX.md` — guía completa desde SO recién instalado:
  Docker/Docker Compose, plantilla de `.env`, levantar el stack, aplicar
  `schema.sql` manual si el volumen ya existía, `scripts/setup-mt4.sh`
  paso a paso, instalación real de MT4 con el instalador de VT Markets,
  fix de `set -gx WINEPREFIX` (fish shell, no `export` como en bash),
  symlinks de `mt4-bridge/` y por qué son locales, verificación del
  puente de archivos.
- `docs/INSTALL_WINDOWS.md` — mismo flujo para Windows nativo (Docker
  Desktop o WSL2, MT4 sin Wine vía `scripts/setup-mt4.ps1`, ruta
  `%APPDATA%\MetaQuotes\Terminal\Common\Files\` en vez de la ruta con
  prefijo de Wine, equivalente con `mklink`). Marcado explícitamente
  como **no verificado end-to-end** (a diferencia del de Linux, que sí
  se probó en la máquina real del usuario).

## Desde el snapshot del 14/08 — qué se agregó

- **Dashboard (Flask, `localhost:8088`)**: posiciones abiertas en vivo
  (precio, profit, SL/TP), botones **BE** y **Cerrar** por posición
  (escriben comandos que el EA lee de `orders/actions/` y ejecuta),
  botón **Reintentar** para señales en `PENDING_MANUAL`, historial de
  señales con filtros por período y numeración de ciclo visual (1-20,
  se resumen las más viejas en la fila "#0"), y un selector de sufijo
  de símbolo del bróker (`-VIP` demo / `-STD` real) que el EA lee en
  caliente desde `orders/config.json` sin recompilar.
- **Fix de pérdida de eventos en Telethon**: en el grupo real (~3900
  suscriptores, tráfico alto), Telethon a veces pedía un resync de
  "difference" ante un gap de `pts` y no volvía a disparar
  `events.NewMessage` — el mensaje se perdía en silencio. Se agregó un
  polling de respaldo cada 15s sobre el historial reciente del chat,
  deduplicado por `message_id`, como red de seguridad del evento en
  vivo. También se corrigió el `timestamp` enviado a n8n para usar la
  fecha real del mensaje (`message.date`) en vez de la hora de captura.
- **Nodo de debug en n8n**: notifica por Telegram privado cualquier
  mensaje del grupo que no matchee el regex de señal nueva, para poder
  confirmar en vivo que Telethon está leyendo el grupo correcto.
- **Repo limpio**: historia de git reescrita para sacar atribución de
  herramientas de IA en los commits, ramas viejas ya mergeadas
  eliminadas (local y remoto), solo quedan `main` y `develop`.
- **README y documentación reestructurados** para portafolio: la
  historia y el porqué del proyecto viven en `README.md`; el detalle
  técnico completo (decisiones de arquitectura, retos técnicos,
  instalación, configuración, roadmap) vive en `docs/versions/v1.md`,
  versionado aparte para cuando exista v2.

## Qué NO hace todavía

- **Interpretación por Gemini** (Fase 4 del roadmap original) — mover
  SL, BE, cerrar, `CLOSE_AT_PRICE` — diseñado en detalle en
  `PROTOCOLOS_KRONOS_BOT.md`, cero código.
- **Cálculo de lotaje por slots** (80/20, sección 5.3 del protocolo) —
  fórmula definida, no implementada. Todas las señales (incluidas ambas
  sub-señales de una señal multi-TP) usan lotaje fijo `0.01`.
- **Ciclo de cierre y registro en Google Sheets** (Fase 7) — sin
  empezar. Los cierres (BE/Cerrar) hoy se hacen manual desde el
  dashboard, y no se registran en ningún lado fuera de Postgres.
- **Loop de reintento de precio con Gemini** (protocolo sección 8) —
  depende de que exista la ejecución real en MT4.
- **Ejecución 100% automática sin confirmación** (Fase 8, futuro) — todo
  el diseño actual asume confirmación humana obligatoria (protocolo,
  principio no negociable #3).
- ~~Detección de motivo de cierre (TP vs SL)~~ — **CORREGIDO
  2026-08-21, ya no está pendiente (esta entrada estaba
  desactualizada).** `DetectClosedPositions()` en
  `KronosBridgeEA.mq4` compara `OrderClosePrice()` contra TP/SL y
  escribe `orders/closed/<ticket>.json` con `close_price`, `profit`
  neto y motivo (`TP_REACHED`/`SL_REACHED`/`CLOSED_MANUAL`).
  Verificado directamente en la máquina real: el `.mq4` en
  `~/.wine-mt4/.../MQL4/Experts/` ya tiene la función, y el `.ex4`
  compilado tiene fecha del 2026-08-21 17:56 (posterior al código) —
  o sea que está compilado y activo. Del lado de n8n, se confirmó vía
  `GET /api/v1/workflows/QxXebyoPgTGmGH2B` en el workflow EN VIVO que
  los nodos `Trigger: leer cierres MT4` → `Leer cierres (MT4)` →
  `Parsear cierre (MT4)` → `Actualizar status: cierre TP/SL` →
  `Avisar en chat: Cierre TP/SL` ya existen y están conectados en
  producción. El ciclo completo (detectar cierre → precio/motivo →
  actualizar Postgres → avisar por Telegram) está activo de punta a
  punta, no pendiente.

## ⚠️ Errores persistentes / problemas abiertos que necesitan iteración

Lista de problemas conocidos, reales o de diseño, que **no están
resueltos** y no son un simple "próximo paso" — requieren decisión,
prueba en real, o iteración adicional antes de darlos por cerrados.

1. **`GEMINI_API_KEY` ausente — bloqueante confirmado para Fase 4.**
   No está en `.env` ni referenciada en `docker-compose.yml`
   (servicio `n8n`, sección `environment`). Sin esto, el nodo
   `Interpretar con Gemini` falla siempre. Falta: conseguir la key
   (capa gratuita, ver `CLAUDE.md`), agregarla en ambos lugares, y
   reiniciar el contenedor de n8n para que la tome. Ver Paso 3 de
   `MERGE_PLAN.md`.
2. **Workflow de producción — verificado por `GET` en vivo el
   2026-08-18, YA SINCRONIZADO (corrige la entrada anterior de este
   punto).** Se consultó `GET /api/v1/workflows/QxXebyoPgTGmGH2B` y se
   comparó nodo por nodo y `connections` completo contra el JSON local
   (`develop` + working tree): **56 nodos en ambos, cero diferencias**
   — Fase 4, consumidor de cierres TP/SL, y el fix de sin-tope de
   sub-señales ya están todos en producción. El nombre del workflow
   sigue diciendo "MVP Fase 3" (cosmético, no se actualizó al renombrar
   fases) — no confundir el nombre con el contenido real. `MERGE_PLAN.md`
   describía esto como pendiente; ya no lo está para el JSON del
   workflow en sí (sigue pendiente el `GEMINI_API_KEY`, punto 1, y
   recompilar el EA, punto 3, para que lo ya subido funcione de
   punta a punta).
3. **RESUELTO 2026-08-21 — `DetectClosedPositions()` ya compilado y
   activo en producción.** Verificado directamente: el `.ex4` en
   `~/.wine-mt4/.../MQL4/Experts/KronosBridgeEA.ex4` tiene fecha
   2026-08-21 17:56, posterior al `.mq4` que agrega la función — está
   compilado y corriendo. El nodo n8n que consume
   `orders/closed/*.json` también está confirmado activo en el
   workflow EN VIVO (no solo en `develop`). Esta entrada decía lo
   contrario por desactualización, no por un problema real.
4. **`docs/INSTALL_WINDOWS.md` no verificado end-to-end.** A
   diferencia de la guía Linux (probada en la máquina real del
   usuario), la de Windows nunca se corrió de punta a punta — puede
   tener pasos rotos o desactualizados si alguien la sigue tal cual.
5. **Pérdida de eventos de Telethon — mitigado, no eliminado.** El
   polling de respaldo cada 15s reduce el riesgo de perder mensajes
   cuando Telegram fuerza un resync de "difference" en el grupo de
   alto tráfico, pero sigue siendo un parche sobre un problema de
   fondo (la librería no siempre re-dispara `events.NewMessage` tras
   el resync). No hay alerta si el polling de respaldo también
   fallara silenciosamente — nadie se entera salvo revisando logs.
6. **Sin cálculo de lotaje real (80/20).** Todas las señales — incluida
   cada sub-señal de una señal multi-TP — usan `0.01` fijo. La fórmula
   de slots está definida en el protocolo (sección 5.3) pero no
   implementada ni probada; hasta que exista, el sistema no gestiona
   riesgo real de forma proporcional al capital.
7. **`error 4109` (trade context busy) — mitigado con pausa fija, no
   resuelto de raíz.** Al abrir 2 sub-señales del mismo instrumento
   casi simultáneas, el bróker rechazaba la segunda `OrderSend`. Se
   agregó una pausa corta entre órdenes consecutivas como parche; no
   hay reintento automático si el error igual ocurriera bajo más
   carga (ej. 3+ sub-señales si se saca el tope, ver punto de
   `sin-tope-sub-senales` arriba).
8. **Sin registro de cierres fuera de Postgres (Fase 7 completa).**
   El lazo de detección TP/SL (punto 3) ya está cerrado y activo, pero el
   registro en Google Sheets sigue sin existir — los cierres viven
   solo en la base de datos, sin respaldo externo ni reporte legible
   fuera del dashboard.
9. **RESUELTO 2026-08-28 — Gemini / Fase 4 dada por terminada en
   diseño y desarrollo (`develop`).** Esta entrada decía "pendiente de
   rediseño con aprobación explícita del usuario, no subir a
   producción bajo ninguna circunstancia" — el usuario confirmó que la
   Fase 4 ya está terminada. Lo que queda no es de diseño, son dos
   cosas puntuales de implementación: (a) el bug de retry/campos
   perdidos en la rama Gemini del workflow `07` (ver "gap operativo"
   al inicio de este documento), y (b) el paso a producción en sí
   (agregar `GEMINI_API_KEY` al `.env`/`docker-compose.yml` de
   producción — hoy solo está en el de dev — y subir el workflow
   corregido). Ninguno de los dos requiere una nueva ronda de
   aprobación de diseño, solo terminarlos.
10. **`error 4109` (trade context busy) — decisión de fix ya tomada,
    falta implementar.** En vez del parche actual de pausa fija entre
    `OrderSend()` consecutivos, el EA debe procesar **una sola orden**
    de `orders/pending/` por ciclo de `OnTimer`, no todas las que
    encuentre de una vez — elimina la causa raíz (varios `OrderSend()`
    casi simultáneos) en lugar de mitigarla. Se implementa después de
    confirmar el punto 11 (medir lentitud antes de tocar el timing del
    EA, para no introducir un cambio de performance a ciegas).
11. **Percepción de lentitud — sin medir todavía, no optimizar a
    ciegas.** Hay percepción de que el sistema es lento, pero no hay
    datos: falta agregar timestamps de diagnóstico en los puntos clave
    del flujo (llegada del webhook, inicio/fin de cada nodo relevante,
    latencia de Gemini si aplica) para identificar con datos reales
    dónde está la lentitud, en vez de asumir que es por "muchos
    listeners" u otra causa no verificada.
12. **Límite de operaciones simultáneas según capital — diseño actual
    en revisión, fórmula nueva AÚN NO DEFINIDA con precisión.** Hoy es
    `floor(capital/100)` operaciones a lotaje fijo `0.01` (ver punto 6).
    Propuesta del usuario en discusión: máximo 5 operaciones
    simultáneas, escalando con el capital, con lotaje ligeramente
    mayor en la primera operación al cruzar ciertos umbrales (ej.
    $600) — falta una tabla completa de ejemplos confirmados por el
    usuario antes de implementar cualquier cosa. No asumir la fórmula
    todavía.
13. **RESUELTO 2026-08-21 — bug real de crecimiento sin límite en
    `signals_archive_summary`, corregido.** El trigger de compactación
    (tope de 20 filas activas en `signals`) archivaba TODO el
    excedente correctamente, pero como dispara después de cada INSERT
    y el excedente sobre 20 casi siempre es 1, cada compactación
    insertaba una fila NUEVA en `signals_archive_summary` — la tabla
    que se suponía iba a evitar el crecimiento sin límite había crecido
    sola a 44 filas y seguía subiendo por cada señal archivada,
    reproduciendo el mismo problema que pretendía resolver. Usuario
    confirmó explícitamente que no quiere detalle fila por fila (no
    exportar a Sheets por ahora), solo el total acumulado sin que la
    tabla crezca. Fix: `compact_old_signals()` ahora hace `UPSERT`
    sobre una única fila (`id=1`, con `CHECK (id = 1)`), acumulando
    `signal_count`, `total_profit_loss`, `status_counts` (merge por
    clave) e `instruments` (unión sin duplicados) en vez de insertar
    una fila por tanda. Las 44 filas viejas de producción se
    consolidaron en esa única fila antes de aplicar el nuevo trigger.
    Commit `3037a97` en `develop` (`db/schema.sql` +
    `dashboard/main.py`, que ahora consulta `WHERE id = 1` en vez de
    `ORDER BY archived_at DESC LIMIT 20`). Aplicado y verificado en la
    base de producción real; pendiente llevar a `main` (ver nota al
    final de este documento sobre el desfase `develop`/`main`).
14. **Causa raíz encontrada de "las órdenes no se ejecutan al
    confirmar" — DIAGNOSTICADO, pendiente de verificación del usuario
    (no marcar resuelto hasta confirmar).** `orders/config.json` tenía
    `{"symbol_suffix": "-VIP"}` mientras la cuenta real (`23096429`,
    gráficos `-STD`) necesita `-STD`. Evidencia directa en
    `MQL4/Logs/20260818.log`: múltiples `OrderSend falló, error 130`
    (`ERR_INVALID_STOPS`) para señales reales confirmadas
    (`signal_id` 2, 3, 12, 13, 19, 20 — señales `9695-B`, `77770001-A`,
    `9719-A/B`, `9726-A/B`), y errores repetidos de "mover a
    break-even" con el mismo símbolo mal configurado. El usuario está
    corrigiendo `config.json` a `-STD` a mano desde el selector del
    dashboard (`localhost:8088`) para verlo en vivo — **actualizar este
    punto a "resuelto" recién cuando confirme que las próximas señales
    ejecutan bien**, no antes.
15. **Falta validación que impida repetir el error del punto 14 —
    especialmente ahora que va a existir un segundo stack de pruebas
    en paralelo (demo, `-VIP`, ver `docker-compose.dev.yml`) corriendo
    junto al de producción (real, `-STD`) en la misma máquina.** Hoy
    `config.json` es un archivo plano sin ningún chequeo — nada impide
    que alguien deje el sufijo de un stack aplicado al otro. Ideas a
    evaluar (sin implementar todavía, decidir con el usuario):
    - **En el EA:** hardcodear (o leer de `orders/config.json`) el
      número de cuenta esperado por sufijo (`23096429` → `-STD`,
      `911260411` → `-STD` en la cuenta demo si mantiene el mismo
      símbolo, o el que corresponda) y comparar contra
      `AccountNumber()` al arrancar y en cada poll — si no coincide,
      **no operar nada**, escribir un error explícito en
      `orders/status.json` y loguear en **Experts** en vez de intentar
      `OrderSend` con un símbolo probablemente inválido para esa
      cuenta. Esto habría bloqueado el bug del punto 14 en vez de
      dejarlo fallar en silencio con error 130.
    - **En el dashboard:** mostrar siempre, junto al selector de
      sufijo, el número de cuenta que reporta `WritePositionsStatus()`
      (`account.number`) al lado del sufijo elegido, con una alerta
      visual si la combinación cuenta/sufijo no es la esperada (mismo
      chequeo que el EA, del lado humano).
    - **Separación física ya ayuda pero no alcanza sola:** el stack de
      pruebas usa un `MT4_ORDERS_HOST_PATH_DEV` distinto (otro prefijo
      de Wine), así que un `config.json` mal puesto en un stack no
      puede pisar el `config.json` del otro — el riesgo real es
      humano (mirar el dashboard equivocado), no de archivo compartido.
16. **Duplicados por reintento de webhook (Telegram/n8n) — identificado
    en una conversación anterior con Claude Code, nunca se llegó a
    documentar en este archivo (se perdió, no está en ningún commit
    del historial de `STATUS.md`) — re-agregado el 2026-08-20.** Si
    Telegram reintenta la entrega de un callback (timeout, error 5xx
    transitorio) o n8n reintenta un nodo HTTP, hoy nada impide que la
    misma confirmación dispare más de una ejecución del flujo — no
    hay constraint `UNIQUE` sobre `message_id` a nivel de callback ni
    control de idempotencia explícito en el nodo que procesa
    Confirmar/Rechazar. **Distinto del bug de las 3 órdenes duplicadas
    resuelto hoy** (commit `1e43027` en `develop`, cherry-pick `70faf71`
    en `main`): ese fue un problema puramente del lado del EA (timer de
    Wine + polling de archivos reprocesando el mismo `.json`), no de
    reintentos de webhook — se confirmó que hubo una sola ejecución de
    n8n y un solo `INSERT`/archivo `pending/` para esa señal. Este
    riesgo (duplicados por reintento HTTP) sigue sin mitigar. Ideas a
    evaluar: constraint `UNIQUE` en `signals.signal_uid` combinado con
    manejo de conflicto (`ON CONFLICT DO NOTHING`) en el `INSERT` de
    confirmación, o un guard idempotente que verifique `status` antes
    de reprocesar un callback ya aplicado (similar al patrón ya usado
    en Fase 5 para no reprocesar doble clic del mismo botón).
17. **PRIORIDAD ALTA — `settings.capital_real` nunca se actualiza desde
    el EA: el lotaje puede estar mal calculado ahora mismo, en
    silencio.** Detectado en auditoría estática de la cadena de
    callbacks (2026-08-21). El EA sí calcula y reporta
    `account.capital_real` (`AccountBalance() - AccountCredit()`) en
    cada ciclo de `WritePositionsStatus()` (`orders/status.json`), y el
    nodo `Obtener capital real (settings)` de
    `webhook-mvp-workflow.json` sí **lee** `settings.capital_real` para
    calcular el lotaje al confirmar una señal — pero **no existe ningún
    nodo en n8n que lea `orders/status.json` y escriba ese valor en
    `settings`**. Esto ya estaba anotado como pendiente en el punto "4 y
    5" de este documento (línea ~357), pero no estaba en esta lista de
    problemas activos con prioridad. Mientras nadie actualice
    `settings.capital_real` a mano, el lotaje se sigue calculando contra
    un valor potencialmente desactualizado — sin error, sin alerta,
    indefinidamente. Falta: un nodo (`scheduleTrigger` + lectura de
    `status.json` + `UPDATE settings`, mismo patrón que los triggers de
    `results/`/`closed/` cada 5s) que mantenga `settings.capital_real`
    sincronizado con lo que reporta el EA.
18. **PRIORIDAD MEDIA — sin alerta si una señal queda `CONFIRMED` sin
    resultado.** Detectado en la misma auditoría. Si el EA no procesa un
    `pending/{id}.json` (por `ACCOUNT_MISMATCH`, ver punto 15, o
    cualquier otro bloqueo silencioso del lado EA/Wine) o si
    `Escribir orden pending (MT4)` falla del lado n8n (disco lleno,
    symlink roto, permisos — ningún nodo de esta cadena tiene
    `onError`/`retryOnFail` configurado, y el workflow no tiene
    `errorWorkflow` en `settings`), la señal queda en `CONFIRMED` para
    siempre sin que nadie se entere salvo revisando MT4 o los logs de
    ejecución de n8n a mano. No es un problema activo hoy (el punto 15,
    `ACCOUNT_MISMATCH`, no ocurrió todavía en producción — perfil
    `PROD_STD` configurado correctamente antes de arrancar el EA), pero
    es un hueco de diseño real: cubre tanto ese caso como cualquier otro
    fallo silencioso de la cadena n8n/EA. Falta: un mecanismo (ej. un
    `scheduleTrigger` que revise `signals` con `status='CONFIRMED'` y
    `updated_at` más viejo que X minutos, y notifique por Telegram) que
    avise si una confirmación no obtiene resultado dentro de un tiempo
    razonable.
19. **PRIORIDAD BAJA — `active_profile`/`account_mismatch` no se
    muestran en el dashboard.** El EA ya los escribe en
    `orders/status.json` en cada ciclo, y `dashboard/main.py`
    (`GET /api/positions`) ya sirve el archivo completo tal cual sin
    filtrar campos — el dato llega hasta la respuesta HTTP. Pero
    `dashboard/static/app.js`/`index.html` no leen ni muestran esos dos
    campos: solo falta UI, no falta dato ni backend. Da visibilidad
    humana complementaria al punto 18 (que cubriría el caso vía alerta
    automática) — útil pero no urgente mientras el punto 15 no sea un
    problema activo.
20. **Punto 16 (duplicados por reintento de webhook) — auditado en
    vivo 2026-08-21, parece ya protegido, PERO sin test real que lo
    confirme (pedido explícito del usuario, no dar por cerrado sin
    eso).** Se revisó el workflow EN PRODUCCIÓN vía `GET
    /api/v1/workflows/QxXebyoPgTGmGH2B`: (a) `Insertar señal
    (Postgres)` no tiene `ON CONFLICT`, pero `signals.signal_uid` tiene
    `UNIQUE` a nivel de schema (`db/schema.sql` línea 16) — un mensaje
    de Telegram reprocesado generaría el mismo `signal_uid` y la
    segunda inserción fallaría por violación de constraint, sin crear
    fila duplicada ni segundo mensaje de Telegram (aunque sí deja una
    ejecución de n8n marcada como fallida, sin alerta — relacionado con
    el punto 18). (b) Los nodos `Actualizar status: CONFIRMED` /
    `REJECTED_BY_USER` ya usan `UPDATE ... WHERE status =
    'PENDING_CONFIRMATION' RETURNING id` dentro de un `WITH`, y los
    nodos `¿Se confirmó ahora?` / `¿Se rechazó ahora?` verifican
    `updated_count = 1` antes de escribir la orden — un reintento del
    callback (doble click o reintento HTTP de Telegram) cae a la rama
    "Ya procesada" sin volver a escribir `orders/pending/`. **Falta:**
    generar una señal de prueba en el stack DEV y simular un reintento
    real de callback para verificar esto en vivo antes de marcarlo
    definitivamente resuelto — pedido explícito del usuario, no asumir
    que la lectura del código alcanza.
21. **Punto 18 (alerta de señal `CONFIRMED` sin resultado) — diseño
    explicado al usuario 2026-08-21, sin decisión final tomada
    todavía.** Se aclaró la diferencia con la notificación que ya
    existe (`Avisar en chat: Resultado MT4`, que solo dispara si el EA
    SÍ llega a escribir un resultado, éxito o error) — el hueco es el
    caso en que el EA nunca ni siquiera intenta la orden (Wine
    colgado, archivo nunca escrito, etc.), donde hoy no llega ningún
    aviso. Diseño propuesto: `scheduleTrigger` cada 2 min + query de
    señales `CONFIRMED` con `updated_at` > 3 min + aviso Telegram, con
    una columna nueva `signals.stuck_alerted BOOLEAN` para no repetir
    el mismo aviso en cada ciclo. Requiere un `ALTER TABLE` en
    producción — el usuario no dio el visto bueno final todavía
    (quedó en "entender para qué sirve"), retomar cuando confirme.

22. **DISEÑADO 2026-08-21, NO IMPLEMENTADO — limpieza automática de
    `PENDING_CONFIRMATION` viejas.** Pedido explícito del usuario: las
    señales que quedan en `PENDING_CONFIRMATION` (nunca confirmadas ni
    rechazadas) deben archivarse/limpiarse automáticamente al día
    siguiente, sin conservar el detalle — mismo criterio que ya aplicó
    para el resto del historial (punto 13). Diseño propuesto:
    - Extender el patrón del trigger `compact_old_signals()` (o un job
      separado, ej. `pg_cron` o un `scheduleTrigger` de n8n una vez al
      día) que seleccione `signals` con `status = 'PENDING_CONFIRMATION'
      AND created_at < NOW() - INTERVAL '24 hours'`, las sume al mismo
      `UPSERT` sobre la fila única `id=1` de `signals_archive_summary`
      (reutilizando exactamente el mecanismo corregido hoy — no crear
      una fila nueva por corrida), y las borre de `signals`
      (+ `signal_modifications` asociadas, mismo orden que ya usa
      `compact_old_signals()` para no romper la FK).
    - Decisión pendiente con el usuario: ¿trigger por tiempo (`pg_cron`,
      requiere la extensión instalada en la imagen de Postgres) o un
      `scheduleTrigger` en n8n que llame una función/`DELETE...RETURNING`
      una vez al día? El trigger actual de `signals` es `AFTER INSERT`,
      no dispara solo, así que la limpieza por antigüedad necesita un
      disparador por tiempo, no por evento — no es una extensión trivial
      del trigger existente, es un mecanismo nuevo que reutiliza el
      mismo patrón de acumulación.
    - **Verificado 2026-08-21**: `total_profit_loss` de
      `signals_archive_summary` **ya se muestra** en el dashboard
      (`dashboard/static/app.js` función `loadSummary()`, con clase
      `profit-pos`/`profit-neg` según signo) — pero como parte de una
      fila de resumen, no como un número grande y prominente. El
      usuario pidió confirmar que se vea "de forma clara y visible, no
      escondida" — falta decidir si el tamaño/posición actual alcanza
      o si conviene destacarlo más (ej. como cifra grande en el header
      del dashboard) antes de dar esto por resuelto.

## Próximos pasos inmediatos (en orden)

0. **Fase 4 (Gemini) — diseño terminado, quedan dos tareas concretas
   (ver punto 9 de errores persistentes, resuelto 2026-08-28):**
   arreglar el bug de retry/campos perdidos en la rama Gemini del
   workflow `07`, y luego pasar a producción (`GEMINI_API_KEY` +
   subir el workflow vía API).
1. Medir la lentitud percibida antes de tocar timing (punto 11) — solo
   después, implementar el fix real de `error 4109` (una orden por
   ciclo de `OnTimer`, punto 10) y recompilar `KronosBridgeEA.mq4`
   (`DetectClosedPositions()` ya está compilado y activo, ver punto 3
   de errores persistentes — este paso ya no incluye eso).
2. Cerrar con el usuario la tabla de ejemplos del nuevo límite de
   operaciones simultáneas por capital (punto 12) antes de implementar
   nada — no asumir la fórmula de `floor(capital/100)` actual como
   definitiva.
3. Registro en Google Sheets de los cierres (Fase 7) — el punto 13
   (pérdida de detalle al archivar en `signals_archive_summary`) ya
   se resolvió con el usuario el 2026-08-21: no le importa el detalle
   fila por fila, solo el total acumulado sin que la tabla crezca sin
   límite (ver esa entrada), así que ya no es un bloqueante para
   decidir esto — falta solo si vale la pena exportar los cierres a
   Sheets como respaldo/reporte legible, no una decisión de pérdida de
   datos.
4. Recién después: evaluar ejecución 100% automática sin confirmación
   (Fase 8), con el historial de v1 como respaldo de confianza.

## Qué es "v2" para este proyecto (recomendación)

No hay un salto de versión mayor pendiente de diseño — el roadmap de
`CLAUDE.md` (Fases 0–8) ya es, en efecto, el plan de v2: v1 fue el
sistema manual/semi-manual anterior (mencionado como respaldo de
confianza en el punto 4 de arriba); v2 es este bot con confirmación
humana + ejecución real en MT4. Cerrar los 4 puntos de la lista de
arriba (en ese orden) **es** completar v2. No conviene inventar un
roadmap paralelo — el existente ya está priorizado por riesgo/impacto
y validado en una operación con dinero real, y el punto más importante
sigue siendo el mismo desde el "gap operativo" al principio de este
documento: Gemini (Fase 4) para no depender de gestión 100% manual de
SL/BE/cierres mientras hay posiciones reales abiertas.

## Fases (referencia de `CLAUDE.md`)

- ✅ Fase 0 — credenciales Telegram, estructura de carpetas.
- ✅ Fase 1 — microservicio Telethon capturando y enviando al webhook,
  con polling de respaldo agregado por pérdida de eventos en canales
  de alto tráfico.
- ✅ Fase 2 — base de datos Postgres, auto-init vía
  `docker-entrypoint-initdb.d`.
- ✅ Fase 3 — webhook + parser regex (incluye multi-TP), verificado
  end-to-end.
- 🔶 Fase 4 — interpretación por Gemini. **Diseño y desarrollo dados
  por terminados** en `develop` (rama `feature/fase4-seguimiento`),
  **no en producción todavía** — falta arreglar el bug de retry/
  campos perdidos en la rama Gemini del workflow `07`, agregar
  `GEMINI_API_KEY` a producción, y subir el workflow (ver aviso al
  inicio y sección de errores persistentes).
- ✅ Fase 5 — botones de confirmar/rechazar funcionales, idempotentes,
  con mensaje de confirmación visible en el chat.
- ✅ Fase 6 — EA puente en MT4. Completa y verificada end-to-end con
  dinero real: Wine/MT4 con sesión real, EA compilado y ejecutando,
  nodos n8n de escribir orden / leer resultado funcionando, tickets
  reales confirmados en la cuenta `23096429`.
- 🔶 Fase 7 — cierre y registro en Google Sheets. El consumidor de
  `orders/closed/*.json` (detección TP/SL) está mergeado, compilado y
  activo de punta a punta en producción real (verificado 2026-08-21,
  ver nota más abajo). Falta únicamente el registro en Google Sheets
  en sí, que no existe todavía.
- 🔲 Fase 8 — ejecución 100% automática (futuro, meta de v2).

## Nota operativa 2026-08-21 — dashboard, base de datos, `develop`/`main`

- **El contenedor de producción real corre desde el worktree
  `Kronos_Bot` (rama `develop`), no desde `Kronos_Bot-prod` (rama
  `main`)** — verificado vía
  `docker inspect ... com.docker.compose.project.working_dir`. La
  regla de `CLAUDE.md` ("producción solo se actualiza desde `main`")
  sigue siendo la política a seguir hacia adelante, pero el estado
  real hoy es que el `docker-compose.yml` que efectivamente levanta el
  dashboard vive en `Kronos_Bot`. `Kronos_Bot-prod`/`main` está al día
  con el rediseño del dashboard (`a6a850d`) pero **2 commits detrás**
  de lo que ya corre en producción real: el filtro "Hoy" por defecto y
  el fix de `signals_archive_summary` (commit `3037a97`). Pendiente
  sincronizar `main` cuando el usuario lo pida.
- **Se vació por completo la base de datos real** (`TRUNCATE signals,
  signal_modifications RESTART IDENTITY CASCADE`) a pedido explícito
  del usuario, incluyendo 11 filas `OPEN` con ticket real de MT4 que
  seguían abiertas en la cuenta — el usuario confirmó explícitamente
  que asumía la pérdida de esa referencia. No hay historial de señales
  anterior a esta fecha.
- Dashboard: filtro de historial de señales por defecto cambiado de
  "Todas" a "Hoy" (`currentSignalsRange`, `dashboard/static/app.js`).
