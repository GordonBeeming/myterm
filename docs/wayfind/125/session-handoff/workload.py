"""Autonomous terminal workload. Each process owns a real PTY slave."""
import fcntl
import json
import os
import select
import struct
import sys
import termios
import time
import tty

tty.setraw(0)
rate = 0
sequence = 0
pending = bytearray()
deadline = time.monotonic()
last_output = deadline
os.write(1, f"BOOT:{os.getpid()}\r\n".encode())
while True:
    ready, _, _ = select.select([0], [], [], max(0, min(0.01, deadline - time.monotonic())))
    if ready:
        chunk = os.read(0, 65536)
        if not chunk:
            break
        pending.extend(chunk)
        if len(pending) > 65536:
            raise RuntimeError("workload input bound")
        while pending.startswith(b"\x1b[") and b"R" in pending:
            end = pending.index(b"R") + 1
            reply = bytes(pending[:end])
            del pending[:end]
            os.write(1, b"REPLY:" + reply.hex().encode() + b"\r\n")
        if pending and not pending.startswith((b"{", b"\x1b[")):
            # Native keyboard review uses a raw echo workload, with no shell commands executed.
            os.write(1, pending)
            pending.clear()
        while b"\n" in pending:
            line, _, pending = pending.partition(b"\n")
            try:
                request = json.loads(line)
            except json.JSONDecodeError:
                os.write(1, line + b"\r\n")
                continue
            if "rate" in request:
                rate = request["rate"]
                deadline = time.monotonic()
                last_output = deadline
            if "keyboard" in request:
                # Keep manual key bytes separate from the workload's JSON control records.
                data = bytes(request["keyboard"])
                if len(data) > 4096:
                    raise RuntimeError("keyboard record bound")
                offset = 0
                while offset < len(data):
                    offset += os.write(1, data[offset:])
            if "echo" in request:
                os.write(1, f"ECHO:{request['echo']}:{os.getpid()}\r\n".encode())
            if "size" in request:
                rows, cols, _, _ = struct.unpack("HHHH", fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))
                os.write(1, f"SIZE:{rows}:{cols}\r\n".encode())
            if "query" in request:
                os.write(1, b"\x1b[6n")
            if "quit" in request:
                sys.exit(0)
    now = time.monotonic()
    if now >= deadline:
        if rate:
            count = max(1, min(65536, round(rate * (now - last_output))))
            last_output = now
            # Stable ASCII records exercise history and wrapping without hidden extensions.
            record = f"OUT:{sequence:012d}:".encode() + b"x" * 80 + b"\r\n"
            payload = (record * ((count + len(record) - 1) // len(record)))[:count]
            offset = 0
            while offset < len(payload):
                offset += os.write(1, payload[offset:])
            sequence += 1
        deadline = now + 0.01
