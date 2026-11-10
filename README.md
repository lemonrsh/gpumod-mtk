## X6886 GPU governor - standalone module

This folder is a self-contained Magisk module: **GPU-DVFS-X6886**. It ships the same
`gpufix.sh` as the main patch, but with the adaptive governor switched on by default,
so it can be installed (or removed) on its own, without the FOD/GSI patch and without
touching `/data/adb/fod` config used by the main module.

It is built by `.github/workflows/release.yml` and published as a second release asset,
`GPU-DVFS-X6886-<version>-<sha>.zip`. Nothing here is copied at flash time - the
top-level `gpufix.sh` is the single source of truth, and CI fails if the two drift apart.

### What it changes on the device

Only these kernel nodes, and only while `ENABLED=1`:

| Node | Role | Idle value | Busy value |
|---|---|---|---|
| `/sys/kernel/ged/hal/custom_boost_gpu_freq` | GED boost floor (ladder **index**) | index of `MIN_HZ` (44, 390 MHz) | index of `TOP_HZ` (1200 MHz) |
| `/sys/module/ged/parameters/gpu_cust_boost_freq` | same value in kHz | 390000 | 1200000 |
| `/sys/module/ged/parameters/boost_gpu_enable` | arms the boost path | 1 | 1 |

While awake the ceiling stays at the top OPP (`gpu_cust_upbound_freq` 1600 MHz) and
`gpu_dvfs_enable` is never touched, so inside the window the GPU still scales by demand
and still idles at 390 MHz. The one exception is sleep: with the screen off, `safer`
and `max` pin **both** the floor and the ceiling to 390 MHz (see below).

The governor samples `/sys/kernel/ged/hal/gpu_utilization` every `INTERVAL` s, raises the
floor when load >= `LOAD_ON` %, and holds it for `HOLD_S` s. In `MODE=safer` it also reads
`/proc/stat` and treats a CPU-loaded system (>= `CPU_ON` %) as busy too, so scrolling and
app switching - not just games - reach 1600 MHz; with the screen off, `safer` and `max`
always pin the GPU at `SLEEP_HZ` (390 MHz, floor **and** ceiling) for exactly as long as
the screen stays off. It throttles only at/above `TEMP_MAX` (50 C battery) and works even
where `/proc/gpufreqv2` is unreadable.

### Install / configure

Flash the ZIP. During the flash the installer asks for a profile with the volume keys:
**VOLUME UP = SAFER** (recommended), **VOLUME DOWN = MAX**, no press within 20 s = SAFER.
An unattended flash therefore always lands on SAFER. Config lives in
`/data/adb/gpufix/gpu.conf`.

```sh
M=/data/adb/modules/gpu_dvfs_x6886
su -c "sh $M/gpufix.sh preset safer"  # recommended: top OPP on load, lowest OPP screen-off
su -c "sh $M/gpufix.sh preset max"    # fastest OPP always, whole system (pinned)
su -c "sh $M/gpufix.sh preset stock"  # release the floor
sh $M/gpufix.sh status                # state, live load, floor asked for, plan
su -c "sh $M/gpufix.sh reapply"       # repair the config AND re-publish index + kHz (no args)
su -c "sh $M/gpufix.sh cap"           # both presets stuck? list every ceiling + release a pin
su -c "sh $M/gpufix.sh ceil 0"        # publish the top OPP on GED's upper bound (repairs 1100 MHz)
su -c "sh $M/gpufix.sh release"       # floor to the lowest OPP (390) - works without /proc
sh $M/gpufix.sh help                  # every command
sh $M/gpufix.sh probe 20              # use the phone normally while it runs
su -c "sh $M/gpufix.sh revert"        # undo the nodes (a reboot does too)
```

| preset | mode | floor | ceiling | note |
| --- | --- | --- | --- | --- |
| `safer` | `safer` | **790 MHz rest, 1600 MHz on any GPU *or* CPU work, 390 screen-off** | top OPP awake (`CEIL_HZ=0`), **390 MHz screen-off** | recommended: whole UI stays fast, nothing pinned awake |
| `max` | `floor` | top OPP while the screen is on, 390 MHz with it off | top OPP awake (`CEIL_HZ=0`), **390 MHz screen-off** | floor == ceiling while awake; pinned at 390 in sleep |
| `boost` | `adaptive` | 1200 MHz while busy, 390 idle | unchanged | follows `gpu_utilization`, holds 20 s |
| `stock` | `off` | 390 MHz | unchanged | nothing raised |

**The ceiling is not optional.** GED will not run above `gpu_cust_upbound_freq`, and the
stock value on this device is `1100000`. `safer` therefore publishes `CEIL_HZ=0` (the top
OPP) just like `max`; without it the floor can ask for 1600 MHz and still top out at
1100 MHz. `status` reports it: if the live upper bound is not the top OPP **while the
screen is on** it says the ceiling is capping the GPU and tells you to run `preset safer`
or `ceil 0`.

