#!/usr/bin/env python3
"""Exercise the class-1 ground-remap trigger on small synthetic LAS files."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import laspy
import numpy as np


REPO_DIR = Path(__file__).resolve().parent.parent
HELPER = REPO_DIR / "remap_unclassified_ground.py"


def create_fixture(path: Path, class1_count: int) -> None:
    class2_count = 17_000
    class12_count = 1_000 if class1_count >= 10_000 else 2_950
    total = class2_count + class1_count + class12_count

    header = laspy.LasHeader(point_format=3, version="1.2")
    header.scales = np.array([0.01, 0.01, 0.01])
    header.offsets = np.array([0.0, 0.0, 0.0])
    las = laspy.LasData(header)

    index = np.arange(total)
    las.x = 1000.2 + (index % 100)
    las.y = 2000.2 + ((index // 100) % 100)
    las.z = np.full(total, 100.0)
    las.classification = np.concatenate(
        [
            np.full(class2_count, 2, dtype=np.uint8),
            np.full(class1_count, 1, dtype=np.uint8),
            np.full(class12_count, 12, dtype=np.uint8),
        ]
    )
    las.write(path)


def run_helper_command(arguments: list[str]) -> dict[str, object]:
    result = subprocess.run(
        [sys.executable, str(HELPER), *arguments],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"helper failed:\nstdout={result.stdout}\nstderr={result.stderr}"
        )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise AssertionError(f"helper did not return JSON: {result.stdout}") from exc


def run_helper(source: Path, output: Path) -> dict[str, object]:
    return run_helper_command([str(source), str(output)])


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="lidar-ground-remap-test-") as root:
        root_path = Path(root)
        affected_source = root_path / "affected.las"
        affected_output = root_path / "affected-remapped.las"
        create_fixture(affected_source, class1_count=12_000)

        affected = run_helper(affected_source, affected_output)
        assert affected["remapped"] is True, affected
        assert affected["class1Points"] == 12_000, affected
        assert affected["class1Share"] > 0.01, affected
        assert affected["groundLikeFraction"] >= 0.80, affected
        assert affected["thresholds"]["minGroundLikeFraction"] == 0.80, affected

        remapped = laspy.read(affected_output)
        assert int((remapped.classification == 1).sum()) == 0
        assert int((remapped.classification == 2).sum()) == 29_000

        unaffected_source = root_path / "unaffected.las"
        unaffected_output = root_path / "unaffected-remapped.las"
        create_fixture(unaffected_source, class1_count=50)

        unaffected = run_helper(unaffected_source, unaffected_output)
        assert unaffected["remapped"] is False, unaffected
        assert not unaffected_output.exists()

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

        xy_source = root_path / "xy-outlier.laz"
        xy_output = root_path / "xy-outlier-filtered.laz"
        header = laspy.LasHeader(point_format=3, version="1.2")
        header.scales = np.array([0.01, 0.01, 0.01])
        header.offsets = np.array([0.0, 0.0, 0.0])
        las = laspy.LasData(header)
        las.x = np.array([505100.0, 505101.0, 505102.0, 519828.96])
        las.y = np.array([6066000.0, 6066001.0, 6066002.0, 6066696.06])
        las.z = np.array([100.0, 100.0, 101.0, 56.57])
        las.classification = np.array([1, 2, 12, 5], dtype=np.uint8)
        las.write(xy_source)

        xy_report = run_helper_command(
            [
                "--rewrite-only",
                str(xy_source),
                str(xy_output),
                "--remove-out-of-sector-xy",
                "--grid-file",
                str(grid_file),
                "--sector-id",
                "61_33",
                "--xy-margin",
                "25",
                "--remap-class1",
            ]
        )
        assert xy_report["inputPoints"] == 4, xy_report
        assert xy_report["outputPoints"] == 3, xy_report
        assert xy_report["removedOutOfSectorXYPoints"] == 1, xy_report
        assert xy_report["remappedClass1Points"] == 1, xy_report

        filtered = laspy.read(xy_output)
        assert len(filtered.points) == 3
        assert int((filtered.classification == 1).sum()) == 0
        assert int((filtered.classification == 2).sum()) == 2
        assert float(filtered.x.max()) < 510025.0

        analysed = run_helper_command(
            [
                "--analyse-only",
                str(xy_source),
                "--remove-out-of-sector-xy",
                "--grid-file",
                str(grid_file),
                "--sector-id",
                "61_33",
                "--xy-margin",
                "25",
            ]
        )
        assert analysed["totalPoints"] == 3, analysed

    print("PASS: class-1 ground-remap trigger selects affected and skips unaffected LAS")


if __name__ == "__main__":
    main()
