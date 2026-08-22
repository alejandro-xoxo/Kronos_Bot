# Split de `webhook-dev-workflow.json` en 7 workflows aislados

Mismo split que `../split-mvp/`, aplicado a la versión dev. La única
diferencia estructural respetada a propósito: el entrypoint sigue siendo
el `Telegram Trigger (unificado dev)` propio de dev (Bot API, no
Webhook+Telethon) — nunca se sincroniza con el de producción, ver
`CLAUDE.md`. El nodo `¿Es callback_query?` decide ahí mismo si despacha
a **03** (confirmación) o sigue el camino de señal nueva/seguimiento
hacia **01** → **02**/**07**.

Ver `../split-mvp/README.md` para el detalle de los pasos manuales tras
importar (reseleccionar destino en cada nodo `Ejecutar: ...`, verificar
credenciales, activar).

Este stack es el que se prueba primero (`docker-compose.dev.yml`, cuenta
demo) antes de replicar el mismo split en producción.
