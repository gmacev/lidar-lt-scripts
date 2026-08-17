#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="${TMPDIR:-/tmp}/lidar-bbox-repair-acceptance"
DATA_DIR="$TEST_ROOT/data"
GRID_FILE="$TEST_ROOT/grid.geojson"
FAKE_CONVERTER="$TEST_ROOT/fake-potree-converter.sh"
REAL_CONVERTER="${REAL_POTREE_CONVERTER:-/opt/potreeconverter-2.1.1/PotreeConverter_linux_x64/PotreeConverter}"

rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT" "$DATA_DIR/01_01/01_01"
trap 'rm -rf "$TEST_ROOT"' EXIT

if [[ ! -x "$REAL_CONVERTER" ]]; then
    echo "SKIP: real PotreeConverter not found at $REAL_CONVERTER"
    exit 0
fi

cat > "$GRID_FILE" <<'EOF'
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "properties": {
        "id": "01_01",
        "url": "http://unused.invalid/01_01.zip"
      },
      "geometry": null
    }
  ]
}
EOF

cat > "$TEST_ROOT/create-fixture.json" <<EOF
[
  {
    "type": "readers.faux",
    "bounds": "([0, 10], [0, 10], [0, 10])",
    "count": 1000,
    "mode": "ramp"
  },
  {
    "type": "writers.las",
    "filename": "$DATA_DIR/01_01/01_01/fixture.laz",
    "compression": "laszip",
    "minor_version": 4,
    "dataformat_id": 6
  }
]
EOF

pdal pipeline "$TEST_ROOT/create-fixture.json" >/dev/null
touch "$DATA_DIR/01_01/.download_complete"

# Make the LAS header deliberately too small on X.  The point data remains
# unchanged; the production repair helper must expand the header from PDAL's
# actual point statistics.
python3 - "$DATA_DIR/01_01/01_01/fixture.laz" <<'PY'
import struct
import sys

path = sys.argv[1]
with open(path, "r+b") as stream:
    stream.seek(179)
    max_x, min_x, max_y, min_y, max_z, min_z = struct.unpack("<6d", stream.read(48))
    stream.seek(179)
    stream.write(struct.pack("<6d", 9.0, min_x, max_y, min_y, max_z, min_z))
PY

cat > "$FAKE_CONVERTER" <<EOF
#!/usr/bin/env bash
set -euo pipefail

state="$TEST_ROOT/converter-attempt"
source_file="\$1"
if [[ ! -e "\$state" ]]; then
    touch "\$state"
    printf 'ERROR: encountered point outside bounding box.\\n'
    printf 'file: %s\\n' "\$source_file"
    exit 1
fi

exec "$REAL_CONVERTER" "\$@"
EOF
chmod 755 "$FAKE_CONVERTER"

GRID_FILE="$GRID_FILE" \
DOWNLOAD_DIR="$DATA_DIR" \
POTREE_CONVERTER="$FAKE_CONVERTER" \
PYTHON_BIN=python3 \
MIN_FREE_GB=1 \
"$SCRIPT_DIR/process_all.sh" \
    --grid "$GRID_FILE" \
    --sector 01_01 \
    --skip-pdal

grep -q $'bbox-repair-triggered\t01_01' "$DATA_DIR/pipeline_events.log"
grep -q $'bbox-repair-end\t01_01' "$DATA_DIR/pipeline_events.log"
[[ -s "$DATA_DIR/01_01/potree_output/metadata.json" ]]
[[ -s "$DATA_DIR/01_01/potree_output/octree.bin" ]]
[[ -s "$DATA_DIR/01_01/potree_output/hierarchy.bin" ]]
grep -q $'\t01_01$' "$DATA_DIR/succeded_sectors.txt"

echo "PASS: Potree bbox failure triggered header-only repair and succeeded on retry"
