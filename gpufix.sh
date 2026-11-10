#!/system/bin/sh
# X6886 GPU DVFS governor for MT6789 / GED / gpufreqv2.
#
# Goal: the GPU follows load everywhere (UI, games, video), instead of sitting at the
# 390 MHz floor almost all the time.
#
# What the kernel allows, and why the old static tweak was wrong for this kernel:
#   * gpu_dvfs_enable=1            -> the driver scales by itself, nothing is pinned.
#   * [GPU-LimitC] CeilingIndex: 0 -> no limiter; the fastest OPP (1600 MHz) is allowed.
#   * [GPU-LimitF] FloorIndex: 44  -> only the "never below 390 MHz" floor is active.
#   * boost_gpu_enable=0 and gpu_cust_boost_freq=390000 -> GED's boost path is inert:
#     its target is the slowest OPP, so a boost asks for the clock the GPU already idles at.
# GED only raises the clock when *it* decides there is 3D work; ordinary UI scrolling
# rarely survives its sampling long enough, which is why it looks stuck at 390 MHz.
#
# This governor reads GED's own load counter (gpu_utilization) every INTERVAL s and
# moves the boost floor: MIN_HZ while idle, TOP_HZ while busy and for HOLD_S after.
# The ceiling stays 1600 MHz and DVFS stays on, so inside that window the clock still
# scales by demand - it is a floor, not a fixed frequency.
#
# TOPPING OUT THE GPU FOR THE WHOLE SYSTEM:  TOP_HZ=0 means "the fastest OPP this
# driver publishes" (index 0, 1600 MHz here). Combined with MODE=floor the floor never
# leaves the top of the ladder, for every app and every screen state. Use the preset:
#     gpufix.sh preset safer    # RECOMMENDED: 790 rest -> 1600 on any UI work -> 390 asleep
#     gpufix.sh preset boost    # 390 idle -> 1200 busy
#     gpufix.sh preset max      # floor AND ceiling = top OPP always (pinned, hot, thirsty)
#     gpufix.sh preset stock    # release everything (stock behaviour)
#
# THE SAFE ONE: MODE=safer rests the floor at MIN_HZ (790 MHz for the safer preset), raises
# it to TOP_HZ (1600) whenever the GPU *or the CPU* is busy - so scrolling, app switching
# and video count, not just games - holds it for HOLD_S after the last busy sample, then
# drops back. It releases to SLEEP_HZ (the lowest OPP) while the screen is off, and when
# the battery is at or above TEMP_MAX (50 C) or below BAT_MIN (15%, not charging), so a
# hot or nearly-flat phone never sits at the top OPP. Nothing is throttled below 50 C.
# At or above TEMP_MAX battery temperature the floor drops to HOT_HZ (default MIN_HZ) until
# the phone cools, so a hot game session cannot sit at the ceiling indefinitely.
#
# THE LADDER MAY BE UNREADABLE: on some GSI/vendor combinations /proc/gpufreqv2 is
# denied to the shell even as root (the vendor power HAL keeps its own label). Index 0
# is the driver's own name for the fastest OPP and 0 is also what custom_upbound_gpu_freq
# wants, so 'preset max' still works: it writes index 0 to the floor and ceiling nodes and
# marks itself OFFLINE in the log. OFFLINE mode cannot tell 390 from 1600 by reading the
# ladder, so the thermal brake writes index TOP_INDEX (default 44 = slowest OPP, which is
# what the floor is at idle anyway) - override TOP_INDEX if your ladder differs.
#
# Two copies exist by design (the main patch ships it disabled, the standalone
# GPU-DVFS-X6886 module ships it enabled with GPU_FIX/ENABLED=1); CI checks that this
# file is byte-identical to gpumod/gpufix.sh.
#
# Modes:
#   status (default)  report + what the governor would do right now; writes nothing
#   probe [SECONDS]   sample frequency/load and say whether scaling works
#   apply [HZ]        one-shot: set the boost floor to HZ (default TOP_HZ)
#   verify [SECONDS]   like probe, with PASS/FAIL wording
#   run               the adaptive loop (foreground; service.sh runs it in background)
#   boot              what service.sh calls: start the loop when ENABLED=1
#   revert            restore the values saved by the first write (a reboot does too)
#   ceil [HZ]         publish the GED upper bound (0 = the top OPP); repairs a 1100 MHz cap
#   reapply           re-publish the whole config to the nodes (indices AND kHz), no args
#   cap               audit every ceiling (driver table, limit_table, pin) and release a pin
#   unpin             release /proc/gpufreqv2/fix_target_opp_index on its own
#   release           drop the floor to SLEEP_HZ (the lowest OPP), works offline
#   preset NAME       safer | boost | max | stock - writes the config and applies at once
#   choose            installer helper: asks with the volume keys (up=safer, down=max)
#
# Config: /data/adb/fod/gpu.conf   Snapshot: /data/adb/fod/gpu.orig   Log: /data/adb/fod/gpu.log
# Nothing is written while ENABLED=0. Every value written is a module parameter or a GED
# node, so a plain reboot restores the stock behaviour even if revert is never run.
MODDIR=${0%/*}
ME="sh $MODDIR/gpufix.sh"
D=/data/adb/fod
# The standalone GPU module keeps its own state so it never edits the main
# patch's /data/adb/fod config (both may be inspected on the same phone).
case "$MODDIR" in *gpu_dvfs_x6886*) D=${GPUFIX_STATE:-/data/adb/gpufix} ;; esac
CONF=$D/gpu.conf
ORIG=$D/gpu.orig
PIDF=$D/.gpufix.pid
LOG=$D/gpu.log
GED=/sys/kernel/ged/hal
P=/sys/module/ged/parameters
TABLES="/proc/gpufreqv2/gpu_working_opp_table /proc/gpufreqv2/stack_working_opp_table"
STATUS=/proc/gpufreqv2/gpufreq_status
PIN=/proc/gpufreqv2/fix_target_opp_index    # pinned target OPP: 0..n pins, -1 releases
AVAIL=/proc/gpufreqv2/available_opp_table  # what the driver will actually hand out
LTABLE=/proc/gpufreqv2/limit_table         # platform limiter rows: "set <id> <max> <min>"
N_CUR=$GED/current_freqency
N_UTIL=$GED/gpu_utilization
N_BOOST=$GED/custom_boost_gpu_freq
N_UPBOUND=$GED/custom_upbound_gpu_freq
N_LEVELS=$GED/total_gpu_freq_level_count
P_DVFS=$P/gpu_dvfs_enable
P_BOOST=$P/boost_gpu_enable
P_CUST=$P/gpu_cust_boost_freq
P_BOTTOM=$P/gpu_bottom_freq
P_UPBOUND=$P/gpu_cust_upbound_freq
LADDER_OK=""        # "" = not probed yet, 1 = readable, 0 = denied to us (OFFLINE mode)

# Defaults; /data/adb/fod/gpu.conf may override them (validated below).
ENABLED=0            # 1 = start the governor at boot
MODE=adaptive        # adaptive | safer (screen-aware) | floor (always TOP_HZ) | off (always MIN_HZ)
MIN_HZ=390000        # floor while idle in use (MODE=safer default is 790000)
SLEEP_HZ=390000      # floor while the screen is off, hot or low on battery (the lowest OPP)
SCREEN_OFF_MIN=1     # MODE=safer: force SLEEP_HZ when the screen is off (1 = yes, 0 = no)
BAT_MIN=15           # MODE=safer: below this battery % (and not charging) do not raise the floor
CPU_ON=0             # MODE=safer: CPU busy %% that also counts as "the UI is working"; 0 = off
SAFE_INDEX=          # ladder index of MIN_HZ, used only when the ladder is unreadable
TOP_HZ=1200000       # floor while the GPU is busy
LOAD_ON=60           # gpu_utilization load %, at or above this counts as busy
HOLD_S=20            # keep TOP_HZ this long after the last busy sample
INTERVAL=2           # loop period in seconds
TEMP_MAX=500         # ONLY at or above this battery temperature (deci-degC = 50 C) throttle:
                     # the floor drops to HOT_HZ. Below it nothing is throttled, ever.
HOT_HZ=0             # floor while >= TEMP_MAX; 0 = use MIN_HZ (e.g. 900000 to stay warm-but-fast)
CEIL_HZ=1600000      # GED upper bound to publish: kHz, or 0 for the fastest OPP
TOP_INDEX=44         # ladder index of the slowest OPP; used only when the ladder is unreadable
# The two ends of the ladder in kHz. Without them, "index 0" and "index 44" can be written
# to the hal nodes while the matching gpu_cust_*_freq parameters keep a stale value - on
# this device that meant index 0 with cust_upbound_freq=1100000 (the stock 1100 MHz cap),
# so the GPU never passed 1100 however correct the indices were.
TOP_HZ_KHZ=1600000   # kHz of the fastest OPP (TOP_INDEX/TOP_HZ=0 refer to this)
BOTTOM_HZ_KHZ=390000 # kHz of the slowest OPP (SLEEP_HZ / TOP_INDEX)
SYNC_PARAM=1         # keep gpu_cust_boost_freq (module parameter) in sync with the floor
UNPIN=1              # release a stale fix_target_opp_index pin (a pin freezes BOTH presets)
KEEP_PIN=0           # 1 = if something pinned the GPU on purpose, leave it alone
SAMPLE_S=10          # default probe/verify window
num_or() {   # $1 value, $2 fallback -> prints a sane non-negative integer
  case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
num_req() {  # $1 value, $2 default -> an empty or invalid value becomes $2 (CEIL_HZ may be 0)
  case "$1" in
    '') printf '%s' "$2" ;;
    *[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}
mkdir -p "$D" 2>/dev/null
[ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 60000 ] && mv -f "$LOG" "$LOG.old"
if [ -f "$CONF" ]; then . "$CONF"; fi
GPU_FIX=$(num_or "${GPU_FIX:-0}" 0)   # v11.3 name for the same switch; kept for old configs
[ "$GPU_FIX" = 1 ] && ENABLED=1
ENABLED=$(num_or "$ENABLED" 0)
MIN_HZ=$(num_or "$MIN_HZ" 390000)
TOP_HZ=$(num_or "$TOP_HZ" 1200000)
LOAD_ON=$(num_or "$LOAD_ON" 60)
HOLD_S=$(num_or "$HOLD_S" 20)
INTERVAL=$(num_or "$INTERVAL" 2)
TEMP_MAX=$(num_or "$TEMP_MAX" 500)
HOT_HZ=$(num_or "$HOT_HZ" 0)
SLEEP_HZ=$(num_or "$SLEEP_HZ" 390000)
SCREEN_OFF_MIN=$(num_or "$SCREEN_OFF_MIN" 1)
BAT_MIN=$(num_or "$BAT_MIN" 15)
CPU_ON=$(num_or "$CPU_ON" 0)
[ "$CPU_ON" -le 100 ] || CPU_ON=100
SAFE_INDEX=$(num_or "$SAFE_INDEX" "")
TOP_INDEX=$(num_or "$TOP_INDEX" 44)
TOP_HZ_KHZ=$(num_or "$TOP_HZ_KHZ" 1600000)
BOTTOM_HZ_KHZ=$(num_or "$BOTTOM_HZ_KHZ" "$SLEEP_HZ")
CEIL_HZ=$(num_req "$CEIL_HZ" 1600000)    # 0 = top OPP; empty is not allowed for the ceiling
SYNC_PARAM=$(num_or "$SYNC_PARAM" 1)
UNPIN=$(num_or "$UNPIN" 1)
KEEP_PIN=$(num_or "$KEEP_PIN" 0)
SAMPLE_S=$(num_or "$SAMPLE_S" 10)
case "$MODE" in adaptive|safer|floor|off) ;; *) MODE=adaptive ;; esac
[ "$INTERVAL" -ge 1 ] || INTERVAL=1
[ "$LOAD_ON" -le 100 ] || LOAD_ON=100

log()  { echo "$(date +%F_%T) $*" >> "$LOG"; }
say()  { printf '%s\n' "$*"; }
both() { say "$*"; log "$*"; }
# --- node io (regression-tested by .github/tests/test_fixes.py) ---
node_val() { read -r _v _rest 2>/dev/null < "$1"; printf '%s' "$_v"; }
write_node() {   # $1 node, $2 value; succeeds only if the readback matches
  [ -w "$1" ] || return 1
  printf '%s\n' "$2" > "$1" 2>/dev/null || return 1
  [ "$(node_val "$1")" = "$2" ]
}
# --- end node io ---

# --- GPU OPP / node helpers (regression-tested by .github/tests/test_fixes.py) ---
opp_lines() {   # print "index freq" for every published OPP: best source first
  for _t in $TABLES; do
    [ -r "$_t" ] || continue
    _o=$(sed -n -e 's/.*Index: *\([0-9][0-9]*\).*Freq: *\([0-9][0-9]*\).*/\1 \2/p' \
                -e 's/^\[\([0-9][0-9]*\)\].*freq *= *\([0-9][0-9]*\).*/\1 \2/p' "$_t" 2>/dev/null)
    [ -n "$_o" ] && { printf '%s\n' "$_o"; return 0; }
  done
  return 1
}
ladder_stats() {   # sets L_N L_MIN L_MAX L_SLOW (index of the slowest OPP)
  L_N=0; L_MIN=""; L_MAX=""; L_SLOW=""
  _lines=$(opp_lines) || return 1
  [ -n "$_lines" ] || return 1
  while read -r _i _f; do
    case "$_i$_f" in ''|*[!0-9]*) continue;; esac
    L_N=$((L_N + 1))
    if [ -z "$L_MIN" ] || [ "$_f" -lt "$L_MIN" ]; then L_MIN=$_f; L_SLOW=$_i; fi
    if [ -z "$L_MAX" ] || [ "$_f" -gt "$L_MAX" ]; then L_MAX=$_f; fi
  done <<OPPEOF
