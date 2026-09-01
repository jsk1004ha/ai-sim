#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

NOP_RV32I = 0x00000013


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("hexfile", type=Path)
    parser.add_argument("--words", type=int, default=4096)
    args = parser.parse_args()

    if args.words <= 0:
        raise SystemExit("--words must be positive")

    payload = args.binary.read_bytes()
    capacity = args.words * 4
    if len(payload) > capacity:
        raise SystemExit(
            f"firmware is {len(payload)} bytes, exceeds {capacity} byte RAM"
        )

    aligned = payload + b"\x00" * ((4 - len(payload) % 4) % 4)
    words = [
        int.from_bytes(aligned[i : i + 4], "little")
        for i in range(0, len(aligned), 4)
    ]
    words.extend([NOP_RV32I] * (args.words - len(words)))

    args.hexfile.parent.mkdir(parents=True, exist_ok=True)
    args.hexfile.write_text(
        "".join(f"{word:08x}\n" for word in words), encoding="ascii"
    )
    print(
        f"wrote {len(words)} initialized words ({capacity} bytes), "
        f"firmware payload {len(payload)} bytes, to {args.hexfile}"
    )


if __name__ == "__main__":
    main()
