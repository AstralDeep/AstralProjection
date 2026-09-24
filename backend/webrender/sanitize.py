"""The renderer's only formatting path: escapes text first, then re-introduces a small
fixed subset of GFM markdown (code, links, emphasis, tables) as known-safe tags; used
by renderer.py and history.py.
"""

from __future__ import annotations

import html
import re
import secrets
from typing import Any

_ALLOWED_URL = re.compile(r"^(https?://|mailto:|/)", re.IGNORECASE)


def _esc(value: Any) -> str:
    if value is None:
        return ""
    return html.escape(str(value), quote=True)


def _safe_url(url: str) -> str:
    s = (url or "").strip()
    return s if _ALLOWED_URL.match(s) else "#"


_CODE = re.compile(r"`([^`]+)`")
_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
_BOLD = re.compile(r"\*\*([^*]+)\*\*|__([^_]+)__")
_STRIKE = re.compile(r"~~([^~]+)~~")
_EM = re.compile(r"(?<!\*)\*([^*]+)\*(?!\*)|(?<!_)_([^_]+)_(?!_)")
_INLINE_TOKEN = re.compile(rf"{_CODE.pattern}|{_LINK.pattern}")

_HR = re.compile(r"^(-{3,}|\*{3,}|_{3,})$")
_TABLE_SEP_CELL = re.compile(r"^:?-+:?$")
_LIST_START = re.compile(r"^(?:[-*]|\d+\.)\s+")
_TABLE_BODY_BREAK = re.compile(r"^(?:#{1,6}\s|>|```|(?:[-*]|\d+\.)\s)")
_UNESCAPED_PIPE = re.compile(r"(?<!\\)\|")


def inline_md(text: Any) -> str:
    return _inline_escaped(_esc(text))


# Emphasis must skip generated HTML: could corrupt an href's _blank
def _inline_escaped(s: str, *, links: bool = True) -> str:
    marker = f"\x00md{secrets.token_hex(16)}:"
    while marker in s:
        marker = f"\x00md{secrets.token_hex(16)}:"
    fragments: list[str] = []

    def protect(m: re.Match[str]) -> str:
        if m.group(1) is not None:
            fragment = (
                '<code class="text-astral-accent bg-white/5 px-1 rounded">'
                f'{m.group(1)}</code>'
            )
        else:
            label = _inline_escaped(m.group(2), links=False)
            url = _safe_url(m.group(3))
            fragment = (
                f'<a href="{url}" target="_blank" rel="noopener noreferrer" '
                'class="text-astral-primary hover:text-astral-secondary hover:underline">'
                f'{label}</a>'
            )
        token = f"{marker}{len(fragments)}{marker}"
        fragments.append(fragment)
        return token

    s = (_INLINE_TOKEN if links else _CODE).sub(protect, s)
    s = _BOLD.sub(lambda m: f'<strong class="text-astral-text">{m.group(1) or m.group(2)}</strong>', s)
    s = _STRIKE.sub(lambda m: f"<del>{m.group(1)}</del>", s)
    s = _EM.sub(lambda m: f"<em>{m.group(1) or m.group(2)}</em>", s)
    return re.sub(
        re.escape(marker) + r"(\d+)" + re.escape(marker),
        lambda m: fragments[int(m.group(1))],
        s,
    )


def _split_table_row(line: str) -> list[str]:
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|") and not s.endswith("\\|"):
        s = s[:-1]
    return [c.strip().replace("\\|", "|") for c in _UNESCAPED_PIPE.split(s)]


def _table_aligns(sep_line: str, n_cols: int):
    if "|" not in sep_line:
        return None
    cells = _split_table_row(sep_line)
    if len(cells) != n_cols:
        return None
    aligns = []
    for cell in cells:
        if not _TABLE_SEP_CELL.match(cell):
            return None
        if cell.startswith(":") and cell.endswith(":"):
            aligns.append("center")
        elif cell.endswith(":"):
            aligns.append("right")
        else:
            aligns.append("left")
    return aligns


def _render_md_table(headers: list[str], aligns: list[str], rows: list[list[str]]) -> str:
    align_cls = {"left": "text-left", "center": "text-center", "right": "text-right"}
    ths = "".join(
        f'<th scope="col" class="px-3 py-2 {align_cls[a]} text-xs font-semibold uppercase '
        f'tracking-wider text-astral-muted whitespace-nowrap">{inline_md(h)}</th>'
        for h, a in zip(headers, aligns)
    )
    trs = []
    for row in rows:
        cells = list(row[: len(headers)]) + [""] * (len(headers) - len(row))
        tds = "".join(
            f'<td class="px-3 py-2 {align_cls[a]} text-astral-text align-top">{inline_md(c)}</td>'
            for c, a in zip(cells, aligns)
        )
        trs.append(f'<tr class="border-t border-white/5">{tds}</tr>')
    return (
        '<div class="my-2 overflow-x-auto rounded-lg border border-white/10">'
        f'<table class="w-full text-sm"><thead class="bg-white/5"><tr>{ths}</tr></thead>'
        f'<tbody>{"".join(trs)}</tbody></table></div>'
    )


