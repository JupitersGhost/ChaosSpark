# ChaosSpark Chaosfield firmware 1.3.0

Classic ESP32-D0WD-V3 / NodeMCU 38-pin, 4 MiB flash, GPIO34 pickup plus GPIO35 modular input,
ESP-IDF **v6.1**. This release measures sources before conditioning, combines
all fresh accepted source contributions into an evolving private SHA3-512
pool, and exports conditioned bytes plus aggregate diagnostics.

GPIO34 keeps its existing pickup, source ID 0, 12-bit / 12 dB configuration,
health policy and diagnostics. GPIO35 / ADC1 channel 7 is added as source ID 5,
`aux_gpio35_adc12`, with its own measurements, health checks, driver counters,
startup/recovery and contributions. No pickup-specific firmware setting is
needed for a passive two-conductor humbucker or Jazz single coil.

GPIO35 is always sampled, including when nothing is connected. The firmware
reports pickup presence as **unknown**: a floating input can vary and a connected
pickup can be quiet. A flat stream is quarantined; a stream that passes the
engineering checks may contribute as unqualified supplementary input. No entropy
credit is assigned to either channel. Read [WIRING.md](WIRING.md) before adding
external pickup wiring. With the recommended bias network, an empty socket is
biased near 1.18 V, rather than electrically floating.

The two channels share ADC1 and are sampled sequentially. The target remains
1,000 retained samples/s per channel. Each channel now has a discarded settling
conversion before its retained read; this reduces mux carryover. GPIO34's timing
source still measures only its retained read. The added conversion work can
change observed cadence/timing, so this does not promise bit-identical GPIO34
measurements. Runtime checks must establish the actual rate and available heap.

**Status:** this is an experimental reference implementation, not a certified
entropy source. Historical host-side validation covered the portable core,
mocked production sampling, wire formatter/decoder, monitor/report behavior,
and reference hashes. The original test harness is not part of this repository
snapshot. [VALIDATION.md](VALIDATION.md) records what was checked and what still
requires target and hardware verification.

## Build, flash, and capture

Install ESP-IDF v6.1 for the classic ESP32 target and activate its environment,
then run from this directory:

```bash
bash build.sh
```

If ESP-IDF is installed but not active, set `CHAOS_SPARK_IDF_DIR` to its root
directory. Standard ESP-IDF variables such as `IDF_TOOLS_PATH` remain available.
Close any serial monitor before flashing the connected board:

```bash
bash flash.sh /dev/serial/by-id/YOUR_ESP32
```

Flash uses generated ESP-IDF arguments at 115200 baud, resets the board, and
replaces its running firmware. It does not perform a full flash erase.

A five-minute capture checks acquisition, timing, output and transport:

```bash
bash capture.sh 300 \
  "GPIO34 unchanged; GPIO35 empty for initial v1.3 test"
```

Update the note if the position or wiring changes. Capture creates a private,
unique directory under the user's XDG state directory, displays each five-second
status and its latest conditioned output, and prints a compact report at the
end. The default serial device is `/dev/chaosfield`. Review the most recent log
again with:

```bash
python3 report.py --latest
```

`report.py PATH` reads a specific log, including older v1.1/v1.2 aggregate logs.
It reports malformed/truncated lines, separates session segments, counts
observed completed windows once, and uses a final host summary when present.
It does not open a serial port. It cannot reconstruct omitted samples or
missing windows from summaries.

`CHAOS_SPARK_CHAOSFIELD_PORT`, `CHAOS_SPARK_PYTHON`, and
`CHAOS_SPARK_LOG_DIR` override the capture defaults. The log directory must be
absolute. The monitor requires PySerial; the report tool uses only the Python
standard library. These scripts do not install host packages or services.

Direct monitor options: `--port PORT --seconds 300 --show-conditioned`,
`--json`, `--note TEXT`, `--log PATH`. Log creation is exclusive, mode 0600.
The log contains status, note and host counters, including a final summary;
it contains neither raw sequences nor conditioned payloads. The terminal
shows conditioned payloads when requested. DTR/RTS are requested low before
opening; some USB drivers can still pulse reset on open.

## Sources and acquisition

| ID | Source | Health/hash symbol | Histogram view |
|---|---|---|---|
| 0 | Pickup, GPIO34 / ADC1 channel 6, 12 dB attenuation | Whole 12-bit ADC code | Whole 12-bit code |
| 1 | One `esp_random()` word per capture | Four bytes, little endian | Bytes |
| 2 | ADC call duration at fixed 240 MHz | Full unsigned 32-bit cycle difference | Low 12 bits of that difference |
| 3 | Passive Wi-Fi scan RSSI + 128 | Byte | Byte |
| 4 | Passive BLE observation RSSI + 128 | Byte | Byte |
| 5 | Modular GPIO35 / ADC1 channel 7, 12 dB attenuation | Whole 12-bit ADC code | Whole 12-bit code |

