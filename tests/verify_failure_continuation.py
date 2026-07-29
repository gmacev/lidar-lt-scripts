#!/usr/bin/env python3
import argparse
from pathlib import Path


def event_index(lines: list[str], event_name: str, sector: str) -> int:
    marker = f"\t{event_name}\t{sector}\t"
    for index, line in enumerate(lines):
        if marker in line:
            return index
    raise AssertionError(f"missing event: {event_name} for {sector}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-root", required=True, type=Path)
    args = parser.parse_args()

    failed_lines = (
        args.data_root / "failed_sectors.txt"
    ).read_text(encoding="utf-8").splitlines()
    assert len(failed_lines) == 1, failed_lines
    failed_fields = failed_lines[0].split("\t")
    assert failed_fields[1] == "02_02", failed_fields
    assert failed_fields[2] == "potree-conversion", failed_fields

    succeeded = {
        line.split("\t", 1)[1]
        for line in (args.data_root / "succeded_sectors.txt")
        .read_text(encoding="utf-8")
        .splitlines()
        if "\t" in line
    }
    assert succeeded == {"01_01", "03_03"}, succeeded

    events = (
        args.data_root / "pipeline_events.log"
    ).read_text(encoding="utf-8").splitlines()
    failed_index = event_index(events, "sector-failed", "02_02")
    third_started_index = event_index(events, "processing-start", "03_03")
    third_succeeded_index = event_index(events, "sector-succeeded", "03_03")
    assert failed_index < third_started_index < third_succeeded_index

    assert list((args.data_root / "02_02").rglob("*.laz"))
    assert not list((args.data_root / "01_01").rglob("*.laz"))
    assert not list((args.data_root / "03_03").rglob("*.laz"))

    print("PASS: processing failure logged by step and next sector continued")


if __name__ == "__main__":
    main()
