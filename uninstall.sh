#!/system/bin/sh
# Undo the GPU governor: stop the loop, then put the stock values back.
STATE=/data/adb/gpufix
if [ -r "$STATE/.gpufix.pid" ]; then
  P=$(cat "$STATE/.gpufix.pid" 2>/dev/null)
  case "$P" in
    ''|*[!0-9]*) ;;
    *) [ "$P" -gt 1 ] && grep -q gpufix "/proc/$P/cmdline" 2>/dev/null && kill "$P" 2>/dev/null ;;
  esac
  rm -f "$STATE/.gpufix.pid"
fi
if [ -r "$STATE/gpu.orig" ]; then
  while IFS='=' read -r K V; do
    case "$K" in ''|\#*) continue;; esac
    case "$V" in ''|*[!0-9]*) continue;; esac
    case "$K" in
      boost_gpu_enable) N=/sys/module/ged/parameters/boost_gpu_enable ;;
      gpu_cust_boost_freq) N=/sys/module/ged/parameters/gpu_cust_boost_freq ;;
      custom_boost_gpu_freq) N=/sys/kernel/ged/hal/custom_boost_gpu_freq ;;
      *) continue ;;
    esac
    [ -w "$N" ] && printf '%s\n' "$V" > "$N" 2>/dev/null
  done < "$STATE/gpu.orig"
  rm -f "$STATE/gpu.orig"
fi
# A reboot restores the module parameters anyway; do not remove the user's config.
exit 0
