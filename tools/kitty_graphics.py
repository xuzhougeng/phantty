#!/usr/bin/env python3
import base64
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ESC = "\x1b"
ST = "\x1b\\"


def _chunk_bytes(data: bytes, chunk_size: int = 4096):
    for start in range(0, len(data), chunk_size):
        yield data[start : start + chunk_size]


def emit_png(
    png_bytes: bytes,
    *,
    cols: int | None = None,
    rows: int | None = None,
    move_cursor: bool = True,
    stream=None,
):
    if stream is None:
        import sys

        stream = sys.stdout

    control = ["a=T", "f=100", "t=d"]
    if cols is not None:
        control.append(f"c={cols}")
    if rows is not None:
        control.append(f"r={rows}")
    if move_cursor:
        control.append("C=1")

    chunks = list(_chunk_bytes(base64.b64encode(png_bytes)))
    for index, chunk in enumerate(chunks):
        parts = list(control)
        parts.append(f"m={1 if index + 1 < len(chunks) else 0}")
        payload = chunk.decode("ascii")
        stream.write(f"{ESC}_G{','.join(parts)};{payload}{ST}")
    stream.flush()


def ensure_png(path: Path) -> bytes:
    suffix = path.suffix.lower()
    if suffix == ".png":
        return path.read_bytes()

    try:
        from PIL import Image
    except ImportError:
        Image = None

    if Image is not None:
        with Image.open(path) as image:
            from io import BytesIO

            buf = BytesIO()
            image.save(buf, format="PNG")
            return buf.getvalue()

    magick = shutil.which("magick") or shutil.which("convert")
    if magick is None:
        raise RuntimeError(
            "non-PNG input requires Pillow or ImageMagick (`magick`/`convert`)"
        )

    with tempfile.TemporaryDirectory(prefix="phantty-imgcat-") as tmp_dir:
        out_path = Path(tmp_dir) / "converted.png"
        subprocess.run(
            [magick, str(path), str(out_path)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=False,
        )
        return out_path.read_bytes()


def render_pdf_page(pdf_path: Path, page: int) -> bytes:
    if page < 1:
        raise ValueError("page numbers start at 1")

    pdftoppm = shutil.which("pdftoppm")
    if pdftoppm is not None:
        with tempfile.TemporaryDirectory(prefix="phantty-pdfcat-") as tmp_dir:
            prefix = Path(tmp_dir) / "page"
            subprocess.run(
                [
                    pdftoppm,
                    "-png",
                    "-f",
                    str(page),
                    "-singlefile",
                    str(pdf_path),
                    str(prefix),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=False,
            )
            return (prefix.with_suffix(".png")).read_bytes()

    mutool = shutil.which("mutool")
    if mutool is not None:
        with tempfile.TemporaryDirectory(prefix="phantty-pdfcat-") as tmp_dir:
            out_path = Path(tmp_dir) / "page.png"
            subprocess.run(
                [
                    mutool,
                    "draw",
                    "-F",
                    "png",
                    "-o",
                    str(out_path),
                    str(pdf_path),
                    str(page),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=False,
            )
            return out_path.read_bytes()

    magick = shutil.which("magick")
    if magick is not None:
        with tempfile.TemporaryDirectory(prefix="phantty-pdfcat-") as tmp_dir:
            out_path = Path(tmp_dir) / "page.png"
            subprocess.run(
                [magick, f"{pdf_path}[{page - 1}]", str(out_path)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=False,
            )
            return out_path.read_bytes()

    raise RuntimeError(
        "PDF rendering requires `pdftoppm`, `mutool`, or ImageMagick (`magick`)"
    )


def positive_int(value: str) -> int:
    result = int(value)
    if result <= 0:
        raise ValueError("value must be positive")
    return result