$_lines
OPPEOF
  [ -n "$L_MIN" ]
}
resolve_opp() {   # $1 = wanted kHz -> sets R_IDX R_FREQ (0 = fastest; else smallest OPP >= wanted)
  R_IDX=""; R_FREQ=""
  # 0 means "the top OPP by name", which is the configured top - not whatever a limited
  # driver happens to publish. Reading it off the table is the 1100 MHz bug in miniature.
  if [ "$1" = 0 ]; then R_IDX=0; R_FREQ=$(top_khz); return 0; fi
  _fast_i=""; _fast_f=0
  _lines=$(opp_lines) || return 1
  [ -n "$_lines" ] || return 1
  while read -r _i _f; do
    case "$_i$_f" in ''|*[!0-9]*) continue;; esac
    if [ "$_f" -gt "$_fast_f" ]; then _fast_f=$_f; _fast_i=$_i; fi
    if [ "$1" -gt 0 ] && [ "$_f" -ge "$1" ] && { [ -z "$R_FREQ" ] || [ "$_f" -lt "$R_FREQ" ]; }; then
      R_IDX=$_i; R_FREQ=$_f
    fi
  done <<OPPEOF
$_lines
OPPEOF
  # A driver table clipped by a limiter only lists up to its current cap. Asking for the
  # configured top OPP means "try to lift that cap", so resolve to the top OPP rather than
  # quietly writing the clamped value back - that clamp is the 1100 MHz bug itself.
  _t=$(top_khz)
  if [ -n "$_t" ] && [ "$1" -ge "$_t" ] 2>/dev/null; then
    R_IDX=0; R_FREQ=$_t; return 0
  fi
  [ -n "$R_FREQ" ] || { R_IDX=$_fast_i; R_FREQ=$_fast_f; }
  [ -n "$R_FREQ" ]
}
# --- OPP end helper (regression-tested by .github/tests/test_fixes.py) ---
offline_top() {   # no ladder: index 0 is the driver's name for the fastest OPP
  # R_FREQ is what the kHz parameters must say. It is 0 only when even the configured
  # top frequency is unknown; top_khz() supplies it from TOP_HZ_KHZ / a known L_MAX.
  R_IDX=0; R_FREQ=$(top_khz)
  return 0
}
bottom_khz() {   # kHz of the slowest OPP: the live ladder wins, else BOTTOM_HZ_KHZ
  case "${L_MIN:-}" in
    ''|*[!0-9]*) case "${BOTTOM_HZ_KHZ:-}" in
                   ''|*[!0-9]*) case "${SLEEP_HZ:-}" in
                                   ''|*[!0-9]*) printf '390000\n' ;;
                                   *) printf '%s\n' "$SLEEP_HZ" ;;
                                 esac ;;
                   *) printf '%s\n' "$BOTTOM_HZ_KHZ" ;;
                 esac ;;
    *) [ "$L_MIN" -gt 0 ] && printf '%s\n' "$L_MIN" || printf '390000\n' ;;
  esac
}
top_khz() {   # kHz that "index 0" means: NEVER below the configured top OPP
  # The live ladder does not win here, the KNOWN top does. /proc/gpufreqv2 publishes a
  # *clipped* table whenever a limiter is active (stock upper bound, platform limit_table),
  # so trusting L_MAX lets a 1100 MHz view of the ladder make us publish
  # gpu_cust_upbound_freq=1100000 - i.e. the script would re-apply the very cap it exists
  # to lift, every 15 s. Take the larger of the two (see opp_top_khz below).
  _c=${TOP_HZ_KHZ:-}
  case "$_c" in ''|*[!0-9]*) _c=1600000 ;; esac
  case "${L_MAX:-}" in
    ''|*[!0-9]*) printf '%s\n' "$_c" ;;
    *) if [ "$L_MAX" -gt "$_c" ]; then printf '%s\n' "$L_MAX"; else printf '%s\n' "$_c"; fi ;;
  esac
}
opp_top_khz() {   # kHz of the fastest OPP the KERNEL publishes (clipped view included)
  # Computed here, not read from L_MAX: L_MAX is only filled by ladder_stats(), and an
  # audit that silently reports "unreadable" because nobody called it first is useless.
  _m=$(opp_lines 2>/dev/null) || { printf ''; return 0; }
  [ -n "$_m" ] || { printf ''; return 0; }
  printf '%s\n' "$_m" | while read -r _i _f; do
    case "$_i$_f" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$_f"
  done | sort -n | tail -1
}
# --- end OPP end helper ---
offline_index() {   # $1 = kHz -> index via the shell-only fallback; sets R_IDX R_FREQ
  case "$1" in
    ''|0) offline_top; return 0 ;;
  esac
  if [ -n "$L_MIN" ] && [ -n "$L_MAX" ] && [ -n "$L_SLOW" ] && [ "$1" -ge "$L_MAX" ]; then
    offline_top; return 0
  fi
  if [ -n "$L_MIN" ] && [ -n "$L_SLOW" ] && [ "$1" -le "$L_MIN" ]; then
    R_IDX=$L_SLOW; R_FREQ=$L_MIN; return 0
  fi
  return 1            # anything in between needs the real ladder
}
ladder_available() {   # remember once whether the kernel ladder can be read at all
  if [ -z "$LADDER_OK" ]; then
    if opp_lines >/dev/null 2>&1; then LADDER_OK=1; else LADDER_OK=0; fi
  fi
  [ "$LADDER_OK" = 1 ]
}
# --- end GPU OPP / node helpers ---
# --- cap audit / pin release (regression-tested by .github/tests/test_fixes.py) ---
# Why this exists: everything above writes two GED nodes, and on a device where both read
# back perfectly the GPU can STILL sit at one frequency forever if (a) the driver target is
# pinned, or (b) the platform limiter clipped the driver's own table. Neither shows up in
# the two nodes we publish, which is exactly why 'both presets are 1100' could survive v12.
pin_state() {   # "none" | "<n>" | "" when the node is absent or unreadable
  [ -r "$PIN" ] || { printf 'none'; return 0; }
  _p=$(node_val "$PIN")
  case "$_p" in
    ''|*[!0-9-]*) printf '' ;;
    -1) printf 'none' ;;
    *) printf '%s' "$_p" ;;
  esac
}
pin_release() {   # drop a stale pin; exit 0 = released now, 2 = nothing pinned, 1 = refusal
  [ "$UNPIN" = 1 ] || return 2
  [ "$KEEP_PIN" = 1 ] && return 2
  _ps=$(pin_state)
  [ "$_ps" = none ] && return 2
  [ -n "$_ps" ] || return 2                  # node absent/unreadable: nothing to undo
  write_node "$PIN" -1 2>/dev/null || return 1
  log "pin: released fix_target_opp_index (was $_ps) - a pin freezes every preset"
  return 0
}
limit_rows() {   # readable limiter rows as "id max min", one per line (empty = no limiter)
  [ -r "$LTABLE" ] || return 0
  while read -r _a _b _c _d; do
    case "$_a" in set) case "$_b$_c$_d" in
        ''|*[!0-9]*) ;;                      # header/comment/blank: skip
        *) printf '%s %s %s\n' "$_b" "$_c" "$_d" ;; esac ;;
    esac
  done < "$LTABLE"
}
cap_sources() {   # every place a ceiling can hide, one aligned line each (read-only)
  # This is what turns "still 1100?" into a single paste instead of four rounds of guessing.
  _t=$(opp_top_khz); _c=$(top_khz); _ps=$(pin_state)
  if [ -z "$_t" ]; then printf 'driver table: unreadable (top treated as %s kHz)\n' "$_c"
  elif [ "$_t" -lt "$_c" ]; then
    printf 'driver table: %s kHz - CLIPPED, expected %s kHz\n' "$_t" "$_c"
  else printf 'driver table: %s kHz\n' "$_t"
  fi
  _lt=$(limit_rows)
  if [ -n "$_lt" ]; then printf 'limit_table:  %s\n' "$(printf '%s' "$_lt" | tr '\n' ';')"
  elif [ -r "$LTABLE" ]; then printf 'limit_table:  no rows (nothing limited)\n'
  else printf 'limit_table:  n/a\n'
  fi
  printf 'hal index:    %s   (0 = the fastest OPP)\n' "$(node_val "$N_UPBOUND")"
  printf 'hal param:    %s   (gpu_cust_upbound_freq, kHz)\n' "$(node_val "$P_UPBOUND")"
  case "$_ps" in
    none) printf 'pin:          none (released)\n' ;;
    '')   printf 'pin:          n/a (node absent)\n' ;;
    *)    printf 'pin:          %s - PINNED, this freezes every preset\n' "$_ps" ;;
  esac
}
# --- end cap audit ---

