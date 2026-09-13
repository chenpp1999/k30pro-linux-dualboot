#!/bin/sh
# One-shot M0 build: fetch inputs -> initramfs -> boot.img
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
WORKDIR="${WORKDIR:-$HERE/out}"
export WORKDIR
mkdir -p "$WORKDIR"

sh "$HERE/fetch-artifacts.sh"
sh "$HERE/build-initramfs.sh"
sh "$HERE/build-bootimg.sh"
