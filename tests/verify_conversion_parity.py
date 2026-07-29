#!/usr/bin/env python3
from pathlib import Path


REPO_DIR = Path(__file__).resolve().parent.parent
PROCESS_ONE = (REPO_DIR / "process_one.sh").read_text(encoding="utf-8")
PROCESS_ALL = (REPO_DIR / "process_all.sh").read_text(encoding="utf-8")


def require(source: str, needle: str, label: str) -> None:
    if needle not in source:
        raise AssertionError(f"{label} is missing required setting: {needle}")


def main() -> None:
    source_of_truth_settings = [
        "Overlap[0:0],Classification[1:7],Z[:600]",
        "--writers.las.forward=",
        "--writers.las.minor_version=2",
        "--writers.las.dataformat_id=0",
        "--attributes intensity classification",
        'classification intensity position ',
    ]

    for setting in source_of_truth_settings:
        require(PROCESS_ONE, setting, "process_one.sh")
        require(PROCESS_ALL, setting, "process_all.sh")

    require(PROCESS_ONE, 'MAX_JOBS=4', "process_one.sh")
    require(PROCESS_ALL, 'MAX_JOBS="${MAX_JOBS:-4}"', "process_all.sh")
    require(PROCESS_ONE, 'RUN_PDAL_CLEANING=true', "process_one.sh")
    require(
        PROCESS_ALL,
        'RUN_PDAL_CLEANING="${RUN_PDAL_CLEANING:-true}"',
        "process_all.sh",
    )
    require(PROCESS_ONE, 'POTREE_ENCODING="BROTLI"', "process_one.sh")
    require(
        PROCESS_ALL,
        'POTREE_ENCODING="${POTREE_ENCODING:-BROTLI}"',
        "process_all.sh",
    )
    require(
        PROCESS_ALL,
        'POTREE_CONVERTER="${POTREE_CONVERTER:-$HOME/PotreeConverter/build/PotreeConverter}"',
        "process_all.sh",
    )

    appearance_changing_options = [
        "--method",
        "--spacing",
        "--scale",
        "--projection",
        "--chunkMethod",
    ]
    for option in appearance_changing_options:
        if option in PROCESS_ALL:
            raise AssertionError(
                f"process_all.sh adds appearance-affecting Potree option: {option}"
            )

    print("PASS: process_all.sh preserves process_one.sh conversion settings")


if __name__ == "__main__":
    main()
