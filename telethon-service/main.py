import os
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

SESSION_PATH = "/app/session/telethon_session"

client = TelegramClient(SESSION_PATH, API_ID, API_HASH)


@client.on(events.NewMessage(chats=GROUP_IDENTIFIER if GROUP_IDENTIFIER else None))
async def handler(event):
    message_text = event.raw_text
    sender = await event.get_sender()
    sender_name = getattr(sender, "username", None) or getattr(sender, "first_name", "desconocido")

    payload = {
        "message_id": event.message.id,
        "chat_id": event.chat_id,
        "sender": sender_name,
        "text": message_text,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "reply_to_message_id": event.message.reply_to_msg_id,
    }

    logger.info(f"Mensaje capturado de {sender_name}: {message_text[:80]!r}")

    try:
        response = requests.post(N8N_WEBHOOK_URL, json=payload, timeout=10)
        response.raise_for_status()
        logger.info(f"Enviado a n8n correctamente (status {response.status_code})")
    except requests.RequestException as e:
        logger.error(f"Error enviando a n8n: {e}")


async def main():
    await client.start(phone=PHONE)
    logger.info("Cliente de Telegram conectado y escuchando mensajes...")

    if not GROUP_IDENTIFIER:
        logger.warning(
            "TELEGRAM_GROUP_ID no está definido. "
            "El bot está escuchando TODOS los chats. "
            "Corre list_groups.py para identificar el ID del grupo y configúralo en .env"
        )

    await client.run_until_disconnected()


if __name__ == "__main__":
    with client:
        client.loop.run_until_complete(main())