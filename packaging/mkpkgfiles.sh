#!/bin/sh
# Stage repo files next to the PKGBUILD so makepkg's local sources resolve.
set -e
cd "$(dirname "$0")"
cp ../psychod/psychod.py .
cp ../dist/psycho.conf ../dist/psycho.config ../dist/picom.conf ../dist/i3status.conf .
cp ../man/psychod.1 ../userguide.txt .
cp ../patches/00*.patch .
echo "staged; now: makepkg -si"
