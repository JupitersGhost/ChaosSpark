# ChaosSpark Chaosfield 1.3.0 validation record

Date: 2026-09-17 UTC

This is a historical engineering record retained from the firmware development
snapshot. The original host-side test harness is not included in this
repository, and these checks were not rerun as part of the public-source scrub.

## Host checks: passed in the original development snapshot

- Portable core under AddressSanitizer and UndefinedBehaviorSanitizer:
  SHA3/CRC, all six sources surviving/failing independently, startup/recovery,
  no replay, retained private state, stale-source handling, constant GPIO35
  quarantine while GPIO34 contributes, GPIO35 full 12-bit rails, recovery.
- Pair diagnostics: +1/-1 correlation, undefined constant input, wipe/gap
  behavior, known eight-sample lead/lag sign convention and acquisition skew.
- Production sampling function extracted unchanged and exercised against
  fake ADC/RTOS calls: channel order, discarded settling reads, GPIO34-only
  duration, GPIO35 read/setup-result failures, GPIO34 failure, queue drops.
- Production JSON/CRC formatter compiled and decoded by the actual monitor;
  all six source entries, independent aux clipping flag, startup/full windows,
  large counters, no raw/private-state export. Largest test line: 12669 bytes
  including envelope; firmware body buffer 16384, monitor limit 20000.
- Nine SHA3 boundary vectors and two pool outputs/private states match Python
  hashlib. Existing v1.2 pool/hash domains are intentionally unchanged.
- Monitor: 6 cases; report: 3 cases. Covers legacy five-source frames, new
  six-source frames, auxiliary-only outputs, count/mask rejection, CRC,
  fragmentation, bounded input, sequence/session handling, private aggregate
  logs/final summary and GPIO35 presence reported as unknown.
## Target build: not verified in this record

The v1.3 build script was invoked; the required ESP-IDF export.sh is absent
from this execution environment. The previous session's ESP-IDF/toolchain
was not retained. This record therefore does not claim a successful ESP32
target build, binary size, linker fit, flash result, or board runtime. Rebuild
with ESP-IDF v6.1 using `build.sh`; do not infer target success from host tests.

## Hardware runtime: not tested in this record

After a successful target build, check boot, free/minimum heap, sustained
sampling, skipped slots, ADC/aux errors, queue drops and UART continuity in
a five-minute capture with GPIO35 empty. Added per-channel settling reads
and GPIO35 work can change sampling cadence and GPIO34 timing observations;
GPIO34's pickup/wiring, source ID, attenuation, bit width and health policy
remain the same. GPIO34 and GPIO35 share an ADC and physical dependencies.

## Wiring: prototype only

`WIRING.md` provides an unbuilt passive bias/AC-coupling/clamp circuit proposal
for loose passive magnetic pickups. It requires physical assembly and range
verification. No broad sensor compatibility or bench qualification is claimed.

All entropy credits remain zero. Basic health and distribution tests, low
correlation and conditioned output do not establish entropy or independence.
