#!/usr/bin/env python3
from __future__ import annotations
import argparse
from pathlib import Path


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("binary", type=Path)
    p.add_argument("hexfile", type=Path)
    p.add_argument("--words", type=int, default=4096)
    args = p.parse_args()
    data = args.binary.read_bytes()
    if len(data) > args.words * 4:
        raise SystemExit(f"firmware is {len(data)} bytes, exceeds {args.words*4} byte RAM")
    data += b"\x00" * ((4 - len(data) % 4) % 4)
    words = [int.from_bytes(data[i:i+4], "little") for i in range(0, len(data), 4)]
    args.hexfile.parent.mkdir(parents=True, exist_ok=True)
    args.hexfile.write_text("".join(f"{w:08x}\n" for w in words), encoding="ascii")
    print(f"wrote {len(words)} initialized words ({len(data)} bytes) to {args.hexfile}")


if __name__ == "__main__":
    main()