A core-1 sampling task is notified by a 1 ms esp_timer. It performs acquisition
and queues bounded records; a separate core-1 worker measures and hashes;
a core-0 task formats UART output. The sampler uses a fixed phase schedule,
counts elapsed slots it could not sample, and does not synthesize catch-up
samples. CPU frequency is fixed at 240 MHz, power management disabled.
Cycle subtraction handles a single wrap; durations of at least one second
are rejected using a separate wall-clock check. Interrupt time can contribute
to the measured duration. This is an ADC-call timing observation, not a
qualified CPU-jitter entropy generator.

The acquisition queue holds 64 records. Sequence gaps discard partial health
and measurement windows for the four fast streams, discard their unabsorbed
pending contributions, and restart startup checks. Records more than 100 ms
old at processing time are discarded similarly. The report exposes queue
drops, stale discards, skipped sample slots and maximum processing age.
Scheduled slots missed before a capture create no synthetic record; their
absence is reported by the scheduler and inter-sample diagnostics.

Wi-Fi passive scans collect up to 64 RSSI observations with 120 ms/channel
and a 30-second pause between scans. BLE scans use a 30 ms window / 100 ms
interval with duplicate filtering disabled. Wi-Fi does not associate. There
is no network sender, GATT server, SSID/BSSID export or advertisement-payload
export. Wi-Fi records are wiped after extracting RSSI. The bounded RF queue
has a separate drop counter; dropped RF events are not reconstructed.

RNG acquisition requires Wi-Fi started with power save successfully disabled,
or BLE scanning with modem sleep disabled. The conflicting bootloader SAR
noise source is never enabled while acquiring pickup ADC samples. The public
boot session identifier is not an entropy credit or authentication mechanism.

These six observation streams have shared dependencies. RNG, RSSI, timing
and a pickup sitting on the module may all reflect radio activity. They are
not assumed independent and their apparent entropy estimates are not added.
GPIO34 is not rewired by this update. GPIO35 wiring is described separately.
No digital filter is applied to either retained stream.

## Source health and mixing

All valid acquired observations update their preconditioning measurements,
even when their health block fails. Raw observations stay on the ESP32;
there is no raw export mode.

- RCT runs across 512-symbol health-block boundaries: cutoff 6 for RNG bytes,
  64 for other streams.
- APT uses nonoverlapping 512-symbol blocks with the first symbol as reference,
  counting it too: cutoff 32 for RNG bytes, 480 for other streams.
- Two clean blocks establish startup/recovery readiness and are discarded.
  The next clean block can contribute. Sparse Wi-Fi RSSI may take tens of
  minutes to contribute, and much longer to complete an 8192-symbol window.
- At least 80% of either ADC channel's codes <=8 or >=4087 raises a rail warning. This
  warning does not alone reject the block; RCT/APT still apply.
- Invalid symbols, driver faults and source staleness quarantine that source.
  Fast streams expire after 2 seconds; RSSI streams after 45 seconds.
- Thresholds are engineering choices, not calibrated NIST health thresholds.

A source failure discards that source's unabsorbed pending material. Other
sources continue. Previously absorbed influence remains in the private pool;
it is not retroactively removed or counted as new entropy.

Every accepted block is SHA3-512 of `CF1.2/source/512/u32le`, source ID as u64
little endian, and 512 raw values as u32 little endian. Pending SHA3 states
start with `CF1/pending` plus u64 source ID and absorb accepted block digests.
Only observed/accepted data is hashed; padding bytes are never taken from C
struct memory.

Private pool state starts as SHA3-512(`CF1.2/pool/init` || public session).
This publicly derivable initial state has no claimed entropy. Every emission:

1. Requires fresh accepted pending input from at least one ready source.
2. Computes SHA3-512 of `CF1.2/pool/absorb/SHA3-512`, previous private state,
   session, sequence, uptime and previous update count (all counters u64le),
   followed by source ID, pending block count (u64le) and pending digest for
   every fresh contributor, in increasing ID order.
3. Derives output with `CF1.2/pool/output` || mixed digest || sequence (u64le).
4. Derives new private state with `CF1.2/pool/ratchet` || mixed digest || sequence
   (u64le), using a separate SHA3-512 invocation.
5. Consumes those pending blocks once and wipes local intermediate digests.

Pool state is RAM-only and never serialized. It resets on boot. No fresh
accepted input means no output and no state advance. The last public output
is never used as the next private state. This is an experimental combiner,
not a standardized or certified DRBG construction.

All records report `credited_entropy_bits: 0` and `qualification: unqualified`.
Passing these checks does not qualify a source. Conditioning can concentrate
existing unpredictability but does not make predictable input unpredictable.
Availability, observed variation and demonstrated entropy remain separate.

## Measurements and status interpretation

Basic completed windows have 8192 symbols. Shannon and empirical MCV
min-entropy are bits per histogram symbol; `markov_lsb128_plugin_bits_per_bit`
is an empirical most-likely 128-bit path in a first-order LSB model. These
are diagnostics without confidence bounds, not the complete SP 800-90B
non-IID estimation suite. There is no arbitrary five-bit cap or health score.
The natural histogram maxima are 12 bits for ADC/cycle view and 8 for bytes.

