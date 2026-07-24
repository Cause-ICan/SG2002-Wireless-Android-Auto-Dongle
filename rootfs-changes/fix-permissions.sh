#!/bin/sh
# Buildroot post-build script - forces correct executable permissions on
# init scripts every build, regardless of where the source files came from.
TARGET_DIR=$1
chmod +x "$TARGET_DIR"/etc/init.d/rcS
chmod +x "$TARGET_DIR"/etc/init.d/rcK
chmod +x "$TARGET_DIR"/etc/init.d/S*
exit 0
