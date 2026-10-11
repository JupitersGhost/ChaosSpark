#!/usr/bin/env bash
set -euo pipefail
umask 077
project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
log_root="${CHAOS_SPARK_LOG_DIR:-$state_home/chaos-spark/chaosfield}"
python_bin="${CHAOS_SPARK_PYTHON:-python3}"
serial_port="${CHAOS_SPARK_CHAOSFIELD_PORT:-/dev/chaosfield}"
[[ "$log_root" == /* ]] || { printf 'CHAOS_SPARK_LOG_DIR must be absolute.\n' >&2; exit 2; }
if [[ $# -gt 2 ]]; then
    printf 'Usage: bash capture.sh [seconds=300] [run note]\n' >&2
    exit 2
fi
capture_seconds="${1:-300}"
run_note="${2:-placement not recorded}"
[[ "$capture_seconds" =~ ^[0-9]{1,5}$ ]] && (( 10#$capture_seconds >= 1 && 10#$capture_seconds <= 86400 )) || {
    printf 'Duration must be 1..86400 seconds.\n' >&2; exit 2;
}
command -v "$python_bin" >/dev/null 2>&1 || { printf 'Python missing: %s\n' "$python_bin" >&2; exit 1; }
mkdir -p "$log_root"
capture_dir="$(mktemp -d "$log_root/run-XXXXXXXX")"
printf 'Capture directory: %s\n' "$capture_dir"
result=0
"$python_bin" "$project_dir/monitor.py" --port "$serial_port" \
    --seconds "$capture_seconds" --note "$run_note" --show-conditioned \
    --log "$capture_dir/status.jsonl" || result=$?
"$python_bin" "$project_dir/report.py" "$capture_dir/status.jsonl" || {
    [[ "$result" -ne 0 ]] || result=1;
}
exit "$result"
