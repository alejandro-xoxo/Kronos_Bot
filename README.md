# Kronos Bot

**Un bot que copia señales de trading de un grupo de Telegram a mi cuenta real de MT4, para que confirmar una operación a las 4 de la mañana me tome un tap, no cinco minutos despierto abriendo MT4 a mano.**

> Estado actual: **[v1 — MVP funcional](docs/versions/v1.md)**, con ejecución real verificada en cuenta live (VT Markets). Ver [evidencia real](#evidencia-real) más abajo. Armado en ~1 semana (arrancó el 10 de agosto de 2026), a la par de mis estudios.

---

## La historia detrás de esto

Todavía estoy estudiando para ser developer. En paralelo empecé a meterme en trading buscando un ingreso extra — algo que pudiera sostener mientras sigo formándome, no un plan de hacerme rico rápido.

Encontré un grupo de señales que se veía sólido: buen historial, comunidad activa. El problema es que es un grupo español, y las señales me caen entre la **1:30 a. m. y las 8:00 a. m.** hora mía. El objetivo real, el que persigo de fondo, es que el copiado sea **100% automático** — que la señal se ejecute sola en mi cuenta mientras yo estoy durmiendo, sin que tenga que despertarme a nada.

No tenía plata para un VPS ni para una IA paga ni para pagarle a un servicio de copy-trading. Tenía mi laptop, tiempo libre robado al sueño, y ganas de meterle mano a un problema mío de verdad — no un tutorial ni un proyecto de práctica que después se archiva. Así nació Kronos Bot. Y como todo sistema que va a mover plata real, no arranqué confiando ciego en él: la v1 que ves acá todavía me pide confirmar cada señal con un botón de Telegram antes de ejecutar, como capa de seguridad mientras valido que el bicho entero funciona sin sorpresas. Es un paso intermedio a propósito, no el destino final — la automatización completa (sin que yo intervenga) es la meta declarada para las próximas versiones, una vez que el historial de ejecuciones reales me dé la confianza para soltarle la decisión también a él.

<p align="center">
  <img src="docs/screenshots/01-senal-en-el-grupo.png" alt="Señal real llegando al grupo de Telegram VIP SIGNALS FX a las 4:19 am" width="420">
</p>
<p align="center"><sub>Así llega una señal real al grupo — de madrugada, en español, formato fijo.</sub></p>

## Qué hace, en corto

1. Mi propia cuenta de Telegram (vía [Telethon](https://docs.telethon.dev/)) escucha el grupo de señales en tiempo real — uso mi cuenta y no un bot porque no soy admin del grupo, así que tengo que "leer" el chat como lo haría yo mismo.
2. Un flujo en [n8n](https://n8n.io/) interpreta cada mensaje: si matchea el formato fijo de señal nueva (instrumento, dirección, entrada, TP, SL), lo parsea por regex; si trae varios TP, genera hasta 2 sub-operaciones independientes según mis propias reglas de riesgo.
3. Me llega al toque una notificación a Telegram con botones **Confirmar / Rechazar**. Acá no hay atajos: nada se ejecuta sin que yo lo apruebe, aunque sea medio dormido con el celular en la cara.
4. Al confirmar, la orden se escribe en un puente de archivos que lee un **Expert Advisor en MQL4** corriendo dentro de MT4 (bajo Wine, en mi propia laptop), que la manda a la cuenta real.
5. El resultado (ticket, precio de ejecución, o motivo de fallo) vuelve a Postgres y me llega la confirmación por Telegram — con la operación ya abierta y corriendo, sin que yo haya tocado MT4.

<p align="center">
  <img src="docs/screenshots/02-confirmacion-telegram.png" alt="Notificación de nueva señal con botones Confirmar/Rechazar y confirmación de ejecución real con ticket" width="420">
</p>
<p align="center"><sub>La señal, el botón de Confirmar, y siete segundos después el ticket real ejecutado.</sub></p>

## Arquitectura

Telegram (grupo) → Telethon → webhook n8n → parser regex → Postgres → confirmación por Telegram → EA en MQL4 (MT4 vía Wine) → orden real en VT Markets → resultado de vuelta a n8n → notificación final. El dashboard consulta el estado en paralelo, sin intervenir en el flujo.

<p align="center">
  <img src="docs/screenshots/03-workflow-n8n.png" alt="Workflow completo en n8n: webhook, parser regex, confirmación, escritura de orden a MT4, lectura de resultados" width="700">
</p>
<p align="center"><sub>El workflow real en n8n — desde el webhook de Telethon hasta la escritura/lectura del puente con MT4.</sub></p>

**Por qué estas decisiones técnicas, no otras:**

- **Telethon en vez de un Bot API de Telegram** — no soy admin del grupo VIP, así que un bot no puede leer sus mensajes. Solo una cuenta de usuario (MTProto) puede.
- **n8n como orquestador en vez de un backend hecho a mano** — necesitaba iterar rápido sobre reglas de negocio (formato de señales, validaciones, reintentos) sin reescribir infraestructura cada vez, corriendo 100% local sin costo.
- **Confirmación humana en v1, no automatización ciega desde el día 1** — antes de dejar que un sistema mueva dinero real solo, quería verlo ejecutar señales reales con un humano de por medio, revisando que el parseo, el lotaje y la conexión con MT4 no fallen. Es una decisión de secuencia, no de filosofía: primero confío, después suelto.
- **EA propio en MQL4 en vez de un copiador comercial** — control total sobre el lotaje, el manejo de errores del bróker, y la lógica de "market vs. limit" según si el precio ya cruzó el nivel de entrada.
- **Todo corre local (mi laptop, CachyOS + Wine)** — cero costo de infraestructura mientras valido que el sistema es rentable en modo semi-automático, antes de justificar gastar en un VPS.

## Stack técnico

| Pieza | Tecnología |
|---|---|
| Captura de señales | Python + Telethon (MTProto) |
| Orquestación | n8n (Docker) |
| Base de datos | PostgreSQL |
| Interpretación de lenguaje variable (fase siguiente) | Gemini API |
| Ejecución real | MQL4 (Expert Advisor) sobre MT4 vía Wine |
| Dashboard de monitoreo | Flask + JS vanilla |
| Notificaciones y confirmación | Telegram Bot API |

## El proceso, no solo el resultado

Esto no salió de tirarle prompts a una IA hasta que "andara" (vibe coding puro) ni de pegar código hasta que compilara. Lo armé tratándolo como un producto real, aunque el único usuario sea yo: con alcance definido antes de escribir código, reglas de negocio versionadas aparte de la implementación, y disciplina de control de versiones — porque eso es lo que quiero que se note de mí como developer, no solo que "funciona". Este repo deja ese proceso a la vista a propósito:

- **Alcance de MVP definido por escrito antes de tocar código** — qué entra en v1 y qué queda explícitamente afuera ([detalle acá](docs/versions/v1.md)) se decidió y se documentó primero, no se fue improvisando sobre la marcha.
- **Fases con estado propio, no una lista de tareas gigante** — cada etapa (captura, parseo, confirmación, ejecución real, dashboard) se cerró y se verificó por separado antes de avanzar a la siguiente, con su estado registrado en `STATUS.md`.
- **Git Flow real**: cada feature en su propia rama (`feature/<algo>`), PR hacia `develop`, y `develop` → `main` solo cuando el ciclo completo está probado — nada de commits directos a `main`.
- **Historial de commits en español, descriptivo y granular** — se puede seguir cómo fue creciendo el proyecto día a día leyendo `git log`, sin necesitar contexto externo.
- **Bugs reales, documentados donde importaban** — el payload anidado del webhook, IDs de Telegram que rompían `INTEGER`, condiciones de carrera al abrir 2 órdenes seguidas, mensajes que Telethon perdía en el canal de más tráfico — todo está en el código y en `STATUS.md`, no escondido debajo de la alfombra.
- **Protocolo de negocio separado del código** (`PROTOCOLOS_KRONOS_BOT.md`) — las reglas de gestión de riesgo (tope de 2 sub-operaciones por señal, expiración a los 5 minutos, lotaje fijo en v1) están versionadas como fuente única de verdad, no dispersas en comentarios.

**Sobre las herramientas:** usé Claude Code como copiloto durante el desarrollo — para escribir código, cazar bugs y acelerar el diagnóstico. Pero cada decisión de arquitectura, cada regla de negocio, y cada línea antes de commitear pasó por mí: qué formato de señal soportar, cuándo una operación se considera vencida, cómo manejar el race condition de dos órdenes seguidas, qué va en v1 y qué no. La herramienta escribió código bajo dirección explícita mía, no al revés — por eso el repo tiene alcance definido, fases verificadas y un Git Flow real, en vez de un historial de "prompteo hasta que funcione".

## Evidencia real

No es una demo — corrió contra la cuenta real de VT Markets:

```
Señal: XAUUSD BUY 4398.57, TP 4402, SL 4370
→ Confirmada por Telegram
→ Ticket real: 24827753
→ Status: OPEN, visible en el dashboard con precio en vivo
```

<p align="center">
  <img src="docs/screenshots/04-dashboard.png" alt="Dashboard con la posición abierta en vivo, historial de señales y botones de acción" width="700">
</p>
<p align="center"><sub>Dashboard local: posición real abierta con precio en vivo, y el historial completo de señales (incluida la que rechacé a mano).</sub></p>

## Documentación

El README cuenta la historia y el porqué. El detalle técnico vive aparte, versionado por su cuenta:

- **[docs/versions/v1.md](docs/versions/v1.md)** — qué incluye v1, qué queda afuera a propósito, y qué sigue en v2.
- **[STATUS.md](STATUS.md)** — estado técnico fase por fase, pensado para retomar el proyecto sin depender de memoria de conversaciones previas.
- **[PROTOCOLOS_KRONOS_BOT.md](PROTOCOLOS_KRONOS_BOT.md)** — reglas de negocio y gestión de riesgo, fuente única de verdad.

## Nota

Este proyecto es una herramienta personal de automatización, no un producto de inversión ni una recomendación de trading. Todo el capital operado es propio y el riesgo se gestiona con reglas explícitas y fijas (ver `PROTOCOLOS_KRONOS_BOT.md`).

---

Construido por [alejandro-xoxo](https://github.com/alejandro-xoxo) mientras aprendo a programar en serio, resolviendo un problema que era mío.
