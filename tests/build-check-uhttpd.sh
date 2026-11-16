#!/bin/bash
# Host-side regression test; never contacts a router.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
checkout() {
    git init -q "$2"
    git -C "$2" fetch -q --depth=1 "$1" "$3"
    git -C "$2" checkout -q --detach FETCH_HEAD
}
checkout https://github.com/openwrt/libubox.git "$work/libubox" 49056d178f42da98048a5d4c23f83a6f6bc6dd80
cmake -S "$work/libubox" -B "$work/ubox-build" -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF -DCMAKE_INSTALL_PREFIX="$work/prefix"
cmake --build "$work/ubox-build" -j2
cmake --install "$work/ubox-build"
checkout https://github.com/openwrt/uhttpd.git "$work/uhttpd" 7e64e8bad2415cec0a6d9770ec379db54273c7a7
git -C "$work/uhttpd" apply --check "$root/patches/uhttpd/100-limit-request-headers.patch"
git -C "$work/uhttpd" apply "$root/patches/uhttpd/100-limit-request-headers.patch"
cmake -S "$work/uhttpd" -B "$work/http-build" -DCMAKE_PREFIX_PATH="$work/prefix" -DTLS_SUPPORT=OFF -DLUA_SUPPORT=OFF -DUBUS_SUPPORT=OFF -DUCODE_SUPPORT=OFF
cmake --build "$work/http-build" -j2
LD_LIBRARY_PATH="$work/prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" python3 "$root/tests/check-uhttpd-http.py" "$work/http-build/uhttpd"
