"""
Script auxiliar: se ejecuta UNA sola vez para identificar el ID del grupo
que queremos escuchar. Corre esto, busca el nombre del grupo en el listado,
y copia el ID a tu archivo .env como TELEGRAM_GROUP_ID.
"""

import os
from telethon import TelegramClient
from telethon.tl.types import Chat, Channel

API_ID = int(os.environ["TELEGRAM_API_ID"])
API_HASH = os.environ["TELEGRAM_API_HASH"]
PHONE = os.environ["TELEGRAM_PHONE"]

SESSION_PATH = "/app/session/telethon_session"

client = TelegramClient(SESSION_PATH, API_ID, API_HASH)


async def main():
    await client.start(phone=PHONE)
    print("\n=== Tus grupos y canales ===\n")

    async for dialog in client.iter_dialogs():
        entity = dialog.entity
        if isinstance(entity, (Chat, Channel)):
            print(f"Nombre: {dialog.name}")
            print(f"ID:     {dialog.id}")
            print("-" * 40)


if __name__ == "__main__":
    with client:
        client.loop.run_until_complete(main())