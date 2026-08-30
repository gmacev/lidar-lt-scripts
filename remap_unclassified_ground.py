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

An explicitly requested sector-XY rewrite can also discard records outside a
conservative projected sector envelope before that unchanged PDAL step.  It
does not apply any Z, class-3, or overlap heuristic.
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
DEFAULT_SECTOR_XY_MARGIN = 25.0

LKS94_SEMI_MAJOR_AXIS = 6378137.0
LKS94_INVERSE_FLATTENING = 298.257222101
LKS94_CENTRAL_MERIDIAN = math.radians(24.0)
LKS94_SCALE_FACTOR = 0.9998
LKS94_FALSE_EASTING = 500_000.0


def grid_layout_from_bounds(
    min_x: float,
    min_y: float,
    max_x: float,
    max_y: float,
) -> tuple[float, float, int, int, int]:
    """Return a bounded 1 m XY grid derived from point bounds."""

    min_x = math.floor(min_x / CELL_SIZE) * CELL_SIZE
    min_y = math.floor(min_y / CELL_SIZE) * CELL_SIZE
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


def grid_layout(header: Any) -> tuple[float, float, int, int, int]:
    """Return a bounded 1 m XY grid derived from the LAS header."""

    return grid_layout_from_bounds(
        float(header.mins[0]),
        float(header.mins[1]),
        float(header.maxs[0]),
        float(header.maxs[1]),
    )


def lks94_tm(lon: float, lat: float) -> tuple[float, float]:
    """Project WGS84/LKS94 longitude-latitude to the project's EPSG:3346 XY."""

    semi_minor = LKS94_SEMI_MAJOR_AXIS * (
        1.0 - 1.0 / LKS94_INVERSE_FLATTENING
    )
    eccentricity_squared = 1.0 - (semi_minor / LKS94_SEMI_MAJOR_AXIS) ** 2
    second_eccentricity_squared = eccentricity_squared / (
        1.0 - eccentricity_squared
    )

    latitude = math.radians(lat)
    longitude = math.radians(lon)
    sine = math.sin(latitude)
    cosine = math.cos(latitude)
    tangent = math.tan(latitude)
    radius = LKS94_SEMI_MAJOR_AXIS / math.sqrt(
        1.0 - eccentricity_squared * sine * sine
    )
    delta_longitude = longitude - LKS94_CENTRAL_MERIDIAN
    a_term = cosine * delta_longitude
    tangent_squared = tangent * tangent
    c_term = second_eccentricity_squared * cosine * cosine

    meridional_arc = LKS94_SEMI_MAJOR_AXIS * (
        (1.0 - eccentricity_squared / 4.0
         - 3.0 * eccentricity_squared**2 / 64.0
         - 5.0 * eccentricity_squared**3 / 256.0) * latitude
        - (3.0 * eccentricity_squared / 8.0
           + 3.0 * eccentricity_squared**2 / 32.0
           + 45.0 * eccentricity_squared**3 / 1024.0) * math.sin(2.0 * latitude)
        + (15.0 * eccentricity_squared**2 / 256.0
           + 45.0 * eccentricity_squared**3 / 1024.0) * math.sin(4.0 * latitude)
        - (35.0 * eccentricity_squared**3 / 3072.0) * math.sin(6.0 * latitude)
    )

    easting = LKS94_FALSE_EASTING + LKS94_SCALE_FACTOR * radius * (
        a_term
        + (1.0 - tangent_squared + c_term) * a_term**3 / 6.0
        + (5.0 - 18.0 * tangent_squared + tangent_squared**2
           + 72.0 * c_term - 58.0 * second_eccentricity_squared)
        * a_term**5 / 120.0
    )
    northing = LKS94_SCALE_FACTOR * (
        meridional_arc
        + radius * tangent * (
            a_term**2 / 2.0
            + (5.0 - tangent_squared + 9.0 * c_term + 4.0 * c_term**2)
            * a_term**4 / 24.0
            + (61.0 - 58.0 * tangent_squared + tangent_squared**2
               + 600.0 * c_term - 330.0 * second_eccentricity_squared)
            * a_term**6 / 720.0
        )
    )
    return easting, northing