def block_md(text: Any) -> str:
    if text is None or text == "":
        return ""
    src = str(text).replace("\r\n", "\n").replace("\r", "\n")
    lines = src.split("\n")
    out: list[str] = []
    i = 0
    n = len(lines)

    def flush_para(buf: list[str]):
        if buf:
            joined = "<br>".join(inline_md(b) for b in buf)
            out.append(f'<p class="mb-2">{joined}</p>')
            buf.clear()

    para: list[str] = []
    while i < n:
        line = lines[i]
        stripped = line.strip()

        if stripped.startswith("```"):
            flush_para(para)
            lang = stripped[3:].strip()
            code_lines = []
            i += 1
            while i < n and not lines[i].strip().startswith("```"):
                code_lines.append(lines[i])
                i += 1
            i += 1
            lang_html = (f'<div class="px-4 py-2 border-b border-white/5 text-xs text-astral-muted">{_esc(lang)}</div>'
                         if lang else "")
            code = _esc("\n".join(code_lines))
            out.append(f'<div class="rounded-lg bg-black/40 border border-white/5 overflow-hidden my-2">{lang_html}'
                       f'<pre class="p-4 text-sm overflow-x-auto"><code class="text-green-400">{code}</code></pre></div>')
            continue

        m = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if m:
            flush_para(para)
            level = len(m.group(1))
            cls = {1: "text-2xl font-bold text-astral-text",
                   2: "text-xl font-semibold text-astral-text",
                   3: "text-lg font-medium text-astral-text",
                   4: "text-base font-semibold text-astral-text",
                   5: "text-sm font-semibold text-astral-text",
                   6: "text-sm font-medium text-astral-muted"}[level]
            out.append(f'<h{level} class="{cls} mb-2">{inline_md(m.group(2))}</h{level}>')
            i += 1
            continue

        if stripped.startswith(">"):
            flush_para(para)
            quote_lines = []
            while i < n and lines[i].strip().startswith(">"):
                quote_lines.append(lines[i].strip()[1:].strip())
                i += 1
            inner = "<br>".join(inline_md(q) for q in quote_lines)
            out.append(f'<blockquote class="border-l-2 border-astral-primary/40 pl-3 text-astral-text/80 my-2">{inner}</blockquote>')
            continue

        if "|" in stripped and i + 1 < n and not _LIST_START.match(stripped):
            headers = _split_table_row(stripped)
            aligns = _table_aligns(lines[i + 1].strip(), len(headers))
            if aligns is not None:
                flush_para(para)
                i += 2
                rows = []
                while (i < n and "|" in lines[i] and lines[i].strip()
                       and not _TABLE_BODY_BREAK.match(lines[i].strip())):
                    rows.append(_split_table_row(lines[i]))
                    i += 1
                out.append(_render_md_table(headers, aligns, rows))
                continue

        if _HR.match(stripped):
            flush_para(para)
            out.append('<hr class="border-white/10 my-3">')
            i += 1
            continue

        if re.match(r"^[-*]\s+", stripped) or re.match(r"^\d+\.\s+", stripped):
            flush_para(para)
            ordered = bool(re.match(r"^\d+\.\s+", stripped))
            items = []
            while i < n:
                ls = lines[i].strip()
                mm = re.match(r"^(?:[-*]|\d+\.)\s+(.*)$", ls)
                if not mm:
                    break
                items.append(f'<li class="leading-relaxed">{inline_md(mm.group(1))}</li>')
                i += 1
            tag = "ol" if ordered else "ul"
            lcls = "list-decimal" if ordered else "list-disc"
            out.append(f'<{tag} class="space-y-1 text-sm {lcls} list-inside text-astral-text my-2">{"".join(items)}</{tag}>')
            continue

        if stripped == "":
            flush_para(para)
            i += 1
            continue

        para.append(stripped)
        i += 1

    flush_para(para)
    return "".join(out)


def plain_md(text: Any) -> str:
    if text is None or text == "":
        return ""
    s = str(text).replace("\r\n", "\n").replace("\r", "\n")
    kept: list[str] = []
    fenced = False
    for line in s.split("\n"):
        stripped = line.strip()
        if stripped.startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            continue
        if _HR.match(stripped):
            continue
        stripped = re.sub(r"^#{1,6}\s*", "", stripped)
        stripped = re.sub(r"^>\s?", "", stripped)
        stripped = _LIST_START.sub("", stripped)
        if stripped and all(
            _TABLE_SEP_CELL.match(cell.strip())
            for cell in _UNESCAPED_PIPE.split(stripped)
            if cell.strip()
        ):
            continue
        stripped = _UNESCAPED_PIPE.sub(" ", stripped)
        if stripped:
            kept.append(stripped)
    out = " ".join(kept)
    out = _CODE.sub(lambda m: m.group(1), out)
    out = _LINK.sub(lambda m: m.group(1), out)
    out = _BOLD.sub(lambda m: m.group(1) or m.group(2), out)
    out = _STRIKE.sub(lambda m: m.group(1), out)
    out = _EM.sub(lambda m: m.group(1) or m.group(2), out)
    return re.sub(r"\s+", " ", out).strip()
