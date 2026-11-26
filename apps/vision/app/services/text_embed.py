"""Text embedding on CPU, in the front-door container that is already warm.

⚖️ WHY CPU IS THE POINT, AND WHY IT IS NEARLY FREE HERE. The sidecar runs two
Modal functions: the GPU model class, and this FastAPI front door on CPU with a
1200s scaledown. The embedding backend for the writing-assistant corpus (shelf
intent, blog posts, the author's imported writing) lives HERE, on the warm
front door, so a vector costs no GPU wake and opens no new billable GPU
lifetime. There is no second service and no `@modal` GPU dispatch, by
construction — the same economic case the barcode and cover-text passes make.

⛔ LAZY, FIRST-USE LOAD — THE ENCODER MUST NOT BLOCK CONTAINER START. bge-m3 is
~2.3GB of fp32 weights; loading it in `lifespan` would pay that on every cold
front door whether or not the request even embeds. It is loaded on the FIRST
`embed_texts` call instead (the shadow-OCR pattern), inside the worker thread
the handler offloads to, so the ASGI event loop is never blocked and the
barcode / cover-text / analyze paths that never embed never pay for it.

⚖️ THE MODEL IS STAMPED, NOT ECHOED. `embed_texts` returns the id of the model
that ACTUALLY ran, which the caller persists on every row — never the requested
value. A re-embed under a new model is then a coexisting backfill, not a
destructive one. `sentence-transformers` loads `BAAI/bge-m3`; the persisted
stamp is the short `bge-m3` the corpus keys on, decoupled from the HF repo id so
a mirror or a re-host does not rewrite every stored row's model column.

⚖️ VECTORS ARE L2-NORMALISED. bge-m3 dense retrieval is scored with cosine
similarity, and normalising here makes an inner-product search over pgvector
equal to cosine without the store having to normalise on write. This is the
canonical bge-m3 dense-retrieval usage; it is a semantic choice about the
vectors, called out so the consumer can veto it if the store wants raw weights.
"""

from __future__ import annotations

import logging
import threading

logger = logging.getLogger(__name__)

# The HuggingFace checkpoint the sidecar loads.
_HF_MODEL_ID = "BAAI/bge-m3"

# ⬛ THE STAMP THE CALLER PERSISTS — the short corpus key, not the HF repo id.
# The response's `model` is this, so a re-host of the weights under a different
# HF path leaves every stored row's model column unchanged and comparable.
SERVED_MODEL = "bge-m3"

# bge-m3's dense vector dimensionality. Reported on every response for a cheap
# caller-side check against the pgvector column width before a write. Derived
# from the loaded model at runtime (see `embed_texts`); this constant is the
# contract value and the fallback the tests pin.
MODEL_DIM = 1024

# ⛔ DOUBLE-CHECKED, LOCKED, FIRST-USE. `embed_texts` runs inside a worker
# thread (the handler offloads it), so two concurrent first requests would both
# try to load 2.3GB. The lock serialises the load; the outer `is None` check
# keeps every warm call lock-free.
_model_lock = threading.Lock()
_model: object | None = None


def _load_model() -> object:
    """Load bge-m3 once, on first use, in the calling worker thread.

    `sentence_transformers` is imported HERE, not at module top, so importing
    this module (and therefore `app.main`) costs nothing and needs neither the
    library nor the weights present — the CI suites mock `embed_texts` and never
    install the 2.3GB dependency. This mirrors `cover_text` importing
    `pytesseract` inside its read.
    """
    global _model
    if _model is None:
        with _model_lock:
            if _model is None:
                from sentence_transformers import SentenceTransformer

                logger.info("loading text embedder %s on cpu", _HF_MODEL_ID)
                _model = SentenceTransformer(_HF_MODEL_ID, device="cpu")
    return _model


def embed_texts(texts: list[str]) -> tuple[list[list[float]], str, int]:
    """Embed `texts` with bge-m3, returning `(vectors, model_stamp, dim)`.

    One vector per input text, in input order. `model_stamp` is the model that
    actually ran (the value the caller persists); `dim` is each vector's length,
    read from the loaded model so the reported dimensionality can never diverge
    from the vectors it describes.

    Runs synchronously and is CPU-heavy (the model load on first call, the
    encode on every call), so the handler offloads it to a worker thread rather
    than calling it on the event loop.
    """
    model = _load_model()
    # normalize_embeddings=True — see the module docstring: cosine via pgvector
    # inner product. convert_to_numpy for a plain (n, dim) array to list-ify.
    encoded = model.encode(  # type: ignore[attr-defined]
        texts,
        normalize_embeddings=True,
        convert_to_numpy=True,
    )
    dim = int(model.get_sentence_embedding_dimension())  # type: ignore[attr-defined]
    return [row.tolist() for row in encoded], SERVED_MODEL, dim