def sector_xy_bounds(
    grid_file: Path,
    sector_id: str,
    margin: float,
) -> dict[str, float]:
    """Return a conservative projected XY bbox for one GeoJSON sector."""

    if not math.isfinite(margin) or margin < 0.0:
        raise ValueError("XY margin must be a finite non-negative number")

    try:
        payload = json.loads(grid_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"grid GeoJSON is invalid: {grid_file}") from exc

    feature = None
    for candidate in payload.get("features", []):
        properties = candidate.get("properties") or {}
        candidate_id = str(properties.get("id", "")).replace("/", "_")
        if candidate_id == sector_id:
            feature = candidate
            break

    if feature is None:
        raise ValueError(f"sector not found in grid: {sector_id}")

    geometry = feature.get("geometry") or {}
    geometry_type = geometry.get("type")
    coordinates = geometry.get("coordinates")
    if geometry_type == "Polygon":
        rings = coordinates or []
    elif geometry_type == "MultiPolygon":
        rings = [ring for polygon in (coordinates or []) for ring in polygon]
    else:
        raise ValueError(
            f"sector {sector_id} must have a Polygon or MultiPolygon geometry"
        )

    projected = [
        lks94_tm(float(point[0]), float(point[1]))
        for ring in rings
        for point in ring
    ]
    if not projected:
        raise ValueError(f"sector {sector_id} has no geometry coordinates")

    min_x = min(point[0] for point in projected) - margin
    max_x = max(point[0] for point in projected) + margin
    min_y = min(point[1] for point in projected) - margin
    max_y = max(point[1] for point in projected) + margin
    return {"minx": min_x, "maxx": max_x, "miny": min_y, "maxy": max_y}


def sector_mask(
    x: np.ndarray,
    y: np.ndarray,
    bounds: dict[str, float],
) -> np.ndarray:
    """Return an inclusive XY mask for a projected sector bbox."""

    return (
        (x >= bounds["minx"])
        & (x <= bounds["maxx"])
        & (y >= bounds["miny"])
        & (y <= bounds["maxy"])
    )


def in_sector_point_bounds(
    path: Path,
    bounds: dict[str, float],
) -> tuple[float, float, float, float]:
    """Find point bounds after excluding XY points outside the sector."""

    min_x = math.inf
    min_y = math.inf
    max_x = -math.inf
    max_y = -math.inf

    with laspy.open(path) as reader:
        for points in reader.chunk_iterator(CHUNK_SIZE):
            x = np.asarray(points.x)
            y = np.asarray(points.y)
            inside = sector_mask(x, y, bounds)
            if not inside.any():
                continue
            min_x = min(min_x, float(x[inside].min()))
            min_y = min(min_y, float(y[inside].min()))
            max_x = max(max_x, float(x[inside].max()))
            max_y = max(max_y, float(y[inside].max()))

    if not all(math.isfinite(value) for value in (min_x, min_y, max_x, max_y)):
        raise ValueError("no points remain inside the sector XY bounds")
    return min_x, min_y, max_x, max_y


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


def analyse_file(
    path: Path,
    xy_bounds: dict[str, float] | None = None,
) -> dict[str, Any]:
    """Measure the trigger without rewriting the source file.

    When XY bounds are provided, out-of-sector records are excluded from the
    measurement and the local grid is sized from the remaining points rather
    than from a potentially corrupt LAS header.
    """

    if xy_bounds is None:
        with laspy.open(path) as reader:
            min_x, min_y, columns, rows, cells = grid_layout(reader.header)
    else:
        min_x, min_y, max_x, max_y = in_sector_point_bounds(path, xy_bounds)
        min_x, min_y, columns, rows, cells = grid_layout_from_bounds(
            min_x,
            min_y,
            max_x,
            max_y,
        )

    with laspy.open(path) as reader:
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
            in_scope = (
                np.ones(len(classification), dtype=bool)
                if xy_bounds is None
                else sector_mask(x, y, xy_bounds)
            )

            total_count += int(in_scope.sum())
            class0_count += int(((classification == 0) & in_scope).sum())
            class1_count += int(((classification == 1) & in_scope).sum())
            class12_count += int(((classification == 12) & in_scope).sum())

            ground = (classification == 2) & in_scope & valid
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
                if xy_bounds is not None:
                    is_class1 &= sector_mask(x, y, xy_bounds)
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


