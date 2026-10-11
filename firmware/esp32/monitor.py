#!/usr/bin/env python3
"""ChaosSpark Chaosfield 1.x: CRC-checked summaries. No raw export."""
import argparse
import json
import math
import os
import re
import time
import zlib

SOURCE_NAMES = ('pickup_adc12', 'esp_rng_byte', 'adc_duration_cycles',
                'wifi_rssi_offset128', 'ble_rssi_offset128', 'aux_gpio35_adc12')
MAX_LINE = 20000


def uint(value):
    return type(value) is int and 0 <= value <= (1 << 64) - 1


class Decoder:
    def __init__(self):
        self.counts = dict(conditioned=0, status=0, bad_crc=0, malformed=0,
                           boot_lines=0, nonprotocol_lines=0, sequence_discontinuities=0, sessions=0)
        self.buf = bytearray()
        self.discard_line = False
        self.previous = None
        self.session = None
        self.latest = None
        self.latest_received = None

    def line(self, raw):
        raw = raw.rstrip(b'\r')
        if len(raw) > MAX_LINE:
            self.counts['malformed'] += 1
            return None
        if not raw.startswith(b'{"body":'):
            self.counts['boot_lines'] += 1
            self.counts['nonprotocol_lines'] += 1
            return None
        try:
            body, suffix = raw[8:].rsplit(b',"crc32":', 1)
            claimed = json.loads(b'{"crc32":' + suffix)['crc32']
            if f'{zlib.crc32(body):08x}' != claimed:
                self.counts['bad_crc'] += 1
                return None
            msg = json.loads(body)
            if not isinstance(msg, dict) or msg.get('protocol') != 'chaos-spark-chaosfield/1':
                raise ValueError('protocol')
            if not isinstance(msg.get('session'), str) or not re.fullmatch(r'[0-9a-f]{32}', msg['session']):
                raise ValueError('session')
            if not uint(msg.get('seq')) or not uint(msg.get('uptime_us')):
                raise ValueError('sequence/time')
            count = msg.get('source_count', 5)
            if type(count) is not int or count not in (5, 6):
                raise ValueError('source count')
            kind = msg.get('type')
            if kind == 'conditioned':
                if not isinstance(msg.get('conditioned_hex'), str) or not re.fullmatch(r'[0-9a-f]{128}', msg['conditioned_hex']):
                    raise ValueError('conditioned length')
                used = msg.get('source_blocks')
                if not isinstance(used, list) or len(used) != count or not all(uint(n) for n in used) or not any(used):
                    raise ValueError('contributions')
                if msg.get('algorithm') != 'SHA3-512' or msg.get('credited_entropy_bits') != 0:
                    raise ValueError('unexpected algorithm/credit')
                if msg.get('mix_policy') == 'private-state-fresh-input':
                    mask = msg.get('pool_ever_source_mask')
                    if not uint(mask) or mask >= (1 << count) or not uint(msg.get('pool_updates')) or not msg['pool_updates']:
                        raise ValueError('pool metadata')
                    if any(n and not mask & (1 << i) for i, n in enumerate(used)):
                        raise ValueError('pool contributor mask')
            elif kind == 'status':
                sources = msg.get('sources')
                if not isinstance(sources, list) or len(sources) != count or any(not isinstance(s, dict) for s in sources):
                    raise ValueError('sources')
            else:
                raise ValueError('type')
            if msg['session'] != self.session:
                self.session = msg['session']
                self.previous = None
                self.latest = None
                self.latest_received = None
                self.counts['sessions'] += 1
            if kind == 'conditioned':
                if self.previous is not None and msg['seq'] != self.previous + 1:
                    self.counts['sequence_discontinuities'] += 1
                self.previous = msg['seq']
                self.latest = msg
                self.latest_received = time.monotonic()
            self.counts[kind] += 1
            return msg
        except (ValueError, KeyError, TypeError, RecursionError):
            self.counts['malformed'] += 1
            return None

    def feed(self, data):
        # Call with bounded transport chunks; oversized records are discarded
        # through their newline so a fragment cannot masquerade as a new frame.
        self.buf.extend(data)
        while b'\n' in self.buf:
            raw, _, rest = self.buf.partition(b'\n')
            self.buf = bytearray(rest)
            if self.discard_line:
                self.discard_line = False
                continue
            msg = self.line(raw)
            if msg is not None:
                yield msg
        if len(self.buf) > MAX_LINE:
            self.counts['malformed'] += 1
            self.buf.clear()
            self.discard_line = True


def fmt(value, places=3):
    return f'{value:.{places}f}' if isinstance(value, (int, float)) and math.isfinite(value) else '--'


def metrics_text(m):
    if not isinstance(m, dict):
        return 'window accumulating'
    return (f"H={fmt(m.get('shannon_bits_per_symbol'))} "
            f"Hmin(emp)={fmt(m.get('mcv_plugin_bits_per_symbol'))} bits/symbol; "
            f"Markov(LSB)={fmt(m.get('markov_lsb128_plugin_bits_per_bit'))} bits/bit; "
            f"chi2={fmt(m.get('chi_square_uniform'), 1)}; n={m.get('n', '?')}")


