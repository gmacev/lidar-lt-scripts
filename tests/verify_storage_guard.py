#!/usr/bin/env python3
import argparse
from pathlib import Path


def read_events(path: Path) -> list[tuple[str, str, str]]:
    events: list[tuple[str, str, str]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split("\t", 3)
        if len(fields) >= 3:
            events.append((fields[1], fields[2], fields[3] if len(fields) == 4 else ""))
    return events


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-root", required=True, type=Path)
    args = parser.parse_args()

    events = read_events(args.data_root / "pipeline_events.log")
    names_by_sector = {(name, sector) for name, sector, _ in events}

    assert ("download-start", "01_01") in names_by_sector
    assert ("processing-start", "01_01") in names_by_sector
    assert ("processing-end", "01_01") in names_by_sector
    assert ("sector-succeeded", "01_01") in names_by_sector
    assert ("storage-low-detected", "02_02") in names_by_sector
    assert ("storage-stop", "02_02") in names_by_sector

    assert ("download-start", "02_02") not in names_by_sector
    assert ("download-start", "03_03") not in names_by_sector
    assert ("processing-start", "02_02") not in names_by_sector
    assert ("processing-start", "03_03") not in names_by_sector

    succeeded = (args.data_root / "succeded_sectors.txt").read_text(encoding="utf-8")
    assert "\t01_01" in succeeded
    assert "\t02_02" not in succeeded
    assert "\t03_03" not in succeeded

    failed = (args.data_root / "failed_sectors.txt").read_text(encoding="utf-8")
    assert not failed.strip(), failed

    report = (args.data_root / "insufficient_storage.txt").read_text(encoding="utf-8")
    expected_fields = [
        "reason=insufficient-storage",
        "available_gib=10.00",
        "threshold_gib=15",
        "selected_total=3",
        "existing_complete=0",
        "newly_succeeded=1",
        "failed_this_run=0",
        "completed_total=1",
        "remaining_unfinished=2",
        "last_sector=01_01",
        "stopped_before=02_02",
    ]
    for field in expected_fields:
        assert field in report, f"missing {field!r} in storage report"

    print(
        "PASS: low storage blocked sector 2 download, sector 1 finished, "
        "and 1 complete / 2 unfinished was recorded"
    )


if __name__ == "__main__":
    main()
