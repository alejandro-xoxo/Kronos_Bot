# KRONOS BOT — PROTOCOLOS DE SEGURIDAD Y FUNCIONAMIENTO

## 1. Propósito de este documento

Este documento define, de forma exhaustiva y sin ambigüedad, todas las reglas operativas, protocolos de seguridad y flujo de datos del sistema Kronos Bot — un copiador automático de señales de trading desde Telegram hacia MT4 (cuenta VT Markets).

Sirve como referencia técnica única para el desarrollo (n8n, EA de MT4, base de datos) y no debe contradecirse entre sí en ninguna fase de implementación.

---

## 2. Arquitectura general del sistema

```
Telegram (grupo VIP SIGNALS FX)
        ↓
Microservicio Telethon (cuenta de usuario personal, MTProto)
        ↓ webhook
n8n (orquestador central: lógica, IA, base de datos, notificaciones)
        ↓
EA puente en MT4 (ejecución real en cuenta VT Markets)
        ↓
Retroalimentación de cierre → n8n → Base de datos + Google Sheets
```

Todo corre en el EliteBook (CachyOS/Arch), con Docker para n8n + Telethon, y Wine/Bottles para MT4.

---

## 3. Captura de mensajes (Entrada)

### 3.1. Mecanismo

- El microservicio Telethon se loguea con la cuenta personal del usuario (vía `api_id`/`api_hash` de my.telegram.org) y escucha en tiempo real el grupo configurado (`TELEGRAM_GROUP_ID`).
- Cada mensaje nuevo genera un payload con: `message_id`, `chat_id`, `sender`, `text`, `timestamp`, `reply_to_message_id`.
- El payload se envía por POST al webhook de n8n.

### 3.2. Regla de referencia entre mensajes

- Telegram provee `reply_to_message_id` cuando un mensaje responde a otro. Este es el mecanismo **principal y confiable** para vincular una instrucción de seguimiento (modificación, cierre, BE) con la señal original.
- Si el mensaje de seguimiento **no viene como reply** (mensaje suelto sin referencia), el sistema debe:
  1. Intentar que Gemini identifique la señal por contexto (símbolo mencionado + búsqueda de la señal con `status = OPEN` más reciente de ese instrumento).
  2. Si no logra identificarla con certeza, el mensaje se marca como `PENDING_MANUAL` y se notifica al usuario — **nunca se ejecuta una acción sobre una señal adivinada sin confirmación.**

---

## 4. Clasificación e interpretación de mensajes (Proceso)

### 4.1. Árbol de decisión

```
Mensaje nuevo recibido
    │
    ├── ¿Coincide con el formato fijo de señal nueva?
    │   (INSTRUMENTO + BUY/SELL + [LIMIT] + TP + SL)
    │       │
    │       └── SÍ → Interpretado por REGEX (interpreted_by = "REGEX")
    │
    └── ¿Es una instrucción de seguimiento? (mover SL, BE, cerrar, mover TP,
        eliminar operación, modificar entrada — redacción variable)
            │
            └── SÍ → Interpretado por Gemini (interpreted_by = "AI")
```

### 4.2. Reglas de interpretación (heredadas del documento base VIP SIGNALS FX)

