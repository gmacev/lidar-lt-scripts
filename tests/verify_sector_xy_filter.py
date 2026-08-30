#!/usr/bin/env python3
"""Exercise the independent sector XY filtering helper."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import laspy
import numpy as np


REPO_DIR = Path(__file__).resolve().parent.parent
HELPER = REPO_DIR / "filter_laz_to_sector.py"


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="lidar-sector-xy-test-") as root:
        root_path = Path(root)
        grid_file = root_path / "grid.geojson"
        grid_file.write_text(
            json.dumps(
                {
                    "type": "FeatureCollection",
                    "features": [
                        {
                            "type": "Feature",
                            "properties": {"id": "61/33"},
                            "geometry": {
                                "type": "Polygon",
                                "coordinates": [
                                    [
                                        [24.07769681037245, 54.76627274319426],
                                        [24.15539338243744, 54.766198102392636],
                                        [24.155221501004316, 54.72127324091781],
                                        [24.07761086920854, 54.721347758400746],
                                        [24.07769681037245, 54.76627274319426],
                                    ]
                                ],
                            },
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

        source = root_path / "xy-outlier.las"
        output = root_path / "xy-filtered.las"
        header = laspy.LasHeader(point_format=3, version="1.2")
        header.scales = np.array([0.01, 0.01, 0.01])
        header.offsets = np.array([0.0, 0.0, 0.0])
        las = laspy.LasData(header)
        las.x = np.array([505100.0, 505101.0, 505102.0, 519828.96])
        las.y = np.array([6066000.0, 6066001.0, 6066002.0, 6066696.06])
        las.z = np.array([100.0, 100.0, 101.0, 56.57])
        las.classification = np.array([1, 2, 12, 5], dtype=np.uint8)
        las.write(source)

        result = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--grid-file",
                str(grid_file),
                "--sector-id",
                "61_33",
                "--xy-margin",
                "25",
                str(source),
                str(output),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"helper failed:\nstdout={result.stdout}\nstderr={result.stderr}"
            )

        report = json.loads(result.stdout)
        assert report["inputPoints"] == 4, report
        assert report["outputPoints"] == 3, report
        assert report["removedOutOfSectorXYPoints"] == 1, report

        filtered = laspy.read(output)
        assert len(filtered.points) == 3
        assert list(np.asarray(filtered.classification)) == [1, 2, 12]
        assert float(filtered.x.max()) < 510025.0

    print("PASS: sector XY filter removes only the out-of-envelope record")


if __name__ == "__main__":
    main()