# --- preset helpers (regression-tested by .github/tests/test_fixes.py) ---
preset_values() {   # $1 preset -> "mode top_hz load_on hold_s interval ceil"; ceil 0 = top OPP
  # The ceiling is expressed as the ladder-agnostic 0 ("fastest OPP"), so a maxed preset
  # works even where /proc/gpufreqv2 is denied to us. "" leaves the ceiling alone.
  case "$1" in
    # safer also lifts the GED upper bound: without it the stock cap (1100 MHz on this
    # device) wins and 'max 1600' is never actually reachable, whatever the floor says.
    safer) printf '%s\n' "safer 0 25 6 1 0" ;;  # 790 rest floor, 1600 on any UI work, 390 asleep
    stock) printf '%s\n' "off 390000 60 0 2 " ;;
    boost) printf '%s\n' "adaptive 1200000 60 20 1 " ;;
    max)   printf '%s\n' "floor 0 60 20 1 0" ;;
    *) return 1 ;;
  esac
}
setkey() {   # $1 file, $2 key, $3 value - replace in place or append; keeps other keys
  [ -f "$1" ] || : > "$1"
  if grep -q "^$2=" "$1" 2>/dev/null; then
    sed "s|^$2=.*|$2=$3|" "$1" > "$1.tmp" 2>/dev/null && mv -f "$1.tmp" "$1"
  else
    printf '%s=%s\n' "$2" "$3" >> "$1"
  fi
}
# --- end preset helpers ---

# --- screen/charging helpers (regression-tested by .github/tests/test_fixes.py) ---
screen_on() {   # 0 = screen is on. Never guesses "off" when it cannot tell.
  _dpms=$(cat /sys/class/drm/card0-DSI-1/dpms 2>/dev/null)
  case "$_dpms" in
    On) return 0 ;;
    Off) return 1 ;;
  esac
  _st=$(dumpsys power 2>/dev/null | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -n 1)
  case "$_st" in
    Awake|Dreaming) return 0 ;;
    Asleep|Dozing) return 1 ;;
  esac
  # Unreadable: assume the screen is ON. Guessing "off" would pin the GPU low and is the
  # worse failure; guessing "on" only costs a little power if the panel is really dark.
  return 0
}
charging() {   # 0 = external power is connected
  case "$(cat /sys/class/power_supply/battery/status 2>/dev/null)" in
    Charging|Full) return 0 ;;
  esac
  case "$(cat /sys/class/power_supply/battery/present 2>/dev/null)$(cat /sys/class/power_supply/usb/online 2>/dev/null)" in
    *1*) return 0 ;;
  esac
  return 1
}
cpu_busy() {   # 0 = the system (not only the GPU) is doing work right now
  # The UI itself is composited on the CPU: scrolling, app switching, dialogs and video
  # all cost cores without ever loading the GPU enough for gpu_utilization to cross
  # LOAD_ON. /proc/stat "idle" excludes iowait on Linux, so 100-idle measures real CPU
  # occupancy; the window is the loop's own INTERVAL, so no extra state is kept.
  [ "$CPU_ON" -gt 0 ] || return 1
  # ONE variable: `read -r a b` would put the whole rest of the line into b, losing the
  # counters. After `set --` the fields are: 1 cpu, 2 user, 3 nice, 4 system, 5 idle, ...
  read -r _line 2>/dev/null < /proc/stat
  set -- $_line
  [ -n "${5:-}" ] || return 1
  case "${5:-}" in *[!0-9]*) return 1 ;; esac
  _t1=$(( ${2:-0} + ${3:-0} + ${4:-0} + ${5:-0} + ${6:-0} + ${7:-0} + ${8:-0} + ${9:-0} ))
  _i1=${5:-0}
  sleep "${CPU_SAMPLE_S:-1}"
  read -r _line 2>/dev/null < /proc/stat
  set -- $_line
  case "${5:-}" in ''|*[!0-9]*) return 1 ;; esac
  _t2=$(( ${2:-0} + ${3:-0} + ${4:-0} + ${5:-0} + ${6:-0} + ${7:-0} + ${8:-0} + ${9:-0} ))
  _i2=${5:-0}
  _dt=$(( _t2 - _t1 )); _di=$(( _i2 - _i1 ))
  [ "$_dt" -gt 0 ] || return 1
  [ $(( (_dt - _di) * 100 / _dt )) -ge "$CPU_ON" ]
}
low_battery() {   # 0 = too empty to raise the floor (and not charging)
  [ "$BAT_MIN" -gt 0 ] || return 1
  charging && return 1
  _c=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  case "$_c" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_c" -lt "$BAT_MIN" ]
}
floor_policy() {   # prints "want_hz reason" for MODE=safer, in order of precedence
  # screen off -> SLEEP_HZ (lowest OPP); hot -> HOT_HZ; low battery -> SLEEP_HZ;
  # GPU busy or CPU busy -> TOP_HZ (1600, whole UI); else MIN_HZ (the 790 MHz floor).
  # $1 = sticky 0/1, $2 = load %, $3 = screen_on 0/1, $4 = hot 0/1, $5 = low_batt 0/1,
  # $6 = cpu_busy 0/1
  if [ "$SCREEN_OFF_MIN" = 1 ] && [ "$3" = 0 ]; then printf '%s screen-off\n' "$SLEEP_HZ"; return 0; fi
  if [ "$4" = 1 ]; then
    if [ "$HOT_HZ" -gt 0 ]; then printf '%s hot\n' "$HOT_HZ"; else printf '%s hot\n' "$SLEEP_HZ"; fi
    return 0
  fi
  if [ "$5" = 1 ]; then printf '%s low-battery\n' "$SLEEP_HZ"; return 0; fi
  if [ "$1" = 1 ] || [ "${6:-0}" = 1 ]; then printf '%s busy\n' "$TOP_HZ"
  else printf '%s idle\n' "$MIN_HZ"; fi
}
# --- end screen/charging helpers ---

# --- adaptive helpers (regression-tested by .github/tests/test_fixes.py) ---
sticky_step() {   # $1 sticky 0/1, $2 load %, $3 now s, $4 last busy s, $5 hold s -> "sticky last_busy"
  case "$1$2$3$4$5" in *[!0-9]*) printf '%s %s\n' "${1:-0}" "${4:-0}"; return 0;; esac
  if [ "$2" -ge "$LOAD_ON" ]; then
    printf '1 %s\n' "$3"
  elif [ "$1" = 1 ] && [ $(( $3 - $4 )) -lt "$5" ]; then
    printf '1 %s\n' "$4"
  else
    printf '0 %s\n' "$4"
  fi
}
pick_target() {   # $1 sticky 0/1 -> wanted floor in kHz
  if [ "$1" = 1 ]; then printf '%s\n' "$TOP_HZ"; else printf '%s\n' "$MIN_HZ"; fi
}
# --- end adaptive helpers ---

is_root() { [ "$(id -u 2>/dev/null)" = 0 ]; }
# --- plan helper (regression-tested by .github/tests/test_fixes.py) ---
plan_now() {   # prints "want_hz reason" for the current instant (MODE and heat respected)
  if hot; then
    if [ "$HOT_HZ" -gt 0 ]; then printf '%s hot\n' "$HOT_HZ"; else printf '%s hot\n' "$SLEEP_HZ"; fi
    return 0
  fi
  case "$MODE" in
    off)   printf '%s released\n' "$MIN_HZ" ;;
    floor) _sc=1; screen_on || _sc=0
           if [ "$_sc" = 0 ]; then printf '%s screen-off\n' "$SLEEP_HZ"
           else printf '%s floor\n' "$TOP_HZ"; fi ;;
    safer) _l=$(num_or "$(node_val "$N_UTIL")" 0)
           _st=0; [ "$_l" -ge "$LOAD_ON" ] && _st=1
           _sc=1; screen_on || _sc=0
           _lb=0; low_battery && _lb=1
           _cb=0; [ -n "$CPU_SAMPLE_S" ] || CPU_SAMPLE_S=1
           [ "$_sc" = 1 ] && { cpu_busy && _cb=1; }
           floor_policy "$_st" "$_l" "$_sc" 0 "$_lb" "$_cb" ;;
    *)     _l=$(num_or "$(node_val "$N_UTIL")" 0)
           if [ "$_l" -ge "$LOAD_ON" ]; then printf '%s busy\n' "$TOP_HZ"
           else printf '%s idle\n' "$MIN_HZ"; fi ;;
  esac
}
# --- end plan helper ---
now_s() { read -r _u _r 2>/dev/null < /proc/uptime; printf '%s' "${_u%%.*}"; }

