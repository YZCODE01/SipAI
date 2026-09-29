#!/usr/bin/env python3
"""Write a small, complete, honestly-compressed PNG for the harness.

Usage: make_png.py <path> [width] [height]

A real encoder rather than a byte dump, for the reason
Verification/ChatAttachments documents: ImageIO withholds the
dimensions of a PNG whose pixel stream is inconsistent with its header,
so a fake would pass `ChatAttachment.load` for the wrong reason.
"""
import struct
import sys
import zlib


def chunk(tag, body):
    return (struct.pack(">I", len(body)) + tag + body
            + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF))


def png(width, height):
    rows = b"".join(b"\x00" + bytes([200, 40, 40, 255] * width) for _ in range(height))
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


path = sys.argv[1]
width = int(sys.argv[2]) if len(sys.argv) > 2 else 4
height = int(sys.argv[3]) if len(sys.argv) > 3 else 4
with open(path, "wb") as f:
    f.write(png(width, height))
