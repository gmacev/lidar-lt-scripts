#!/usr/bin/env python3
import argparse
import os
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def parse_delay(value: str) -> tuple[str, float]:
    name, seconds = value.split("=", 1)
    return name, float(seconds)


class DelayedHandler(SimpleHTTPRequestHandler):
    delays: dict[str, float] = {}

    def do_GET(self) -> None:
        filename = Path(self.path.split("?", 1)[0]).name
        delay = self.delays.get(filename, 0.0)
        if delay:
            time.sleep(delay)
        super().do_GET()

    def log_message(self, format_string: str, *args: object) -> None:
        print(
            f"{self.log_date_time_string()} {self.client_address[0]} "
            f"{format_string % args}",
            flush=True,
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--delay", action="append", default=[], type=parse_delay)
    args = parser.parse_args()

    os.chdir(args.root)
    DelayedHandler.delays = dict(args.delay)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), DelayedHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