# --- installer chooser (used from customize.sh, not by the governor loop) ---
_uisay() { type say >/dev/null 2>&1 && say "$*" || printf '%s\n' "$*"; }
key_event() {   # $1 timeout s -> 0/1 = volume up, 2/3 = volume down, 4 = timeout
  # Magisk exports KEYCHECK; outside the installer this is a harmless no-op.
  _to=${1:-20}
  if command -v getevent >/dev/null 2>&1; then
    # `timeout` keeps the installer from hanging if the panel is asleep. Without it,
    # take the one blocking event - the installer only asks when a human is watching.
    if command -v timeout >/dev/null 2>&1; then
      _ev=$(timeout "$_to" getevent -qlc 1 2>/dev/null | tail -n 1)
    else
      _ev=$(getevent -qlc 1 2>/dev/null | tail -n 1)
    fi
    case "$_ev" in
      *KEY_VOLUMEUP*DOWN*)   return 0 ;;
      *KEY_VOLUMEUP*UP*)     return 1 ;;
      *KEY_VOLUMEDOWN*DOWN*) return 2 ;;
      *KEY_VOLUMEDOWN*UP*)   return 3 ;;
    esac
    return 4
  fi
  if [ -n "$KEYCHECK" ] && command -v "$KEYCHECK" >/dev/null 2>&1; then
    [ -r "$KEYCHECK" ] && . "$KEYCHECK"
    _k=$("$KEYCHECK" "$_to")
    case "$_k" in
      0) return 0 ;; 1) return 1 ;; 2) return 2 ;; 3) return 3 ;;
    esac
  fi
  return 4
}
choose_preset() {   # volume-key picker for the Magisk installer
  # Volume UP = SAFER (whole-system boost on load, lowest OPP with the screen off),
  # Volume DOWN = MAX (pinned at the top OPP). No press within CHOOSE_TIMEOUT s = SAFER.
  # The answer is written to $GPUFIX_CHOICE when set (the installer reads it), else printed;
  # this function never changes the config itself, the caller decides.
  _ans=safer; _why="no press, default"
  if command -v getevent >/dev/null 2>&1 || [ -n "$KEYCHECK" ]; then
    if key_event "${CHOOSE_TIMEOUT:-20}"; then
      _why="volume up"
    else
      case $? in
        2|3) _ans=max; _why="volume down" ;;
      esac
    fi
  else
    _why="non-interactive, default"
  fi
  _uisay "gpu preset: $([ "$_ans" = max ] && echo MAX || echo SAFER) ($_why)"
  if [ -n "$GPUFIX_CHOICE" ]; then
    printf '%s\n' "$_ans" > "$GPUFIX_CHOICE"
  else
    printf '%s\n' "$_ans"
  fi
}
# --- end installer chooser ---
# --- thermal limit helper (regression-tested by .github/tests/test_fixes.py) ---
hot() {   # 0 = at or above TEMP_MAX: the floor must be released at once
  _t=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
  case "$_t" in ''|*[!0-9]*) return 1;; esac
  [ "$_t" -ge "$TEMP_MAX" ]
}
# --- end thermal limit helper ---
limits() {   # one-line form of the driver's own limiter rows
  [ -r "$STATUS" ] || { printf 'n/a'; return; }
  grep -E '\[GPU-Limit[CF]\]' "$STATUS" 2>/dev/null |
    sed -n -e 's/.*\[GPU-LimitC\].*CeilingIndex: *\([0-9][0-9]*\).*/C=\1/p' \
           -e 's/.*\[GPU-LimitF\].*FloorIndex: *\([0-9][0-9]*\).*/F=\1/p' | tr '\n' ' ' | sed 's/ *$//'
}
snapshot() {   # keep the pre-change values once; never overwrite a real snapshot
  [ -f "$ORIG" ] && return 0
  {
    printf 'boost_gpu_enable=%s\n' "$(node_val "$P_BOOST")"
    printf 'gpu_cust_boost_freq=%s\n' "$(node_val "$P_CUST")"
    printf 'custom_boost_gpu_freq=%s\n' "$(node_val "$N_BOOST")"
    printf 'custom_upbound_gpu_freq=%s\n' "$(node_val "$N_UPBOUND")"
    printf 'gpu_cust_upbound_freq=%s\n' "$(node_val "$P_UPBOUND")"
    printf 'fix_target_opp_index=%s\n' "$(pin_state)"
  } > "$ORIG"
  log "snapshot $(tr '\n' ' ' < "$ORIG")"
}
hz_text() {   # $1 = kHz, "" -> human wording; 0 means "the top OPP" on this kernel
  case "$1" in
    0) printf 'the top OPP' ;;
    '') printf 'unknown' ;;
    *) printf '%s kHz' "$1" ;;
  esac
}
floor_freq() {   # prints the kHz of the OPP currently written to custom_boost_gpu_freq
  _fi=$(node_val "$N_BOOST")
  [ -n "$_fi" ] || return 1
  opp_lines | while read -r _i _f; do [ "$_i" = "$_fi" ] && { printf '%s\n' "$_f"; break; }; done
}
write_floor() {   # writes an ALREADY resolved R_IDX/R_FREQ (no ladder lookup)
  # Resolving and writing are separate on purpose: a preset resolves the index first (and
  # refuses without writing config), then the write must not re-resolve it under a
  # different rule. exit codes: 0 = written, 2 = already there, 1 = failed
  _cur=$(node_val "$N_BOOST")
  if [ "$_cur" = "$R_IDX" ]; then
    if [ "$SYNC_PARAM" != 1 ] || [ "$(node_val "$P_CUST")" = "$R_FREQ" ]; then return 2; fi
  fi
  snapshot
  write_node "$N_BOOST" "$R_IDX" || return 1
  # Publish a real kHz whenever we know one: index 0 with a stale cust_boost_freq is how
  # the GPU stayed at the old cap while every index looked right.
  _pub=$R_FREQ; [ -n "$_pub" ] && [ "$_pub" != 0 ] || _pub=""
  if [ -z "$_pub" ]; then
    case "$R_IDX" in 0) _pub=$(top_khz) ;; "$TOP_INDEX") _pub=$(bottom_khz) ;; esac
  fi
  if [ "$SYNC_PARAM" = 1 ] && [ -n "$_pub" ] && [ "$_pub" != 0 ]; then write_node "$P_CUST" "$_pub"; fi
  [ "$(node_val "$P_BOOST")" = 1 ] || write_node "$P_BOOST" 1
  return 0
}
floor_to() {   # $1 = kHz; resolves the OPP then writes it (see write_floor)
  if ! ladder_available; then
    # No ladder: only the two ends can be named. "Release" means the lowest OPP, which is
    # TOP_INDEX on this kernel (44 = 390 MHz). L_MIN is only known if the ladder was read
    # at some point, so fall back to SLEEP_HZ - the configured bottom - rather than fail.
    _hz=$(num_or "$1" 0)
    _low=$(num_or "$SLEEP_HZ" 390000)
    case "$_hz" in
      0) offline_top ;;
      *) if [ "$_hz" -le "$_low" ]; then
           R_IDX=$TOP_INDEX; R_FREQ=$(bottom_khz)
         elif [ "$_hz" = "$MIN_HZ" ] && [ -n "$SAFE_INDEX" ]; then
           # MIN_HZ is the rest floor: its index is what SAFE_INDEX records, that is the
           # whole point of the key. Resolving it again through offline_index cannot work.
           R_IDX=$SAFE_INDEX; R_FREQ=$MIN_HZ
         elif [ -n "$L_MIN" ] && [ "$_hz" -le "$L_MIN" ]; then
           R_IDX=$TOP_INDEX; R_FREQ=$L_MIN
         else
           offline_index "$_hz" || return 1
         fi ;;
    esac
  elif ! resolve_opp "$1"; then
    return 1
  fi
  write_floor
}

status() {
  say "== gpufix status ($(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2))"
  say "state: enabled=$ENABLED mode=$MODE min=$MIN_HZ top=$TOP_HZ load_on=${LOAD_ON}% hold=${HOLD_S}s every=${INTERVAL}s"
  say "root:  $(is_root && echo yes || echo 'no (read-only)')   config: $( [ -f "$CONF" ] && echo "$CONF" || echo defaults)"
  _bt=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
  case "$_bt" in
    ''|*[!0-9]*) say "temp:  unreadable   limit=$((TEMP_MAX / 10)) C" ;;
    *) if [ "$_bt" -ge "$TEMP_MAX" ]; then
         say "temp:  $((_bt / 10)) C >= limit $((TEMP_MAX / 10)) C - THROTTLED to $(hz_text "$SLEEP_HZ") now"
       else
         say "temp:  $((_bt / 10)) C   limit=$((TEMP_MAX / 10)) C (nothing throttled below it)"
       fi ;;
  esac
  if [ "$MODE" = safer ]; then
    say "safer: idle=$(hz_text "$MIN_HZ") busy=$(hz_text "$TOP_HZ") sleep=$(hz_text "$SLEEP_HZ")"
    say "safer: screen=$(screen_on && echo on || echo off) screen_off_min=$SCREEN_OFF_MIN bat_min=${BAT_MIN}% cpu_on=${CPU_ON}% charging=$(charging && echo yes || echo no)"
  fi
  say "ged:   dvfs=$(cat "$P_DVFS" 2>/dev/null) boost_gpu_enable=$(cat "$P_BOOST" 2>/dev/null) bottom_freq=$(cat "$P_BOTTOM" 2>/dev/null) cust_boost_freq=$(cat "$P_CUST" 2>/dev/null) cust_upbound_freq=$(cat "$P_UPBOUND" 2>/dev/null)"
  say "live:  $(cat "$N_CUR" 2>/dev/null) | util(load block idle): $(cat "$N_UTIL" 2>/dev/null)"
  say "ged:   boost target level=$(node_val "$N_BOOST") levels=$(node_val "$N_LEVELS")"
  say "limit: $(limits)"
  _lvl_load=$(node_val "$N_UTIL")
  if ladder_stats; then
    say "opp:   $L_N levels, $L_MIN..$L_MAX kHz (slowest = index $L_SLOW)"
    _pw=$(plan_now)
    _pt=${_pw% *}; _pr=${_pw#* }
    if resolve_opp "$_pt"; then
      say "plan:  load ${_lvl_load:-?}% / mode $MODE / ${_pr} -> level $R_IDX ($(hz_text "$R_FREQ"))"
      [ "$R_FREQ" -ge "$L_MAX" ] && say "pin:   floor = ceiling = $R_FREQ kHz; the GPU cannot scale down on its own."
    fi
    _ff=$(floor_freq)
    [ -n "$_ff" ] && say "asked: level $(node_val "$N_BOOST") = $_ff kHz (module floor)"
  else
    say "opp:   ladder not readable ($TABLES) - middle-of-ladder writes unavailable"
    say "       (top-OPP/slowest-OPP writes still work: preset max / preset stock)"
  fi
  _ps=$(pin_state)
  case "$_ps" in
    ''|none) ;;
    *) say "pin:   fix_target_opp_index=$_ps - a PIN overrides both nodes below, in every preset." ;;
  esac
  _t=$(opp_top_khz); _c=$(top_khz)
  if [ -n "$_t" ] && [ "$_t" -lt "$_c" ]; then
    say "cap:   the driver's own table stops at $_t kHz, not $_c: a limiter below GED is active."
    say "       '$ME cap' names it."
  fi
  _dv=$(node_val "$P_DVFS"); _ceiling=$(limits | sed -n 's/.*C=\([0-9]*\).*/\1/p')
  _ub=$(node_val "$P_UPBOUND"); _ubi=$(node_val "$N_UPBOUND")
  [ "$_ubi" = 0 ] && [ -z "$L_MAX" ] && _ub=""   # offline: the kHz behind index 0 is unknown
  if [ -n "$_ub" ] && [ "$_ubi" = 0 ]; then
    say "ceil:  upper bound hal index 0 = the top OPP is allowed"
  elif [ -n "$_ub" ]; then
    if [ -n "$L_MAX" ] && [ "$_ub" = "$L_MAX" ]; then
      say "ceil:  upper bound $(hz_text "$_ub") (hal index $_ubi) - the top OPP is allowed"
    else
      say "ceil:  upper bound $(hz_text "$_ub") (hal index $_ubi) - GED will not go above this"
    fi
  elif [ -n "$_ubi" ]; then
    say "ceil:  upper bound hal index $_ubi"
  fi
  # A right index with a stale kHz parameter is the bug that hid a 1100 MHz cap behind a
  # correct 'hal index 0'. Say it out loud instead of leaving it to be spotted by eye.
  _fni2=$(node_val "$N_BOOST"); _fkv=$(node_val "$P_CUST")
  _want_f=$(case "$_fni2" in 0) top_khz ;; "$TOP_INDEX") bottom_khz ;; *) echo "" ;; esac)
  if [ -n "$_want_f" ] && [ -n "$_fkv" ] && [ "$_fkv" != "$_want_f" ]; then
    say "floor: hal index $_fni2 means $_want_f kHz, but cust_boost_freq reads $_fkv."
    say "       Fix: preserve sync ('SYNC_PARAM=1') and re-run 'preset safer', or 'reapply'."
  fi
  _uki2=$(node_val "$N_UPBOUND"); _ukv=$(node_val "$P_UPBOUND")
  _want_u=$(case "$_uki2" in 0) top_khz ;; "$TOP_INDEX") bottom_khz ;; *) echo "" ;; esac)
  if [ -n "$_want_u" ] && [ -n "$_ukv" ] && [ "$_ukv" != "$_want_u" ]; then
    say "ceil:  hal index $_uki2 means $_want_u kHz, but cust_upbound_freq reads $_ukv."
    say "       That stale parameter is what caps the GPU. Fix: 'reapply'."
  fi
  if [ -n "$LADDER_OK" ] && [ "$LADDER_OK" = 0 ]; then
    say "mode:  OFFLINE - /proc/gpufreqv2 is not readable to this shell, so only top-OPP"
    say "       and slowest-OPP writes are possible; preset max still works (index 0)."
  fi
  if [ "$_dv" != 1 ]; then
    say "verdict: gpu_dvfs_enable=$_dv - DVFS is off and the GPU is pinned. That is the real fault."
  elif [ -n "$_ceiling" ] && [ "$_ceiling" != 0 ]; then
    say "verdict: a limiter caps the GPU at index $_ceiling (not the fastest OPP)."
  elif [ "$ENABLED" != 1 ]; then
    say "verdict: governor is off (ENABLED=0 in $CONF). The GPU follows GED demand only,"
    say "         which on this kernel means it sits at $L_MIN kHz almost all the time."
  elif [ "$MODE" = floor ]; then
    say "verdict: MODE=floor (max) - $(hz_text "$TOP_HZ") whenever the screen is on, and"
    say "         $(hz_text "$SLEEP_HZ") while it is off. Ceiling target: $(hz_text "$CEIL_HZ")."
    if [ -n "$_ub" ] && { [ "$_ubi" != 0 ] && [ "$_ub" != "$L_MAX" ]; }; then
      say "         BUT the live upper bound is $_ub kHz (hal index $_ubi): until that is the top"
      say "         OPP, GED will not go above it. Run 'preset max' to set it."
    fi
  elif [ "$MODE" = safer ]; then
    say "verdict: MODE=safer - the floor rests at $(hz_text "$MIN_HZ") and jumps to $(hz_text "$TOP_HZ")"
    say "         for ${HOLD_S}s whenever the GPU *or* the CPU${CPU_ON:+ (>${CPU_ON}%)} is busy, so the whole UI benefits."
    say "         screen off, >= $((TEMP_MAX / 10)) C or below ${BAT_MIN}% -> $(hz_text "$SLEEP_HZ")."
    say "         ceiling target: $(hz_text "$CEIL_HZ")."
    # The most common reason "safer shows 1100 MHz": the floor is asking for 1600 but GED's
    # upper bound is still the stock 1100000, so the GPU can never reach the top OPP.
    if [ -n "$_ub" ] && [ "$_ubi" != 0 ]; then
      say "         ! the ceiling is CAPPING the GPU at $(hz_text "$_ub") (hal index $_ubi)."
      say "           The floor can ask for 1600 all it likes; GED will not go above this."
      say "           Fix: '$ME preset safer' (lifts both), or '$ME ceil 0'."
    fi
  elif [ "$MODE" = off ]; then
    say "verdict: MODE=off - the floor is parked at $(hz_text "$SLEEP_HZ") (the lowest OPP); nothing"
    say "         is raised, so GED's own demand handling decides the clock."
  elif [ "$MODE" = adaptive ]; then
    say "verdict: MODE=adaptive - floor moves to $(hz_text "$TOP_HZ") while the GPU is busy, back to"
    say "         $(hz_text "$MIN_HZ") after ${HOLD_S}s idle. (CPU load does not raise it; use safer.)"
  else
    say "verdict: governor on - floor moves to $(hz_text "$TOP_HZ") while busy, back to $(hz_text "$MIN_HZ") when idle."
  fi
  [ -f "$ORIG" ] && say "state: nodes were changed (undo: '$ME revert' or reboot)"
  if [ -f "$PIDF" ]; then
    _p=$(cat "$PIDF" 2>/dev/null)
    case "$_p" in ''|*[!0-9]*) ;; *) kill -0 "$_p" 2>/dev/null && say "loop:  running (pid $_p)";; esac
  fi
  log "status: enabled=$ENABLED mode=$MODE load=${_lvl_load:-?} dvfs=$_dv"
}