1. No se invierte la dirección (`BUY`/`SELL`) bajo ninguna circunstancia.
2. Si el mensaje NO contiene la palabra `LIMIT` → ejecución por mercado.
3. Si contiene `LIMIT` pero el precio actual ya alcanzó el nivel de entrada indicado → se ejecuta igualmente como mercado (usando los parámetros de la señal).
4. Si contiene `LIMIT` y el precio no ha llegado al nivel → se crea orden pendiente.
5. Si la señal no incluye SL → no se inventa; queda en espera de un mensaje posterior que lo indique. La señal **no se ejecuta** hasta tener SL, salvo que el sistema determine explícitamente lo contrario en una versión futura.
6. Si la señal trae varios TP (TP1, TP2, TP3...) → se genera **una sub-señal independiente por cada TP presente en el mensaje, sin tope** (regla actualizada — antes limitaba a 2, decisión explícita del usuario del 2026-08-18 para que la práctica coincida con el tutorial oficial del grupo, que indica abrir una operación por cada TP):
   - **Sub-señal A** → TP1 (el primer TP del mensaje), **Sub-señal B** → TP2, **Sub-señal C** → TP3, y así sucesivamente (`A`, `B`, ... `Z`, `AA`, `AB`... si hiciera falta).
   - Si la señal solo trae 1 TP → se genera únicamente la sub-señal A (comportamiento sin cambios).
   - Todas las sub-señales comparten instrumento, dirección, tipo de ejecución, precio de entrada y SL — **solo el TP difiere entre ellas**.
   - Cada sub-señal es un registro **independiente** en `signals` (una fila por sub-señal, no un campo adicional en la misma fila), con su propio `signal_uid`, y se valida, notifica y confirma/rechaza **por separado**: una notificación de Telegram por sub-señal, cada una con sus propios botones Confirmar/Rechazar. Confirmar o rechazar una no afecta a las demás.
   - **Excepción (agregada 2026-09-01, decisión explícita del usuario):** cuando una sub-señal llega a `TP_REACHED`, las sub-señales hermanas del mismo mensaje que **todavía no llegaron a `OPEN`** (es decir, siguen en `PENDING_CONFIRMATION` o `CONFIRMED` sin ejecutar en MT4) se cancelan automáticamente (`status = CANCELLED_SIBLING_TP`, ver `db/schema.sql`) y se notifica por Telegram. Objetivo: si el primer TP de la señal ya se cumplió, no tiene sentido dejar operaciones pendientes de confirmación esperando el mismo instrumento/entrada/SL. Esto **no aplica** si la hermana llega a `SL_REACHED` o `CLOSED_MANUAL` (esos casos siguen siendo completamente independientes), ni afecta a hermanas que ya están `OPEN` (esas siguen su propio ciclo de vida sin tocarse).
   - **Lotaje:** todas las sub-señales usan el valor fijo `0.01` (el mismo de cualquier señal en este MVP). No existe todavía ningún mecanismo de "competencia por slot" entre sub-señales de la misma señal — eso depende del cálculo de slots (sección 5.3, tope de 3 operaciones simultáneas), que sigue sin conectarse al flujo de ejecución real. Sin ese tope, una señal con muchos TP puede comprometer varias veces `0.01` de lote simultáneamente — se revisita cuando el cálculo de lotaje inteligente esté implementado y validado.
7. "BE" (Break Even), mencionado solo o en frases como "cerrar a BE" / "mover a BE", se interpreta **siempre como una modificación del Stop Loss** al precio de entrada de la operación. Nunca se aplica al Take Profit. Si el caller quiere modificar el TP, lo indica explícitamente con la palabra "TP" en el mensaje.
8. No se inventan valores de ningún tipo (precios, SL, TP, lotaje) que no estén explícitamente presentes en el mensaje o derivados de una regla ya definida en este documento.

### 4.3. Regla de antigüedad de la señal

```
tiempo_transcurrido = ahora - signal_timestamp

¿tiempo_transcurrido ≤ 5 minutos?
    │
    ├── SÍ → la señal es válida, se procede a validar el resto de condiciones
    │
    └── NO → la señal se descarta completamente (status = EXPIRED)
              No existe ventana intermedia ni validación de rango de precio
              como excepción. Es una regla binaria, sin excepciones.
```

### 4.4. Fallback de interpretación por IA (Gemini)

```
n8n envía el mensaje a Gemini
    ↓
¿Respuesta exitosa?
    │
    ├── SÍ → continuar flujo normal
    │
    └── NO (error 429 u otro) → 1 (UN) reintento inmediato
              ↓
         ¿Respuesta exitosa?
              │
              ├── SÍ → continuar flujo normal
              │
              └── NO → status = PENDING_MANUAL
                        + notificación urgente a Telegram:
                        "🚨 No se pudo interpretar este mensaje, revisar
                         manualmente: [texto original]"
                        NO se hace espera larga (backoff de varios segundos)
                        porque compromete la ventana de ejecución
                        (objetivo: 8–30 segundos desde que llega la señal).
```

---

## 5. Gestión de capital y lotaje

### 5.1. Fuente del capital

- **Actualizado 2026-08-28, decisión explícita del usuario — reemplaza
  la regla anterior de esta sección.** El campo `capital_real` se
  calcula **automáticamente en el EA** de MT4 usando `AccountBalance()`
  completo (función nativa de MQL4), **incluyendo el crédito del
  bróker**. La versión anterior de esta regla excluía el crédito
  restando `AccountCredit()`; el usuario confirmó explícitamente que
  quiere el capital total, crédito incluido, como base del cálculo de
  lotaje.