**Sleep is the only exception.** While the screen is off, both `safer` (with
`SCREEN_OFF_MIN=1`) and `max` pin the floor *and* the ceiling to `SLEEP_HZ` (390 MHz,
the lowest OPP), so the GPU stays at 390 MHz for the whole sleep and nothing that wakes
it can boost it higher. The ceiling is restored to `CEIL_HZ` the tick the screen wakes.
Awake, nothing changes: no state other than screen-off ever lowers the ceiling.

**Screen off rules — not SoC sleep.** The trigger is the panel state, judged from
several sources (framebuffer blank, DSI dpms, backlight brightness, and
`dumpsys power` `mWakefulness`); any trusted "dark" signal wins. That matters on ROMs
whose suspend/doze is unreliable but whose screen still turns off, and on MTK kernels
whose DRM connector keeps reporting `dpms On` with the panel dark (v1.4.2 trusted that
node first, so the pin never engaged and the GPU idled at a mid OPP all night).
While asleep the governor also releases any `fix_target_opp_index` pin every tick,
and `gpu.log` records the node readback on every screen off/on transition.

**And gpuppm must agree (v1.4.4).** The GED nodes are only gpuppm's *FPSGO* limiter
row. On the reporter's ROM a **DEBUG limiter floor at OPP 13 (950 MHz, priority 8)**
outranked the FPSGO sleep ceiling (priority 4) when the window collided, so gpuppm
aligned the ceiling up to 13 and pinned the GPU at 950 MHz all night — with both GED
nodes reading 44/390000. While asleep the governor now also clears any gpuppm limiter
*floor* above the lowest OPP through `/proc/gpufreqv2/limit_table` (`set <id> -3 -1`,
ceiling kept, SEGMENT untouched), and restores the exact saved floors on wake — so
awake arbitration, including whatever set that floor, is unchanged. `gpufix.sh cap`
now prints the real limiter table (id/name/priority/ceiling/floor) and the effective
window from `gpufreq_status` (`ceiling idx 13 (FPSGO), floor idx 13 (DEBUG)`), and
correctly reads this kernel's worded `fix_target_opp_index` node ("fix OPP index: N"
 / "…is disabled") instead of reporting it absent.

**Re-cleared every tick (v1.4.5).** Whatever sets that floor re-sets it some minutes
into a sleep, and v1.4.4 skipped limiters it had already cleared once — so 390 MHz
worked instantly at screen-off and 950 MHz quietly came back later. The guard now
re-clears every tick for the whole sleep (the saved list only remembers the pre-sleep
values for the wake restore; a re-clear is logged at most once per sleep).

### Action button (v1.4.5, volume-key choice since v1.4.6)

The module ships `action.sh`, so the Magisk app shows an **Action** button for it.
Tapping it first **shows the active mode**, then waits 20 s for a volume key:
**VOLUME UP = SAFER, VOLUME DOWN = MAX, no press = keep the active mode**. A changed
choice is applied immediately — no reboot: the preset is written to `gpu.conf` and
published to the nodes at once, the running governor picks it up within a second,
and if the loop was not running yet (fresh flash) it is started in the background.
The result is verified against `gpu.conf` and printed (`ACTIVE mode is now …`), so
a failed apply says so instead of silently doing nothing. The choice persists in
`gpu.conf`, so it also survives the next reboot.

If `/proc/gpufreqv2/*` is unreadable to the shell (some GSIs deny it even to root),
`safer`, `max` and `stock` still work: they write index 0 (the driver's name for the
fastest OPP) or `TOP_INDEX` (default 44 = slowest OPP) to the GED nodes, and the thermal
brake uses `TOP_INDEX` as well. Only `preset boost` needs the ladder, and it refuses
instead of guessing.

**Thermal limit: 50 C, and nothing below it.** `TEMP_MAX=500` is the only throttle point:
below 50 C battery nothing is eased or throttled; at or above it the floor drops to
`HOT_HZ` (default `0` = lowest OPP) until the phone cools. Set `HOT_HZ=900000` to stay
fast-but-safe instead. The loop re-reads the config every ~15 ticks, so edits apply
without a restart.

Remove the module in Magisk to stop it; `uninstall.sh` also restores the nodes.

### Known limits

* The vendor power HAL is free to rewrite `custom_boost_gpu_freq`; if that happens the
  governor simply sets it back on the next tick (that is what the loop is for).
* Where `/proc/gpufreqv2/*` is denied, `gpu_cust_boost_freq` / `gpu_cust_upbound_freq`
  are left holding their old kHz values while the enforced hal indices are 0. GED obeys
  the index, so this only affects the *reported* numbers, never the clock.
* This is still a *floor*: if the GPU never leaves 390 MHz even with the floor raised,
  the cap is elsewhere (firmware `[PPM Ceiling]`, thermal policy) and no write to these
  nodes will help. `gpufix.sh verify` is the honest test.
* Untested on hardware. The OPP index resolution is unit-tested on the host
  (`.github/tests/test_fixes.py`, `GpuHelperTests`).
