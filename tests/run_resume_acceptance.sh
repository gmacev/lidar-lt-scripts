#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/lidar-resume-acceptance.XXXXXXXX)"
DATA_ROOT="$TEST_ROOT/data"

cleanup() {
    case "$TEST_ROOT" in
        /tmp/lidar-resume-acceptance.*)
            rm -rf -- "$TEST_ROOT"
            ;;
        *)
            printf 'Refusing to clean unexpected test path: %s\n' "$TEST_ROOT" >&2
            ;;
    esac
}
trap cleanup EXIT

make_complete_output() {
    local sector_id="$1"
    local output_dir="$DATA_ROOT/$sector_id/potree_output"

    mkdir -p "$output_dir"
    printf '{}\n' > "$output_dir/metadata.json"
    printf 'octree\n' > "$output_dir/octree.bin"
    printf 'hierarchy\n' > "$output_dir/hierarchy.bin"
    printf '[]\n' > "$output_dir/source_manifest.json"
}

mkdir -p "$DATA_ROOT"
make_complete_output "01_01"
make_complete_output "02_02"

printf '2026-08-03T00:00:00Z\t01_01\n' > "$DATA_ROOT/succeded_sectors.txt"
printf '2026-08-03T00:01:00Z\t02_02\n' >> "$DATA_ROOT/succeded_sectors.txt"

before_success_lines="$(wc -l < "$DATA_ROOT/succeded_sectors.txt")"

MIN_FREE_GB=999999999 \
POTREE_CONVERTER="/opt/potreeconverter-2.1.1/PotreeConverter_linux_x64/PotreeConverter" \
bash "$REPO_DIR/process_all.sh" \
    --grid "$SCRIPT_DIR/fixtures/three-sector-grid.geojson" \
    --download-dir "$DATA_ROOT" \
    > "$TEST_ROOT/process-all.log"

after_success_lines="$(wc -l < "$DATA_ROOT/succeded_sectors.txt")"
[[ "$after_success_lines" == "$before_success_lines" ]] || {
    printf 'Success log changed during resume: before=%s after=%s\n' \
        "$before_success_lines" "$after_success_lines" >&2
    exit 1
}

[[ ! -e "$DATA_ROOT/.downloads/03_03.zip" &&
   ! -e "$DATA_ROOT/.downloads/03_03.zip.part" ]] || {
    printf 'Pending sector download started despite forced storage stop\n' >&2
    exit 1
}

grep -q 'Resume scan: 2 complete sector(s) skipped, 1 pending of 3 selected.' \
    "$TEST_ROOT/process-all.log"
grep -q 'existing_complete=2' "$DATA_ROOT/insufficient_storage.txt"
grep -q 'completed_total=2' "$DATA_ROOT/insufficient_storage.txt"
grep -q 'remaining_unfinished=1' "$DATA_ROOT/insufficient_storage.txt"
grep -q $'resume-scan\t-\tselected_total=3; existing_complete=2; pending=1' \
    "$DATA_ROOT/pipeline_events.log"

printf 'PASS: completed outputs were skipped without duplicate success entries.\n'
printf 'PASS: storage stop reported 2 complete and 1 unfinished sector.\n'
