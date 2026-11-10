#!/system/bin/sh
# Magisk "Action" button for GPU-DVFS-X6886 (shown in the Magisk app on modules
# that ship action.sh): toggle SAFER <-> MAX, applied immediately - no reboot.
# 'preset' writes gpu.conf and publishes the nodes at once; if the governor
# loop is not running yet (fresh flash), it is started exactly like service.sh
# does at boot. The choice persists in gpu.conf, so it survives reboots too.
MODDIR=${0%/*}
[ -f "$MODDIR/gpufix.sh" ] || MODDIR=/data/adb/modules/gpu_dvfs_x6886
STATE=/data/adb/gpufix
CFG=$STATE/gpu.conf

CUR=$(sed -n 's/^MODE=//p' "$CFG" 2>/dev/null | head -n 1)
case "$CUR" in
  floor) NEXT=safer; FROM=MAX;   TO=SAFER ;;
  safer) NEXT=max;   FROM=SAFER; TO=MAX ;;
  *)     NEXT=safer; FROM=${CUR:-none}; TO=SAFER ;;
esac

echo "gpufix action: $FROM -> $TO - applying now (no reboot)"
GPUFIX_STATE="$STATE" sh "$MODDIR/gpufix.sh" preset "$NEXT" || {
  echo "gpufix action: preset failed - see $STATE/gpu.log"
  exit 1
}

# Is the governor loop already running? Same single-instance check as boot().
PIDF=$STATE/.gpufix.pid
RUNNING=0
if [ -r "$PIDF" ]; then
  P=$(cat "$PIDF" 2>/dev/null)
  case "$P" in
    ''|*[!0-9]*) ;;
    *) [ "$P" -gt 1 ] && grep -q gpufix "/proc/$P/cmdline" 2>/dev/null && RUNNING=1 ;;
  esac
fi
if [ "$RUNNING" = 1 ]; then
  echo "gpufix action: governor is running - the new mode is live within a second."
else
  ( sh "$MODDIR/gpufix.sh" boot >/dev/null 2>&1 & )
  echo "gpufix action: governor was not running, started it in the background."
fi

echo "gpufix action: now $TO. Both profiles still pin 390 MHz while the screen is off."
echo "gpufix action: tap Action again to switch back."
GPUFIX_STATE="$STATE" sh "$MODDIR/gpufix.sh" status 2>/dev/null | grep -E '^(state|live):' | head -n 3
