#!/system/bin/sh
# Late-start service for the standalone GPU governor. gpufix.sh holds the logic.
MODDIR=${0%/*}
[ -f "$MODDIR/gpufix.sh" ] || exit 0
( sh "$MODDIR/gpufix.sh" boot >/dev/null 2>&1 & )
