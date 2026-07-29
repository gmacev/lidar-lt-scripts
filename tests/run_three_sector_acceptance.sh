#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="/tmp/lidar-pipeline-acceptance"
SERVER_ROOT="$TEST_ROOT/server"
DATA_ROOT="$TEST_ROOT/data"
FAILURE_DATA_ROOT="$TEST_ROOT/failure-data"
SERVER_PID=""

cleanup() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

rm -rf "$TEST_ROOT"
mkdir -p \
    "$SERVER_ROOT/01_01" \
    "$SERVER_ROOT/02_02" \
    "$SERVER_ROOT/03_03" \
    "$DATA_ROOT" \
    "$FAILURE_DATA_ROOT"

pdal pipeline "$SCRIPT_DIR/fixtures/heavy-laz-pipeline.json"
pdal pipeline "$SCRIPT_DIR/fixtures/light-laz-pipeline.json"
pdal pipeline "$SCRIPT_DIR/fixtures/heavy-laz-finalize.json"
pdal pipeline "$SCRIPT_DIR/fixtures/light-laz-finalize.json"

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
    --delay 02_02.zip=1 \
    --delay 03_03.zip=8 \
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
    --download-dir "$DATA_ROOT"

python3 "$SCRIPT_DIR/verify_pipeline_events.py" \
    --events "$DATA_ROOT/pipeline_events.log" \
    --succeeded "$DATA_ROOT/succeded_sectors.txt"

if [[ -s "$DATA_ROOT/failed_sectors.txt" ]]; then
    printf 'Unexpected failures:\n' >&2
    cat "$DATA_ROOT/failed_sectors.txt" >&2
    exit 1
fi

POTREE_CONVERTER="$SCRIPT_DIR/fail_second_potree.sh" \
bash "$REPO_DIR/process_all.sh" \
    --grid "$SCRIPT_DIR/fixtures/three-sector-grid.geojson" \
    --download-dir "$FAILURE_DATA_ROOT"

python3 "$SCRIPT_DIR/verify_failure_continuation.py" \
    --data-root "$FAILURE_DATA_ROOT"

printf 'Acceptance artifacts: %s\n' "$TEST_ROOT"
