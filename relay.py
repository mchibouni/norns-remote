#!/usr/bin/env python3
"""norns-remote relay: the norns screen to browsers, their keys and knobs back.

The norns-remote mod (lib/mod.lua) sends the screen here over OSC, one letter per
pixel. Browsers get it over a websocket as 8192 levels (0-15), zlib-compressed,
and send back key presses and knob turns: keys go to matron's own /remote/key
OSC command, turns to the mod's /norns-remote/enc, which counts them in steps.
The page itself (index.html) is served on the same port.

Standard library only, so it runs on the norns' stock Python 3.9.
"""
import asyncio
import base64
import hashlib
import json
import os
import struct
import zlib

HTTP_PORT = int(os.environ.get("NORNS_REMOTE_PORT", "8099"))
SCREEN_PORT = 10112                # mod -> relay, on localhost
MATRON = ("127.0.0.1", 10111)      # matron's OSC port
PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")
WS_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
LEVELS = bytes((i - 65) & 0x0F for i in range(256))  # "A".."P" -> 0..15
MAX_BACKLOG = 64 * 1024            # skip frames for a client this far behind

clients = set()
last_frame = None
matron = None                      # datagram transport, also used to send
PAGE_BODY = b""


def osc(path, *ints):
    def pad(b):
        return b + b"\0" * (4 - len(b) % 4)
    return (pad(path.encode()) + pad(("," + "i" * len(ints)).encode())
            + struct.pack(f">{len(ints)}i", *ints))


def osc_string(packet):
    """(path, first argument) of an OSC message whose first argument is a string."""
    try:
        end = packet.index(b"\0")
        tags = (end // 4 + 1) * 4
        tags_end = packet.index(b"\0", tags)
        if packet[tags:tags + 2] != b",s":
            return None, None
        arg = (tags_end // 4 + 1) * 4
        return packet[:end], packet[arg:packet.index(b"\0", arg)]
    except ValueError:
        return None, None


def ws_send(writer, payload, opcode=0x2):
    n = len(payload)
    if n < 126:
        head = struct.pack(">BB", 0x80 | opcode, n)
    elif n < 65536:
        head = struct.pack(">BBH", 0x80 | opcode, 126, n)
    else:
        head = struct.pack(">BBQ", 0x80 | opcode, 127, n)
    writer.write(head + payload)


class Screen(asyncio.DatagramProtocol):
    def datagram_received(self, data, _addr):
        global last_frame
        path, pixels = osc_string(data)
        if pixels is None or path != b"/norns-remote/screen" or len(pixels) != 128 * 64:
            return
        last_frame = zlib.compress(pixels.translate(LEVELS), 1)
        for writer in list(clients):
            if writer.transport.get_write_buffer_size() < MAX_BACKLOG:
                ws_send(writer, last_frame)


def ping(new=False):
    if matron is not None:
        matron.sendto(osc("/norns-remote/ping", 1 if new else 0), MATRON)


async def pinger():
    while True:
        await asyncio.sleep(1)
        if clients:
            ping()


def handle_input(text):
    if matron is None:
        return
    try:
        msg = json.loads(text)
        if "key" in msg:
            n, z = (int(v) for v in msg["key"])
            if n in (1, 2, 3) and z in (0, 1):
                matron.sendto(osc("/remote/key", n, z), MATRON)
        elif "enc" in msg:
            n, d = (int(v) for v in msg["enc"])
            if n in (1, 2, 3) and -64 <= d <= 64 and d:
                matron.sendto(osc("/norns-remote/enc", n, d), MATRON)
    except (ValueError, TypeError, KeyError):
        pass


async def read_frame(reader):
    b1, b2 = await reader.readexactly(2)
    n = b2 & 0x7F
    if n == 126:
        n = struct.unpack(">H", await reader.readexactly(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", await reader.readexactly(8))[0]
    if n > 65536:
        raise ConnectionError("frame too large")
    mask = await reader.readexactly(4) if b2 & 0x80 else b"\0\0\0\0"
    data = bytearray(await reader.readexactly(n))
    for i in range(n):
        data[i] ^= mask[i % 4]
    return b1 & 0x0F, bytes(data)


async def websocket(reader, writer, headers):
    key = headers.get("sec-websocket-key", "").encode()
    accept = base64.b64encode(hashlib.sha1(key + WS_GUID).digest())
    writer.write(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                 b"Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
    if last_frame is not None:
        ws_send(writer, last_frame)
    clients.add(writer)
    ping(new=True)
    try:
        while True:
            opcode, payload = await read_frame(reader)
            if opcode == 0x8:
                ws_send(writer, payload[:2], 0x8)
                break
            if opcode == 0x9:
                ws_send(writer, payload, 0xA)
            elif opcode == 0x1:
                handle_input(payload.decode("utf-8", "replace"))
    except (asyncio.IncompleteReadError, ConnectionError):
        pass
    finally:
        clients.discard(writer)


async def handle(reader, writer):
    try:
        head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
        lines = head.decode("latin-1").split("\r\n")
        path = lines[0].split(" ")[1]
        headers = {k.strip().lower(): v.strip()
                   for k, v in (ln.split(":", 1) for ln in lines[1:] if ":" in ln)}
        if path == "/ws" and headers.get("upgrade", "").lower() == "websocket":
            await websocket(reader, writer, headers)
        elif path in ("/", "/index.html"):
            body = PAGE_BODY
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                         b"Cache-Control: no-cache\r\nContent-Length: %d\r\n"
                         b"Connection: close\r\n\r\n" % len(body) + body)
        else:
            writer.write(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n"
                         b"Connection: close\r\n\r\n")
        await writer.drain()
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError,
            ConnectionError, IndexError, ValueError):
        pass
    finally:
        writer.close()


async def main():
    global matron
    loop = asyncio.get_running_loop()
    try:
        matron, _ = await loop.create_datagram_endpoint(
            Screen, local_addr=("127.0.0.1", SCREEN_PORT))
        server = await asyncio.start_server(handle, port=HTTP_PORT)
    except OSError as exc:  # the mod starts a relay at every matron start
        print(f"norns-remote: not starting, ports in use ({exc})", flush=True)
        return
    print(f"norns-remote: http://0.0.0.0:{HTTP_PORT}/", flush=True)
    async with server:
        await asyncio.gather(server.serve_forever(), pinger())


if __name__ == "__main__":
    with open(PAGE, "rb") as fh:
        PAGE_BODY = fh.read()
    asyncio.run(main())
