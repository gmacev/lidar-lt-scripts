#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="${TMPDIR:-/tmp}/lidar-ground-remap-acceptance"
DATA_ROOT="$TEST_ROOT/data"
GRID_FILE="$TEST_ROOT/grid.geojson"
SOURCE_FILE="$DATA_ROOT/01_01/01_01/source.laz"
POTREE_CONVERTER_BIN="${POTREE_CONVERTER:-/opt/potreeconverter-2.1.1/PotreeConverter_linux_x64/PotreeConverter}"

rm -rf "$TEST_ROOT"
mkdir -p "$(dirname "$SOURCE_FILE")"
trap 'rm -rf "$TEST_ROOT"' EXIT

if [[ ! -x "$POTREE_CONVERTER_BIN" ]]; then
    echo "SKIP: real PotreeConverter not found at $POTREE_CONVERTER_BIN"
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

python3 - "$SOURCE_FILE" <<'PY'
import sys
from pathlib import Path

import laspy
import numpy as np

path = Path(sys.argv[1])
class2_count = 17_000
class1_count = 12_000
class12_count = 1_000
total = class2_count + class1_count + class12_count

header = laspy.LasHeader(point_format=3, version="1.2")
header.scales = np.array([0.01, 0.01, 0.01])
header.offsets = np.array([0.0, 0.0, 0.0])
las = laspy.LasData(header)
index = np.arange(total)
las.x = 1000.2 + (index % 100)
las.y = 2000.2 + ((index // 100) % 100)
las.z = np.full(total, 100.0)
las.intensity = np.full(total, 100, dtype=np.uint16)
las.classification = np.concatenate([
    np.full(class2_count, 2, dtype=np.uint8),
    np.full(class1_count, 1, dtype=np.uint8),
    np.full(class12_count, 12, dtype=np.uint8),
])
las.write(path)
PY

touch "$DATA_ROOT/01_01/.download_complete"

PYTHON_BIN=python3 \
POTREE_CONVERTER="$POTREE_CONVERTER_BIN" \
MIN_FREE_GB=1 \
bash "$REPO_DIR/process_all.sh" \
    --grid "$GRID_FILE" \
    --sector 01_01 \
    --download-dir "$DATA_ROOT"

grep -q $'class1-ground-remap\t01_01' "$DATA_ROOT/pipeline_events.log"
test -s "$DATA_ROOT/01_01/potree_output/metadata.json"
test -s "$DATA_ROOT/01_01/potree_output/octree.bin"
test -s "$DATA_ROOT/01_01/potree_output/hierarchy.bin"
jq -e '.points == 29000' "$DATA_ROOT/01_01/potree_output/metadata.json" >/dev/null

echo "PASS: process_all remapped the affected source before unchanged PDAL/Potree conversion"
