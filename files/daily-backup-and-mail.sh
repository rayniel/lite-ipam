#!/bin/sh

/usr/libexec/lite-ipam/lite-ipam.sh backup-now || exit 1
exec /usr/libexec/lite-ipam/lite-ipam.sh cleanup-runtime