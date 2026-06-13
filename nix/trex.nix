{ lib
, stdenv
, python312
, zlib
, glibc
, patchelf
, makeWrapper
, coreutils
, gnugrep
, gawk
, gnused
, procps
, util-linux
, pciutils
, kmod
, iproute2
  # Build NVIDIA/Mellanox (mlx5) and Broadcom (bnxt) PMDs. Off by default: they
  # add a large, slower build and the internal ibverbs path is not validated
  # against modern toolchains here. Intel / virtio / af_packet NICs work either way.
, withMlx ? false
, withBnxt ? false
}:

let
  # Libraries the linked binaries and the bundled .so need at runtime.
  # The main binaries additionally locate the bundled libzmq/libbpf through
  # an $ORIGIN-relative rpath (see installPhase).
  rpathLibs = lib.makeLibraryPath [
    zlib
    (lib.getLib stdenv.cc.cc) # libstdc++ / libgcc_s
    glibc
  ];

  # Tools the t-rex wrapper scripts and dpdk_setup_ports.py shell out to.
  runtimePath = lib.makeBinPath [
    python312 coreutils gnugrep gawk gnused procps util-linux pciutils kmod iproute2
  ];

  configureFlags =
    lib.optionalString (!withMlx) " --no-mlx=all"
    + lib.optionalString (!withBnxt) " --no-bnxt";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "trex";
  version = "3.08";

  # NOTE: do not use lib.cleanSource here — it strips *.so/*.a, but TRex ships a
  # prebuilt external_libs/zmq/x86_64/libzmq.so that the build links against.
  # The flake's git filtering already excludes .git and build artifacts.
  src = ../.;

  # ws_main.py hardcodes assumptions of the (old) toolchain TRex was released
  # with: -Werror, -march=native, and legacy C constructs that modern GCC / the
  # NixOS cc-wrapper reject. Also trims the build to the two release binaries.
  patches = [ ./nixos-build.patch ];

  nativeBuildInputs = [
    python312
    glibc.bin # provides `ldd`, which `./b configure` insists on
    patchelf
    makeWrapper
  ];

  buildInputs = [ zlib ];

  # The bundled DPDK / BPF code is not warning-clean under modern hardening
  # (e.g. -Wformat-security fires because TRex compiles with -Wno-format).
  hardeningDisable = [ "all" ];

  # waf needs a stable lock name across configure + build.
  WAFLOCK = ".lock-wafbuild_dpdk";

  enableParallelBuilding = true;

  configurePhase = ''
    runHook preConfigure
    pushd linux_dpdk
    python3 waf-2.0.21 configure${configureFlags}
    popd
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    pushd linux_dpdk
    python3 waf-2.0.21 build -j''${NIX_BUILD_CORES:-1}
    popd
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    built=$PWD/linux_dpdk/build_dpdk/linux_dpdk

    # The whole scripts/ dir is TRex's runtime root (binaries, .so, python
    # client, traffic profiles, port-setup tooling). Copy it preserving symlinks;
    # the build-tree symlinks are replaced with the real artifacts below.
    mkdir -p $out/opt
    cp -a scripts $out/opt/trex
    cd $out/opt/trex

    # Real release binaries (scripts/_t-rex-64* are symlinks into the build tree).
    rm -f _t-rex-64 _t-rex-64-o
    install -m755 "$built/_t-rex-64"   _t-rex-64
    install -m755 "$built/_t-rex-64-o" _t-rex-64-o

    # Real BPF shared libraries.
    rm -f so/x86_64/libbpf-64.so so/x86_64/libbpf-64-o.so
    install -m755 "$built/libbpf-64.so"   so/x86_64/libbpf-64.so
    install -m755 "$built/libbpf-64-o.so" so/x86_64/libbpf-64-o.so

    # Drop the stale bundled libstdc++ (only GLIBCXX_3.4.24); our binaries are
    # built with this gcc and resolve libstdc++ from the store via rpath.
    rm -f so/x86_64/libstdc++.so.6 so/libstdc++.so.6

    # bird/* are dangling symlinks (the Bird server is not built).
    rm -rf bird

    # Shrink the 130 MB+ debug binaries down to ~15 MB.
    strip _t-rex-64 _t-rex-64-o
    strip --strip-unneeded so/x86_64/libbpf-64.so so/x86_64/libbpf-64-o.so

    # The relative rpath "so:so/x86_64" only works from the runtime cwd. Pin it
    # to the binary's own location so the binaries also run standalone.
    for b in _t-rex-64 _t-rex-64-o; do
      patchelf --set-rpath '$ORIGIN/so/x86_64:${rpathLibs}' "$b"
    done
    for l in so/x86_64/libzmq.so.5 so/x86_64/libbpf-64.so so/x86_64/libbpf-64-o.so \
             external_libs/pyzmq-ctypes/zmq/intel/64bit/libzmq.so; do
      patchelf --set-rpath '${rpathLibs}' "$l"
    done

    # Rewrite "#!/bin/bash" (absent on NixOS) and "#!/usr/bin/env python".
    patchShebangs --host $out/opt/trex

    # Entry points.
    mkdir -p $out/bin

    # Full launchers: cd into the runtime root and run the port-setup tooling.
    # These configure DPDK and must be run as root.
    for n in t-rex-64 t-rex-64-o trex-cfg trex-console; do
      makeWrapper "$out/opt/trex/$n" "$out/bin/$n" \
        --chdir "$out/opt/trex" \
        --prefix PATH : "${runtimePath}"
    done

    # Raw binaries (no port setup); handy for `--help` and custom invocations.
    for n in _t-rex-64 _t-rex-64-o; do
      makeWrapper "$out/opt/trex/$n" "$out/bin/$n" \
        --chdir "$out/opt/trex"
    done

    runHook postInstall
  '';

  # Binaries are stripped + patchelf'd in installPhase already.
  dontStrip = true;

  meta = {
    description = "Cisco TRex realistic traffic generator (built from source against bundled DPDK 25.07)";
    homepage = "https://trex-tgn.cisco.com/";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
    mainProgram = "t-rex-64";
    # TRex is a DPDK application: running it needs root, hugepages and (for
    # most NICs) DPDK-bound interfaces. The package builds and `--help` works
    # unprivileged; driving traffic is an operational, root-level concern.
  };
})
