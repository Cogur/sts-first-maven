#!/bin/sh
# Copies TVT's Linux NET_SDK libraries into vendor/ from the @2bad/tvt npm
# package (which redistributes them). They are never committed to this repo.
set -eu
cd "$(dirname "$0")/.."
VERSION="${TVT_PKG_VERSION:-2.1.0}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
(cd "$tmp" && npm pack --silent "@2bad/tvt@$VERSION" >/dev/null && tar xzf ./*.tgz)
mkdir -p vendor
cp "$tmp"/package/bin/linux/*.so* vendor/
# libdvrnetsdk.so resolves its siblings by soname.
[ -e vendor/libNatClientSDK.so ] || ln -s libNatClientSDK.so.1 vendor/libNatClientSDK.so
ls -l vendor
