# Nix flake for TRex (build from source)

This packages [Cisco TRex](https://trex-tgn.cisco.com/) **v3.08** by compiling it
from source (including the bundled DPDK 25.07 and BPF/JIT) with the toolchain
from `nixpkgs`. No upstream binaries are used.

## Usage

```sh
nix build .#trex          # build, result in ./result
./result/bin/_t-rex-64 --help

nix run .#                # t-rex-64  (configures DPDK ports; needs root)
nix run .#console         # trex-console (interactive client, no root)
```

`nix develop` drops you into a shell with the build toolchain; see the shell
hook for the in-tree `./b configure && ./b build` recipe.

## What you get

`result/bin/`:

| command         | what it is                                                        |
|-----------------|-------------------------------------------------------------------|
| `t-rex-64`      | full launcher (AVX build, falls back to portable) — **run as root**|
| `t-rex-64-o`    | full launcher, portable (SSE4.2) build                            |
| `_t-rex-64`     | raw engine binary (AVX, `-march=sandybridge`)                     |
| `_t-rex-64-o`   | raw engine binary (portable, `-march=corei7`)                    |
| `trex-cfg`      | DPDK port setup helper                                            |
| `trex-console`  | interactive Python client                                        |

The complete runtime tree (engine, shared libs, Python client, traffic
profiles, port-setup tooling) lives under `result/opt/trex`.

## Running it

TRex is a DPDK application. Building and `--help` work unprivileged, but driving
traffic needs, at runtime:

* **root** (`sudo result/bin/t-rex-64 ...`),
* **hugepages** configured, and
* interfaces **bound to a DPDK-capable driver** (`vfio-pci`/`igb_uio`), or a
  config in `/etc/trex_cfg.yaml`.

These are host/operational concerns the package cannot provide. On NixOS, enable
hugepages and load `vfio-pci` via your system configuration.

## Build options

`callPackage ./nix/trex.nix { withMlx = true; withBnxt = true; }`

* `withMlx` (default `false`) — NVIDIA/Mellanox **mlx5** PMD (internal ibverbs).
* `withBnxt` (default `false`) — Broadcom **bnxt** PMD.

Both are off by default: they add a large, slower build and are **not validated**
against this modern toolchain. Intel, virtio and af_packet NICs work regardless.

## How the source is adapted (`nixos-build.patch`)

TRex's `waf` build assumes the (older) toolchain its release binaries were built
with. The patch makes it build with current GCC / the NixOS cc-wrapper:

* drop `-Werror` (newer `-Wall` warnings would otherwise be fatal);
* add `-Wno-error=implicit-function-declaration` / `-implicit-int` /
  `-int-conversion` / `-incompatible-pointer-types` — GCC 14+ and the
  cc-wrapper make these legacy-C constructs hard errors, but the bundled DPDK
  (notably a `#ifndef TREX_PATCH` that hides `rte_eth_get_restore_flags`) relies
  on them being warnings;
* replace `-march=native` (stripped by Nix, which then left the build without
  SSE4.2 and broke `_mm_crc32_u64`) with a concrete `-march=sandybridge`;
* trim the build matrix to the two **release** binaries (drop debug builds).

It also adds **vhost-user vdev** support that stock TRex doesn't build:

* compiles DPDK's `net_vhost` PMD + `lib/vhost` (and `lib/dmadev`) — only
  `net_virtio_user` shipped before — with VDUSE stubbed and vhost NUMA/postcopy
  disabled to avoid kernel-header / libnuma build deps;
* registers `net_vhost` and `net_virtio_user` as supported TRex drivers via a new
  `CTRexExtendedDriverVhost` handler (virtio queue config, but `has_pci=false`).

This lets two TRex instances (or TRex and testpmd/pktgen/a custom app) talk over
a vhost-user unix socket with no NIC and no hugepages — see
[`examples/vhost-user/`](examples/vhost-user/), a ready-to-run two-instance
send/receive test (`sudo`-free wrapper; needs passwordless sudo for the two DPDK
processes).

The derivation additionally:

* uses **Python 3.12** — waf 2.0.21 imports `pipes`, removed in Python 3.13;
* sets `hardeningDisable = [ "all" ]` — TRex compiles with `-Wno-format`, which
  clashes with the cc-wrapper's `-Wformat-security`;
* drops the stale bundled `libstdc++.so.6` (only `GLIBCXX_3.4.24`) so the
  binaries use this gcc's libstdc++ via rpath;
* sets an `$ORIGIN`-relative rpath so the engine finds its bundled
  `libbpf`/`libzmq` regardless of the working directory.
