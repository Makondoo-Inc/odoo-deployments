"""Minimal SMTP sink on 127.0.0.1:2525: accepts every message and discards it.

Point the copy's outgoing mail server at it to measure how fast Odoo's mail
queue drains without a real provider:
    python3 smtp_sink.py > results/smtp_sink.log &
    psql ... -c "update ir_mail_server set smtp_host='127.0.0.1', smtp_port=2525, smtp_encryption='none', smtp_user=null, smtp_pass=null, active=true"
    then enable the "Mail: Email Queue Manager" cron on the copy.
Logs one line per message received (epoch, count, bytes).

Copyright (C) 2025-2026 Makondoo Inc. Licence: AGPL-3.0-or-later
"""
import asyncio
import time

COUNT = 0


async def handle(reader, writer):
    global COUNT
    writer.write(b"220 sink ESMTP\r\n")
    await writer.drain()
    in_data, size = False, 0
    while line := await reader.readline():
        if in_data:
            if line in (b".\r\n", b".\n"):
                in_data = False
                COUNT += 1
                print(f"{time.time():.0f} msg {COUNT} {size}", flush=True)
                writer.write(b"250 OK\r\n")
            else:
                size += len(line)
                continue
        else:
            cmd = line[:4].upper()
            if cmd in (b"EHLO", b"HELO"):
                writer.write(b"250-sink\r\n250 SIZE 52428800\r\n")
            elif cmd == b"DATA":
                in_data, size = True, 0
                writer.write(b"354 go ahead\r\n")
            elif cmd == b"QUIT":
                writer.write(b"221 bye\r\n")
                await writer.drain()
                break
            else:
                writer.write(b"250 OK\r\n")
        await writer.drain()
    writer.close()


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", 2525)
    async with server:
        await server.serve_forever()


asyncio.run(main())
