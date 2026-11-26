"""Parse an uploaded document to plain text on the CPU front door.

Backs the writing-assistant ingestion of the author's OWN unpublished writing
(PDF / ePub / DOCX / Markdown / plain text). There is NO GPU dispatch — this
runs on the always-warm FastAPI container, the same economic case the barcode,
cover-text and `/embed` passes make — and the bytes are never persisted past
this call: the caller chunks the returned text, embeds it, and discards the
original, keeping the retention surface to the encrypted chunks.

⚖️ THE HEAVY PARSERS ARE LAZY-IMPORTED, like `text_embed` loads bge-m3 on first
use. `fitz` (PyMuPDF), `docx` (python-docx) and `ebooklib` are imported INSIDE
the branch that needs them, not at module top, so importing this module — and
therefore `app.main` — stays cheap, and CI need not have a given parser
installed unless a test actually exercises that format. Only the format a
request uses is ever loaded.

⚖️ TOLERANT TEXT DECODE, NOT STRICT. `txt`/`md` decode UTF-8 with `replace`:
the caller has declared the format, and a stray non-UTF-8 byte should cost one
replacement character, not the whole document. Markdown is returned as its raw
text — the downstream chunker owns markdown structure, so nothing semantic is
stripped here.
"""

from __future__ import annotations

import io
import re
from html.parser import HTMLParser

# The formats the endpoint accepts, lowercased. `txt` and `md` share a branch
# (md is returned raw); the other three each own a parser.
SUPPORTED_FORMATS = frozenset({"txt", "md", "pdf", "docx", "epub"})


class UnsupportedFormatError(ValueError):
    """Raised for a `format` outside `SUPPORTED_FORMATS`.

    The handler maps it to VisionError MALFORMED_REQUEST: resending the same
    unknown format cannot make the request valid, so the caller must not retry.
    """


def extract(content_bytes: bytes, fmt: str) -> tuple[str, int]:
    """Parse `content_bytes` of declared `fmt` to `(plain_text, char_count)`.

    `char_count` is `len(plain_text)` — Unicode code points, the cheap
    caller-side check the contract documents. A known format whose bytes carry
    no extractable text returns `("", 0)` rather than raising; the caller
    catches the zero count as a parse failure. An unknown `fmt` raises
    `UnsupportedFormatError`.

    Runs synchronously and is CPU-bound (PDF/epub parsing especially), so the
    handler offloads it to a worker thread rather than calling it on the ASGI
    event loop — the same offload `read_cover_text` and `embed_texts` get.
    """
    normalized = fmt.strip().lower()
    if normalized in ("txt", "md"):
        text = _extract_text(content_bytes)
    elif normalized == "pdf":
        text = _extract_pdf(content_bytes)
    elif normalized == "docx":
        text = _extract_docx(content_bytes)
    elif normalized == "epub":
        text = _extract_epub(content_bytes)
    else:
        raise UnsupportedFormatError(f"Unsupported document format: {fmt!r}")
    return text, len(text)


def _extract_text(content_bytes: bytes) -> str:
    """Plain text / Markdown: decode UTF-8, tolerant of stray bytes. Returned
    verbatim — the chunker downstream handles any markdown structure."""
    return content_bytes.decode("utf-8", errors="replace")


def _extract_pdf(content_bytes: bytes) -> str:
    """Concatenate the text layer of every page, in page order.

    ⚠️ Reads the text LAYER only: a scanned/image-only PDF with no embedded
    text yields "" (char_count 0), which the caller catches — this is not an
    OCR path. Page text is joined with newlines; PyMuPDF does not reconstruct
    multi-column reading order, so a heavily laid-out PDF can interleave
    columns. The author's prose manuscripts are single-column, the target here.
    """
    import fitz  # PyMuPDF — lazy; a ~22MB binary wheel, no torch.

    parts: list[str] = []
    with fitz.open(stream=content_bytes, filetype="pdf") as doc:
        for page in doc:
            parts.append(page.get_text())
    return "\n".join(parts)


