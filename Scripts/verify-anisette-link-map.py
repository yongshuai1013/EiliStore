#!/usr/bin/env python3
"""Verify native engine inclusion without decoding arbitrary Mach-O symbol bytes."""
import argparse
from pathlib import Path
import sys


def linked_native_engine(data: bytes) -> bool:
    in_symbols = False
    for line in data.splitlines():
        if line == b"# Symbols:":
            in_symbols = True
            continue
        if line == b"# Dead Stripped Symbols:":
            break
        if not in_symbols:
            continue
        fields = line.split()
        if (len(fields) >= 4 and fields[0].startswith(b"0x")
                and fields[-1] == b"_get_anisette_headers_uc"):
            return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("link_map", type=Path)
    args = parser.parse_args()
    try:
        present = linked_native_engine(args.link_map.read_bytes())
    except OSError as error:
        print(f"ERROR: cannot read App Link Map: {error}", file=sys.stderr)
        return 1
    if not present:
        print("ERROR: On-Device native entry point is absent from active App symbols", file=sys.stderr)
        return 1
    print("PASS: active On-Device native engine entry point in App Link Map")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
