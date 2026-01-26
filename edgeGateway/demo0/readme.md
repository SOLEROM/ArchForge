# demo0

* External: UDP JSON commands/results
* Internal: ZMQ PUB/SUB topics
* Tracker: fake tracker that generates a moving bbox around a start point

## runnig

```
python3 tracker_worker.py
python3 gateway_udp_zmq.py
python3 ground_client.py
```

demo run:

```
../../runners/termTabs2.sh -f run.conf
```
