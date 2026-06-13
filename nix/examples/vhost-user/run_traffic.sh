#!/usr/bin/env bash
# Wire two TRex instances together over a vhost-user unix socket and push
# traffic from one to the other.
#
# Run as your normal user (NOT `sudo ./run_traffic.sh`): the script uses sudo
# only for the two DPDK processes, so the python STL client keeps using your
# user's python3. Your sudo must be usable non-interactively.
#
#   ./run_traffic.sh [/path/to/trex]     (defaults to ../../../result)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TREX=$(readlink -f "${1:-$HERE/../../../result}")
BIN="$TREX/bin/_t-rex-64"
# TRex's bundled scapy-2.4.3 imports `cgi`, removed in Python 3.13, so the STL
# client needs Python <= 3.12. Prefer one from PATH, else fetch nixpkgs' python312.
PY=$(command -v python3.12 || command -v python3.11 || true)
[ -z "$PY" ] && PY="$(nix-build '<nixpkgs>' -A python312 --no-out-link 2>/dev/null)/bin/python3"

cleanup(){ sudo pkill -9 -f "opt/trex/_t-rex-64" 2>/dev/null; sudo rm -f /tmp/trex-vhost.sock; }
trap cleanup EXIT
cleanup; sleep 1; rm -f /tmp/send.log /tmp/recv.log

echo "### SEND instance (virtio_user, vhost-user server) + RECV instance (net_vhost, client)"
# Server side first so the socket exists; the client (net_vhost) auto-reconnects anyway.
sudo stdbuf -oL "$BIN" --cfg "$HERE/cfg_send.yaml" -i --software -c 1 --prefix send </dev/null >/tmp/send.log 2>&1 &
sleep 5
sudo stdbuf -oL "$BIN" --cfg "$HERE/cfg_recv.yaml" -i --software -c 1 --prefix recv </dev/null >/tmp/recv.log 2>&1 &

echo "### waiting for link up on both ports..."
for i in $(seq 1 25); do
  [ "$(grep -c 'Link Up' /tmp/send.log 2>/dev/null)" -ge 1 ] &&
  [ "$(grep -c 'Link Up' /tmp/recv.log 2>/dev/null)" -ge 1 ] && { echo "  links up after ${i}s"; break; }
  sleep 1
done
grep -h 'Link Up' /tmp/send.log /tmp/recv.log | sed 's/^/  /'

echo "### traffic test (STL python client)"
cd "$TREX/opt/trex"
TREX_CLIENT_PATH="$PWD/automation/trex_control_plane/interactive" "$PY" "$HERE/traffic_test.py"
