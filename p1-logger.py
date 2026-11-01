#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = [
#     "pyserial>=3.5",
# ]
# ///
"""
p1-logger: raw DSMR / P1 smart-meter capture with hourly log rotation.

Reads the P1 port of a Dutch/Belgian smart meter (DSMR 4/5: 115200 8N1; the
USB cable does the signal inversion) and appends **every byte received,
verbatim** to an hourly file. No parsing, no CRC filtering, no reformatting:
the file is a byte-exact copy of the serial stream, so telegrams
(`/...` through `!CRC`) appear exactly as the meter sent them, including any
corrupted ones. Parsing happens later, from these files.

Log files live under `<logdir>/YYYY/YYYYMMDD/HH.txt` (UTC). Hourly rather
than daily (as jeenode-listener does) because a DSMR 5 meter sends ~1 KB/s:
a day is ~90 MB, and `rclone copy` re-uploads a changed file whole on every
sync tick. The file switches only at a telegram start (`/`), so a telegram
is never split across two files. Every chunk read from the port is
appended with an open/write/close, so nothing sits in a buffer on crash.

Like jeenode-listener's housemon-logger, this script does only the capture.
Off-box shipping is a separate rclone timer (p1-sync.timer). Live
re-exposure (e.g. serial over TCP for Home Assistant's DSMR integration) can
be added as another `Sink` without touching the raw file sink: there is one
reader per port, and every sink gets the same bytes.
"""

import argparse
import logging
import os
import signal
import sys
import threading
from datetime import datetime, timezone
from pathlib import Path

import serial

# ---------------------------------------------------------------------------
# Configuration constants
# ---------------------------------------------------------------------------

RECONNECT_DELAY = 5.0       # seconds between serial reconnect attempts
SERIAL_READ_TIMEOUT = 1.0   # seconds per read() so we can check signals
READ_SIZE = 4096            # max bytes per read()

# DSMR 4/5 defaults. DSMR 2.2/3 meters use 9600 7E1 instead.
DEFAULT_DEVICE = "/dev/ttyUSB0"
DEFAULT_BAUD = 115200
DEFAULT_LOGDIR = "~/p1-logger"

TELEGRAM_START = b"/"

log = logging.getLogger("p1-logger")


# ---------------------------------------------------------------------------
# File path helpers
# ---------------------------------------------------------------------------

def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def hourly_path(logdir: Path, now: datetime) -> Path:
    day = now.strftime("%Y%m%d")
    return logdir / now.strftime("%Y") / day / (now.strftime("%H") + ".txt")


# ---------------------------------------------------------------------------
# Sinks: everything read from the port goes to every sink, unchanged
# ---------------------------------------------------------------------------

class Sink:
    def write(self, data: bytes) -> None:
        raise NotImplementedError

    def close(self) -> None:
        pass


class HourlyFileSink(Sink):
    """
    Byte-exact append to <logdir>/YYYY/YYYYMMDD/HH.txt. The target file is
    re-evaluated at each telegram start, so rotation happens between
    telegrams, never inside one.
    """

    def __init__(self, logdir: Path):
        self.logdir = logdir
        self._path = None

    def _append(self, data: bytes) -> None:
        if not data:
            return
        if self._path is None:
            self._rotate()
        with self._path.open("ab") as f:
            f.write(data)

    def _rotate(self) -> None:
        path = hourly_path(self.logdir, utc_now())
        if path != self._path:
            path.parent.mkdir(parents=True, exist_ok=True)
            if self._path is not None:
                log.info("rotating to %s", path)
            self._path = path

    def write(self, data: bytes) -> None:
        # Split at every telegram start; re-pick the file before each one.
        start = 0
        i = data.find(TELEGRAM_START)
        while i >= 0:
            self._append(data[start:i])
            self._rotate()
            start = i
            i = data.find(TELEGRAM_START, i + 1)
        self._append(data[start:])


# ---------------------------------------------------------------------------
# Serial reader
# ---------------------------------------------------------------------------

class SerialReader:
    """Owns the serial port, handles (re)connection, fans bytes out to sinks."""

    def __init__(self, device: str, baud: int, sinks: list):
        self.device = device
        self.baud = baud
        self.sinks = sinks
        self._stop = threading.Event()

    def stop(self) -> None:
        self._stop.set()

    def run(self) -> None:
        while not self._stop.is_set():
            ser = None
            try:
                log.info("opening serial %s @ %d 8N1", self.device, self.baud)
                ser = serial.Serial(self.device, self.baud,
                                    timeout=SERIAL_READ_TIMEOUT)
                self._read_loop(ser)
            except (serial.SerialException, OSError) as e:
                log.warning("serial error on %s: %s", self.device, e)
            finally:
                if ser is not None:
                    try:
                        ser.close()
                    except Exception:
                        pass
            if self._stop.is_set():
                break
            log.info("reconnecting in %.0fs", RECONNECT_DELAY)
            if self._stop.wait(RECONNECT_DELAY):
                break
        for sink in self.sinks:
            sink.close()

    def _read_loop(self, ser: serial.Serial) -> None:
        first = True
        while not self._stop.is_set():
            # Block for the first byte (up to the timeout), then take
            # whatever else has already arrived.
            data = ser.read(1)
            if not data:
                continue
            waiting = ser.in_waiting
            if waiting:
                data += ser.read(min(waiting, READ_SIZE))
            if first:
                log.info("receiving data")
                first = False
            for sink in self.sinks:
                sink.write(data)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="raw P1/DSMR smart-meter logger with hourly log rotation",
    )
    p.add_argument("--device", default=DEFAULT_DEVICE,
                   help=f"serial device path (default: {DEFAULT_DEVICE})")
    p.add_argument("--baud", type=int, default=DEFAULT_BAUD,
                   help=f"baud rate, 8N1 (default: {DEFAULT_BAUD})")
    p.add_argument("--logdir", default=DEFAULT_LOGDIR,
                   help=f"local log directory (default: {DEFAULT_LOGDIR})")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    logdir = Path(os.path.expanduser(args.logdir)).resolve()
    logdir.mkdir(parents=True, exist_ok=True)
    log.info("logdir=%s device=%s baud=%d", logdir, args.device, args.baud)

    reader = SerialReader(args.device, args.baud, [HourlyFileSink(logdir)])

    def handle_signal(signum, _frame):
        log.info("received signal %d, shutting down", signum)
        reader.stop()

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    reader.run()
    log.info("exit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
