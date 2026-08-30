#!/usr/bin/env python3
"""Filter LAS/LAZ points to a sector's projected XY envelope.

The GeoJSON grid is in longitude/latitude, while the source LAS files use
LKS94 / Lithuania TM (EPSG:3346).  This helper projects the selected sector,
adds a small configurable safety margin, and rewrites only points inside the
resulting axis-aligned XY envelope.  Z, classification, overlap flags, VLRs,
and all other point attributes are preserved.
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


CHUNK_SIZE = 2_000_000
DEFAULT_XY_MARGIN = 25.0

LKS94_SEMI_MAJOR_AXIS = 6378137.0
LKS94_INVERSE_FLATTENING = 298.257222101
LKS94_CENTRAL_MERIDIAN = math.radians(24.0)
LKS94_SCALE_FACTOR = 0.9998
LKS94_FALSE_EASTING = 500_000.0


def lks94_tm(lon: float, lat: float) -> tuple[float, float]:
    """Project WGS84/LKS94 longitude-latitude to EPSG:3346 XY."""

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

    return {
        "minx": min(point[0] for point in projected) - margin,
        "maxx": max(point[0] for point in projected) + margin,
        "miny": min(point[1] for point in projected) - margin,
        "maxy": max(point[1] for point in projected) + margin,
    }


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


def filter_laz(
    source: Path,
    destination: Path,
    bounds: dict[str, float],
) -> dict[str, Any]:
    """Write a copy containing only points inside the sector XY envelope."""

    input_points = 0
    output_points = 0
    removed_points = 0

    with laspy.open(source) as reader:
        header = reader.header.copy()
        # PDAL 2.3 rejects LAS 1.4 point formats without the WKT global
        # encoding flag after a laspy rewrite.  The source VLRs are retained.
        if header.version.minor >= 4 or header.point_format.id >= 6:
            header.global_encoding.wkt = True

        with laspy.open(destination, mode="w", header=header) as writer:
            for points in reader.chunk_iterator(CHUNK_SIZE):
                input_points += len(points)
                x = np.asarray(points.x)
                y = np.asarray(points.y)
                keep = sector_mask(x, y, bounds)
                removed_points += int((~keep).sum())
                selected = points[keep]
                output_points += len(selected)
                writer.write_points(selected)

    if output_points == 0:
        raise ValueError("XY filtering removed every point")

    return {
        "source": str(source),
        "destination": str(destination),
        "inputPoints": input_points,
        "outputPoints": output_points,
        "removedOutOfSectorXYPoints": removed_points,
        "bounds": bounds,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Filter LAS/LAZ points to a sector's projected XY envelope."
    )
    parser.add_argument("--grid-file", type=Path, required=True)
    parser.add_argument("--sector-id", required=True)
    parser.add_argument(
        "--xy-margin",
        type=float,
        default=DEFAULT_XY_MARGIN,
        help=(
            "projected XY margin in metres around the sector bbox "
            f"(default: {DEFAULT_XY_MARGIN:g})"
        ),
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        bounds = sector_xy_bounds(args.grid_file, args.sector_id, args.xy_margin)
        report = filter_laz(args.source, args.destination, bounds)
        print(json.dumps(report, separators=(",", ":")))
        return 0
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
