#!/usr/bin/python3
"""Test-only SFTP proxy: delay/drop one upload CLOSE reply from a real SSH fixture."""
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
        if kind == 4 and wrote:
            wrote = False
            if marker.exists():
                mode = marker.read_text()
                marker.unlink()
                if mode == 'delay':
                    time.sleep(2)
                elif mode == 'drop':
                    break
                else:
                    raise ValueError(mode)
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
