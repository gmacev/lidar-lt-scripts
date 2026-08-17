#!/usr/bin/env python3
"""Repair LAS/LAZ header bounds without rewriting point data.

PDAL's point reader can compute the actual point extents.  This utility uses
those extents and updates only the six LAS header bounding-box doubles.  The
compressed point records, VLRs, scale, offsets, and all other header fields
are left untouched.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import subprocess
import sys
from pathlib import Path


LAS_SIGNATURE = b"LASF"
LAS_BOUNDS_OFFSET = 179
LAS_BOUNDS_SIZE = 6 * 8


def actual_bounds(path: Path) -> dict[str, float]:
    command = [
        "pdal",
        "info",
        "--stats",
        "--dimensions=X,Y,Z",
        str(path),
    ]
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"PDAL stats failed: {detail}")

    try:
        payload = json.loads(result.stdout)
        statistics = payload["stats"]["statistic"]
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        raise RuntimeError("PDAL stats output was not understood") from exc

    values: dict[str, dict[str, float]] = {}
    for statistic in statistics:
        name = statistic.get("name")
        if name in {"X", "Y", "Z"}:
            values[name] = statistic

    if set(values) != {"X", "Y", "Z"}:
        raise RuntimeError("PDAL stats did not contain X, Y, and Z")

    return {
        "maxx": float(values["X"]["maximum"]),
        "minx": float(values["X"]["minimum"]),
        "maxy": float(values["Y"]["maximum"]),
        "miny": float(values["Y"]["minimum"]),
        "maxz": float(values["Z"]["maximum"]),
        "minz": float(values["Z"]["minimum"]),
    }


def read_header_bounds(path: Path) -> dict[str, float]:
    with path.open("rb") as stream:
        header = stream.read(LAS_BOUNDS_OFFSET + LAS_BOUNDS_SIZE)

    if len(header) < LAS_BOUNDS_OFFSET + LAS_BOUNDS_SIZE:
        raise RuntimeError("file is too small to contain a LAS bounding box")
    if header[:4] != LAS_SIGNATURE:
        raise RuntimeError("file does not have a LAS/LAZ signature")

    maxx, minx, maxy, miny, maxz, minz = struct.unpack_from(
        "<6d", header, LAS_BOUNDS_OFFSET
    )
    return {
        "maxx": maxx,
        "minx": minx,
        "maxy": maxy,
        "miny": miny,
        "maxz": maxz,
        "minz": minz,
    }


def repaired_bounds(
    header: dict[str, float], actual: dict[str, float]
) -> dict[str, float]:
    # Keep an already wider header unchanged.  If an actual point is on the
    # edge, move the repaired bound by one representable double so Potree's
    # strict comparison cannot reject an equal decoded coordinate.
    return {
        "maxx": max(header["maxx"], math.nextafter(actual["maxx"], math.inf)),
        "minx": min(header["minx"], math.nextafter(actual["minx"], -math.inf)),
        "maxy": max(header["maxy"], math.nextafter(actual["maxy"], math.inf)),
        "miny": min(header["miny"], math.nextafter(actual["miny"], -math.inf)),
        "maxz": max(header["maxz"], math.nextafter(actual["maxz"], math.inf)),
        "minz": min(header["minz"], math.nextafter(actual["minz"], -math.inf)),
    }


def write_header_bounds(path: Path, bounds: dict[str, float]) -> None:
    packed = struct.pack(
        "<6d",
        bounds["maxx"],
        bounds["minx"],
        bounds["maxy"],
        bounds["miny"],
        bounds["maxz"],
        bounds["minz"],
    )
    with path.open("r+b") as stream:
        stream.seek(LAS_BOUNDS_OFFSET)
        stream.write(packed)
        stream.flush()


def repair(path: Path, dry_run: bool) -> bool:
    header = read_header_bounds(path)
    actual = actual_bounds(path)
    repaired = repaired_bounds(header, actual)
    changed = repaired != header

    if changed and not dry_run:
        write_header_bounds(path, repaired)

    action = "would repair" if dry_run and changed else "repaired" if changed else "already valid"
    print(f"{action}: {path}")
    if changed:
        print(
            "  header: "
            f"x=[{header['minx']}, {header['maxx']}], "
            f"y=[{header['miny']}, {header['maxy']}], "
            f"z=[{header['minz']}, {header['maxz']}]"
        )
        print(
            "  actual: "
            f"x=[{actual['minx']}, {actual['maxx']}], "
            f"y=[{actual['miny']}, {actual['maxy']}], "
            f"z=[{actual['minz']}, {actual['maxz']}]"
        )
    return changed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Repair LAS/LAZ header bounds using PDAL point statistics."
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("files", nargs="+")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        for raw_path in args.files:
            repair(Path(raw_path), args.dry_run)
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
