#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$project_dir"

if ! command -v idf.py >/dev/null 2>&1; then
    idf_dir="${CHAOS_SPARK_IDF_DIR:-${IDF_PATH:-}}"
    if [[ -z "$idf_dir" || ! -f "$idf_dir/export.sh" ]]; then
        printf '%s\n' 'ESP-IDF is not active. Source export.sh or set CHAOS_SPARK_IDF_DIR.' >&2
        exit 1
    fi
    # ESP-IDF shell activation does not promise nounset compatibility.
    set +u
    source "$idf_dir/export.sh"
    set -u
fi

idf_version="$(idf.py --version)"
if [[ "$idf_version" != 'ESP-IDF v6.1'* ]]; then
    printf 'Expected ESP-IDF v6.1; found %s\n' "$idf_version" >&2
    exit 1
fi

idf.py -DIDF_TARGET=esp32 build
