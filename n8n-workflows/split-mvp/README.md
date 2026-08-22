# Split de `webhook-mvp-workflow.json` en 7 workflows aislados

Divide el workflow monolítico de producción en 7 workflows independientes,
para que un canal que se satura o falla (ej. Gemini lento, un error en el
scheduler de cierres) no bloquee ni comparta cola de ejecución con los
demás. Los workflows que antes eran ramas del mismo trigger (señal nueva
vs. seguimiento, confirmación vs. ejecución en MT4) ahora se conectan
entre sí con nodos **Execute Workflow** en modo fire-and-forget
(`waitForSubWorkflow: false`): el workflow que dispara sigue su curso al
toque, sin esperar respuesta, y el destino corre en su propia ejecución.

Los que ya tenían su propio trigger nativo (schedulers de resultados/
cierres MT4, callback de Telegram) quedan cada uno en su propio archivo
tal cual — ya estaban aislados por trigger, solo se separan del archivo.

También se bajó el intervalo de los dos `scheduleTrigger` (resultados y
cierres MT4) de 5s a 1s.

## Archivos

1. `01-entrada-webhook-telethon.json` — Webhook Telethon → valida secreto
   → parsea regex → despacha a **02** (señal nueva) o **07** (seguimiento).
2. `02-señal-nueva-parseo-confirmado.json` — inserta señal, notifica Telegram.
3. `03-confirmación-telegram.json` — callback Confirmar/Rechazar → al
   confirmar, despacha a **04** en paralelo (no espera).
4. `04-ejecución-en-mt4.json` — escribe la orden pending para el EA.
5. `05-scheduler-resultados-mt4.json` — lee resultados del EA cada 1s.
6. `06-scheduler-cierres-mt4.json` — lee cierres TP/SL del EA cada 1s.
7. `07-seguimiento-gemini.json` — clasifica y, si aplica, interpreta con
   Gemini las instrucciones de seguimiento.

## Pasos manuales después de importar en n8n

Cada workflow es independiente pero **no** se auto-referencian: los
nodos `Ejecutar: <nombre>` (tipo Execute Workflow) se crearon con
`workflowId.value` vacío porque el ID real no existe hasta importar el
archivo destino. Después de importar los 7:

1. Abrir cada nodo `Ejecutar: ...` y reseleccionar el workflow destino
   correspondiente en el picker (el nombre ya está puesto como
   `cachedResultName`, solo hay que confirmar la selección).
2. Verificar que las credenciales (Postgres, Telegram, Gemini/HTTP) sigan
   apuntando bien — se copiaron con el mismo `id` de credencial del
   workflow original, así que si es la misma instancia de n8n deberían
   quedar resueltas solas.
3. Activar los 7 workflows.
4. **No** subir esto a producción hasta probarlo en el stack dev
   equivalente (`split-dev/`) — ver regla de `develop → main → producción`
   en `CLAUDE.md`.

Fase 4 (Gemini, workflow 07) sigue bloqueada para producción por decisión
del usuario — ver `STATUS.md`. Este split no cambia ese estado: solo
reorganiza el archivo, no habilita nada nuevo.