def _extract_docx(content_bytes: bytes) -> str:
    """Join the document's paragraph text in order.

    ⚠️ Paragraphs only — text inside tables, headers and footers is not
    captured. The author's manuscripts are paragraph prose, the target here.
    """
    import docx  # python-docx — lazy.

    document = docx.Document(io.BytesIO(content_bytes))
    return "\n".join(paragraph.text for paragraph in document.paragraphs)


def _extract_epub(content_bytes: bytes) -> str:
    """Join the epub's document items in SPINE (reading) order, tag-stripped.

    The spine is the author-defined reading sequence; iterating it (rather than
    the unordered item list) keeps chapters in order. The navigation document
    (the generated table of contents) is skipped so its chapter-title list does
    not land in the prose. Any stray document item the spine does not reference
    is appended afterwards, defensively, so no body text is silently dropped.

    `read_epub` is handed a `BytesIO` — nothing touches disk. `ignore_ncx` is
    set to silence ebooklib's deprecation warning and keep the logs clean.
    """
    import ebooklib
    from ebooklib import epub

    book = epub.read_epub(io.BytesIO(content_bytes), options={"ignore_ncx": True})

    parts: list[str] = []
    seen: set[str | None] = set()
    for idref, _linear in book.spine:
        item = book.get_item_with_id(idref)
        if item is None or item.get_type() != ebooklib.ITEM_DOCUMENT:
            continue
        if isinstance(item, epub.EpubNav):
            continue
        seen.add(item.get_id())
        parts.append(_html_to_text(item.get_content()))

    for item in book.get_items_of_type(ebooklib.ITEM_DOCUMENT):
        if item.get_id() not in seen and not isinstance(item, epub.EpubNav):
            parts.append(_html_to_text(item.get_content()))

    return "\n\n".join(part for part in parts if part)


# Tags whose boundaries become line breaks, so block structure survives the
# strip as paragraph breaks instead of words running together.
_BLOCK_TAGS = frozenset(
    {
        "p",
        "div",
        "br",
        "li",
        "tr",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "blockquote",
        "section",
        "article",
        "figcaption",
        "pre",
    }
)

# Tags whose text content is metadata or scripting, never prose — dropped whole.
_SKIP_TAGS = frozenset({"script", "style", "head"})


class _TextExtractor(HTMLParser):
    """Collect the visible text of an (X)HTML document.

    `convert_charrefs=True` unescapes entities into the text stream. Block tags
    emit a newline at their boundaries so paragraphs stay separated; the content
    of `head`/`script`/`style` is suppressed entirely via a depth counter (so
    nesting cannot leave it half-on).
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._parts: list[str] = []
        self._skip_depth = 0

    def handle_starttag(self, tag: str, attrs: object) -> None:
        if tag in _SKIP_TAGS:
            self._skip_depth += 1
        elif tag in _BLOCK_TAGS:
            self._parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in _SKIP_TAGS:
            if self._skip_depth:
                self._skip_depth -= 1
        elif tag in _BLOCK_TAGS:
            self._parts.append("\n")

    def handle_data(self, data: str) -> None:
        if self._skip_depth == 0:
            self._parts.append(data)

    def text(self) -> str:
        return "".join(self._parts)


def _html_to_text(content: str | bytes) -> str:
    """Strip (X)HTML to plain text via the stdlib parser (no bs4/lxml-text dep),
    then normalise the whitespace the block-tag line breaks introduce.

    ebooklib hands document content back as `bytes` (the raw XHTML); the `str`
    branch is for robustness against a stub that widens the return type.
    """
    html = content.decode("utf-8", errors="replace") if isinstance(content, bytes) else content
    parser = _TextExtractor()
    parser.feed(html)
    parser.close()
    text = parser.text()
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()
