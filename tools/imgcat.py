#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path

from kitty_graphics import emit_png, ensure_png, positive_int


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Display an image in a Kitty Graphics compatible terminal."
    )
    parser.add_argument("image", type=Path, help="path to the image file")
    parser.add_argument("--cols", type=positive_int, help="target width in terminal cells")
    parser.add_argument("--rows", type=positive_int, help="target height in terminal cells")
    parser.add_argument(
        "--no-move-cursor",
        action="store_true",
        help="do not move the cursor below the image after drawing",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    try:
        png_bytes = ensure_png(args.image)
        emit_png(
            png_bytes,
            cols=args.cols,
            rows=args.rows,
            move_cursor=not args.no_move_cursor,
        )
    except Exception as exc:
        print(f"imgcat: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
