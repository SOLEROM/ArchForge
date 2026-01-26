#!/usr/bin/env python3
import json
import time
import zmq


TOPIC_CMD = b"track.cmd"
TOPIC_RES = b"track.res"

CMD_PORT = 5557   # internal bus: commands
RES_PORT = 5558   # internal bus: results


def main():
    ctx = zmq.Context.instance()

    # Subscribe to commands
    sub = ctx.socket(zmq.SUB)
    sub.connect(f"tcp://127.0.0.1:{CMD_PORT}")
    sub.setsockopt(zmq.SUBSCRIBE, TOPIC_CMD)

    # Publish results
    pub = ctx.socket(zmq.PUB)
    pub.bind(f"tcp://127.0.0.1:{RES_PORT}")

    poller = zmq.Poller()
    poller.register(sub, zmq.POLLIN)

    tracking = False
    new_flag = False
    base_x = base_y = 0
    step = 0

    print("[tracker] up")

    while True:
        events = dict(poller.poll(20))

        # Handle commands
        if sub in events:
            topic, payload = sub.recv_multipart()
            cmd = json.loads(payload.decode("utf-8"))

            if cmd.get("cmd") == "start":
                base_x = int(cmd["x"])
                base_y = int(cmd["y"])
                step = 0
                tracking = True
                new_flag = True
                print(f"[tracker] START at ({base_x},{base_y})")
            elif cmd.get("cmd") == "stop":
                tracking = False
                print("[tracker] STOP")

                # Publish a final "empty" result
                res = {
                    "type": "track_res",
                    "ts": time.time(),
                    "bbox": None,
                    "success": False,
                    "new": False,
                }
                pub.send_multipart([TOPIC_RES, json.dumps(res).encode("utf-8")])

        # Produce results (fake tracking)
        if tracking:
            # Fake bbox motion: small drift to show updates
            step += 1
            x = base_x + (step % 30) - 15
            y = base_y + ((step * 2) % 30) - 15
            w, h = 60, 60

            res = {
                "type": "track_res",
                "ts": time.time(),
                "bbox": [int(x), int(y), int(w), int(h)],
                "success": True,
                "new": bool(new_flag),
            }
            new_flag = False

            pub.send_multipart([TOPIC_RES, json.dumps(res).encode("utf-8")])

            time.sleep(0.05)  # ~20 Hz output


if __name__ == "__main__":
    main()

