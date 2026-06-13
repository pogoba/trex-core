#!/usr/bin/env python3
# Drives an ASTF (real TCP) test across the two instances started by run_tcp.sh
# and prints the resulting performance numbers. Needs Python <= 3.12 (bundled
# scapy uses the removed `cgi` module); run_tcp.sh resolves that for you.
import sys, os, time
sys.path.insert(0, os.environ['TREX_CLIENT_PATH'])
from trex.astf.api import *

PROFILE  = os.environ.get('PROFILE', 'astf/http_simple.py')
MULT     = int(os.environ.get('MULT', '100'))      # cps multiplier (profile cps * MULT)
DURATION = int(os.environ.get('DURATION', '10'))

srv = ASTFClient(server='127.0.0.1', sync_port=4501, async_port=4500)  # server instance
cli = ASTFClient(server='127.0.0.1', sync_port=4521, async_port=4520)  # client / load-gen
try:
    srv.connect(); cli.connect()
    srv.reset(); cli.reset()
    srv.load_profile(PROFILE); cli.load_profile(PROFILE)
    srv.clear_stats(); cli.clear_stats()

    print(">>> %s  mult=%d  duration=%ds" % (PROFILE, MULT, DURATION))
    srv.start(mult=1, duration=-1, block=False)        # server-only: just listen & answer
    cli.start(mult=MULT, duration=DURATION)            # client: open TCP connections
    cli.wait_on_traffic(timeout=DURATION + 30)
    time.sleep(1)

    c = cli.get_stats()['traffic']['client']
    s = srv.get_stats()['traffic']['server']
    conn   = c.get('tcps_connects', 0)
    accept = s.get('tcps_accepts', 0)
    l7byte = c.get('tcps_sndbyte', 0) + c.get('tcps_rcvbyte', 0)
    rexmit = c.get('tcps_rexmttot', 0) + s.get('tcps_rexmttot', 0)

    print("\n=== TCP (ASTF) performance over vhost-user ===")
    print("  connections opened     : %d" % conn)
    print("  server accepts         : %d" % accept)
    print("  connections / sec      : %.0f" % (conn / DURATION if DURATION else 0))
    print("  L7 throughput          : %.3f Gbit/s" % (l7byte * 8 / DURATION / 1e9 if DURATION else 0))
    print("  TCP retransmits        : %d" % rexmit)
    ok = conn > 0 and conn == accept
    print("  RESULT                 : %s" % ("PASS" if ok else "CHECK (conn=%d accept=%d)" % (conn, accept)))
    sys.exit(0 if ok else 2)
finally:
    try: srv.stop(); cli.stop()
    except Exception: pass
    try: srv.disconnect(); cli.disconnect()
    except Exception: pass
