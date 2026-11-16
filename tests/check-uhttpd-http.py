#!/usr/bin/env python3
"""Bounded loopback regression checks against a compiled uhttpd binary."""
import pathlib
import socket
import subprocess
import sys
import tempfile
import time

binary = str(pathlib.Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory() as temp:
    pathlib.Path(temp, 'index.html').write_text('mango-header-test\n')
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    server = subprocess.Popen([binary, '-f', '-p', f'127.0.0.1:{port}', '-h', temp],
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for _ in range(100):
            if server.poll() is not None:
                raise RuntimeError(server.stderr.read().decode())
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.2):
                    break
            except OSError:
                time.sleep(.1)
        else:
            raise RuntimeError('uhttpd startup timeout')

        def request(headers, expected):
            with socket.create_connection(('127.0.0.1', port), timeout=3) as s:
                s.sendall(b'GET / HTTP/1.0\r\n' + headers + b'\r\n')
                response = b''
                while b'\r\n' not in response:
                    block = s.recv(4096)
                    if not block:
                        break
                    response += block
                assert response.split(b' ', 2)[1] == str(expected).encode(), response[:100]

        request(b'Host: localhost\r\n', 200)
        request(b'X: a\r\n' * 100, 200)
        request(b'X: a\r\n' * 101, 431)
        # Four individually short lines totalling exactly 16 KiB, then one byte over.
        line = b'X: ' + b'a' * 4091 + b'\r\n'
        request(line * 4, 200)
        request(line * 4 + b'Y: b\r\n', 431)
        # Rejections must not poison later clients.
        request(b'Host: localhost\r\n', 200)
        print('PASS: normal requests, 100/101 headers, 16 KiB boundary, recovery')
    finally:
        server.terminate()
        try:
            server.wait(timeout=3)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
