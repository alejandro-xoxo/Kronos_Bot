"""
Exporta el historial de mensajes del grupo TELEGRAM_GROUP_ID a un archivo
.md, para armar un dataset real con el que diseñar los regex de Fase 4.

SOLO LECTURA: usa exclusivamente iter_messages() (GetHistoryRequest por
debajo). No llama a ningún método que escriba en el grupo (send_message,
edit_message, delete_messages, etc.).

Reusa la sesión de Telethon YA AUTENTICADA del servicio `telethon` — esa
sesión vive en el volumen Docker `telethon_session`, no en el filesystem
del host, así que este script tiene que correr con acceso a ese volumen.
La forma más simple es ejecutarlo DENTRO del contenedor `telethon` ya
levantado (comparte imagen, deps y el volumen montado en /app/session):

    docker compose cp scripts/export-group-history.py telethon:/app/export-group-history.py
    docker compose exec telethon python /app/export-group-history.py
    docker compose cp telethon:/app/kronos_group_export.md ./kronos_group_export.md

(reemplazar `docker compose` por el compose file de prod si hace falta,
ej. `docker compose -f docker-compose.yml ...` desde Kronos_Bot-prod).

No requiere ningún env var nuevo — usa las mismas TELEGRAM_API_ID,
TELEGRAM_API_HASH, TELEGRAM_PHONE, TELEGRAM_GROUP_ID que ya están en el
.env del stack.
"""

import asyncio
import os
from datetime import timezone

from telethon import TelegramClient
from telethon.errors import FloodWaitError

API_ID = int(os.environ["TELEGRAM_API_ID"])
API_HASH = os.environ["TELEGRAM_API_HASH"]
PHONE = os.environ["TELEGRAM_PHONE"]
GROUP_IDENTIFIER = int(os.environ["TELEGRAM_GROUP_ID"])

SESSION_PATH = "/app/session/telethon_session"

MAX_MESSAGES = 3000
BATCH_SIZE = 100  # mensajes por lote antes de la pausa
PAUSE_BETWEEN_BATCHES_SECONDS = 2  # margen conservador bajo el límite de Telegram

OUTPUT_PATH = "/app/kronos_group_export.md"

client = TelegramClient(SESSION_PATH, API_ID, API_HASH)


async def main():
    await client.start(phone=PHONE)
    entity = await client.get_entity(GROUP_IDENTIFIER)

    messages = []
    fetched_since_pause = 0

    print(f"Exportando hasta {MAX_MESSAGES} mensajes de '{getattr(entity, 'title', GROUP_IDENTIFIER)}'...")

    # El FloodWaitError lo lanza la propia llamada a Telegram dentro de
    # iter_messages() (al pedir el próximo lote internamente), no el
    # sleep de la pausa — por eso el try/except tiene que envolver el
    # iterador completo, no el asyncio.sleep().
    iterator = client.iter_messages(entity, limit=MAX_MESSAGES)
    while True:
        try:
            message = await iterator.__anext__()
        except StopAsyncIteration:
            break
        except FloodWaitError as e:
            print(f"  FloodWait: esperando {e.seconds}s pedido por Telegram...")
            await asyncio.sleep(e.seconds)
            continue

        # Saltar entradas de servicio (usuario entró/salió, etc.) — no
        # tienen texto ni son señales, solo agregan ruido al dataset.
        if message.action is not None:
            continue

        messages.append(message)
        fetched_since_pause += 1

        if fetched_since_pause >= BATCH_SIZE:
            print(f"  {len(messages)} mensajes descargados, pausa de {PAUSE_BETWEEN_BATCHES_SECONDS}s...")
            await asyncio.sleep(PAUSE_BETWEEN_BATCHES_SECONDS)
            fetched_since_pause = 0

    # iter_messages entrega del más nuevo al más viejo; invertir para que
    # el .md quede en orden cronológico ascendente, más fácil de leer.
    messages.reverse()

    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        f.write(f"# Historial exportado — {getattr(entity, 'title', GROUP_IDENTIFIER)}\n\n")
        f.write(f"Total de mensajes: {len(messages)}\n\n---\n\n")

        for message in messages:
            timestamp = message.date.astimezone(timezone.utc).isoformat()
            reply_note = f" (reply a #{message.reply_to_msg_id})" if message.reply_to_msg_id else ""
            text = (message.raw_text or "").strip()

            f.write(f"## #{message.id} — {timestamp}{reply_note}\n\n")
            if text:
                f.write(f"{text}\n\n")
            else:
                f.write("_(mensaje sin texto — media/sticker/etc.)_\n\n")

    print(f"Listo: {len(messages)} mensajes escritos en {OUTPUT_PATH}")


if __name__ == "__main__":
    with client:
        client.loop.run_until_complete(main())
