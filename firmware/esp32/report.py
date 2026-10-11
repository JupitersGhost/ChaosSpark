#!/usr/bin/env python3
"""Compact offline review of Chaosfield aggregate JSONL logs; opens no devices."""
import argparse
import json
import math
import os
from pathlib import Path


def number(v):
    return type(v) in (int, float) and math.isfinite(v)


def pretty(v):
    if not number(v):
        return '--'
    return str(v) if type(v) is int else f'{v:.4f}'


class Review:
    def __init__(self):
        self.first = self.last = self.summary = None
        self.statuses = self.bad = self.other = self.sessions = 0
        self.session = None
        self.ranges = {}
        self.window_keys = {}
        self.window_counts = {}
        self.resets = 0

    def range(self, key, value):
        if number(value):
            lo, hi = self.ranges.get(key, (value, value))
            self.ranges[key] = (min(lo, value), max(hi, value))

    def window(self, key, end, m):
        if not isinstance(m, dict) or not m.get('n'):
            return
        # Status repeats the last completed window. Count each observed window
        # once; do not fabricate missing windows between status snapshots.
        token = (self.sessions, end)
        if self.window_keys.get(key) == token:
            return
        self.window_keys[key] = token
        self.window_counts[key] = self.window_counts.get(key, 0) + 1
        for field in ('shannon_bits_per_symbol', 'mcv_plugin_bits_per_symbol',
                      'markov_lsb128_plugin_bits_per_bit', 'rail_fraction'):
            self.range((key, field), m.get(field))

    def add(self, obj):
        if not isinstance(obj, dict):
            self.bad += 1
            return
        if obj.get('type') == 'host_summary':
            self.summary = obj
            return
        if obj.get('type') != 'status':
            self.other += 1
            return
        sources = obj.get('sources')
        if (not isinstance(sources, list) or len(sources) not in (5, 6)
                or any(not isinstance(s, dict) for s in sources)
                or not isinstance(obj.get('session'), str)
                or not number(obj.get('uptime_us'))):
            self.bad += 1
            return
        changed = obj['session'] != self.session
        if changed:
            self.sessions += 1
            self.session = obj['session']
        elif self.last and obj['uptime_us'] < self.last['uptime_us']:
            self.resets += 1
        self.statuses += 1
        if self.first is None:
            self.first = obj
        self.last = obj
        self.range('heap', obj.get('free_heap'))
        for i, s in enumerate(sources):
            self.window(i, s.get('last_window_end_us'), s.get('last_window'))
        progress = obj.get('conditioned_output_progress') or {}
        self.window('output', progress.get('last_window_end_us'),
                    obj.get('conditioned_output_last_window'))

    def span(self, key):
        if key not in self.ranges:
            return '--'
        lo, hi = self.ranges[key]
        return pretty(lo) if lo == hi else f'{pretty(lo)}..{pretty(hi)}'

    def render(self):
        lines = [f'Parsed statuses={self.statuses}; session segments={self.sessions}; '
                 f'invalid/truncated lines={self.bad}; other records={self.other}']
        if self.last is None:
            return '\n'.join(lines + ['No complete status records found.'])
        m = self.last
        lines += [f"Firmware {m.get('firmware', '?')}; last session {m['session']}; "
                  f"last uptime={m['uptime_us']/1e6:.3f}s; pool={m.get('pool_state', '?')}"]
        if self.sessions == 1:
            lines.append(f"Observed uptime span={(m['uptime_us']-self.first['uptime_us'])/1e6:.3f}s; "
                         f'backward timestamps={self.resets}')
        note = m.get('run_note') or (self.summary or {}).get('run_note')
        if note:
            lines.append('Run note: ' + json.dumps(str(note), ensure_ascii=True))
        lines.append('Ranges below cover observed completed windows; final counters are per boot.')
        lines.append(f"Free heap range={self.span('heap')} bytes; lifetime minimum={pretty(m.get('minimum_free_heap'))}")
        acq = m.get('acquisition') or {}
        elapsed = acq.get('last_us', 0)-acq.get('first_us', 0)
        if elapsed > 0:
            rate = (acq.get('captured', 0)-1)*1e6/elapsed
            lines.append(f"Acquisition average={rate:.2f} samples/s; target={acq.get('target_hz', '?')}; "
                         f"CPU={acq.get('cpu_mhz', '?')} MHz")
            for fields in (('skipped_slots', 'max_lateness_us', 'queue_drops'),
                           ('stale_discarded', 'max_processing_age_us', 'timing_invalid', 'rng_unavailable')):
                lines.append('  ' + '; '.join(f'{k}={pretty(acq.get(k))}' for k in fields))
        for fields in (('adc_errors', 'wifi_errors', 'ble_errors'),
                       ('tx_drops', 'radio_queue_drops', 'suppressed_outputs')):
            lines.append('; '.join(f'{k}={pretty(m.get(k))}' for k in fields))
        lines.append(f"Pool updates={pretty(m.get('pool_updates'))}; ever-source mask={pretty(m.get('pool_ever_source_mask'))}; credited bits=0 (unqualified)")
        for i, s in enumerate(m['sources']):
            lines.append(f"{i} {s.get('name', '?')}: {s.get('state', '?')}; "
                         f"active={s.get('active', '?')}; samples={pretty(s.get('samples'))}")
            lines.append(f"  absorbed={pretty(s.get('absorbed_blocks'))}; queued contributions={pretty(s.get('contributed_blocks'))}; "
                         f"RCT/APT failed blocks={pretty(s.get('rct_failed_blocks'))}/{pretty(s.get('apt_failed_blocks'))}; "
                         f"gaps={pretty(s.get('discontinuities'))}")
            lines.append(f"  current fault={pretty(s.get('current_fault_mask'))}; historical fault={pretty(s.get('last_fault_mask'))}; "
                         f"clip warning now={s.get('clip_warning', '?')}; historical warnings={pretty(s.get('clip_warning_blocks'))}")
            lines.append(self.metric_line(i, s.get('metric_view', 'whole_symbol')))
            if not self.window_counts.get(i):
                p = s.get('partial_window_provisional') or {}
                lines.append(f"  Partial symbols={pretty(s.get('partial_metrics_symbols'))}/8192; "
                             f"provisional H/Hmin={pretty(p.get('shannon_bits_per_symbol'))}/{pretty(p.get('mcv_plugin_bits_per_symbol'))}")
        if 'aux_gpio35' in m:
            lines.append('GPIO35: optional generic ADC; pickup presence UNKNOWN (no plug detector).')
            lines.append(f"  GPIO35 ADC errors={pretty(m.get('aux_adc_errors'))}")
            for label, diag in (('GPIO34', m.get('pickup_diagnostics_last_window')),
                                ('GPIO35', m['aux_gpio35'].get('diagnostics_last_window'))):
                if diag:
                    lines.append(f'  {label} latest autocorrelations: ' + ', '.join(
                        f"{d.get('lag_samples')}:{pretty(d.get('pearson_r'))}"
                        for d in diag.get('lag_correlations', [])))
            pair = m.get('adc_pair_last_window') or {}
            if pair:
                lines.append('  GPIO35[n] vs GPIO34[n-lag]: ' + ', '.join(
                    f"{d.get('lag_samples')}:{pretty(d.get('pearson_r'))}"
                    for d in pair.get('correlations', [])))
                lines.append(f"  Pair window end={pretty(pair.get('window_end_us'))} us; "
                             f"sequential mean/max skew={pretty(pair.get('mean_skew_us'))}/"
                             f"{pretty(pair.get('max_skew_us'))} us; independence unproven.")
        lines.append('CONDITIONED OUTPUT:')
        lines.append(self.metric_line('output', 'bytes'))
        progress = m.get('conditioned_output_progress') or {}
        lines.append(f"  Queued bytes={pretty(progress.get('total_queued_bytes'))}; "
                     f"window progress={pretty(progress.get('partial_bytes'))}/8192")
        if self.summary:
            lines.append(f"Monitor end={self.summary.get('end_reason', '?')}; "
                         f"elapsed={pretty(self.summary.get('elapsed_seconds'))}s; "
                         f"trailing partial bytes={pretty(self.summary.get('trailing_partial_bytes'))}")
        else:
            lines.append('No final host summary; reception totals below stop at the last status.')
        host = (self.summary or m).get('host_received') or {}
        lines.append('Host: ' + '; '.join(f'{k}={pretty(host.get(k))}' for k in
                     ('conditioned', 'status', 'bad_crc', 'malformed', 'sequence_discontinuities', 'sessions')))
        lines.append('H/MCV/Markov are empirical diagnostics, not certified entropy estimates.')
        return '\n'.join(lines)

    def metric_line(self, key, view):
        return (f"  {self.window_counts.get(key, 0)} observed completed windows ({view}): "
                f"H={self.span((key, 'shannon_bits_per_symbol'))}; "
                f"Hmin(emp)={self.span((key, 'mcv_plugin_bits_per_symbol'))} bits/symbol; "
                f"Markov(LSB)={self.span((key, 'markov_lsb128_plugin_bits_per_bit'))} bits/bit; "
                f"rail fraction={self.span((key, 'rail_fraction'))}")