sample() {   # $1 seconds, $2 label; sets S_* and prints the numbers
  _secs=$(num_or "$1" "$SAMPLE_S")
  [ "$_secs" -ge 1 ] || _secs=1
  [ "$_secs" -le 300 ] || _secs=300
  _n=$((_secs * 4)); _step=0.25
  sleep 0.25 2>/dev/null || { _n=$_secs; _step=1; }
  S_MIN=""; S_MAX=""; S_LAST=""; S_LOADMAX=0; S_LOADSUM=0; S_LOADED=0; S_IDLEHI=0; S_CHANGES=0; _i=0
  while [ "$_i" -lt "$_n" ]; do
    read -r _idx _freq _rest 2>/dev/null < "$N_CUR"
    read -r _l _b _id 2>/dev/null < "$N_UTIL"
    case "$_freq" in ''|*[!0-9]*) _freq="";; esac
    _l=$(num_or "$_l" 0)
    if [ -n "$_freq" ]; then
      if [ -z "$S_MIN" ] || [ "$_freq" -lt "$S_MIN" ]; then S_MIN=$_freq; fi
      if [ -z "$S_MAX" ] || [ "$_freq" -gt "$S_MAX" ]; then S_MAX=$_freq; fi
      if [ -n "$S_LAST" ] && [ "$_freq" != "$S_LAST" ]; then S_CHANGES=$((S_CHANGES + 1)); fi
      if [ "$_l" -eq 0 ] && [ -n "$S_MIN" ] && [ "$_freq" -gt "$S_MIN" ]; then S_IDLEHI=$((S_IDLEHI + 1)); fi
      S_LAST=$_freq
    fi
    [ "$_l" -gt "$S_LOADMAX" ] && S_LOADMAX=$_l
    [ "$_l" -gt 0 ] && S_LOADED=$((S_LOADED + 1))
    S_LOADSUM=$((S_LOADSUM + _l))
    _i=$((_i + 1))
    [ "$_i" -lt "$_n" ] && sleep "$_step" 2>/dev/null
  done
  [ -n "$S_MIN" ] || S_MIN=0
  [ -n "$S_MAX" ] || S_MAX=0
  if [ "$_n" -gt 0 ]; then _mean=$((S_LOADSUM / _n)); else _mean=0; fi
  say "== $2: ${_secs}s, $_n samples"
  say "freq:  min $S_MIN  max $S_MAX  last $S_LAST  changes $S_CHANGES kHz"
  say "load:  max ${S_LOADMAX}%  mean ${_mean}%  samples with load>0: $S_LOADED/$_n"
  FLOORF=""; _fni=""; _uni=""
  if ! ladder_available; then
    say "note:  the OPP ladder is not readable to this shell; judging by the nodes instead."
  fi
  if [ "$2" = verify ]; then   # one read can catch a mid-write - read again before judging
    _fni=$(node_val "$N_BOOST"); _uni=$(node_val "$N_UPBOUND")
  fi
  if ladder_stats; then
    say "floor: $L_MIN kHz (ladder index $L_SLOW), ceiling $L_MAX kHz"
    FLOORF=$(floor_freq)
    [ -n "$FLOORF" ] && say "asked: level $(node_val "$N_BOOST") = $(hz_text "$FLOORF") (by this module)"
  fi
  SCALE_OK=""
  if [ "$S_MAX" -eq 0 ]; then
    say "note:  GED nodes not readable - is this a MediaTek device with /sys/kernel/ged?"
  elif [ "$S_CHANGES" -gt 0 ]; then
    SCALE_OK=1
    say "result: the GPU changed frequency $S_CHANGES times ($S_MIN..$S_MAX kHz) - scaling works."
    [ "$S_IDLEHI" -gt 0 ] && say "warn:  it sat above $S_MIN kHz in $S_IDLEHI unloaded samples; a floor may be held too long."
  elif [ -n "$L_MAX" ] && [ "$S_LAST" -ge "$L_MAX" ]; then
    SCALE_OK=1
    say "result: held at the ceiling ($S_LAST kHz) - the floor is at the top OPP, nothing scales higher."
  elif [ -n "$FLOORF" ] && [ -n "$L_MIN" ] && [ "$FLOORF" -gt "$L_MIN" ] && [ "$S_LAST" -le "$L_MIN" ]; then
    SCALE_OK=0
    say "result: the floor was asked to be $FLOORF kHz, yet the clock stayed at $S_LAST kHz."
    say "        Something outside these nodes holds it (limiter, thermal or vendor power HAL)."
  elif [ -n "$L_MIN" ] && [ "$S_LAST" -le "$L_MIN" ]; then
    if [ "$S_LOADMAX" -ge 50 ]; then
      SCALE_OK=0
      say "result: flat at the $S_LAST kHz floor while load reached ${S_LOADMAX}% - no higher OPP was requested."
      say "        Raise the floor: $ME preset boost (or max), then verify again."
    else
      say "result: flat at the $S_LAST kHz floor and the GPU was mostly idle - this window proves nothing."
      say "        Repeat inside a 3D game or benchmark."
    fi
  elif [ -z "$L_MIN" ]; then
    _fl=$_fni; _ub=$_uni
    case "$_fl" in 0|'') ;; *) _fl=$(node_val "$N_BOOST") ;; esac
    case "$_ub" in 0|'') ;; *) _ub=$(node_val "$N_UPBOUND") ;; esac
    if [ "$_fl" = 0 ] && [ "$_ub" = 0 ]; then
      SCALE_OK=1
      say "result: floor and ceiling are both index 0, so a flat $S_LAST kHz is a pin at the top OPP."
    elif [ "$_fl" = 0 ]; then
      SCALE_OK=1
      say "result: floor is index 0 (top OPP); ceiling index $_ub. Flat $S_LAST kHz is the pin."
    else
      say "note:  floor index $_fl / ceiling index $_ub - without the ladder these cannot be"
      say "       translated to kHz. Raw nodes are in 'gpufix.sh status'."
    fi
  else
    SCALE_OK=1
    say "result: held at $S_LAST kHz for the whole window (above the floor) - demand was met at that step."
    say "        Check idle afterwards: with the governor on it should drop back to $MIN_HZ kHz."
  fi
  if [ "$2" = verify ]; then
    case "$SCALE_OK" in
      1) say "verify: PASS - the GPU is not stuck at its floor." ;;
      0) say "verify: FAIL - still flat at the floor under load; the floor did not take effect." ;;
      *) say "verify: INCONCLUSIVE - no usable samples or no readable ladder." ;;
    esac
  fi
  log "sample/$2: ${_secs}s min=$S_MIN max=$S_MAX last=$S_LAST changes=$S_CHANGES loadmax=$S_LOADMAX verdict=${SCALE_OK:-unknown}"
}

