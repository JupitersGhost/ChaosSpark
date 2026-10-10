# ChaosSpark

ChaosSpark is an experimental entropy observatory for a Raspberry Pi 5. It
collects changing observations from several local sources, evaluates each
source independently, and combines accepted material under deliberately
conservative crediting rules.

It began as a way to understand what these sources were doing over time. It
became a more serious Ada project than I originally expected, so I am publishing
it as a source showcase and a record of the design.

> **Project status:** experimental and intended for study. ChaosSpark is not a
> certified entropy source, a replacement for the operating system RNG, or a
> production security component.

## Overview

The current Raspberry Pi deployment observes:

- the Pi hardware RNG;
- a separately conditioned ESP32 source;
- camera and microphone activity;
- Wi-Fi and Bluetooth observations; and
- thermal, fan, and other timing-oriented system observations.

Every source has its own acquisition window, health state, counters, and
diagnostics. Sources must pass their health gate before they can contribute.
Accepted material is mixed and conditioned with SHA3-512, while a local web
dashboard exposes current state and a short browser-side history.

ChaosSpark can also exchange authenticated CHVS frames over a private network
overlay. Received or already-conditioned material may influence the pool, but
it receives zero new local entropy credit.

## Design principles

- **Source isolation:** one failing source does not silently become another
  source's problem.
- **Health before credit:** warmup, suspect, and quarantined sources do not
  receive normal credit.
- **Conservative accounting:** diagnostic estimates are not treated as proof of
  a certified entropy rate.
- **Explicit provenance:** conditioned and remote inputs retain their origin and
  are not relabeled as fresh local entropy.
- **Observable behavior:** counters, health transitions, rejections, and credit
  decisions are visible in the status output.

## Ada and SPARK scope

The project is written in Ada 2022. `Chaos_Types`, which holds the bounded source
state and health-state transitions, is analyzed with SPARK. The latest proof run
discharged 22 obligations covering initialization, runtime checks, contracts,
and termination in that package.

The statistics, OpenSSL boundary, networking, operating-system integration,
sensor collection, and main loop are Ada but remain outside the current SPARK
proof boundary. The accurate description is therefore “a formally analyzed
core,” not fully verified or certified software.

The detailed comments in `src/` are intentional. They document the reasoning
behind health thresholds, sensor transformations, and entropy-credit decisions.

## ESP32 / Chaosfield firmware

The ESP32 firmware is not included in this repository. A reference firmware
implementation is planned for a separate repository. Until then, existing ESP32
firmware can interoperate by implementing the serial contract below.

### Current serial contract

The host reads the configured Chaosfield serial device at **115200 baud**. The
firmware must emit one compact JSON envelope per line:

```json
{"body":{"protocol":"chaos-spark-chaosfield/1","session":"<32 hex characters>","seq":1,"type":"conditioned","qualification":"unqualified","mix_policy":"private-state-fresh-input","credited_entropy_bits":0,"source_count":6,"algorithm":"SHA3-512","contributor_count":1,"conditioned_hex":"<128 hex characters>"},"crc32":"<8 hex characters>"}
```

Implementation rules, briefly:

1. Create a new 16-byte random session identifier at startup and encode it as
   32 hexadecimal characters.
2. Health-test the ESP32's raw inputs locally, then produce a 64-byte SHA3-512
   conditioned block from the accepted contributors.
3. Increment `seq` for each conditioned frame. Repeated or decreasing sequence
   numbers are rejected; gaps are accepted but recorded.
4. Keep `qualification` as `unqualified`, `credited_entropy_bits` as `0`, and
   `mix_policy` as `private-state-fresh-input`. The Pi treats this input as
   influence, not newly certified local entropy.
5. The current host contract expects `source_count` to be `6` and
   `contributor_count` to be between `1` and `6`.
6. Serialize the inner `body` object compactly. Calculate standard IEEE CRC-32
   over the exact UTF-8 bytes of that serialized object, including its braces.
   Place the eight-digit hexadecimal CRC in the outer envelope and terminate the
   frame with a newline.

Status frames use the same common fields with `type` set to `status`; they do
not need `algorithm`, `contributor_count`, or `conditioned_hex`.

The protocol name and field rules above are the compatibility boundary for the
future firmware repository. If they change, both ends should change together.

## Reference system

The current installation uses the following host platform:

| Component | Configuration |
| --- | --- |
| Host | Raspberry Pi 5 with 4 GB RAM |
| Operating system | Void Linux |
| OS and storage | USB flash drive |
| Enclosure and cooling | Fan-cooled Raspberry Pi case purchased through Amazon; exact model not recorded |

The Makefile also reflects the attached hardware and device paths on this
system. These values are deployment examples, not general requirements:

- Raspberry Pi hardware RNG at `/dev/hwrng`.
- CP2102-based Chaosfield ESP32 (`10c4:ea60`) with example serial `0001`.
- Adesso CyberTrack H4 video and audio interfaces (`0c45:636b`).
- Camera at `/dev/video0`, audio at `plughw:CARD=H4,DEV=0`, and Wi-Fi on
  `wlan0`.
- Raspberry Pi-specific thermal and hwmon paths under `/sys/class`.

USB serials, ALSA card names, interfaces, and hwmon numbering vary between
machines. Most device names can be changed with `CHAOS_SPARK_*` environment
variables. The udev rules and hwmon paths should still be reviewed for the
actual target.

## Building

The build requires GNAT with Ada 2022 support and the OpenSSL 3 development
libraries. GNATprove is additionally required for proof analysis.

```sh
make build
make prove
```

Build products and GNATprove working files are intentionally excluded from the
repository.

## Deployment note

`make install-service` describes one runit-based deployment. It creates a
service user, state and log directories, a CHVS key, udev rules, and files under
`/etc`. It should be read and adapted before use.

Keys, peer lists, tailnet names, hostnames, and deployment addresses are runtime
configuration and are not included here. The example service discovers a
private-overlay address with the Tailscale client and otherwise binds to
`127.0.0.1`.

## Repository layout

```text
chaos_spark.gpr  GNAT project definition
Makefile         build, proof, and example deployment targets
src/             Ada and SPARK source
web/             local status dashboard
```

## License

ChaosSpark is available under the Apache License 2.0. See `LICENSE` for the full
terms.