def read_log(path):
    review = Review()
    with path.open(encoding='utf-8', errors='replace') as f:
        # A valid aggregate line is <20 KiB. Bound malformed input processing.
        while True:
            line = f.readline(65537)
            if not line:
                break
            if len(line) > 65536:
                review.bad += 1
                while line and not line.endswith('\n'):
                    line = f.readline(65537)
                continue
            if not line.strip():
                continue
            try:
                review.add(json.loads(line))
            except (ValueError, TypeError, RecursionError):
                review.bad += 1
    return review


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('path', nargs='?', type=Path)
    p.add_argument('--latest', action='store_true', help='Use newest .jsonl under the stack logs directory')
    args = p.parse_args()
    if bool(args.path) == args.latest:
        p.error('Supply a log path OR --latest')
    try:
        if args.latest:
            state_home = Path(os.environ.get('XDG_STATE_HOME', str(Path.home()/'.local'/'state')))
            root = Path(os.environ.get(
                'CHAOS_SPARK_LOG_DIR', str(state_home/'chaos-spark'/'chaosfield')))
            args.path = max(root.rglob('*.jsonl'), key=lambda f: f.stat().st_mtime)
        print('Log: ' + str(args.path))
        report = read_log(args.path)
        print(report.render())
        if not report.statuses:
            p.exit(1)
    except (OSError, ValueError) as exc:
        p.exit(1, f'Report: {exc}\n')


if __name__ == '__main__':
    main()
