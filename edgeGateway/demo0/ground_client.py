#!/usr/bin/env python3
import json
import socket
import time

GATEWAY_IP = "127.0.0.1"
GATEWAY_CMD_PORT = 9000

GROUND_LISTEN_PORT = 9001  # receives results from gateway


def send_cmd(sock, msg):
    sock.sendto(json.dumps(msg).encode("utf-8"), (GATEWAY_IP, GATEWAY_CMD_PORT))


def main():
    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.bind(("", GROUND_LISTEN_PORT))
    rx.settimeout(0.5)

    print("[ground] sending START")
    send_cmd(tx, {"cmd": "start", "x": 320, "y": 180, "frame_id": 1})

    t0 = time.time()
    while time.time() - t0 < 3.0:
        try:
            data, addr = rx.recvfrom(4096)
            res = json.loads(data.decode("utf-8"))
            print("[ground] RES:", res)
        except socket.timeout:
            pass

    print("[ground] sending STOP")
    send_cmd(tx, {"cmd": "stop", "frame_id": 2})

    # read a little more
    t1 = time.time()
    while time.time() - t1 < 1.0:
        try:
            data, addr = rx.recvfrom(4096)
            res = json.loads(data.decode("utf-8"))
            print("[ground] RES:", res)
        except socket.timeout:
            pass


if __name__ == "__main__":
    main()