preset() {   # $1 = safer | boost | max | stock
  _vals=$(preset_values "$1") || {
    say "usage: $ME preset [safer|boost|max|stock]"
    say "  safer  RECOMMENDED: floor 790 MHz, 1600 the moment the UI is busy (CPU or GPU),"
    say "         390 with the screen off; nothing is throttled below 50 C"
    say "  boost  follow GPU load: 390 idle -> 1200 busy (mild)"
    say "  max    floor = ceiling = 1600 MHz all the time (hottest, thirstiest)"
    say "  stock  release the floor, stock behaviour"
    return 2
  }
  _name=$1
  set -- $_vals
  MODE=$1; TOP_HZ=$2; LOAD_ON=$3; HOLD_S=$4; INTERVAL=$5; _ceil=$6; ENABLED=1
  if [ "$MODE" = safer ]; then
    # A safer install carries its own idle floor (790 MHz) and its own sleep floor.
    MIN_HZ=790000
    SLEEP_HZ=390000
  fi
  case "$MODE" in off) _want=$MIN_HZ ;; *) _want=$TOP_HZ ;; esac
  # Resolve what this preset will write BEFORE touching gpu.conf: a preset we cannot
  # apply must leave the running config - and the governor re-reading it - alone.
  if is_root; then
    if ladder_available; then
      resolve_opp "$_want" || { say "! could not resolve $_want kHz on this ladder; nothing written."; return 1; }
      _lvl="$R_IDX ($R_FREQ kHz)"
      if [ "$MODE" = safer ]; then
        # now the idle end (790 MHz); this also becomes the offline fallback index
        resolve_opp "$MIN_HZ" || { say "! could not resolve $MIN_HZ kHz; nothing written."; return 1; }
        SAFE_INDEX=$R_IDX; _lvl="$R_IDX ($R_FREQ kHz)"
      fi
    else
      # Index 0 is the driver's name for the fastest OPP and TOP_INDEX the slowest, so
      # safer/max/stock work where /proc/gpufreqv2 is denied. Only 'boost' needs the middle.
      case "$_name" in
        max)   R_IDX=0; R_FREQ=0; _lvl="0 (the top OPP)" ;;
        safer) R_IDX=$SAFE_INDEX; R_FREQ=$MIN_HZ
               _lvl="$SAFE_INDEX (about $(hz_text "$MIN_HZ"); ladder unreadable)" ;;
        stock) R_IDX=$TOP_INDEX; R_FREQ=$SLEEP_HZ; _lvl="$TOP_INDEX (the lowest OPP)" ;;
        *)     say "the OPP ladder is not readable here (denied to this shell context), and this"
               say "preset needs a frequency in the middle of the ladder. Nothing was written."
               say "On this build use 'safer', 'max' (top OPP) or 'stock' (lowest OPP)."
               return 1 ;;
      esac
    fi
  fi
  setkey "$CONF" ENABLED 1
  setkey "$CONF" MODE "$MODE"
  setkey "$CONF" TOP_HZ "$TOP_HZ"
  setkey "$CONF" LOAD_ON "$LOAD_ON"
  setkey "$CONF" HOLD_S "$HOLD_S"
  setkey "$CONF" INTERVAL "$INTERVAL"
  [ -n "$_ceil" ] && setkey "$CONF" CEIL_HZ "$_ceil"
  case "$_name" in
    safer) setkey "$CONF" MIN_HZ "$MIN_HZ"
           setkey "$CONF" SLEEP_HZ "$SLEEP_HZ"
           setkey "$CONF" SCREEN_OFF_MIN 1
           setkey "$CONF" CPU_ON 60
           # Unreadable ladder: the safest guess is one step above the slowest OPP, which
           # is 790 MHz here (0 = 1600, 44 = 390). The real ladder overrides it above.
           [ -n "$SAFE_INDEX" ] || SAFE_INDEX=$((TOP_INDEX > 0 ? TOP_INDEX - 1 : 0))
           setkey "$CONF" SAFE_INDEX "$SAFE_INDEX" ;;
    stock) setkey "$CONF" SCREEN_OFF_MIN 0
           setkey "$CONF" MIN_HZ 390000; MIN_HZ=390000
           setkey "$CONF" SLEEP_HZ 390000; SLEEP_HZ=390000 ;;
    max|boost)
           # Never inherit a safer install's 790 MHz rest floor: max means pinned, and the
           # 50 C brake must go all the way down to the lowest OPP.
           setkey "$CONF" MIN_HZ 390000; MIN_HZ=390000
           setkey "$CONF" SLEEP_HZ 390000; SLEEP_HZ=390000 ;;
  esac
  : > "$D/.gpufix.reload"   # a running governor must pick this up before we touch the node
  both "preset $_name: MODE=$MODE TOP_HZ=$TOP_HZ LOAD_ON=$LOAD_ON HOLD_S=$HOLD_S INTERVAL=$INTERVAL"
  if ! is_root; then
    say "saved. Needs root to change the nodes now; it applies at the next tick or boot."
    return 0
  fi
  if [ "$MODE" = floor ]; then
    say "note: $(hz_text "$TOP_HZ") whenever the screen is on, $(hz_text "$SLEEP_HZ") while it is off."
    say "      Battery drain rises; at/above $((TEMP_MAX / 10)) C the floor drops to"
    say "      $([ "$HOT_HZ" -gt 0 ] && echo "$HOT_HZ" || echo "$SLEEP_HZ") kHz until it cools."
  elif [ "$MODE" = safer ]; then
    say "note: rests at $(hz_text "$MIN_HZ") and jumps to $(hz_text "$TOP_HZ") the moment the GPU *or*"
    say "      the CPU is busy - any app, any scrolling - keeping it ${HOLD_S}s after."
    say "      Screen off, >= $((TEMP_MAX / 10)) C or below ${BAT_MIN}% -> $(hz_text "$SLEEP_HZ")."
    say "      Ceiling: $(hz_text "$CEIL_HZ"). Nothing is throttled below $((TEMP_MAX / 10)) C."
  elif [ "$MODE" = off ] && [ -z "$_ceil" ]; then
    say "note: the floor is released; the GED upper bound is left where it is."
    say "      A reboot (or '$ME revert') restores the stock ceiling too."
  fi
  # safer writes its idle floor now (never leaves the GPU pinned at the top); the loop
  # raises it to TOP_HZ as soon as the UI is busy.
  write_floor
  case $? in
    0) both "floor now level $_lvl" ;;
    2) say "floor already level $_lvl" ;;
    *) say "! could not move the floor (custom_boost_gpu_freq reads $(node_val "$N_BOOST"))"; return 1 ;;
  esac
  if [ "$MODE" = floor ] || [ "$MODE" = safer ]; then
    # $_ceil: 0 = the top OPP; "" = leave the ceiling alone (boost/stock)
    CEIL_HZ=$_ceil
    ceil_to "$_ceil"
    case $? in
      0) both "ceiling now level $R_IDX ($(hz_text "$R_FREQ"))" ;;
      2) say "ceiling already level $R_IDX ($(hz_text "$R_FREQ"))" ;;
      *) say "! could not move the ceiling (custom_upbound_gpu_freq reads $(node_val "$N_UPBOUND"))" ;;
    esac
  fi
}

apply() {   # $1 = Hz for the floor, default TOP_HZ
  _want=$(num_or "$1" "$TOP_HZ")
  is_root || { say "apply needs root (su -c '$ME apply')"; return 1; }
  if ! ladder_stats; then
    say "cannot read the GPU OPP ladder ($TABLES). Refusing to guess an OPP index."
    return 1
  fi
  if hot; then
    say "battery is at $(( $(cat /sys/class/power_supply/battery/temp 2>/dev/null) / 10 )) C (TEMP_MAX=$((TEMP_MAX / 10)) C); not applying."
    return 1
  fi
  resolve_opp "$_want" || { say "no OPP resolved for $_want kHz"; return 1; }
  if [ "$_want" -gt 0 ] && [ "$R_FREQ" -le "$L_MIN" ]; then
    say "$_want kHz resolves to the $L_MIN kHz floor - nothing to raise. Use a higher value,"
    say "or 0 for the fastest OPP ($L_MAX kHz)."
    return 1
  fi
  say "floor: level $R_IDX = $R_FREQ kHz (requested $_want, ladder $L_MIN..$L_MAX)"
  floor_to "$_want"
  case $? in
    0) both "floor set to level $R_IDX ($R_FREQ kHz)" ;;
    2) say "floor already at level $R_IDX ($R_FREQ kHz) - nothing written" ;;
    *) say "! could not move the floor (custom_boost_gpu_freq readback $(node_val "$N_BOOST"))"; return 1 ;;
  esac
  say "check:  $ME probe 20   (use the phone normally)"
  say "undo:   $ME revert    (or reboot)"
}

ceil() {   # $1 = kHz for the GED upper bound, 0 = the top OPP (default CEIL_HZ)
  # GED will not run above this bound. A stock 1100000 is why a floor asking for 1600
  # stopped at 1100 MHz, so this is the one-shot repair for that state.
  _want=$(num_or "$1" "$CEIL_HZ")
  is_root || { say "ceil needs root (su -c '$ME ceil 0')"; return 1; }
  case "$_want" in ''|*[!0-9]*) say "usage: $ME ceil [kHz|0]   (0 = the top OPP)"; return 2 ;; esac
  if [ "$_want" != 0 ] && ! ladder_stats; then
    say "cannot read the GPU OPP ladder ($TABLES); only 0 (the top OPP) can be set here."
    return 1
  fi
  say "ceiling: requested $(hz_text "$_want")"
  ceil_to "$_want"
  case $? in
    0) both "ceiling now level $R_IDX ($(hz_text "$R_FREQ"))"
       setkey "$CONF" CEIL_HZ "$_want" ;;
    2) say "ceiling already level $R_IDX ($(hz_text "$R_FREQ"))"
       setkey "$CONF" CEIL_HZ "$_want" ;;
    *) say "! could not move the ceiling (custom_upbound_gpu_freq reads $(node_val "$N_UPBOUND"))"
       _cl=$(opp_top_khz); _ct=$(top_khz)
       case "$_cl" in
         ''|*[!0-9]*) ;;
         *) [ "$_cl" -lt "$_ct" ] && \
              say "  the driver publishes only $_cl kHz, not $_ct: a limiter below GED is active ('$ME cap')." ;;
       esac
       return 1 ;;
  esac
  _ub=$(node_val "$P_UPBOUND"); _ubi=$(node_val "$N_UPBOUND")
  say "check:  custom_upbound_gpu_freq=$_ubi gpu_cust_upbound_freq=${_ub:-?}"
  [ "$_ubi" = 0 ] || say "! note: the hal index is not 0 yet; GED may still cap the GPU below the top OPP."
  # Offline we cannot name a mid-ladder frequency, so only report what the node says.
  if [ -n "$_ub" ] && [ "$_ub" != 0 ] && [ "$_ubi" = 0 ] && [ "$_want" = 0 ] &&
     ! ladder_available; then
    say "note:   the hal index is 0 (the top OPP) but the kHz parameter still reads $_ub:"
    say "        the driver would not take the configured top. Run '$ME cap' to see why."
  fi
  say "undo:   $ME revert    (or reboot)"
}

cap() {   # "who is holding the clock down?" - audit every source, then release a pin
  is_root || { say "cap needs root"; return 1; }
  say "== ceiling audit (want: $(top_khz) kHz = the top OPP)"
  cap_sources
  pin_release
  case $? in
    0) say "released a stale fix_target_opp_index pin - re-run '$ME reapply' now" ;;
    2) say "nothing pinned: the two nodes above are the only GED-side limits" ;;
  esac
  say "next: $ME reapply   (re-publishes both nodes from the config)"
}

