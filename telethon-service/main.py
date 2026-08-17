import os
import asyncio
import logging
from datetime import datetime, timezone

import requests
from telethon import TelegramClient, events

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("telethon-signal-reader")

API_ID = int(os.environ["TELEGRAM_API_ID"])
API_HASH = os.environ["TELEGRAM_API_HASH"]
PHONE = os.environ["TELEGRAM_PHONE"]
N8N_WEBHOOK_URL = os.environ["N8N_WEBHOOK_URL"]

_group_env = os.environ.get("TELEGRAM_GROUP_ID", "").strip()
GROUP_IDENTIFIER = int(_group_env) if _group_env else None

# Polling de respaldo: en canales de mucho tráfico, Telethon a veces pide
# una "difference" (resync de pts) al reconectar o ante gaps de updates, y
# en ese proceso puede no volver a disparar events.NewMessage para el
# mensaje que causó el gap — se pierde silenciosamente (bug conocido de la
# librería, no del servidor). Este loop revisa el historial reciente cada
# POLL_INTERVAL_SECONDS y reenvía cualquier mensaje no visto todavía, como
# red de seguridad del evento en vivo.
POLL_INTERVAL_SECONDS = 15
POLL_HISTORY_LIMIT = 20

SESSION_PATH = "/app/session/telethon_session"

client = TelegramClient(SESSION_PATH, API_ID, API_HASH)

# IDs de mensaje ya enviados a n8n (por el evento en vivo o por el polling),
# para no reenviar el mismo mensaje dos veces.
seen_message_ids = set()


async def process_message(message):
    if message.id in seen_message_ids:
        return
    seen_message_ids.add(message.id)

    message_text = message.raw_text or ""
    sender = await message.get_sender()
    sender_name = getattr(sender, "username", None) or getattr(sender, "first_name", "desconocido")

    payload = {
        "message_id": message.id,
        "chat_id": message.chat_id,
        "sender": sender_name,
        "text": message_text,
        "timestamp": message.date.astimezone(timezone.utc).isoformat(),
        "reply_to_message_id": message.reply_to_msg_id,
    }

    logger.info(f"Mensaje capturado de {sender_name}: {message_text[:80]!r}")

    try:
        response = requests.post(N8N_WEBHOOK_URL, json=payload, timeout=10)
        response.raise_for_status()
        logger.info(f"Enviado a n8n correctamente (status {response.status_code})")
    except requests.RequestException as e:
        logger.error(f"Error enviando a n8n: {e}")


@client.on(events.NewMessage(chats=GROUP_IDENTIFIER if GROUP_IDENTIFIER else None))
async def handler(event):
    await process_message(event.message)


async def poll_recent_messages():
    if not GROUP_IDENTIFIER:
        return

    while True:
        await asyncio.sleep(POLL_INTERVAL_SECONDS)
        try:
            async for message in client.iter_messages(GROUP_IDENTIFIER, limit=POLL_HISTORY_LIMIT):
                if message.id in seen_message_ids:
                    continue
                logger.info(f"Polling de respaldo: recuperado mensaje {message.id} no visto por el evento en vivo")
                await process_message(message)
        except Exception as e:
            logger.error(f"Error en polling de respaldo: {e}")


async def main():
    await client.start(phone=PHONE)
    logger.info("Cliente de Telegram conectado y escuchando mensajes...")

    if not GROUP_IDENTIFIER:
        logger.warning(
            "TELEGRAM_GROUP_ID no está definido. "
            "El bot está escuchando TODOS los chats. "
            "Corre list_groups.py para identificar el ID del grupo y configúralo en .env"
        )
    else:
        # Sembrar seen_message_ids con el historial reciente para no
        # reenviar mensajes viejos al arrancar el polling de respaldo.
        async for message in client.iter_messages(GROUP_IDENTIFIER, limit=POLL_HISTORY_LIMIT):
            seen_message_ids.add(message.id)

    asyncio.create_task(poll_recent_messages())
    await client.run_until_disconnected()


if __name__ == "__main__":
    with client:
        client.loop.run_until_complete(main())
