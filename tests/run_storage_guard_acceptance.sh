#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="/tmp/lidar-storage-guard-acceptance"
FIXTURE_ROOT="/tmp/lidar-pipeline-acceptance"
SERVER_ROOT="$TEST_ROOT/server"
DATA_ROOT="$TEST_ROOT/data"
FAKE_BIN="$TEST_ROOT/bin"
SERVER_PID=""

cleanup() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

rm -rf "$TEST_ROOT" "$FIXTURE_ROOT"
mkdir -p "$SERVER_ROOT/01_01" "$SERVER_ROOT/02_02" "$SERVER_ROOT/03_03"
mkdir -p "$DATA_ROOT" "$FAKE_BIN" "$FIXTURE_ROOT"

pdal pipeline "$SCRIPT_DIR/fixtures/light-laz-pipeline.json"
pdal pipeline "$SCRIPT_DIR/fixtures/light-laz-finalize.json"

for sector in 01_01 02_02 03_03; do
    cp "$FIXTURE_ROOT/fixture-light.laz" "$SERVER_ROOT/$sector/source.laz"
    (
        cd "$SERVER_ROOT"
        zip -q -r "$sector.zip" "$sector"
    )
done

cp "$SCRIPT_DIR/fake_df_sequence.sh" "$FAKE_BIN/df"
chmod 755 "$FAKE_BIN/df"

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

PATH="$FAKE_BIN:$PATH" \
FAKE_DF_STATE="$TEST_ROOT/df-call-count" \
POTREE_CONVERTER="/opt/potreeconverter-2.1.1/PotreeConverter_linux_x64/PotreeConverter" \
bash "$REPO_DIR/process_all.sh" \
    --grid "$SCRIPT_DIR/fixtures/three-sector-grid.geojson" \
    --download-dir "$DATA_ROOT"

python3 "$SCRIPT_DIR/verify_storage_guard.py" --data-root "$DATA_ROOT"

printf 'Storage guard artifacts: %s\n' "$TEST_ROOT"
