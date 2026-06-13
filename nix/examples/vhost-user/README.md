# Two TRex instances over a vhost-user vdev

Connects two TRex instances through a DPDK **vhost-user** unix socket (no NIC,
no hugepages needed) so one instance transmits and the other receives — useful
for software-loopback microbenchmarks alongside tools like `testpmd`, `pktgen`
or a custom `mirror` app that speak the same vhost-user socket.

```
  SEND instance                            RECV instance
  net_virtio_user0  ── /tmp/trex-vhost.sock ──  net_vhost0
  (vhost-user server)                       (vhost-user client)
  RPC 4521 / pub 4520                       RPC 4501 / pub 4500
```

## Run interactively


  Terminal 1 — SEND instance (start this one first; it owns the socket)

  sudo ./result/bin/_t-rex-64 --cfg $PWD/nix/examples/vhost-user/cfg_send.yaml \
       -i --software -c 1 --prefix send

  Terminal 2 — RECV instance

  sudo ./result/bin/_t-rex-64 --cfg $PWD/nix/examples/vhost-user/cfg_recv.yaml \
       -i --software -c 1 --prefix recv

  Both should print link : Link Up …. Leave them running (Ctrl-C to stop).

  Terminal 3 — console on the SENDER, generate traffic

  ./result/bin/trex-console -p 4521 --async_port 4520
  Then at the trex> prompt:
  trex> start -f stl/udp_1pkt_simple.py -m 10kpps -p 0 -d 30
  EX=nix/examples/vhost-user             # the two configs live here

  The model: each instance runs as a foreground stateless server (-i) in its own terminal; you then attach a trex-console (a separate client process) to each to actually push/inspect traffic. Servers need sudo (DPDK);
  consoles run as your user.

  Terminal 1 — SEND instance (start this one first; it owns the socket)

  sudo ./result/bin/_t-rex-64 --cfg $PWD/nix/examples/vhost-user/cfg_send.yaml \
       -i --software -c 1 --prefix send

  Terminal 2 — RECV instance

  sudo ./result/bin/_t-rex-64 --cfg $PWD/nix/examples/vhost-user/cfg_recv.yaml \
       -i --software -c 1 --prefix recv


tui
start -f stl/udp_for_benchmarks.py -m 100% -p 0 -d 30 -t packet_len=1400
stats -p 0

## Run interactively (TCP)

  SEND (start first)
  sudo ./result/bin/_t-rex-64 --cfg $PWD/nix/examples/vhost-user/cfg_send.yaml \
       --astf -i --lro-disable --tso-disable --software -c 1 --prefix send

  RECV
  sudo ./result/bin/_t-rex-64 --cfg $PWD/nix/examples/vhost-user/cfg_recv.yaml \
       --astf --astf-server-only -i --lro-disable --tso-disable --software -c 1 --prefix recv



## Run

```sh
nix build .#trex          # from the repo root, produces ./result
sudo nix/examples/vhost-user/run_traffic.sh
```

Expected tail:

```
  link : Link Up - speed 200000 Mbps - full-duplex
  link : Link Up - speed 10000 Mbps - full-duplex
>>> starting 3s of traffic from sender (virtio_user) -> receiver (vhost)
SENDER   tx packets (port0): 6001
RECEIVER rx packets (port0): 6001
RESULT: PASS - traffic flowed over vhost-user
```

## How it works

- **`cfg_send.yaml`** — `--vdev=net_virtio_user0,path=...,server=1`. The virtio_user
  frontend, configured as the socket **server** (creates and listens).
- **`cfg_recv.yaml`** — `--vdev=net_vhost0,iface=...,client=1`. The vhost backend,
  configured as the **client** so it auto-reconnects until the peer is up (this
  ordering avoids the "connection refused" race).
- Each config gives the vdev plus a `dummy` second port (TRex wants port pairs),
  a distinct `--prefix` (separate DPDK runtime dir) and distinct
  `zmq_rpc_port`/`zmq_pub_port` so the two instances coexist.
- `ext_dpdk_opt` injects raw EAL args: `--iova-mode=va` (required — TRex forces
  `--no-huge` for pure vdev setups, and physical addresses aren't available then)
  and `--single-file-segments` on the memory-owning (virtio_user) side.
- `-i --software -c 1` runs interactive stateless mode with a single TX/RX queue.
- `traffic_test.py` uses the bundled STL client to add a stream on the sender,
  run 3 s of traffic, and compare `opackets` vs the receiver's `ipackets`.

## Notes / requirements

These vdevs only exist because the Nix build adds `net_vhost` + `lib/vhost` to
TRex's DPDK and registers `net_vhost` / `net_virtio_user` as supported drivers
(see `../nixos-build.patch`); stock TRex builds neither.

- Run as **root**. No hugepages or NIC binding required (pure software vdevs).
- To flip the traffic direction, move the `STLStream` to the other client in
  `traffic_test.py` — both ends can TX and RX.
- To pair TRex with a non-TRex app, point that app's `net_virtio_user`/`net_vhost`
  vdev at the same socket path with the opposite client/server role.
