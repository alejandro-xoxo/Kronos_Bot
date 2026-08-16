# Kronos Bot — Estado actual

> Snapshot técnico del proyecto al 2026-08-14, rama `feature/mt4-ea-bridge`
> (sin mergear a `develop` todavía). Pensado para poder pegarse completo a
> una sesión nueva de Claude Code (o de cualquier asistente) sin depender
> de memoria de conversación previa. Para reglas de negocio detalladas ver
> `PROTOCOLOS_KRONOS_BOT.md`; para contexto general y reglas de trabajo,
> `CLAUDE.md`.

## Qué funciona probado de punta a punta (no solo diseñado)

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

### 1. Wine + MT4 instalado — ✅ completo, sin login todavía

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
- **Pendiente:** el usuario todavía no inició sesión con la cuenta real
  (servidor `VTMarkets-Live 9`) — decisión deliberada de esperar a estar
  en la red de casa por seguridad, no un bloqueo técnico.

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
- `.gitignore` excluye `mt4-bridge/orders/pending/*` y
  `mt4-bridge/orders/results/*`, con excepción explícita de los
  `.gitkeep`.

### 3. EA en MQL4 — código completo y revisado, sin compilar todavía

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
- Revisado en conjunto con el usuario (vía archivo enviado, no pegado en
  terminal — pegarlo corrompía el código).
- **Pendiente:** compilar con MetaEditor (F7) — requiere interfaz
  gráfica, no se puede automatizar desde una sesión de Claude Code (el
  entorno de herramientas no comparte pantalla/GUI con la sesión de
  escritorio real). Tampoco se probó todavía contra el gráfico real de
  MT4.

### 4 y 5 — Nodos de n8n para el puente con MT4

- **Etapa 4 — ✅ implementada, sin probar end-to-end todavía.** En la
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
  - **Pendiente:** prueba end-to-end real (confirmar una señal de
    verdad en Telegram y verificar que el EA la levanta y ejecuta) —
    no se disparó todavía para no tocar la cuenta real sin que el
    usuario lo decida explícitamente.
- **Etapa 5 — 🔲 no iniciada.** Nodo (probablemente por polling con un
  Cron/Interval trigger, ya que n8n no tiene forma nativa de "escuchar"
  cambios en el filesystem) que lea `orders/results/{signal_id}.json`,
  actualice `signals.mt4_ticket`/`status` en Postgres, notifique al
  usuario por Telegram con el resultado real (ticket, precio de
  ejecución o motivo de fallo), y borre el archivo de `results/` tras
  procesarlo.

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

## Qué NO hace todavía

- **Interpretación por Gemini** (Fase 4 del roadmap original) — mover
  SL, BE, cerrar, `CLOSE_AT_PRICE` — diseñado en detalle en
  `PROTOCOLOS_KRONOS_BOT.md`, cero código.
- **Cálculo de lotaje por slots** (80/20, sección 5.3 del protocolo) —
  fórmula definida, no implementada. Todas las señales (incluidas ambas
  sub-señales de una señal multi-TP) usan lotaje fijo `0.01`.
- **Ejecución real en MT4** — el EA existe pero no está compilado ni
  probado; los nodos de n8n que lo alimentan (Etapas 4 y 5 de arriba) no
  existen todavía. Nada se ejecuta de verdad en la cuenta real hasta que
  esto esté completo.
- **Ciclo de cierre y registro en Google Sheets** (Fase 7) — sin
  empezar, depende de que la ejecución real en MT4 esté funcionando
  primero (necesita que el EA reporte cierres, no solo aperturas).
- **Loop de reintento de precio con Gemini** (protocolo sección 8) —
  depende de que exista la ejecución real en MT4.
- **Ejecución 100% automática sin confirmación** (Fase 8, futuro) — todo
  el diseño actual asume confirmación humana obligatoria (protocolo,
  principio no negociable #3).

## Próximos pasos inmediatos (en orden)

1. **[Manual, usuario]** Compilar `mt4-bridge/ea/KronosBridgeEA.mq4` con
   MetaEditor (F7) dentro de MT4, revisar que compile sin errores.
2. **[Manual, usuario]** Iniciar sesión en MT4 con la cuenta real
   (servidor `VTMarkets-Live 9`), desde la red de casa.
3. **[Con Claude Code]** Etapa 4: nodo n8n que escribe
   `orders/pending/{signal_id}.json` al confirmar una señal.
4. **[Con Claude Code]** Etapa 5: nodo n8n que lee
   `orders/results/{signal_id}.json`, actualiza Postgres y notifica.
5. Prueba end-to-end completa: señal real → confirmar en Telegram → EA
   ejecuta en MT4 (demo o real, a decidir) → resultado vuelve a Telegram.
6. Recién después de validar el flujo básico de ejecución: cálculo de
   lotaje por slots, interpretación por Gemini, ciclo de cierre.

## Fases (referencia de `CLAUDE.md`)

- ✅ Fase 0 — credenciales Telegram, estructura de carpetas.
- ✅ Fase 1 — microservicio Telethon capturando y enviando al webhook.
- ✅ Fase 2 — base de datos Postgres, auto-init vía
  `docker-entrypoint-initdb.d`.
- ✅ Fase 3 — webhook + parser regex (incluye multi-TP), verificado
  end-to-end.
- 🔲 Fase 4 — interpretación por Gemini. No iniciada.
- ✅ Fase 5 — botones de confirmar/rechazar funcionales, idempotentes,
  con mensaje de confirmación visible en el chat.
- 🔶 Fase 6 — EA puente en MT4. Wine/MT4 instalados, formato de
  archivos y symlinks verificados, EA escrito y revisado — pendiente
  compilar, loguearse en MT4, y los nodos n8n de las Etapas 4/5 de esta
  misma fase (ver detalle arriba).
- 🔲 Fase 7 — cierre y registro en Google Sheets.
- 🔲 Fase 8 — ejecución 100% automática (futuro).
