#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path

from kitty_graphics import emit_png, positive_int, render_pdf_page


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Render PDF pages into Kitty Graphics compatible output."
    )
    parser.add_argument("pdf", type=Path, help="path to the PDF file")
    parser.add_argument(
        "--page",
        type=positive_int,
        action="append",
        help="page number to render; can be repeated",
    )
    parser.add_argument("--cols", type=positive_int, help="target width in terminal cells")
    parser.add_argument("--rows", type=positive_int, help="target height in terminal cells")
    parser.add_argument(
        "--no-move-cursor",
        action="store_true",
        help="do not move the cursor below each rendered page",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    pages = args.page or [1]

    try:
        for page in pages:
            png_bytes = render_pdf_page(args.pdf, page)
            emit_png(
                png_bytes,
                cols=args.cols,
                rows=args.rows,
                move_cursor=not args.no_move_cursor,
            )
    except Exception as exc:
        print(f"pdfcat: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
