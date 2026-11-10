#!/system/bin/sh
# Magisk "Action" button for GPU-DVFS-X6886 (shown in the Magisk app on modules
# that ship action.sh). What a tap does:
#   1. shows the ACTIVE mode,
#   2. waits CHOOSE_TIMEOUT s (default 20) for a volume key - UP = SAFER,
#      DOWN = MAX, no press = keep the active mode,
#   3. applies a changed choice at once (no reboot) and verifies it.
# The choice is written to gpu.conf by 'preset', so it survives reboots too,
# and if the governor loop is not running yet (fresh flash) it is started
# exactly like service.sh does at boot.
if [ -n "${MODDIR:-}" ] && [ -f "$MODDIR/gpufix.sh" ]; then
  :
elif [ -f "${0%/*}/gpufix.sh" ]; then
  MODDIR=${0%/*}
else
  MODDIR=/data/adb/modules/gpu_dvfs_x6886
fi
STATE=/data/adb/gpufix
CFG=$STATE/gpu.conf
CHOICE_FILE=$STATE/.action.choice

preset_of() {   # MODE -> preset name
  case "$1" in floor) printf 'max' ;; *) printf 'safer' ;; esac
}
label_of() {   # preset name -> human label
  case "$1" in
    max) printf 'MAX (1600 MHz awake, 390 screen-off)' ;;
    *)   printf 'SAFER (790 rest, 1600 on work, 390 screen-off)' ;;
  esac
}
ensure_loop() {   # start the governor if it is not running (boot()'s own check)
  _pidf=$STATE/.gpufix.pid; _running=0
  if [ -r "$_pidf" ]; then
    _p=$(cat "$_pidf" 2>/dev/null)
    case "$_p" in
      ''|*[!0-9]*) ;;
      *) [ "$_p" -gt 1 ] && grep -q gpufix "/proc/$_p/cmdline" 2>/dev/null && _running=1 ;;
    esac
  fi
  if [ "$_running" = 1 ]; then
    echo "gpufix action: governor is running - the choice is live within a second."
  else
    ( sh "$MODDIR/gpufix.sh" boot >/dev/null 2>&1 & )
    echo "gpufix action: governor was not running, started it in the background."
  fi
}

CUR_MODE=$(sed -n 's/^MODE=//p' "$CFG" 2>/dev/null | head -n 1 | tr -d ' \r')
case "$CUR_MODE" in
  floor) CUR=max;   ACTIVE=$(label_of max) ;;
  safer) CUR=safer; ACTIVE=$(label_of safer) ;;
  *)     CUR=other; ACTIVE="MODE=${CUR_MODE:-?} (not SAFER/MAX)" ;;
esac
echo "gpufix action: ACTIVE mode is $ACTIVE"
echo "gpufix action: press VOLUME UP = SAFER or VOLUME DOWN = MAX within ${CHOOSE_TIMEOUT:-20}s"
if [ "$CUR" = other ]; then
  echo "gpufix action: to select - no press defaults to SAFER."
  FALLBACK=safer
else
  echo "gpufix action: to change it - no press keeps $ACTIVE."
  FALLBACK=$CUR
fi

rm -f "$CHOICE_FILE"
GPUFIX_STATE="$STATE" GPUFIX_CHOICE="$CHOICE_FILE" CHOOSE_FALLBACK="$FALLBACK" \
  CHOOSE_TIMEOUT="${CHOOSE_TIMEOUT:-20}" sh "$MODDIR/gpufix.sh" choose
SEL=$(cat "$CHOICE_FILE" 2>/dev/null | head -n 1)
rm -f "$CHOICE_FILE"
case "$SEL" in safer|max) ;; *) SEL=$FALLBACK ;; esac

if [ "$SEL" = "$CUR" ]; then
  echo "gpufix action: keeping $ACTIVE - nothing changed."
  ensure_loop
  GPUFIX_STATE="$STATE" sh "$MODDIR/gpufix.sh" status 2>/dev/null | grep -E '^(state|verdict):' | head -n 3
  exit 0
fi

echo "gpufix action: switching to $(label_of "$SEL") - applying now (no reboot)..."
if ! GPUFIX_STATE="$STATE" sh "$MODDIR/gpufix.sh" preset "$SEL"; then
  echo "gpufix action: FAILED - preset did not apply. Run: sh $MODDIR/gpufix.sh status"
  exit 1
fi

NEW_MODE=$(sed -n 's/^MODE=//p' "$CFG" 2>/dev/null | head -n 1 | tr -d ' \r')
if [ "$(preset_of "$NEW_MODE")" = "$SEL" ]; then
  echo "gpufix action: ACTIVE mode is now $(label_of "$SEL")  [MODE=$NEW_MODE]"
else
  echo "gpufix action: FAILED - config still says MODE=${NEW_MODE:-?}; see $STATE/gpu.log"
  exit 1
fi
ensure_loop
echo "gpufix action: done. Both profiles still pin 390 MHz while the screen is off."
GPUFIX_STATE="$STATE" sh "$MODDIR/gpufix.sh" status 2>/dev/null | grep -E '^(state|live|verdict):' | head -n 4