def rewrite_laz(
    path: Path,
    destination: Path,
    xy_bounds: dict[str, float] | None = None,
    remap_class1_points: bool = False,
) -> dict[str, Any]:
    """Rewrite a LAZ, optionally filtering XY outliers and remapping class 1."""

    input_points = 0
    output_points = 0
    removed_points = 0
    remapped_points = 0

    with laspy.open(path) as reader:
        header = reader.header.copy()
        # PDAL 2.3 rejects LAS 1.4 point formats without the WKT global
        # encoding flag after a laspy rewrite.  The source VLRs are retained.
        if header.version.minor >= 4 or header.point_format.id >= 6:
            header.global_encoding.wkt = True

        with laspy.open(destination, mode="w", header=header) as writer:
            for points in reader.chunk_iterator(CHUNK_SIZE):
                input_points += len(points)
                if xy_bounds is None:
                    selected = points
                else:
                    x = np.asarray(points.x)
                    y = np.asarray(points.y)
                    keep = sector_mask(x, y, xy_bounds)
                    removed_points += int((~keep).sum())
                    selected = points[keep]

                if remap_class1_points:
                    classification = np.asarray(selected.classification)
                    remap_mask = classification == 1
                    remapped_points += int(remap_mask.sum())
                    selected.classification[remap_mask] = 2

                output_points += len(selected)
                writer.write_points(selected)

    if output_points == 0:
        raise ValueError("XY filtering removed every point")

    return {
        "source": str(path),
        "destination": str(destination),
        "inputPoints": input_points,
        "outputPoints": output_points,
        "removedOutOfSectorXYPoints": removed_points,
        "remappedClass1Points": remapped_points,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Detect/remap ground-like LAS class-1 points and optionally "
            "remove XY outliers outside a sector."
        )
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
    parser.add_argument(
        "--rewrite-only",
        action="store_true",
        help="write a filtered copy without evaluating the remap trigger",
    )
    parser.add_argument(
        "--remap-class1",
        action="store_true",
        help="also rewrite class-1 points as class 2 in --rewrite-only mode",
    )
    parser.add_argument(
        "--remove-out-of-sector-xy",
        action="store_true",
        help="remove points outside the selected sector's projected XY bbox",
    )
    parser.add_argument(
        "--grid-file",
        type=Path,
        help="GeoJSON grid used with --remove-out-of-sector-xy",
    )
    parser.add_argument(
        "--sector-id",
        help="sector ID used with --remove-out-of-sector-xy",
    )
    parser.add_argument(
        "--xy-margin",
        type=float,
        default=DEFAULT_SECTOR_XY_MARGIN,
        help=(
            "projected XY margin in metres around the sector bbox "
            f"(default: {DEFAULT_SECTOR_XY_MARGIN:g})"
        ),
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("remap_output", type=Path, nargs="?")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if sum((args.analyse_only, args.remap_only, args.rewrite_only)) > 1:
            raise ValueError(
                "--analyse-only, --remap-only, and --rewrite-only are mutually exclusive"
            )
        if args.remap_class1 and not args.rewrite_only:
            raise ValueError("--remap-class1 requires --rewrite-only")

        xy_bounds = None
        if args.remove_out_of_sector_xy:
            if args.grid_file is None or args.sector_id is None:
                raise ValueError(
                    "--remove-out-of-sector-xy requires --grid-file and --sector-id"
                )
            xy_bounds = sector_xy_bounds(
                args.grid_file,
                args.sector_id,
                args.xy_margin,
            )

        if args.remap_only:
            if args.remap_output is None:
                raise ValueError("--remap-only requires a destination path")
            if xy_bounds is None:
                remap_class1(args.source, args.remap_output)
            else:
                report = rewrite_laz(
                    args.source,
                    args.remap_output,
                    xy_bounds=xy_bounds,
                    remap_class1_points=True,
                )
                print(json.dumps(report, separators=(",", ":")))
            return 0

        if args.rewrite_only:
            if args.remap_output is None:
                raise ValueError("--rewrite-only requires a destination path")
            if xy_bounds is None:
                raise ValueError(
                    "--rewrite-only requires --remove-out-of-sector-xy"
                )
            report = rewrite_laz(
                args.source,
                args.remap_output,
                xy_bounds=xy_bounds,
                remap_class1_points=args.remap_class1,
            )
            print(json.dumps(report, separators=(",", ":")))
            return 0

        result = analyse_file(args.source, xy_bounds=xy_bounds)
        if args.analyse_only:
            print(json.dumps(result, separators=(",", ":")))
            return 0

        if args.remap_output is None:
            raise ValueError("a remap destination is required")

        if result["remapped"] or xy_bounds is not None:
            if xy_bounds is None:
                remap_class1(args.source, args.remap_output)
                result["remappedClass1Points"] = result["class1Points"]
            else:
                report = rewrite_laz(
                    args.source,
                    args.remap_output,
                    xy_bounds=xy_bounds,
                    remap_class1_points=bool(result["remapped"]),
                )
                result.update(
                    {
                        "outputPoints": report["outputPoints"],
                        "removedOutOfSectorXYPoints": report[
                            "removedOutOfSectorXYPoints"
                        ],
                        "remappedClass1Points": report["remappedClass1Points"],
                    }
                )
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