reapply() {   # re-publish the current config to the nodes; no arguments, no guessing
  # "I flashed the update - make it actually take effect." It heals values an older
  # installer left behind, then writes BOTH the hal index and the matching kHz parameter,
  # so a stale cust_upbound_freq / cust_boost_freq cannot survive.
  is_root || { say "reapply needs root"; return 1; }
  _rc=0
  if [ "$MODE" = safer ]; then
    [ -n "$SAFE_INDEX" ] || { SAFE_INDEX=$((TOP_INDEX > 0 ? TOP_INDEX - 1 : 0)); setkey "$CONF" SAFE_INDEX "$SAFE_INDEX"; }
    # 1600000 spelled out is still "the top OPP"; normalise it so a denied ladder agrees.
    case "$CEIL_HZ" in ''|*[!0-9]*) CEIL_HZ=0; setkey "$CONF" CEIL_HZ 0 ;; esac
    [ "$CEIL_HZ" = "$(top_khz)" ] && { CEIL_HZ=0; setkey "$CONF" CEIL_HZ 0; }
    [ "$MIN_HZ" = 390000 ] && { MIN_HZ=790000; setkey "$CONF" MIN_HZ 790000; }
    [ "$CPU_ON" = 0 ] && { CPU_ON=60; setkey "$CONF" CPU_ON 60; }
  fi
  # Legacy 43 C throttle -> the 50 C limit this project ships. Value check, not a regex on
  # a line: the config carries trailing comments, which is why the installer migrations
  # never matched.
  if [ "$TEMP_MAX" = 430 ]; then
    TEMP_MAX=500
    setkey "$CONF" TEMP_MAX 500
    say "heal:   TEMP_MAX 430 -> 500 (the limit is 50 C, not 43 C)"
  fi
  say "config: MODE=$MODE min=$MIN_HZ top=$TOP_HZ sleep=$SLEEP_HZ ceil=$CEIL_HZ temp=$((TEMP_MAX / 10))C"
  # 0. a pinned target OPP overrides BOTH nodes below: release it first or nothing counts
  pin_release
  case $? in
    0) say "heal:   released a stale fix_target_opp_index pin (it freezes every preset)" ;;
    1) say "! could not release the fix_target_opp_index pin"; _rc=1 ;;
  esac
  # 1. the ceiling - the one that silently capped the GPU at 1100 MHz
  _cc=0
  case "$CEIL_HZ" in
    ''|*[!0-9]*) say "! CEIL_HZ is not a number ($CEIL_HZ)"; _rc=1 ;;
    *) ceil_to "$CEIL_HZ"
       case $? in
         0|2) say "ceiling: hal index $(node_val "$N_UPBOUND") / $(node_val "$P_UPBOUND") kHz" ;;
         *)   say "! could not publish the ceiling"; _cc=1; _rc=1 ;;
       esac ;;
  esac
  # A readback that matches the request is not proof the kernel agrees: re-check it from
  # the OUTSIDE (what the driver is willing to hand out), and say it plainly if it differs.
  if [ "$_cc" = 0 ]; then
    _want=$(top_khz); _got=$(node_val "$P_UPBOUND")
    case "$_got" in
      ''|*[!0-9]*) say "! gpu_cust_upbound_freq is unreadable" ;;
      *) if [ "$_got" -lt "$_want" ]; then
           say "! ceiling: asked $_want kHz, kernel kept $_got - a limiter below GED is active"
           say "  $ME cap   lists every source (driver table, limit_table, pin)."
         fi ;;
    esac
  fi
  # 2. the floor, at the end of the ladder this mode rests at
  _frc=1
  if [ "$MODE" = safer ] && ! ladder_available && [ -n "$SAFE_INDEX" ]; then
    # MIN_HZ's index is SAFE_INDEX by definition; offline_index cannot derive it.
    R_IDX=$SAFE_INDEX; R_FREQ=$MIN_HZ
    write_floor
    _frc=$?
    _e=$MIN_HZ
  else
    case "$MODE" in
      floor) _e=$TOP_HZ ;;
      safer) _e=$MIN_HZ ;;
      *)     _e=$SLEEP_HZ ;;
    esac
    floor_to "$_e"
    _frc=$?
  fi
  case $_frc in
    0|2) say "floor:   hal index $(node_val "$N_BOOST") / $(node_val "$P_CUST") kHz" ;;
    *)   say "! could not publish the floor at $(hz_text "$_e")"; _rc=1 ;;
  esac
  # 3. a driver table that is still clipped means a limiter BELOW GED is active: say it
  _t=$(opp_top_khz); _c=$(top_khz)
  if [ -n "$_t" ] && [ "$_t" -lt "$_c" ]; then
    say "! the driver still publishes max $_t kHz (expected $_c): a limiter below GED"
    say "  is active - '$ME status' names it."
  fi
  # 4. wake the running loop so it does not undo any of this on its next tick
  : > "$D/.gpufix.reload" 2>/dev/null
  if [ -n "$CPU_ON" ] && [ "$CPU_ON" -gt 0 ]; then
    say "cpu:     UI work (>${CPU_ON}%) raises the floor too"
  else
    say "cpu:     only GPU load raises the floor (CPU_ON=0)"
  fi
  [ "$_rc" = 0 ] && say "done. '$ME status' shows the live state."
  return $_rc
}

release() {
  is_root || { say "release needs root"; return 1; }
  # "release" means the lowest OPP, and it has to work on a build where /proc is denied:
  # floor_to() knows how to name the bottom of the ladder in both cases.
  floor_to "$SLEEP_HZ"
  _rc=$?
  _now=$(node_val "$N_BOOST")
  case $_rc in
    0) both "floor released to level $_now ($(hz_text "$SLEEP_HZ"))" ;;
    2) say "floor already at level $_now ($(hz_text "$SLEEP_HZ")) - nothing written" ;;
    *) if [ "$_now" = "${R_IDX:-}" ] || { [ -n "$_now" ] && [ "$_now" = "$TOP_INDEX" ]; }; then
         say "floor is at level $_now (the lowest OPP) - nothing to do"
       else
         say "! could not release the floor (custom_boost_gpu_freq reads ${_now:-?})"; return 1
       fi ;;
  esac
}

ceil_to() {   # publishes GED's upper bound: index on the hal node, kHz on the parameter
  # $1 = kHz; 0 = fastest OPP. Sets R_IDX/R_FREQ for the requested value first: on a
  # ladder-unreadable build R_FREQ is 0 (unknown), so a readback compare must not use the
  # stale frequency from an earlier resolve.
  [ -n "$CEIL_HZ" ] || { say "ceiling control disabled (CEIL_HZ empty)"; return 2; }
  _want=$1; _want=$(num_or "$_want" "")        # 0 stays 0: index 0 is the fastest OPP
  if ! ladder_available; then
    _top=$(top_khz)
    case "$_want" in
      0) R_IDX=0; R_FREQ=$_top ;;
      '') say "! CEIL_HZ is not a number"; return 1 ;;
      # CEIL_HZ=1600000 is the top OPP written as a number: on a denied ladder that is
      # still index 0, so accept it instead of refusing the very config we ship.
      *) if [ -n "$_top" ] && [ "$_want" -ge "$_top" ]; then
           R_IDX=0; R_FREQ=$_top
         else
           say "! the ladder is unreadable here, so only a top OPP (CEIL_HZ=0) can be set"
           return 1
         fi ;;
    esac
  else
    resolve_opp "$_want" || return 1
  fi
  _cur=$(node_val "$N_UPBOUND")
  # The index is necessary but NOT sufficient: if the kHz parameter disagrees we must fix
  # it, otherwise GED keeps enforcing the old bound (seen: index 0, param 1100000).
  _pk=$R_FREQ
  { [ -n "$_pk" ] && [ "$_pk" != 0 ]; } || { case "$R_IDX" in 0) _pk=$(top_khz) ;; "$TOP_INDEX") _pk=$(bottom_khz) ;; *) _pk="" ;; esac; }
  if [ "$_cur" = "$R_IDX" ] &&
     { [ -z "$_pk" ] || [ "$(node_val "$P_UPBOUND")" = "$_pk" ]; }; then
    return 2
  fi
  snapshot
  write_node "$N_UPBOUND" "$R_IDX" || return 1
  # Publish the kHz as well, from the configured end of the ladder if the live one is
  # unknown: the hal index alone does not lift GED's real cap on this kernel.
  if [ -n "$_pk" ] && [ "$_pk" != 0 ]; then
    write_node "$P_UPBOUND" "$_pk" 2>/dev/null && return 0
    # The kernel refused the configured top: fall back to what it actually publishes, but
    # never silently - that refusal IS the answer to "why is it still 1100?".
    _cl=$(opp_top_khz)
    if [ -n "$_cl" ] && [ "$_cl" != "$_pk" ] && write_node "$P_UPBOUND" "$_cl" 2>/dev/null; then
      log "ceil: kernel refused $_pk, kept its own top $_cl (limiter below GED)"
      say "! ceil: the kernel refused $_pk kHz and kept $_cl - a limiter caps the GPU"
      return 0
    fi
    return 1
  fi
  return 0
}

revert() {   # restore what snapshot() saved, including a pin we released
  is_root || { say "revert needs root"; return 1; }
  if [ ! -f "$ORIG" ]; then
    say "no snapshot at $ORIG - this script changed nothing. A reboot also restores the kernel defaults."
    return 1
  fi
  _ok=0; _fail=0
  while IFS='=' read -r _k _v; do
    case "$_k" in ''|\#*) continue;; esac
    case "$_v" in ''|*[!0-9]*) continue;; esac
    case "$_k" in
      boost_gpu_enable) _n=$P_BOOST ;;
      gpu_cust_boost_freq) _n=$P_CUST ;;
      custom_boost_gpu_freq) _n=$N_BOOST ;;
      custom_upbound_gpu_freq) _n=$N_UPBOUND ;;
      gpu_cust_upbound_freq) _n=$P_UPBOUND ;;
      fix_target_opp_index) _n=$PIN ;;   # "none" is not numeric: skipped above, see below
      *) continue ;;
    esac
    if write_node "$_n" "$_v"; then _ok=$((_ok + 1)); both "restored $_k=$_v"
    else _fail=$((_fail + 1)); say "! could not restore $_k=$_v ($_n)"; fi
  done < "$ORIG"
  # a snapshot of "none" means the pin was already released; -1 keeps it that way
  _pn=$(sed -n 's/^fix_target_opp_index=//p' "$ORIG" 2>/dev/null)
  [ "$_pn" = "none" ] && { write_node "$PIN" -1 && both "pin kept released"; }
  if [ "$_fail" -eq 0 ]; then
    rm -f "$ORIG"
    say "reverted ($_ok values)."
    log "reverted"
  else
    say "some values did not restore; a reboot will."
  fi
  say "state: boost_gpu_enable=$(node_val "$P_BOOST") custom_boost_gpu_freq=$(node_val "$N_BOOST") gpu_cust_boost_freq=$(node_val "$P_CUST")"
  say "       custom_upbound_gpu_freq=$(node_val "$N_UPBOUND") gpu_cust_upbound_freq=$(node_val "$P_UPBOUND")"
}

