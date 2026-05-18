#!/usr/bin/env python3
"""Generate a minimal multi-page PDF whose text is fully selectable.

Used to produce the science-class demo handout that the teacher app can
import via syncfusion_flutter_pdf. Standard library only — no reportlab —
because the demo machine may not have it installed.

The PDF embeds plain ASCII text using the built-in Helvetica font (one of
the 14 standard PDF fonts, so no font files needed). Each input line maps
to a single Tj show, with simple page-breaking on a fixed line budget.
"""
from __future__ import annotations
import sys
import zlib
from pathlib import Path

PAGE_WIDTH = 612      # 8.5"
PAGE_HEIGHT = 792     # 11"
LEFT_MARGIN = 54
TOP_MARGIN = 54
LINE_HEIGHT = 14      # pts
FONT_SIZE = 11
LINES_PER_PAGE = (PAGE_HEIGHT - 2 * TOP_MARGIN) // LINE_HEIGHT


def escape_pdf_string(s: str) -> str:
    # PDF literal strings: escape backslash and parentheses.
    return (
        s.replace("\\", "\\\\")
         .replace("(", "\\(")
         .replace(")", "\\)")
    )


def render_page_stream(lines: list[str]) -> bytes:
    parts: list[str] = ["BT", f"/F1 {FONT_SIZE} Tf", f"{LINE_HEIGHT} TL"]
    y = PAGE_HEIGHT - TOP_MARGIN
    parts.append(f"{LEFT_MARGIN} {y} Td")
    first = True
    for line in lines:
        if first:
            first = False
        else:
            parts.append("T*")
        # Empty lines: emit an empty Tj so vertical spacing stays right.
        parts.append(f"({escape_pdf_string(line)}) Tj")
    parts.append("ET")
    return "\n".join(parts).encode("latin-1")


def build_pdf(text: str) -> bytes:
    raw_lines = text.splitlines() or [""]
    # Drop trailing empties so we don't open a blank final page.
    while raw_lines and raw_lines[-1].strip() == "":
        raw_lines.pop()

    pages: list[list[str]] = []
    for i in range(0, len(raw_lines), LINES_PER_PAGE):
        pages.append(raw_lines[i:i + LINES_PER_PAGE])
    if not pages:
        pages = [[""]]

    # Object table: [catalog, pages, font, page1, content1, page2, content2, ...]
    objects: list[bytes] = []

    def add_object(body: bytes) -> int:
        objects.append(body)
        return len(objects)  # 1-indexed

    # Reserve slots so cross-references match.
    catalog_id = add_object(b"")
    pages_id = add_object(b"")
    font_id = add_object(
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    )

    page_ids: list[int] = []
    for page_lines in pages:
        content_bytes = render_page_stream(page_lines)
        compressed = zlib.compress(content_bytes)
        content_obj = (
            f"<< /Length {len(compressed)} /Filter /FlateDecode >>\nstream\n".encode("latin-1")
            + compressed
            + b"\nendstream"
        )
        content_id = add_object(content_obj)
        page_obj = (
            f"<< /Type /Page /Parent {pages_id} 0 R "
            f"/MediaBox [0 0 {PAGE_WIDTH} {PAGE_HEIGHT}] "
            f"/Resources << /Font << /F1 {font_id} 0 R >> >> "
            f"/Contents {content_id} 0 R >>"
        ).encode("latin-1")
        page_id = add_object(page_obj)
        page_ids.append(page_id)

    kids = " ".join(f"{pid} 0 R" for pid in page_ids)
    objects[pages_id - 1] = (
        f"<< /Type /Pages /Kids [{kids}] /Count {len(page_ids)} >>".encode("latin-1")
    )
    objects[catalog_id - 1] = (
        f"<< /Type /Catalog /Pages {pages_id} 0 R >>".encode("latin-1")
    )

    # Serialize.
    buf = bytearray()
    buf += b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"
    offsets: list[int] = []
    for idx, body in enumerate(objects, start=1):
        offsets.append(len(buf))
        buf += f"{idx} 0 obj\n".encode("latin-1")
        buf += body
        buf += b"\nendobj\n"
    xref_offset = len(buf)
    buf += f"xref\n0 {len(objects) + 1}\n".encode("latin-1")
    buf += b"0000000000 65535 f \n"
    for off in offsets:
        buf += f"{off:010d} 00000 n \n".encode("latin-1")
    buf += (
        f"trailer\n<< /Size {len(objects) + 1} /Root {catalog_id} 0 R >>\n"
        f"startxref\n{xref_offset}\n%%EOF"
    ).encode("latin-1")
    return bytes(buf)


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write("usage: build_demo_pdf.py <input.txt> <output.pdf>\n")
        return 2
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    pdf_bytes = build_pdf(src.read_text(encoding="utf-8"))
    dst.write_bytes(pdf_bytes)
    print(f"wrote {dst} ({len(pdf_bytes)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
