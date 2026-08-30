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

    print("PASS: class-1 ground-remap trigger selects affected and skips unaffected LAS")


if __name__ == "__main__":
    main()
