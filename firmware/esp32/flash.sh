#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
    printf 'Usage: bash flash.sh /dev/serial/by-id/YOUR_ESP32\n' >&2
    exit 2
fi
flash_port="$1"
if [[ ! -c "$flash_port" ]]; then
    printf 'Not a serial device: %s\n' "$flash_port" >&2
    exit 1
fi
project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$project_dir"

if ! command -v idf.py >/dev/null 2>&1; then
    idf_dir="${CHAOS_SPARK_IDF_DIR:-${IDF_PATH:-}}"
    if [[ -z "$idf_dir" || ! -f "$idf_dir/export.sh" ]]; then
        printf '%s\n' 'ESP-IDF is not active. Source export.sh or set CHAOS_SPARK_IDF_DIR.' >&2
        exit 1
    fi
    set +u
    source "$idf_dir/export.sh"
    set -u
fi

idf_version="$(idf.py --version)"
[[ "$idf_version" == 'ESP-IDF v6.1'* ]] || {
    printf 'Expected ESP-IDF v6.1; found %s\n' "$idf_version" >&2
    exit 1
}
# Builds as needed and uses generated flash arguments; no erase-flash.
idf.py -DIDF_TARGET=esp32 -p "$flash_port" -b 115200 flash
