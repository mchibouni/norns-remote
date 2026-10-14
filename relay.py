#!/usr/bin/env python3
"""norns-remote relay: the norns screen and parameters to browsers, their input back.

The mod (lib/remote.lua) sends the screen here over OSC, one letter per pixel, and
parameters and levels as JSON text. Browsers get the screen over a websocket as
8192 levels (0-15), zlib-compressed, and the JSON as is. They send back keys, knob
turns and parameter changes: keys go to matron's own /remote/key OSC command, the
rest to the mod's /norns-remote/<command>. The relay itself lists the installed
scripts, and serves the page (index.html) on the same port.

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
FROM_MOD_PORT = 10112              # mod -> relay, on localhost
MATRON = ("127.0.0.1", 10111)      # matron's OSC port
HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(HERE, "index.html")
CODE = os.path.dirname(HERE)       # dust/code, where the scripts are
WS_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
LEVELS = bytes((i - 65) & 0x0F for i in range(256))  # "A".."P" -> 0..15
MAX_BACKLOG = 64 * 1024            # skip frames for a client this far behind

clients = set()
last_frame = None
matron = None                      # datagram transport, also used to send


def osc(path, *args):
    def pad(b):
        return b + b"\0" * (4 - len(b) % 4)
    tags, data = ",", b""
    for a in args:
        if isinstance(a, int):
            tags, data = tags + "i", data + struct.pack(">i", a)
        elif isinstance(a, float):
            tags, data = tags + "f", data + struct.pack(">f", a)
        else:
            tags, data = tags + "s", data + pad(str(a).encode())
    return pad(path.encode()) + pad(tags.encode()) + data


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


def broadcast(payload, opcode):
    for writer in list(clients):
        if writer.transport.get_write_buffer_size() < MAX_BACKLOG:
            ws_send(writer, payload, opcode)


class FromMod(asyncio.DatagramProtocol):
    def datagram_received(self, data, _addr):
        global last_frame
        path, arg = osc_string(data)
        if arg is None:
            return
        if path == b"/norns-remote/screen" and len(arg) == 128 * 64:
            last_frame = zlib.compress(arg.translate(LEVELS), 1)
            broadcast(last_frame, 0x2)
        elif path == b"/norns-remote/json":
            broadcast(arg, 0x1)


def ping(new=False):
    if matron is not None:
        matron.sendto(osc("/norns-remote/ping", 1 if new else 0), MATRON)


async def pinger():
    while True:
        await asyncio.sleep(1)
        if clients:
            ping()


def scripts():
    """The installed scripts, named as the norns SELECT menu names them."""
    found = []
    for folder in sorted(os.listdir(CODE), key=str.lower):
        path = os.path.join(CODE, folder)
        if folder.startswith(".") or not os.path.isdir(path):
            continue
        for name in sorted(os.listdir(path), key=str.lower):
            if name.endswith(".lua") and os.path.isfile(os.path.join(path, name)):
                stem = name[:-4]
                found.append({"name": folder if stem == folder else f"{folder}/{stem}",
                              "path": os.path.join(path, name)})
    return found


def to_matron(command, *args):
    if matron is not None:
        matron.sendto(osc("/norns-remote/" + command, *args), MATRON)


def handle_input(writer, text):
    try:
        msg = json.loads(text)
        if "key" in msg:
            n, z = (int(v) for v in msg["key"])
            if n in (1, 2, 3) and z in (0, 1) and matron is not None:
                matron.sendto(osc("/remote/key", n, z), MATRON)
        elif "enc" in msg:
            n, d = (int(v) for v in msg["enc"])
            if n in (1, 2, 3) and -64 <= d <= 64 and d:
                to_matron("enc", n, d)
        elif "set" in msg or "raw" in msg or "delta" in msg:
            command = next(c for c in ("set", "raw", "delta") if c in msg)
            i, v = msg[command]
            to_matron(command, int(i), float(v))
        elif "trig" in msg:
            to_matron("trig", int(msg["trig"]))
        elif "load" in msg:
            if any(s["path"] == msg["load"] for s in scripts()):
                to_matron("load", msg["load"])
        elif "scripts" in msg:
            ws_send(writer, json.dumps({"type": "scripts", "list": scripts()}).encode(), 0x1)
    except (ValueError, TypeError, KeyError, StopIteration, OSError):
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
                handle_input(writer, payload.decode("utf-8", "replace"))
    except (asyncio.IncompleteReadError, ConnectionError):
        pass
    finally:
        clients.discard(writer)


def read_page():
    with open(PAGE, "rb") as fh:
        return fh.read()


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
            body = await asyncio.to_thread(read_page)  # read each time: edits show on reload
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
            FromMod, local_addr=("127.0.0.1", FROM_MOD_PORT))
        server = await asyncio.start_server(handle, port=HTTP_PORT)
    except OSError as exc:  # the mod starts a relay at every matron start
        print(f"norns-remote: not starting, ports in use ({exc})", flush=True)
        return
    print(f"norns-remote: http://0.0.0.0:{HTTP_PORT}/", flush=True)
    async with server:
        await asyncio.gather(server.serve_forever(), pinger())


if __name__ == "__main__":
    asyncio.run(main())
