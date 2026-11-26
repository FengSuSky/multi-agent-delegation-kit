#!/usr/bin/env bash
# Test double for DELEGATE_PROXY_ENSURE_CMD: opens a TCP listener on argv[1] and records its pid in argv[2].
import os
import socket
import sys
import time

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", int(sys.argv[1])))
listener.listen(1)
with open(sys.argv[2], "w") as pid_file:
    pid_file.write(str(os.getpid()))
time.sleep(60)
