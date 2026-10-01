#!/usr/bin/env python3
"""**METAL AGAINST PROD, THE SAME PAGES THROUGH THE SAME CADDY.** lynrummy.com
is angry-gopher on Linux on the prod droplet; metal.lynrummy.com is the same
code on the gopher-metal droplet, reached through prod's Caddy over the
private network. Each page is fetched from both, alternating, ROUNDS times, and
the median and 90th percentile reported.

Two vantage points:

  from here  https from this box, as a browser would; the name is pinned to
             prod's address, because this box's DNS sometimes stalls for
             seconds and that is nobody's server.
  from prod  plain http on the prod droplet itself, no Caddy, no internet:
             localhost:9001 (Linux) against 10.100.0.4:80 (metal). This is the
             servers alone, plus one private-network hop for metal.

The time is to the first byte of the answer (curl's time_starttransfer), less
the connection and TLS setup, which neither server does.

  droplet/race.py            (ROUNDS=40 by default)
"""
import os, statistics, subprocess, sys

PROD = "162.243.1.123"
METAL_PRIVATE = "10.100.0.4"
ROUNDS = int(os.environ.get("ROUNDS", "40"))
PATHS = ["/", "/gallery/safari.png", "/delivery", "/game"]
FORMAT = "%{http_code} %{size_download} %{time_appconnect} %{time_connect} %{time_starttransfer}\\n"


def curl_args(url, resolve=None):
    args = ["curl", "-s", "-o", "/dev/null", "--max-time", "10", "-w", FORMAT]
    if resolve:
        args += ["--resolve", resolve]
    return args + [url]


def parse(line):
    code, size, tls, connect, first = line.split()
    setup = float(tls) if float(tls) > 0 else float(connect)
    return code, int(size), (float(first) - setup) * 1000


def from_here():
    out = {}
    for _ in range(ROUNDS):
        for path in PATHS:
            for site in ["lynrummy.com", "metal.lynrummy.com"]:
                line = subprocess.run(curl_args(f"https://{site}{path}", f"{site}:443:{PROD}"),
                                      capture_output=True, text=True).stdout
                out.setdefault((path, site), []).append(parse(line))
    return out


def from_prod():
    # One ssh, one shell loop on prod; each curl prints a line tagged with
    # what it fetched.
    lines = []
    for _ in range(ROUNDS):
        for path in PATHS:
            for site, base in [("linux", "http://localhost:9001"), ("metal", f"http://{METAL_PRIVATE}")]:
                cmd = " ".join(f"'{a}'" for a in curl_args(base + path))
                lines.append(f"printf '{path} {site} '; {cmd}")
    script = "\n".join(lines)
    got = subprocess.run(["ssh", PROD, "bash -s"], input=script, capture_output=True, text=True).stdout
    out = {}
    for line in got.splitlines():
        path, site, rest = line.split(" ", 2)
        out.setdefault((path, site), []).append(parse(rest))
    return out


def report(title, results, sites):
    print(f"\n{title}  ({ROUNDS} fetches each; ms to first byte: median / 90th)")
    print(f"  {'page':<22}{sites[0]:>22}{sites[1]:>22}")
    for path in PATHS:
        cells = []
        for site in sites:
            runs = results[(path, site)]
            codes = {f"{c} {s}B" for c, s, _ in runs}
            ms = sorted(t for _, _, t in runs)
            cells.append(f"{statistics.median(ms):6.2f} / {ms[int(len(ms) * 0.9)]:6.2f}")
            if len(codes) != 1:
                print(f"  NOTE {path} on {site} answered differently: {codes}")
        print(f"  {path:<22}{cells[0]:>22}{cells[1]:>22}")


report("FROM HERE, https through prod's Caddy", from_here(), ["lynrummy.com", "metal.lynrummy.com"])
report("FROM PROD, the servers alone", from_prod(), ["linux", "metal"])
