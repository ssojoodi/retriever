#!/usr/bin/python3
"""Test-only SFTP proxy for delayed replies and interrupted transfers."""
import pathlib
import struct
import subprocess
import sys
import time

marker = pathlib.Path(sys.argv[1])
child = subprocess.Popen(sys.argv[2:], stdin=subprocess.PIPE, stdout=subprocess.PIPE)


def packet(stream):
    header = stream.read(4)
    if len(header) != 4:
        raise EOFError
    length = struct.unpack('>I', header)[0]
    body = stream.read(length)
    if len(body) != length:
        raise EOFError
    return header + body


def forward(data, stream):
    stream.write(data)
    stream.flush()


try:
    wrote = False
    while True:
        request = packet(sys.stdin.buffer)
        forward(request, child.stdin)
        response = packet(child.stdout)
        kind = request[4]
        if kind == 6:
            wrote = True
        mode = marker.read_text() if marker.exists() else ''
        late_write = False
        if mode == 'drop-write-late' and kind == 6:
            handle_length = struct.unpack('>I', request[9:13])[0]
            offset = struct.unpack('>Q', request[13 + handle_length:21 + handle_length])[0]
            late_write = offset >= 1_150_000_000
        if (mode == 'drop-write' and kind == 6) or late_write or (mode == 'drop-rename' and kind in (18, 200)):
            marker.unlink()
            break
        if kind == 5 and mode in ('drop-next-read', 'expect-resumed-read'):
            handle_length = struct.unpack('>I', request[9:13])[0]
            offset = struct.unpack('>Q', request[13 + handle_length:21 + handle_length])[0]
            if mode == 'drop-next-read' and offset > 0:
                marker.unlink()
                break
            if mode == 'expect-resumed-read':
                marker.unlink()
                if offset == 0:
                    break
        # The interrupted write fixture has one 32 KiB chunk on the server.
        if mode == 'verify-resumed-write':
            if kind == 5:
                time.sleep(1)
            if kind == 6:
                handle_length = struct.unpack('>I', request[9:13])[0]
                offset = struct.unpack_from('>Q', request, 13 + handle_length)[0]
                if offset != 32768:
                    raise AssertionError(f"First resumed write started at {offset}")
                marker.unlink()
        if mode == 'delay-read' and kind == 5:
            marker.unlink()
            time.sleep(2)
        if kind == 4 and wrote:
            wrote = False
            if mode in ('delay', 'drop'):
                marker.unlink()
                if mode == 'delay':
                    time.sleep(2)
                else:
                    break
        forward(response, sys.stdout.buffer)
except (EOFError, BrokenPipeError):
    pass
finally:
    child.terminate()
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
