import sys, os, time
sys.path.insert(0, os.environ['TREX_CLIENT_PATH'])
from trex.stl.api import *

def main():
    # Sender = virtio_user instance (RPC 4521 / pub 4520)
    # Receiver = vhost instance     (RPC 4501 / pub 4500)
    snd = STLClient(server='127.0.0.1', sync_port=4521, async_port=4520)
    rcv = STLClient(server='127.0.0.1', sync_port=4501, async_port=4500)
    snd.connect(); rcv.connect()
    snd.reset(ports=[0]); rcv.reset(ports=[0])
    snd.set_port_attr(ports=[0], promiscuous=True)
    rcv.set_port_attr(ports=[0], promiscuous=True)

    pkt = Ether(dst="ff:ff:ff:ff:ff:ff")/IP(src="1.1.1.2", dst="1.1.1.1")/UDP(sport=1025, dport=12)/('X'*64)
    stream = STLStream(packet=STLPktBuilder(pkt=pkt), mode=STLTXCont(pps=2000))
    snd.add_streams(stream, ports=[0])

    snd.clear_stats(); rcv.clear_stats()
    print(">>> starting 3s of traffic from sender (virtio_user) -> receiver (vhost)")
    snd.start(ports=[0], duration=3)
    snd.wait_on_traffic(timeout=15)
    time.sleep(1)

    s = snd.get_stats(); r = rcv.get_stats()
    tx = s[0]['opackets']; rx = r[0]['ipackets']
    print("SENDER   tx packets (port0):", tx)
    print("RECEIVER rx packets (port0):", rx)
    snd.disconnect(); rcv.disconnect()
    print("RESULT:", "PASS - traffic flowed over vhost-user" if rx > 0 else "FAIL - no packets received")
    sys.exit(0 if rx > 0 else 2)

main()
