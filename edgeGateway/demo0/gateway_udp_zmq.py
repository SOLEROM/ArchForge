#!/usr/bin/env python3
import json
import socket
import time
import zmq

TOPIC_CMD = b"track.cmd"
TOPIC_RES = b"track.res"

CMD_PORT = 5557   # ZMQ internal: commands
RES_PORT = 5558   # ZMQ internal: results

UDP_LISTEN_PORT = 9000          # ground -> gateway commands
UDP_GROUND_IP = "127.0.0.1"     # where to send results
UDP_GROUND_PORT = 9001          # gateway -> ground results


def main():
    ctx = zmq.Context.instance()

    # ZMQ: publish commands into the internal bus
    zmq_pub_cmd = ctx.socket(zmq.PUB)
    zmq_pub_cmd.bind(f"tcp://127.0.0.1:{CMD_PORT}")

    # ZMQ: subscribe to results from the internal bus
    zmq_sub_res = ctx.socket(zmq.SUB)
    zmq_sub_res.connect(f"tcp://127.0.0.1:{RES_PORT}")
    zmq_sub_res.setsockopt(zmq.SUBSCRIBE, TOPIC_RES)

    poller = zmq.Poller()
    poller.register(zmq_sub_res, zmq.POLLIN)

    # UDP: listen for external commands
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(("", UDP_LISTEN_PORT))
    udp.setblocking(False)

    print(f"[gateway] up (UDP listen :{UDP_LISTEN_PORT} -> ground {UDP_GROUND_IP}:{UDP_GROUND_PORT})")

    while True:
        # 1) UDP -> ZMQ (commands)
        try:
            data, addr = udp.recvfrom(4096)
            cmd = json.loads(data.decode("utf-8"))

            # Minimal validation
            if cmd.get("cmd") in ("start", "stop"):
                cmd["ts_gateway"] = time.time()
                zmq_pub_cmd.send_multipart([TOPIC_CMD, json.dumps(cmd).encode("utf-8")])
                print(f"[gateway] UDP->ZMQ {cmd} from {addr}")
        except BlockingIOError:
            pass
        except Exception as e:
            print(f"[gateway] bad UDP packet: {e!r}")

        # 2) ZMQ -> UDP (results)
        events = dict(poller.poll(5))
        if zmq_sub_res in events:
            topic, payload = zmq_sub_res.recv_multipart()
            # forward as-is to ground
            udp.sendto(payload, (UDP_GROUND_IP, UDP_GROUND_PORT))

        time.sleep(0.001)


if __name__ == "__main__":
    main()

