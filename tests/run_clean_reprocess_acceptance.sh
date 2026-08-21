#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="/tmp/lidar-clean-reprocess-acceptance"
SERVER_ROOT="$TEST_ROOT/server"
DATA_ROOT="$TEST_ROOT/data"
SERVER_PID=""

cleanup() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

rm -rf "$TEST_ROOT"
mkdir -p \
    "$SERVER_ROOT/01_01" \
    "$SERVER_ROOT/02_02" \
    "$SERVER_ROOT/03_03" \
    "$DATA_ROOT"

sed "s#/tmp/lidar-pipeline-acceptance#$TEST_ROOT#g" \
    "$SCRIPT_DIR/fixtures/heavy-laz-pipeline.json" > "$TEST_ROOT/heavy-laz-pipeline.json"
sed "s#/tmp/lidar-pipeline-acceptance#$TEST_ROOT#g" \
    "$SCRIPT_DIR/fixtures/light-laz-pipeline.json" > "$TEST_ROOT/light-laz-pipeline.json"
sed "s#/tmp/lidar-pipeline-acceptance#$TEST_ROOT#g" \
    "$SCRIPT_DIR/fixtures/heavy-laz-finalize.json" > "$TEST_ROOT/heavy-laz-finalize.json"
sed "s#/tmp/lidar-pipeline-acceptance#$TEST_ROOT#g" \
    "$SCRIPT_DIR/fixtures/light-laz-finalize.json" > "$TEST_ROOT/light-laz-finalize.json"

pdal pipeline "$TEST_ROOT/heavy-laz-pipeline.json"
pdal pipeline "$TEST_ROOT/light-laz-pipeline.json"
pdal pipeline "$TEST_ROOT/heavy-laz-finalize.json"
pdal pipeline "$TEST_ROOT/light-laz-finalize.json"

cp "$TEST_ROOT/fixture-heavy.laz" "$SERVER_ROOT/01_01/source.laz"
cp "$TEST_ROOT/fixture-light.laz" "$SERVER_ROOT/02_02/source.laz"
cp "$TEST_ROOT/fixture-light.laz" "$SERVER_ROOT/03_03/source.laz"

(
    cd "$SERVER_ROOT"
    zip -q -r 01_01.zip 01_01
    zip -q -r 02_02.zip 02_02
    zip -q -r 03_03.zip 03_03
)

python3 "$SCRIPT_DIR/slow_http_server.py" \
    --root "$SERVER_ROOT" \
    --port 18765 \
    > "$TEST_ROOT/http-server.log" 2>&1 &
SERVER_PID=$!

for _ in {1..50}; do
    if curl -fsS -o /dev/null "http://127.0.0.1:18765/01_01.zip"; then
        break
    fi
    sleep 0.1
done
kill -0 "$SERVER_PID"

POTREE_CONVERTER="/opt/potreeconverter-2.1.1/PotreeConverter_linux_x64/PotreeConverter" \
bash "$REPO_DIR/process_all.sh" \
    --grid "$SCRIPT_DIR/fixtures/three-sector-grid.geojson" \
    --download-dir "$DATA_ROOT" \
    > "$TEST_ROOT/initial.log"

initial_success_lines="$(wc -l < "$DATA_ROOT/succeded_sectors.txt")"
[[ "$initial_success_lines" == 3 ]] || {
    printf 'Expected 3 initial success entries, got %s\n' "$initial_success_lines" >&2
    exit 1
}

printf 'stale marker\n' > "$DATA_ROOT/01_01/stale-marker.txt"
cat > "$TEST_ROOT/reprocess-list.csv" <<'EOF'
INDEKSAS,PAVAD,LIDAR_LAZ
01/01,fixture,http://127.0.0.1:18765/01_01.zip
02/02,fixture,http://127.0.0.1:18765/02_02.zip
EOF

POTREE_CONVERTER="/opt/potreeconverter-2.1.1/PotreeConverter_linux_x64/PotreeConverter" \
bash "$REPO_DIR/process_all.sh" \
    --grid "$SCRIPT_DIR/fixtures/three-sector-grid.geojson" \
    --sector-list "$TEST_ROOT/reprocess-list.csv" \
    --reprocess \
    --download-dir "$DATA_ROOT" \
    > "$TEST_ROOT/reprocess.log"

grep -q 'Clean reprocess scan: 2 explicitly selected sector(s) will be rebuilt.' \
    "$TEST_ROOT/reprocess.log"
grep -q $'reprocess-scan\t-\tselected_total=2; pending=2; existing_complete=0' \
    "$DATA_ROOT/pipeline_events.log"
grep -q $'reprocess-clean-start\t01_01' "$DATA_ROOT/pipeline_events.log"
grep -q $'reprocess-clean-start\t02_02' "$DATA_ROOT/pipeline_events.log"
[[ ! -e "$DATA_ROOT/01_01/stale-marker.txt" ]] || {
    printf 'Reprocess did not remove stale sector state\n' >&2
    exit 1
}

for sector in 01_01 02_02; do
    for file in metadata.json octree.bin hierarchy.bin source_manifest.json; do
        [[ -s "$DATA_ROOT/$sector/potree_output/$file" ]] || {
            printf 'Missing reprocessed output: %s/%s\n' "$sector" "$file" >&2
            exit 1
        }
    done
done

after_success_lines="$(wc -l < "$DATA_ROOT/succeded_sectors.txt")"
[[ "$after_success_lines" == 3 ]] || {
    printf 'Reprocess duplicated success entries: before=3 after=%s\n' \
        "$after_success_lines" >&2
    exit 1
}

if POTREE_CONVERTER="/opt/potreeconverter-2.1.1/PotreeConverter_linux_x64/PotreeConverter" \
    bash "$REPO_DIR/process_all.sh" \
        --grid "$SCRIPT_DIR/fixtures/three-sector-grid.geojson" \
        --reprocess \
        --download-dir "$DATA_ROOT" \
        > "$TEST_ROOT/missing-selection.log" 2>&1; then
    printf -- '--reprocess unexpectedly allowed the entire grid\n' >&2
    exit 1
fi
grep -q -- '--reprocess requires --sector or --sector-list' \
    "$TEST_ROOT/missing-selection.log"

printf 'PASS: selected complete sectors were cleanly deleted and reprocessed.\n'
printf 'PASS: CSV sector-list input worked and success log remained deduplicated.\n'
printf 'PASS: --reprocess refused an unbounded whole-grid operation.\n'
