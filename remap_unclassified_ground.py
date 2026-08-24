#!/usr/bin/env python3
"""Detect and optionally remap significant ground-like LAS class-1 points.

The source files that motivated this helper contain a large population of
class-1 points on the same local surface as class 2 (ground).  The production
pipeline can then keep its established PDAL overlap and height filters while
presenting those points as ground.

The trigger is intentionally based on the source point distribution rather
than the survey year or LAS version:

* at least 10,000 class-1 points;
* class 1 is at least 1% of all source points; and
* at least 80% of class-1 points are within 0.25 m of the mean class-2 Z in
  their 1 m XY cell.

The production caller aggregates these measurements across every LAZ in a
sector.  When the sector trigger matches, every class-1 point in every source
file is rewritten as class 2 in a temporary output file.  The caller then
applies the unchanged PDAL range filter and LAS writer options.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any

import laspy
import numpy as np


CELL_SIZE = 1.0
GROUND_Z_TOLERANCE = 0.25
MIN_CLASS1_POINTS = 10_000
MIN_CLASS1_SHARE = 0.01
MIN_GROUND_LIKE_FRACTION = 0.80
CHUNK_SIZE = 2_000_000
MAX_GRID_CELLS = 4_000_000


def grid_layout(header: Any) -> tuple[float, float, int, int, int]:
    """Return a bounded 1 m XY grid derived from the LAS header."""

    min_x = math.floor(float(header.mins[0]) / CELL_SIZE) * CELL_SIZE
    min_y = math.floor(float(header.mins[1]) / CELL_SIZE) * CELL_SIZE
    max_x = float(header.maxs[0])
    max_y = float(header.maxs[1])
    width = max_x - min_x
    height = max_y - min_y

    if not math.isfinite(width) or not math.isfinite(height):
        raise ValueError("LAS bounds are not finite")
    if width < 0 or height < 0:
        raise ValueError("LAS bounds are inverted")

    columns = int(math.ceil(width / CELL_SIZE)) + 1
    rows = int(math.ceil(height / CELL_SIZE)) + 1
    cells = columns * rows
    if cells > MAX_GRID_CELLS:
        raise ValueError(
            f"1 m grid is too large ({cells} cells; limit {MAX_GRID_CELLS})"
        )

    return min_x, min_y, columns, rows, cells


def cell_ids(
    x: np.ndarray,
    y: np.ndarray,
    min_x: float,
    min_y: float,
    columns: int,
    rows: int,
) -> tuple[np.ndarray, np.ndarray]:
    """Convert coordinates to flat grid IDs and a bounds-valid mask."""

    column = np.floor((x - min_x) / CELL_SIZE).astype(np.int64)
    row = np.floor((y - min_y) / CELL_SIZE).astype(np.int64)
    valid = (
        (column >= 0)
        & (column < columns)
        & (row >= 0)
        & (row < rows)
    )
    return row * columns + column, valid


def analyse_file(path: Path) -> dict[str, Any]:
    """Measure the trigger without rewriting the source file."""

    with laspy.open(path) as reader:
        min_x, min_y, columns, rows, cells = grid_layout(reader.header)
        class2_sum = np.zeros(cells, dtype=np.float64)
        class2_count = np.zeros(cells, dtype=np.int64)
        total_count = 0
        class1_count = 0
        class0_count = 0
        class12_count = 0

        for points in reader.chunk_iterator(CHUNK_SIZE):
            x = np.asarray(points.x)
            y = np.asarray(points.y)
            z = np.asarray(points.z)
            classification = np.asarray(points.classification)
            ids, valid = cell_ids(x, y, min_x, min_y, columns, rows)

            total_count += len(classification)
            class0_count += int((classification == 0).sum())
            class1_count += int((classification == 1).sum())
            class12_count += int((classification == 12).sum())

            ground = (classification == 2) & valid
            if ground.any():
                ground_ids = ids[ground]
                class2_sum += np.bincount(
                    ground_ids,
                    weights=z[ground],
                    minlength=cells,
                )
                class2_count += np.bincount(
                    ground_ids,
                    minlength=cells,
                )

    class2_mean = np.zeros(cells, dtype=np.float64)
    has_ground = class2_count > 0
    class2_mean[has_ground] = class2_sum[has_ground] / class2_count[has_ground]

    ground_like_count = 0
    if class1_count:
        with laspy.open(path) as reader:
            for points in reader.chunk_iterator(CHUNK_SIZE):
                x = np.asarray(points.x)
                y = np.asarray(points.y)
                z = np.asarray(points.z)
                classification = np.asarray(points.classification)
                is_class1 = classification == 1
                if not is_class1.any():
                    continue

                ids, valid = cell_ids(
                    x[is_class1],
                    y[is_class1],
                    min_x,
                    min_y,
                    columns,
                    rows,
                )
                if not valid.any():
                    continue

                valid_ids = ids[valid]
                valid_z = z[is_class1][valid]
                ground_like_count += int(
                    (
                        has_ground[valid_ids]
                        & (
                            np.abs(valid_z - class2_mean[valid_ids])
                            <= GROUND_Z_TOLERANCE
                        )
                    ).sum()
                )

    class1_share = class1_count / total_count if total_count else 0.0
    ground_like_fraction = (
        ground_like_count / class1_count if class1_count else 0.0
    )
    remapped = remap_trigger(
        total_count,
        class1_count,
        ground_like_count,
    )

    return {
        "source": str(path),
        "totalPoints": total_count,
        "class0Points": class0_count,
        "class1Points": class1_count,
        "class2Points": int(class2_count.sum()),
        "class12Points": class12_count,
        "class1Share": class1_share,
        "groundLikeClass1Points": ground_like_count,
        "groundLikeFraction": ground_like_fraction,
        "remapped": remapped,
        "thresholds": {
            "minClass1Points": MIN_CLASS1_POINTS,
            "minClass1Share": MIN_CLASS1_SHARE,
            "minGroundLikeFraction": MIN_GROUND_LIKE_FRACTION,
            "groundZTolerance": GROUND_Z_TOLERANCE,
            "cellSize": CELL_SIZE,
        },
    }


def remap_trigger(
    total_count: int,
    class1_count: int,
    ground_like_count: int,
) -> bool:
    """Return whether the aggregated class-1 population is affected."""

    class1_share = class1_count / total_count if total_count else 0.0
    ground_like_fraction = (
        ground_like_count / class1_count if class1_count else 0.0
    )
    return (
        class1_count >= MIN_CLASS1_POINTS
        and class1_share >= MIN_CLASS1_SHARE
        and ground_like_fraction >= MIN_GROUND_LIKE_FRACTION
    )


def remap_class1(path: Path, destination: Path) -> None:
    """Write a copy with every class-1 point assigned to class 2."""

    with laspy.open(path) as reader:
        header = reader.header.copy()
        # PDAL 2.3 rejects LAS 1.4 point formats without the WKT global
        # encoding flag after a laspy rewrite.  The source VLRs are retained.
        if header.version.minor >= 4 or header.point_format.id >= 6:
            header.global_encoding.wkt = True

        with laspy.open(destination, mode="w", header=header) as writer:
            for points in reader.chunk_iterator(CHUNK_SIZE):
                classification = np.asarray(points.classification)
                points.classification[classification == 1] = 2
                writer.write_points(points)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Detect and optionally remap ground-like LAS class-1 points."
    )
    parser.add_argument(
        "--analyse-only",
        action="store_true",
        help="analyse one source and print JSON without writing a remap copy",
    )
    parser.add_argument(
        "--remap-only",
        action="store_true",
        help="write a remap copy without re-evaluating the trigger",
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("remap_output", type=Path, nargs="?")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.analyse_only and args.remap_only:
            raise ValueError("--analyse-only and --remap-only are mutually exclusive")

        if args.remap_only:
            if args.remap_output is None:
                raise ValueError("--remap-only requires a destination path")
            remap_class1(args.source, args.remap_output)
            return 0

        result = analyse_file(args.source)
        if args.analyse_only:
            print(json.dumps(result, separators=(",", ":")))
            return 0

        if args.remap_output is None:
            raise ValueError("a remap destination is required")

        if result["remapped"]:
            remap_class1(args.source, args.remap_output)
            result["remappedClass1Points"] = result["class1Points"]
        else:
            args.remap_output.unlink(missing_ok=True)
            result["remappedClass1Points"] = 0

        print(json.dumps(result, separators=(",", ":")))
        return 0
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