def status_text(msg, decoder, show_conditioned=False):
    lines = [f"\nChaosSpark Chaosfield {msg.get('firmware', '?')} | uptime {msg['uptime_us']/1e6:.1f}s | "
             f"pool {msg.get('pool_state', 'legacy status')}",
             f"Received {decoder.counts['conditioned']} conditioned blocks / "
             f"{decoder.counts['conditioned']*64} bytes this monitor run | credited entropy: 0 (unqualified)"]
    if 'pool_ever_source_mask' in msg:
        names = [s.get('name', '?') for s in msg['sources']]
        retained = [n for i, n in enumerate(names) if msg['pool_ever_source_mask'] & (1 << i)]
        lines.append('  Sources absorbed this boot: ' + (', '.join(retained) or 'none yet'))
        lines.append('  This is contribution history; independence and entropy remain unqualified.')
    acq = msg.get('acquisition')
    if isinstance(acq, dict):
        elapsed = acq.get('last_us', 0) - acq.get('first_us', 0)
        rate = (acq.get('captured', 0) - 1) * 1e6 / elapsed if elapsed > 0 else 0
        lines.append(f"  Acquisition: {rate:.1f} samples/s average; skipped slots={acq.get('skipped_slots', '?')}; "
                     f"queue drops={acq.get('queue_drops', '?')}; stale discarded={acq.get('stale_discarded', '?')}")
        lines.append(f"  Heap: {msg.get('free_heap', '?')} bytes free; lifetime minimum={msg.get('minimum_free_heap', '?')}; "
                     f"ADC/WiFi/BLE errors={msg.get('adc_errors', '?')}/{msg.get('wifi_errors', '?')}/{msg.get('ble_errors', '?')}")
    for source in msg['sources']:
        state = source.get('state', 'ready' if source.get('active') else 'not_ready')
        flags = []
        if source.get('clip_warning'):
            flags.append('rail warning in latest health block')
        if source.get('included_last_output'):
            flags.append('fresh input in last output')
        if not source.get('active'):
            flags.append(f"startup needs {source.get('startup_clean_samples_remaining', '?')} clean samples")
        lines.append(f"  {source.get('name', '?')}: {state}; " + '; '.join(flags))
        last = source.get('last_window')
        preview = source.get('partial_window_provisional')
        end = source.get('last_window_end_us', 0)
        if last:
            age = max(0, msg['uptime_us'] - end) / 1e6 if end else 0
            lines.append(f"    Last completed window (age {age:.1f}s): {metrics_text(last)}")
        elif preview:
            lines.append('    PROVISIONAL partial window: ' + metrics_text(preview))
        else:
            lines.append('    window accumulating')
        if source.get('metric_view') == 'cycles_lsb12':
            lines.append('    Histogram: cycle-count low 12 bits; health/hash: full 32-bit duration.')
        lines.append(f"    Metric progress={source.get('partial_metrics_symbols', '?')}/8192; "
                     f"contributed blocks={source.get('contributed_blocks', '?')}; "
                     f"RCT/APT failed blocks={source.get('rct_failed_blocks', '?')}/{source.get('apt_failed_blocks', '?')}; "
                     f"historical rail warnings={source.get('clip_warning_blocks', '?')}")
        if 'absorbed_blocks' in source:
            last_absorbed = source.get('last_absorbed_us', 0)
            age = f"{max(0, msg['uptime_us']-last_absorbed)/1e6:.1f}s" if last_absorbed else 'never'
            lines.append(f"    Pool absorbed blocks={source['absorbed_blocks']}; last absorption age={age}; "
                         f"acquisition gaps={source.get('discontinuities', '?')}")
    diag = msg.get('pickup_diagnostics_last_window')
    if isinstance(diag, dict):
        lines.append(f"  Pickup low/high fractions: {fmt(diag.get('low_fraction'))}/{fmt(diag.get('high_fraction'))}; "
                     f"state Markov={fmt(diag.get('state_markov128_plugin_bits_per_symbol'))} bits/state")
        lines.append('  Pickup lag correlations: ' + ', '.join(
            f"{d.get('lag_samples')}:{fmt(d.get('pearson_r'))}" for d in diag.get('lag_correlations', [])))
        lines.append(f"  Pickup run maxima [low, interior, high]: {diag.get('longest_run_samples', [])} samples; "
                     f"sampling interval mean={fmt(diag.get('interval_us', {}).get('mean'), 1)} us")
    aux = msg.get('aux_gpio35')
    if isinstance(aux, dict):
        lines.append('  GPIO35: generic optional ADC; pickup presence unknown; no automatic detection.')
        lines.append(f"  GPIO35 ADC errors={msg.get('aux_adc_errors', '?')}")
        diag = aux.get('diagnostics_last_window') or {}
        lines.append('  GPIO35 lag correlations: ' + ', '.join(
            f"{v.get('lag_samples')}:{fmt(v.get('pearson_r'))}" for v in diag.get('lag_correlations', [])))
        pair = msg.get('adc_pair_last_window') or {}
        if pair:
            lines.append('  GPIO35 vs GPIO34 correlations (signed sample lag): ' + ', '.join(
                f"{v.get('lag_samples')}:{fmt(v.get('pearson_r'))}" for v in pair.get('correlations', [])))
            lines.append(f"  Sequential channel skew mean={fmt(pair.get('mean_skew_us'))} us; "
                         'shared ADC/environment; independence not established.')
    progress = msg.get('conditioned_output_progress', {})
    lines.append('  CONDITIONED: ' + metrics_text(msg.get('conditioned_output_last_window')))
    lines.append(f"  Output window: {progress.get('partial_bytes', '?')}/{progress.get('target_bytes', 8192)} bytes; "
                 f"completed windows={progress.get('completed_windows', '?')}")
    end = progress.get('last_window_end_us', 0)
    if isinstance(end, int) and end:
        lines.append(f"  Last output statistics window age: {(msg['uptime_us']-end)/1e6:.1f}s")
    latest = decoder.latest
    if latest:
        source_names = [source.get('name', '?') for source in msg['sources']]
        contributing = [f'{name}({n})' for name, n in zip(source_names, latest['source_blocks']) if n]
        age = max(0, (msg['uptime_us']-latest['uptime_us'])/1e6)
        lines.append(f"  Last received output seq={latest['seq']}, age={age:.1f}s: " + ', '.join(contributing))
        if show_conditioned:
            lines.append('  SHA3-512: ' + latest['conditioned_hex'])
    else:
        lines.append('  No conditioned block received yet in this session.')
    lines.append(f"  Transport: bad CRC={decoder.counts['bad_crc']}, malformed={decoder.counts['malformed']}, "
                 f"sequence gaps/repeats={decoder.counts['sequence_discontinuities']}")
    return '\n'.join(lines)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port', required=True)
    p.add_argument('--note', help='Optional placement/run description stored in each aggregate log record')
    p.add_argument('--seconds', type=int, default=120)
    p.add_argument('--show-conditioned', action='store_true', help='Show the latest 64-byte conditioned block at each status update')
    p.add_argument('--json', action='store_true', help='Show complete status and host counters as JSON')
    p.add_argument('--log', help='Create a private JSONL file of status/aggregate measurements; must not already exist')
    args = p.parse_args()
    if not 1 <= args.seconds <= 86400:
        p.error('--seconds must be between 1 and 86400')
    if args.note and len(args.note) > 512:
        p.error('--note must be at most 512 characters')
    import serial
    decoder = Decoder()
    logfile = None
    s = serial.Serial(port=None, baudrate=115200, timeout=0.2, exclusive=True)
    s.dtr = False
    s.rts = False
    s.port = args.port
    last_record = time.monotonic()
    started = last_record
    end_reason = 'completed'
    try:
        if args.log:
            logfile = os.fdopen(os.open(args.log, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w')
        s.open()
        deadline = time.monotonic() + args.seconds
        print('Listening at 115200 baud. Raw samples remain on the ESP32.', flush=True)
        while time.monotonic() < deadline:
            for msg in decoder.feed(s.read(4096)):
                last_record = time.monotonic()
                if msg['type'] != 'status':
                    continue
                record = dict(msg, host_received=dict(decoder.counts),
                              host_received_conditioned_bytes=decoder.counts['conditioned']*64)
                if args.note:
                    record['run_note'] = args.note
                if logfile:
                    logfile.write(json.dumps(record, separators=(',', ':')) + '\n')
                    logfile.flush()
                if args.json:
                    if args.show_conditioned and decoder.latest:
                        record['host_latest_conditioned'] = decoder.latest
                    print(json.dumps(record, indent=2), flush=True)
                else:
                    print(status_text(msg, decoder, args.show_conditioned), flush=True)
            if time.monotonic()-last_record > 10:
                print('No valid frame for 10 seconds; checking serial stream...', flush=True)
                last_record = time.monotonic()
    except KeyboardInterrupt:
        end_reason = 'interrupted'
    except (OSError, serial.SerialException) as exc:
        end_reason = 'serial_or_log_error'
        p.exit(1, f'Monitor: {exc}\n')
    finally:
        s.close()
        summary = dict(type='host_summary', host_received=dict(decoder.counts),
                       host_received_conditioned_bytes=decoder.counts['conditioned']*64,
                       elapsed_seconds=round(time.monotonic()-started, 3),
                       end_reason=end_reason, trailing_partial_bytes=len(decoder.buf),
                       run_note=args.note)
        if logfile:
            logfile.write(json.dumps(summary, separators=(',', ':')) + '\n')
            logfile.close()
        print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
