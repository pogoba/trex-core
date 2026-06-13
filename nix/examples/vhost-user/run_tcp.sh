#!/usr/bin/env bash
# Run a TCP (ASTF) test between two TRex instances over vhost-user and print the
# resulting performance number.
#
# Run as your normal user (sudo is used only for the two DPDK processes).
#   ./run_tcp.sh [/path/to/trex]
#   MULT=150 DURATION=20 ./run_tcp.sh     # push harder / run longer
#
# MULT is a connections-per-second multiplier (http_simple.py base = 2.776 cps).
# The software net_vhost TX path saturates around ~250 cps (MULT ~250+) and
# currently aborts under that overload, so the default leaves headroom.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TREX=$(readlink -f "${1:-$HERE/../../../result}")
BIN="$TREX/bin/_t-rex-64"
OFF="--lro-disable --tso-disable --queue-drop"  # software vdevs: no TSO/LRO; drop (not spin-retry) on TX-queue-full to avoid the watchdog abort
# bundled scapy needs python <= 3.12:
PY=$(command -v python3.12 || command -v python3.11 || true)
[ -z "$PY" ] && PY="$(nix-build '<nixpkgs>' -A python312 --no-out-link 2>/dev/null)/bin/python3"

cleanup(){ sudo pkill -9 -x _t-rex-64 2>/dev/null; sudo rm -f /tmp/trex-vhost.sock; }
trap cleanup EXIT
cleanup; sleep 1; sudo rm -rf /run/dpdk/asend /run/dpdk/arecv; rm -f /tmp/aclient.log /tmp/aserver.log

echo "### starting ASTF client (load-gen) + server instances"
sudo stdbuf -oL "$BIN" --cfg "$HERE/cfg_astf_client.yaml" --astf -i $OFF --software -c 1 --prefix asend </dev/null >/tmp/aclient.log 2>&1 &
sleep 4
sudo stdbuf -oL "$BIN" --cfg "$HERE/cfg_astf_server.yaml" --astf -i --astf-server-only $OFF --software -c 1 --prefix arecv </dev/null >/tmp/aserver.log 2>&1 &

for i in $(seq 1 25); do sleep 1
  [ "$(sudo ss -ltn 2>/dev/null | grep -cE ':4521')" -ge 1 ] &&
  [ "$(sudo ss -ltn 2>/dev/null | grep -cE ':4501')" -ge 1 ] && { echo "  both console servers up after ${i}s"; break; }
done

cd "$TREX/opt/trex"
TREX_CLIENT_PATH="$PWD/automation/trex_control_plane/interactive" \
  PROFILE="${PROFILE:-astf/http_simple.py}" MULT="${MULT:-100}" DURATION="${DURATION:-10}" \
  "$PY" "$HERE/tcp_test.py"
