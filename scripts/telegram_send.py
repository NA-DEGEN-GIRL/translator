#!/usr/bin/env python3
"""Send files via Telegram Bot.

Setup:
1. Create bot via @BotFather → get bot token
2. Send any message to your bot
3. Get your chat ID: curl https://api.telegram.org/bot<TOKEN>/getUpdates

Create .telegram.env:
    TELEGRAM_BOT_TOKEN=your-bot-token
    TELEGRAM_CHAT_ID=your-chat-id

Usage:
    python scripts/telegram_send.py path/to/file.apk
    python scripts/telegram_send.py path/to/file.apk "Optional caption"
"""

import sys
import os
import requests
from pathlib import Path

ENV_FILE = Path(__file__).parent.parent / '.telegram.env'

def load_config():
    if not ENV_FILE.exists():
        print(f"Error: {ENV_FILE} not found.")
        print("Create it with TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID")
        sys.exit(1)

    config = {}
    for line in ENV_FILE.read_text().strip().splitlines():
        line = line.strip()
        if '=' in line and not line.startswith('#'):
            k, v = line.split('=', 1)
            config[k.strip()] = v.strip()

    token = config.get('TELEGRAM_BOT_TOKEN')
    chat_id = config.get('TELEGRAM_CHAT_ID')

    if not token or not chat_id:
        print("Error: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID required in .telegram.env")
        sys.exit(1)

    return token, chat_id

def send_file(filepath, caption=None):
    token, chat_id = load_config()
    filepath = Path(filepath)

    if not filepath.exists():
        print(f"Error: {filepath} not found")
        sys.exit(1)

    url = f"https://api.telegram.org/bot{token}/sendDocument"
    with open(filepath, 'rb') as f:
        data = {'chat_id': chat_id}
        if caption:
            data['caption'] = caption
        r = requests.post(url, data=data, files={'document': (filepath.name, f)})

    if r.status_code == 200 and r.json().get('ok'):
        print(f"Sent: {filepath.name} ({filepath.stat().st_size / 1024 / 1024:.1f}MB)")
    else:
        print(f"Failed: {r.status_code} {r.text[:200]}")
        sys.exit(1)

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python scripts/telegram_send.py <file> [caption]")
        sys.exit(1)

    caption = sys.argv[2] if len(sys.argv) > 2 else None
    send_file(sys.argv[1], caption)
