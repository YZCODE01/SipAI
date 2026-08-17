#!/usr/bin/env python3
"""Render one CHANGELOG.md version section as the HTML Sparkle displays.

Sparkle shows an update's description in a WebView, and generate_appcast
picks that description up from ``<archive-basename>.html`` sitting beside
the archive. So the release notes the user reads in the update dialog are
whatever this produces — CHANGELOG.md stays the single source, and no
release note is ever written twice.

Usage:  changelog_to_html.py CHANGELOG.md 1.0.0 > SipAI-1.0.0.html

Handles the subset the changelog actually uses: ``###`` headings, ``-``
bullets with wrapped continuation lines, ``**bold**``, ``` `code` ``` and
``[text](url)``. Anything richer would be a changelog that has outgrown
being read inside a 400-point dialog.
"""

from __future__ import annotations

import html
import re
import sys

# Inline code is shielded BEFORE the other inline passes, so a ** inside a
# code span cannot be read as emphasis and a _ cannot mangle snake_case —
# the same ordering the app's own renderer uses.
_CODE_SHIELD = "\x00CODE{}\x00"


def _inline(text: str) -> str:
    shielded: list[str] = []

    def stash(match: re.Match[str]) -> str:
        shielded.append(match.group(1))
        return _CODE_SHIELD.format(len(shielded) - 1)

    text = re.sub(r"`([^`]+)`", stash, text)
    text = html.escape(text, quote=False)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)

    for i, code in enumerate(shielded):
        text = text.replace(
            _CODE_SHIELD.format(i), f"<code>{html.escape(code, quote=False)}</code>"
        )
    return text


def extract(markdown: str, version: str) -> list[str]:
    """The lines under ``## [version]``, up to the next ``## `` heading."""
    lines = markdown.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.startswith(f"## [{version}]"):
            start = i + 1
            break
    if start is None:
        raise SystemExit(f"no '## [{version}]' section in the changelog")

    body: list[str] = []
    for line in lines[start:]:
        if line.startswith("## "):
            break
        # Link-reference definitions ("[1.0.0]: https://…") are markdown
        # plumbing, not something to show in the dialog.
        if re.match(r"^\[[^\]]+\]:\s", line):
            continue
        body.append(line)
    return body


def render(body: list[str]) -> str:
    out: list[str] = []
    in_list = False
    # A bullet's continuation lines are indented, and joining them is what
    # keeps a wrapped sentence one sentence rather than several stray ones.
    pending: str | None = None

    def flush() -> None:
        nonlocal pending
        if pending is not None:
            out.append(f"    <li>{_inline(pending)}</li>")
            pending = None

    def close_list() -> None:
        nonlocal in_list
        flush()
        if in_list:
            out.append("  </ul>")
            in_list = False

    for line in body:
        stripped = line.strip()

        if not stripped:
            flush()
            continue

        if stripped.startswith("### "):
            close_list()
            out.append(f"  <h3>{_inline(stripped[4:])}</h3>")
            continue

        if stripped.startswith("- "):
            flush()
            if not in_list:
                out.append("  <ul>")
                in_list = True
            pending = stripped[2:]
            continue

        if pending is not None:
            pending += " " + stripped
            continue

        close_list()
        out.append(f"  <p>{_inline(stripped)}</p>")

    close_list()
    return "\n".join(out)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    path, version = sys.argv[1], sys.argv[2]

    with open(path, encoding="utf-8") as handle:
        body = extract(handle.read(), version)

    # Sparkle renders this inside its own window, so the styling stays
    # minimal and system-native, and follows the user's appearance rather
    # than pinning colours that would glare in dark mode.
    print(
        f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
  :root {{ color-scheme: light dark; }}
  body {{
    font: 13px/1.55 -apple-system, BlinkMacSystemFont, sans-serif;
    margin: 0; padding: 4px 2px;
  }}
  h3 {{ font-size: 13px; margin: 14px 0 6px; }}
  h3:first-child {{ margin-top: 0; }}
  ul {{ margin: 0; padding-left: 20px; }}
  li {{ margin-bottom: 6px; }}
  code {{
    font: 11.5px ui-monospace, SFMono-Regular, Menlo, monospace;
    background: color-mix(in srgb, currentColor 10%, transparent);
    padding: 1px 4px; border-radius: 3px;
  }}
</style></head>
<body>
{render(body)}
</body></html>"""
    )


if __name__ == "__main__":
    main()