run() {   # the adaptive loop
  is_root || { say "run needs root"; return 1; }
  [ -w "$N_BOOST" ] || { say "$N_BOOST is not writable; cannot govern the GPU."; return 1; }
  log "run: mode=$MODE min=$MIN_HZ top=$TOP_HZ load_on=$LOAD_ON hold=$HOLD_S interval=$INTERVAL temp_max=$TEMP_MAX"
  ST=0; LAST=0; _n=0; _hot_logged=0; _last_floor=""
  while :; do
    # Re-read the config every ~15 ticks, or at once when `preset` asked for it -
    # otherwise a running loop would keep its old MODE/TOP_HZ and undo the preset.
    # _n is incremented at the top of the body, so on the first pass it is already 1 and a
    # plain _n % 15 would skip the initial reload; (_n - 1) makes the first tick count as
    # zero and keeps reload, ceiling and pin re-assert on the SAME cadence.
    if [ $(((_n - 1) % 15)) -eq 0 ] || [ -f "$D/.gpufix.reload" ]; then
      rm -f "$D/.gpufix.reload"
      [ -f "$CONF" ] && . "$CONF"
      ST=0; LAST=0   # a new MODE starts fresh; do not inherit a "busy" hold from the old one
      case "$MODE" in adaptive|safer|floor|off) ;; *) MODE=adaptive ;; esac
      MIN_HZ=$(num_or "$MIN_HZ" 390000); TOP_HZ=$(num_or "$TOP_HZ" 1200000)
      SCREEN_OFF_MIN=$(num_or "$SCREEN_OFF_MIN" 1); BAT_MIN=$(num_or "$BAT_MIN" 15)
      SLEEP_HZ=$(num_or "$SLEEP_HZ" 390000); CPU_ON=$(num_or "$CPU_ON" 0)
      SAFE_INDEX=$(num_or "$SAFE_INDEX" "")
      LOAD_ON=$(num_or "$LOAD_ON" 60);   HOLD_S=$(num_or "$HOLD_S" 20)
      TEMP_MAX=$(num_or "$TEMP_MAX" 500); INTERVAL=$(num_or "$INTERVAL" 2)
      [ "$INTERVAL" -ge 1 ] || INTERVAL=1
      if [ "$(num_or "${ENABLED:-0}" 0)" != 1 ]; then
        log "run: ENABLED is no longer 1 -> releasing the floor and exiting"
        resolve_opp "$SLEEP_HZ" && floor_to "$SLEEP_HZ"
        rm -f "$PIDF"; exit 0
      fi
    fi
    _n=$((_n + 1))
    NW=$(now_s)
    read -r _idx _freq _rest 2>/dev/null < "$N_CUR"
    read -r _l _b _i 2>/dev/null < "$N_UTIL"
    LOAD=$(num_or "$_l" 0)
    REASON=""; _hot_new=0; _scr=1; _lowb=0; _cb=0
    # max and safer both need the screen state: max sleeps at the lowest OPP, safer uses it
    # as the lowest rung of its policy.
    if [ "$MODE" = floor ] || [ "$MODE" = safer ]; then
      screen_on || _scr=0
    fi
    if [ "$MODE" = safer ]; then
      low_battery && _lowb=1
      # "whole UI, not only games": the CPU-side of the UI counts as load too, but only
      # while the screen is on - a dark screen must never be kept awake by this.
      [ "$_scr" = 1 ] && { cpu_busy && _cb=1; }
    fi
    if hot; then
      if [ "$_hot_logged" != 1 ]; then
        _hot_new=1; _hot_logged=1
        log "run: battery at $(( $(cat /sys/class/power_supply/battery/temp 2>/dev/null) / 10 )) C (limit $((TEMP_MAX / 10)) C), floor -> $([ "$HOT_HZ" -gt 0 ] && echo "$HOT_HZ" || echo "$SLEEP_HZ") kHz"
      fi
      _res="0 $LAST"; REASON=hot
    else
      _hot_logged=0
      case "$MODE" in
        off)   _res="0 $LAST"; REASON=off ;;
        # max: the top OPP while the screen is on, the lowest OPP while it is off
        floor) if [ "$_scr" = 0 ]; then _res="0 $NW"; REASON=screen-off
               else _res="1 $NW"; REASON=mode; fi ;;
        # safer: the screen being off is an instant release, not a held state; a busy CPU
        # requests the top OPP for exactly the tick it is busy, then HOLD_S keeps it there
        safer) if [ "$_scr" = 0 ]; then _res="0 $NW"
               elif [ "$_cb" = 1 ]; then _res="1 $NW"
               else _res=$(sticky_step "$ST" "$LOAD" "$NW" "$LAST" "$HOLD_S"); fi ;;
        *)     _res=$(sticky_step "$ST" "$LOAD" "$NW" "$LAST" "$HOLD_S") ;;
      esac
    fi
    ST=${_res% *}; LAST=${_res#* }
    case "$ST" in 0|1) ;; *) ST=0 ;; esac
    if [ "$REASON" = hot ]; then
      if [ "$HOT_HZ" -gt 0 ]; then WANT=$HOT_HZ; else WANT=$SLEEP_HZ; fi
    elif [ "$MODE" = safer ]; then
      _pol=$(floor_policy "$ST" "$LOAD" "$_scr" "$([ "$REASON" = hot ] && echo 1 || echo 0)" "$_lowb" "$_cb")
      WANT=${_pol% *}; REASON=${_pol#* }
    else
      WANT=$(pick_target "$ST")
    fi
    # Offline mode (ladder denied to us): use the shell-only index rules. The thermal
    # brake writes TOP_INDEX (44 on MT6789 = slowest OPP = the idle floor) because we
    # cannot name a mid-ladder index there - with a readable ladder HOT_HZ works fully.
    if ! ladder_available; then
      # Any release (idle, screen off, hot, low battery, mode=off) must land on the lowest
      # OPP by name: offline_index maps only 0/'' to the top, everything else needs the
      # ladder. v11.5 left MODE=safer/adaptive pinned at the top after load ended.
      # NOTE: with MIN_HZ above the slowest OPP (MODE=safer's 790 MHz) MIN_HZ is NOT the
      # lowest step any more - the brakes and the dark screen use SLEEP_HZ for that.
      if [ "$REASON" = hot ] || [ "$REASON" = low-battery ] ||
         [ "$REASON" = screen-off ] || [ "$REASON" = off ] || [ "$WANT" = "$SLEEP_HZ" ]; then
        R_IDX=$TOP_INDEX; R_FREQ=$SLEEP_HZ
      elif [ "$WANT" = "$MIN_HZ" ] && [ -n "$SAFE_INDEX" ]; then
        R_IDX=$SAFE_INDEX; R_FREQ=$MIN_HZ
      elif offline_index "$WANT"; then : ; else R_IDX=""; fi
      if [ -n "$R_IDX" ] && { [ "$(node_val "$N_BOOST")" != "$R_IDX" ]; }; then
        if write_floor; then
          log "run(offline): floor -> level $R_IDX ($(hz_text "$R_FREQ")), reason ${REASON:-busy}"
        else
          [ $((_n % 60)) -eq 0 ] && log "run(offline): could not set level $R_IDX; node reads $(node_val "$N_BOOST")"
        fi
      fi
      [ "$MODE" = safer ] && [ -z "$CEIL_HZ" ] && CEIL_HZ=0   # safer always needs the top OPP open
      [ -n "$CEIL_HZ" ] && [ $(((_n - 1) % 15)) -eq 0 ] && ceil_to "$CEIL_HZ" >/dev/null 2>&1
      # a vendor power HAL re-pins after thermal events; a pin would silently
      # override both nodes we just wrote, in every preset.
      [ $(((_n - 1) % 15)) -eq 0 ] && pin_release >/dev/null 2>&1
      sleep "$INTERVAL"
      continue
    fi
    # Always go through floor_to(): it re-reads the node, so a vendor power HAL that
    # rewrites custom_boost_gpu_freq gets corrected on the next tick (exit 2 = no write).
    if resolve_opp "$WANT"; then
      floor_to "$WANT"
      _rc=$?
      if [ "$_rc" = 0 ]; then
        case "$REASON$ST" in
          hot*) [ "$_hot_new" = 1 ] || log "run: too hot -> floor $(hz_text "$R_FREQ") (level $R_IDX)" ;;
          screen-off*) log "run: screen off -> floor $(hz_text "$R_FREQ") (level $R_IDX)" ;;
          low-battery*) log "run: battery low -> floor $(hz_text "$R_FREQ") (level $R_IDX)" ;;
          mode*) log "run: mode=floor -> floor $(hz_text "$R_FREQ") (level $R_IDX)" ;;
          busy*) if [ "$LOAD" -ge "$LOAD_ON" ]; then
                   log "run: GPU load ${LOAD}% -> floor $(hz_text "$R_FREQ") (level $R_IDX), hold ${HOLD_S}s"
                 else
                   log "run: UI busy (CPU) -> floor $(hz_text "$R_FREQ") (level $R_IDX), hold ${HOLD_S}s"
                 fi ;;
          1) log "run: load ${LOAD}% -> floor $(hz_text "$R_FREQ") (level $R_IDX), hold ${HOLD_S}s" ;;
          *) log "run: idle ${LOAD}% -> floor $(hz_text "$R_FREQ") (level $R_IDX)" ;;
        esac
      elif [ $((_n % 60)) -eq 0 ]; then
        log "run: could not set level $R_IDX ($R_FREQ kHz); node reads $(node_val "$N_BOOST")"
      fi
    fi
    [ "$MODE" = safer ] && [ -z "$CEIL_HZ" ] && CEIL_HZ=0   # safer always needs the top OPP open
    [ -n "$CEIL_HZ" ] && [ $(((_n - 1) % 15)) -eq 0 ] && ceil_to "$CEIL_HZ" >/dev/null 2>&1
    # a vendor power HAL re-pins after thermal events; a pin would silently
    # override both nodes we just wrote, in every preset.
    [ $(((_n - 1) % 15)) -eq 0 ] && pin_release >/dev/null 2>&1
    sleep "$INTERVAL"
  done
}

boot() {
  [ "$ENABLED" = 1 ] || { log "boot: ENABLED=0, nothing to do"; exit 0; }
  # single instance without depending on the host module's lib.sh
  if [ -f "$PIDF" ]; then
    _o=$(cat "$PIDF" 2>/dev/null)
    case "$_o" in
      ''|*[!0-9]*) ;;
      *) if [ "$_o" != "$$" ] && kill -0 "$_o" 2>/dev/null &&
            grep -q gpufix "/proc/$_o/cmdline" 2>/dev/null; then
           log "boot: already running (pid $_o)"; exit 0
         fi ;;
    esac
  fi
  echo $$ > "$PIDF"
  until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 3; done
  sleep 20
  log "boot: ENABLED=1 mode=$MODE -> starting governor (pid $$)"
  run
  rm -f "$PIDF"
}

case "$1" in
  ''|status) status ;;
  probe) sample "${2:-$SAMPLE_S}" probe ;;
  verify) sample "${2:-$SAMPLE_S}" verify ;;
  apply) apply "$2" ;;
  ceil) ceil "$2" ;;
  reapply|fix|repair) reapply ;;
  cap|why) cap ;;
  unpin) is_root || { say "unpin needs root"; exit 1; }
         pin_release; case $? in
           0) say "released a stale fix_target_opp_index pin" ;;
           2) say "nothing is pinned (fix_target_opp_index is $(pin_state))" ;;
           *) say "! could not release the pin" ;;
         esac ;;
  preset) shift; preset "$1" ;;
  choose) choose_preset ;;
  release) release ;;
  run) run ;;
  revert) revert ;;
  boot) boot ;;
  help|-h|--help) sed -n '/^# Modes:/,/^# Config:/p' "$0" | sed 's/^# \{0,1\}//;$d' ;;
  *) say "usage: $ME [status|reapply|cap|unpin|probe [s]|apply [hz]|ceil [hz|0]|release|preset safer|boost|max|stock|verify [s]|run|revert|boot]"; exit 2 ;;
esac