- El EA reporta `capital_real` a n8n junto con el resto de datos de la cuenta (ej. en cada heartbeat o antes de cada ejecución), y n8n actualiza el valor en la tabla `settings`. No requiere edición manual del usuario en operación normal — solo se edita a mano si se necesita forzar un valor distinto por alguna razón excepcional.

### 5.2. Cálculo del lote total disponible

```
lote_total = floor(capital_real / 100) × 0.01
```

**Estado: ACTIVO.** Esta fórmula es la que hoy calcula `lot` en
`n8n-workflows/webhook-mvp-workflow.json` (nodo "Preparar orden
pending (JSON)"), con piso de `0.01` si el resultado da 0 o negativo.
Se recalcula contra el `capital_real` actual de `settings` en cada
confirmación de señal — no se "pega" a un máximo histórico de capital.
Sin techo superior definido.

### 5.3. División en slots (máximo 3 operaciones simultáneas)

**Estado: OBSOLETA (2026-08-29) — Fase 2 (sección 12.3) fija el tope
en 1 operación simultánea**, usando el lotaje completo disponible sin
repartir. No hay "competencia por slot" posible con tope de 1; esta
sección queda como referencia histórica del diseño de 3 slots, no
como diseño vigente. Si el tope de 1 se revisa más adelante, evaluar
si esta sección se retoma o se rediseña de nuevo.

**Historial (diseño previo a Fase 2):** **DISEÑADO, NO IMPLEMENTADO
(rediseño confirmado 2026-08-21, reemplaza la versión anterior de esta
sección que usaba un split 80/20 con tope de 2 slots — esa versión
queda descartada, no es una alternativa).** Esta sección describe una
división posterior de `lote_total` (5.2) entre hasta 3 operaciones
simultáneas compitiendo por el mismo capital. No está conectada al
flujo real: hoy cada sub-señal usa el `lote_total` completo de 5.2 sin
ninguna competencia por slot entre ellas. No confundir ambas reglas.

A diferencia del diseño anterior (split fijo 80/20 entre 2 slots), el
tope de operaciones simultáneas queda fijo en **3, sin importar cuánto
crezca el capital**, y las `N` unidades de `0.01` disponibles se
reparten lo más parejo posible entre los slots activos, dando el
sobrante a los primeros.

```
N = floor(capital_real / 100)                (unidades de 0.01)
operaciones_activas = mínimo(N, 3)           ← tope fijo de 3

# Reparto de N unidades entre operaciones_activas, lo más parejo
# posible; el sobrante (N mod operaciones_activas) se asigna a las
# primeras operaciones de la lista, una unidad extra cada una.
base = floor(N / operaciones_activas)
sobrante = N mod operaciones_activas

slot[i] = (base + 1) × 0.01   para las primeras `sobrante` posiciones
slot[i] = base × 0.01         para el resto
```

Si `N = 0` (capital_real < 100) → no hay ningún slot disponible, toda
señal nueva se rechaza por falta de lotaje (ver 5.4).

**Tabla de referencia (verificada y confirmada por el usuario
2026-08-21):**

| Capital | N (unidades de 0.01) | Operaciones activas | Slots (lote por operación) |
|---|---|---|---|
| $100 | 1 | 1 | 0.01 |
| $200 | 2 | 2 | 0.01, 0.01 |
| $300 | 3 | 3 | 0.01, 0.01, 0.01 |
| $400 | 4 | 3 | 0.02, 0.01, 0.01 |
| $500 | 5 | 3 | 0.02, 0.02, 0.01 |
| $600 | 6 | 3 | 0.02, 0.02, 0.02 |
| $700 | 7 | 3 | 0.03, 0.02, 0.02 |
| $800 | 8 | 3 | 0.03, 0.03, 0.02 |
| $900 | 9 | 3 | 0.03, 0.03, 0.03 |

### 5.4. Ocupación y liberación de slots

- Los slots se ocupan **por tamaño, el más grande disponible primero**, sin importar el orden de llegada de las señales.
- Cuando una operación cierra (TP, SL, cierre manual, o cierre por condición de carrera de precio), su slot se libera inmediatamente y queda disponible para la siguiente señal que llegue.
- Si los 3 slots están ocupados (o si `capital_real` no alcanza para ningún slot, `N = 0`) y llega una señal nueva → **se rechaza automáticamente**:
  - **No se inserta ningún registro en la tabla `signals`.**
  - Se registra únicamente en la hoja "Rechazadas" de Google Sheets.
  - Se envía notificación por Telegram informando el rechazo por falta de lotaje disponible.

---

## 6. Validación de precio antes de ejecutar

- El precio de referencia para validar una señal **siempre proviene del EA en MT4** (el mismo motor que ejecutará la orden), nunca de una API externa de precios. Esto evita discrepancias entre el precio validado y el precio real de ejecución en VT Markets.

---

## 7. Flujo de confirmación (señales nuevas)

### 7.1. Confirmación de señales nuevas — manual o automática según Fase 2 (sección 12.3)

**Actualizado 2026-08-29**: con Fase 2 declarada, una señal nueva se
auto-confirma si cumple las condiciones de la sección 12.3 (0
operaciones `OPEN` y ganancia del día <6%); si no las cumple, cae a
confirmación manual como en Fase 1.

```
Señal nueva parseada
    ↓
Validaciones pasadas (antigüedad ≤5min, slot de lotaje disponible)
    ↓
INSERT en tabla signals (status = PENDING_CONFIRMATION)
    ↓
¿Cumple condiciones de auto-confirmación? (sección 12.3: 0 OPEN
y ganancia del día <6%)
    ↓
    ├── SÍ → status = CONFIRMED automáticamente → se envía orden al EA
    │        (se notifica igual por Telegram, sin esperar botón)
    │
    └── NO → Notificación a Telegram con [Confirmar] [Rechazar]
             ↓
             ├── Usuario confirma → status = CONFIRMED → orden al EA
             │
             └── Usuario rechaza → status = REJECTED_BY_USER (queda
                                     en DB para historial, a diferencia
                                     de los rechazos por falta de lotaje)
```

### 7.2. Instrucciones de seguimiento sobre operaciones ya confirmadas/abiertas

- **Se ejecutan automáticamente, sin pedir confirmación al usuario**, ya que la operación original ya fue aprobada por él.
- Aplica a: mover SL, mover a BE, mover TP, cerrar operación, eliminar operación pendiente.

---

## 8. Protocolo de modificación con reintento (loop de seguridad de precio)

### 8.1. Escenario que cubre

Cuando llega una instrucción de modificación (ej. "mover SL a BE") y, para el momento en que la orden llega al EA, el precio de mercado ya se movió más allá del nivel objetivo, existe riesgo de que MT4 rechace la modificación o la ejecute de forma no segura.

### 8.2. Flujo exacto

```
n8n envía orden de modificación al EA (intento 1)
    ↓
¿MT4 acepta la modificación?
    │
    ├── SÍ → éxito
    │        → actualizar signal_modifications y signals
    │        → notificación de éxito a Telegram:
    │          "✅ SL de [INSTRUMENTO] (ticket #[X]) movido a [precio] — éxito"
    │
    └── NO → n8n envía a Gemini: precio actual de mercado, precio que
              se intentó fijar, dirección de la operación (BUY/SELL)
              ↓
         Gemini devuelve un precio ajustado, calculando la posición
         de MENOR riesgo posible que sea válida para el bróker
              ↓
         n8n envía orden de modificación al EA (intento 2, con el
         precio ajustado por Gemini)
              ↓
         ¿MT4 acepta esta vez?
              │
              ├── SÍ → éxito (mismo reporte que arriba)
              │
              └── NO → notificación a Telegram con 2 opciones y
                        temporizador de 30 segundos:
                        "⚠️ No se pudo mover SL de [INSTRUMENTO]
                         (ticket #[X]) tras 2 intentos. Precio actual:
                         [precio]. Instrucción original: '[texto]'
                         interpretada como [SL_TO_BE / TP_UPDATE].

                         Responde con:
                         - Un precio exacto (ej: 4422.50) → se
                           reintenta con ese valor
                         - 'cerrar' → se cierra la operación ya a
                           mercado

                         Si no respondes en 30 segundos, se hace un
                         reintento final automático con el precio
                         más seguro que calcule Gemini en ese momento."
                        ↓
                   Espera de 30 segundos:
                        │
                        ├── Usuario responde con un precio →
                        │   intento final con ese valor exacto
                        │   (sin pasar por Gemini)
                        │
                        ├── Usuario responde "cerrar" →
                        │   EA cierra la operación a mercado
                        │   inmediatamente
                        │
                        └── Sin respuesta en 30s →
                            Gemini recalcula con el precio más
                            actual disponible → intento final
                            automático (intento 3, el último)
                            ↓
                   Se reporta el resultado final (éxito o fallo)
                   por Telegram. No hay más reintentos automáticos
                   después de este punto.
```

### 8.3. Límite estricto de intentos automáticos

- Máximo **2 intentos automáticos** antes de requerir intervención del usuario (directo o por timeout).
- El intento post-timeout (30s) cuenta como el 3er y último intento del ciclo.
- Nunca se reintenta indefinidamente sin notificar al usuario.

---

### 8.4. Tipo de modificación: cierre manual a precio específico (`CLOSE_AT_PRICE`)

Detectado en ejemplos reales del grupo: el caller a veces cierra una
operación manualmente en un punto intermedio, distinto del TP o SL
originales:

```
"Cerrar a 4366 -60PIPS"
"CERRAR A 4374, +20 PIPS"
```

Esto es un tipo de modificación adicional a los ya definidos
(`ENTRY_CHANGE`, `SL_CHANGE`, `SL_TO_BE`, `CANCEL`, `TP_UPDATE`):

- **`CLOSE_AT_PRICE`** — orden de cierre inmediato a mercado del
  ticket correspondiente, extraída del precio mencionado en el
  mensaje (usado como referencia informativa/auditoría, no como
  condición — el cierre es a mercado, al precio disponible en el
  momento de ejecutar).
- A diferencia de `SL_TO_BE`, esta acción **no pasa por el loop de
  reintento de precio de la sección 8.2** — cerrar a mercado casi
  siempre es aceptado por el bróker (no depende de fijar un nivel
  exacto), así que solo requiere manejo de error simple (reintentar
  una vez si falla por desconexión, notificar si persiste).

## 9. Ciclo de cierre y retroalimentación

```
EA detecta cierre de una operación (TP alcanzado, SL alcanzado,
cierre manual, o cierre forzado por el protocolo de la sección 8)
    ↓
EA reporta a n8n: ticket, precio de cierre, profit/loss real
    ↓
n8n localiza la señal correspondiente por mt4_ticket
    ↓
Actualiza:
    - status → TP_REACHED | SL_REACHED | CLOSED_MANUAL |
               CLOSED_BY_PRICE_RACE
    - close_timestamp
    - close_price
    - profit_loss
    ↓
Libera el slot de lotaje que ocupaba esa operación (sección 5.4)
    ↓
Registra el resultado final en Google Sheets (hoja "Señales")
    ↓
Notifica el resultado al usuario por Telegram
```

---

## 10. Estados posibles de una señal (`status` en tabla `signals`)

| Estado | Significado |
|---|---|
| `PENDING_CONFIRMATION` | Señal nueva parseada, esperando confirmación del usuario |
| `CONFIRMED` | Usuario confirmó, orden enviada al EA |
| `REJECTED_BY_USER` | Usuario rechazó la señal explícitamente |
| `OPEN` | Operación ejecutada y actualmente abierta en MT4 |
| `TP_REACHED` | Cerrada por alcanzar Take Profit |
| `SL_REACHED` | Cerrada por alcanzar Stop Loss |
| `CLOSED_MANUAL` | Cerrada manualmente (por instrucción del caller o del usuario) |
| `CLOSED_BY_PRICE_RACE` | Cerrada por el protocolo de la sección 8 (condición de carrera de precio) |
| `EXPIRED` | Descartada por exceder los 5 minutos de antigüedad |
| `PENDING_MANUAL` | No se pudo interpretar ni por regex ni por IA; requiere revisión manual |

**Nota:** las señales rechazadas por falta de lotaje disponible (sección 5.4) **no generan un registro en esta tabla** — solo quedan en el log de Google Sheets.

---

## 11. Notificaciones al usuario (resumen de todos los disparadores)

| Evento | Canal | Contenido |
|---|---|---|
| Nueva señal válida, esperando confirmación | Telegram | Datos completos + botones Confirmar/Rechazar |
| Señal rechazada por falta de lotaje | Telegram + Sheets | Motivo del rechazo |
| Fallo total de interpretación (IA + regex) | Telegram (urgente) | Texto original del mensaje |
| Modificación exitosa | Telegram | Confirmación con ticket y valor aplicado |
| Modificación fallida tras 2 intentos | Telegram (con opciones + timeout 30s) | Precio actual, precio objetivo, instrucción original |
| Cierre de operación (cualquier motivo) | Telegram + Sheets | Resultado final ($/pips) |
| Señal no identificable (sin reply válido y sin contexto claro) | Telegram | Marcada como PENDING_MANUAL |

---

## 12. Principios de seguridad transversales (aplican a todo el sistema)

1. **No se inventan datos.** Ningún campo (precio, SL, TP, lote) se completa con suposiciones; si falta información crítica, la señal no se ejecuta hasta tenerla.
2. **Actualizado 2026-08-28 — el capital real SÍ incluye el crédito del bróker**, por decisión explícita del usuario (ver sección 5.1). Se calcula automáticamente en el EA como `AccountBalance()` completo.
3. **Actualizado 2026-08-29, decisión explícita del usuario — Fase 2
   de este protocolo (100% automático) declarada iniciada.** (Numeración
   propia de este documento — Fase 1/Fase 2 semi-auto/100%-auto — no
   confundir con la numeración de fases 0-8 de `CLAUDE.md`, donde este
   mismo hito es "Fase 8".) El sistema ya no requiere
   confirmación humana obligatoria para señales nuevas — se considera
   validado el modo semi-automático (Fase 1), condición que esta
   misma sección ya anticipaba (ver antes sección 13) para pasar de
   fase. La confirmación humana se reemplaza por estos controles de
   riesgo automáticos, no se elimina sin reemplazo:
   - **Máximo 1 operación (`OPEN`) simultánea** — usa el lotaje
     completo disponible (`floor(capital_real / 100) × 0.01`, sección
     5.2), sin repartir entre slots: no hace falta con tope de 1.
   - **Circuit breaker de ganancia diaria**: si la cuenta ya subió
     ≥6% respecto al capital de inicio del día, se deja de
     auto-confirmar hasta el día siguiente (cae a confirmación
     manual). Las posiciones ya abiertas no se tocan.

   Aplicación **incremental** a producción real, empezando por el
   stack dev (ver `STATUS.md` e historial de versiones `v2.x`) — la
   declaración de fase no implica que ya esté activo en la cuenta
   real, solo que dejó de ser una excepción no autorizada. Las
   modificaciones sobre operaciones ya aprobadas siguen
   ejecutándose sin intervención, como en Fase 1.
4. **Ningún loop de reintento es infinito.** Todo mecanismo de reintento automático tiene un tope máximo definido (2 intentos + 1 post-timeout) y termina en notificación al usuario si falla.
5. **Las credenciales (.env) nunca se versionan en git** y deben rotarse inmediatamente si se exponen accidentalmente.
6. **El precio de validación y ejecución siempre proviene de la misma fuente** (el EA en MT4), nunca de una API externa, para evitar discrepancias entre lo que el sistema valida y lo que realmente ejecuta el bróker.
7. **Toda acción automática queda auditada** en la base de datos (tablas `signals` y `signal_modifications`), incluyendo quién/qué la interpretó (`REGEX` o `AI`).

---

## 13. Fuera de alcance en esta fase (explícitamente no implementado)

- División de una señal con más de 2 TP en más de 2 operaciones — el tope es 2 sub-señales (TP1 y TP2), el resto se ignora (ver sección 4.2 regla 6).
- Cierres parciales de una misma operación en base a múltiples TP — cada sub-señal es una operación completa independiente, no un cierre parcial de otra.
- Cálculo de lotaje diferenciado por sub-señal (competencia por slot, sección 5.3) — con el tope de 1 operación simultánea de Fase 2 (sección 12.3), no aplica: no hay "competencia" posible con una sola operación a la vez. Esta sección de slots queda obsoleta salvo que el tope de 1 se revise más adelante.
- Migración a VPS Windows en la nube y modelos de IA de pago — evaluado solo después de validar rentabilidad en el entorno local/gratuito.
