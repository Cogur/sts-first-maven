#!/bin/sh
# Builds the shim and checks it against a fake NAT library (no vendor code, no network).
set -eu
cd "$(dirname "$0")"
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
gcc -shared -fPIC -O2 -Wall -Wextra -o "$out/libhg_p2p_serial.so" ../hg_p2p_serial.c -ldl
gcc -shared -fPIC -o "$out/libfakenat.so" fake_nat.c
gcc -o "$out/shim_test" shim_test.c -L"$out" -lfakenat
HG_P2P_SERIAL_MAP="0123456789ABCDEF0123456789ABCDEF=NB8AF056T0D2" HG_P2P_DEBUG=1 \
  LD_PRELOAD="$out/libhg_p2p_serial.so" LD_LIBRARY_PATH="$out" "$out/shim_test"
