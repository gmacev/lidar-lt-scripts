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


def find_index(
    events: list[tuple[str, str, str]],
    event_name: str,
    sector: str,
) -> int:
    for index, event in enumerate(events):
        if event[0] == event_name and event[1] == sector:
            return index
    raise AssertionError(f"missing event: {event_name} for {sector}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--events", required=True, type=Path)
    parser.add_argument("--succeeded", required=True, type=Path)
    args = parser.parse_args()

    events = read_events(args.events)

    sector_1_processing_start = find_index(events, "processing-start", "01_01")
    sector_1_processing_end = find_index(events, "processing-end", "01_01")
    sector_2_download_start = find_index(events, "download-start", "02_02")
    sector_2_download_end = find_index(events, "download-end", "02_02")
    sector_2_processing_start = find_index(events, "processing-start", "02_02")
    sector_2_processing_end = find_index(events, "processing-end", "02_02")
    sector_3_download_start = find_index(events, "download-start", "03_03")
    sector_3_download_end = find_index(events, "download-end", "03_03")
    sector_3_wait_start = find_index(events, "prepare-wait-start", "03_03")
    sector_3_processing_start = find_index(events, "processing-start", "03_03")

    assert sector_2_download_start < sector_1_processing_end
    assert sector_1_processing_start < sector_2_download_end
    assert sector_2_download_end < sector_1_processing_end
    assert sector_1_processing_end < sector_2_processing_start

    assert sector_3_download_start < sector_2_processing_end
    assert sector_2_processing_start < sector_3_download_end
    assert sector_2_processing_end < sector_3_download_end
    assert sector_3_wait_start < sector_3_download_end < sector_3_processing_start

    succeeded = {
        line.split("\t", 1)[1]
        for line in args.succeeded.read_text(encoding="utf-8").splitlines()
        if "\t" in line
    }
    assert succeeded == {"01_01", "02_02", "03_03"}, succeeded

    print("PASS: three-sector overlap, handoff, and wait behavior verified")


if __name__ == "__main__":
    main()