**Timing fields require attention:** its histogram, Shannon, empirical MCV
and chi-square use low 12 bits of each cycle difference. RCT/APT, conditioning,
min/max/mean and run lengths use the full 32-bit difference. The LSB Markov
model uses its least significant bit. Wire fields distinguish
`symbol_bits:12`, `raw_symbol_bits:32`, `metric_view:cycles_lsb12`.

`partial_window_provisional` reports a nonmutating partial-window diagnostic
once at least 64 symbols are present. It never changes source acceptance.
`last_window` retains the last complete window with its timestamp, including
through outages. Completed-window age and partial progress are displayed.
A provisional estimate from few samples is not comparable to a full window.

Each ADC channel's diagnostics retain low/interior/high state transitions, first-order
state Markov, run-length bins, lag correlations at 1/2/4/8/16/32 samples,
inter-sample interval min/mean/max, mean absolute code delta, and during/between
Wi-Fi-scan groups. Boundary runs are censored. Undefined correlations are
null. Wi-Fi scanning versus not scanning is not RF-on versus RF-off isolation.
An acquisition gap resets working pickup diagnostics while retaining the
last completed report and its age. Rail clipping does not reveal voltage
outside the ADC range, and firmware cannot supply input bias/protection.

`adc_pair_last_window` reports Pearson correlation at signed lags -16, -8, -1,
0, 1, 8 and 16. The definition is GPIO35[n] versus GPIO34[n-lag], using sequential
retained pairs. Undefined correlations are null; paired windows reset on capture
gaps or either ADC read failure. Mean/max conversion skew and window age are
visible. Low linear correlation does not establish independence.

`pickup_clip_warning` in output records continues to describe GPIO34;
`aux_clip_warning` separately describes GPIO35. Both statuses retain individual
rail counters, current warning flags and source health.

Conditioned output has its own Shannon, empirical MCV, LSB Markov and chi-square
measurements over 8192 bytes successfully queued for UART. At approximately
64 bytes per 500 ms, the first full window takes about 64 seconds of output.
Status exposes progress and age. These output statistics do not measure
unseen private state or prove input entropy. Raw-pool combined entropy is
not estimated by summing per-source numbers.

- `pool_state:streaming`: recently queued output; otherwise
  `waiting_for_fresh_input`. Neither means entropy qualification.
- `source_blocks`: fresh accepted block counts in that particular output.
- `pool_ever_source_mask`: which source IDs have been absorbed since boot;
  history only, not current freshness, independence or entropy assurance.
- `absorbed_blocks`: source blocks consumed by private pool updates, including
  an update whose outgoing packet could not enter the TX queue.
- `contributed_blocks`: blocks contributing to outputs successfully queued
  for UART. The host separately counts received blocks and checks sequences.
- `included_last_output` refers to the last queued output; inspect its age.
- `current_fault_mask` refers to the current health block. `last_fault_mask`
  retains historical fault reasons after recovery. Bits: 1 RCT, 2 APT,
  8 driver/RF, 16 stale, 32 acquisition discontinuity, 64 invalid symbol.
- RCT/APT counters count affected health blocks; gap/driver events also affect
  the general failure count. Historical clipping warnings never reset on
  recovery and do not indicate that the current window is still clipped.
- `minimum_free_heap` is the boot-lifetime heap low-water mark. Sampling rate
  uses captured count and first/last acquisition timestamps, not loop counts.

115200 baud, 8N1. NDJSON envelopes contain `body` and a lowercase IEEE CRC32
of the exact body bytes, including its braces. CRC detects transport damage;
it does not authenticate a sender. Protocol is `chaos-spark-chaosfield/1`,
firmware `1.3.0`, `source_count:6`, mix policy `private-state-fresh-input`. Maximum formatter
buffer is 16384 bytes; monitor line limit is 20000 bytes. Source arrays now have
six entries, with the previous five IDs preserved. Use this bundled monitor;
older monitors or host collectors may reject the six-source v1.3 format.

## Verification record

The original development validation covered source isolation and recovery,
startup, total outage, no replay, retained state, fresh-input requirements,
cycle-count health behavior, provisional metrics, schedule accounting, pickup
diagnostics, CRC framing, and bounded reports. SHA3 boundary and pool vectors
were compared with Python's `hashlib`. The associated host-side test harness is
not included in this repository snapshot, so these are historical results, not
checks a clone can presently reproduce. See [VALIDATION.md](VALIDATION.md) for
the remaining target-build and board-runtime work.

The Raspberry Pi inputs, Ada/SPARK host collector, and forwarding are handled
by the parent ChaosSpark project. Nothing in this firmware feeds the kernel RNG
or assigns cryptographic entropy credit.

## Primary references

- [Espressif RNG](https://docs.espressif.com/projects/esp-idf/en/v6.1/esp32/api-reference/system/random.html)
- [Espressif timer](https://docs.espressif.com/projects/esp-idf/en/v6.1/esp32/api-reference/system/esp_timer.html)
- [Espressif CPU/system APIs](https://docs.espressif.com/projects/esp-idf/en/v6.1/esp32/api-reference/system/misc_system_api.html)
- [NIST SP 800-90B](https://csrc.nist.gov/pubs/sp/800/90/b/final)
