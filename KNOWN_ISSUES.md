# Known Issues

A running list of known issues in this repository. Each entry below has a
short summary here and a detailed write-up in the section that follows.

## Index

1. [RAG demo: the two indexers are mutually destructive on the `rag-demo` Qdrant collection](#1-rag-demo-the-two-indexers-are-mutually-destructive-on-the-rag-demo-qdrant-collection)
2. [LobeChat MCP session retry requires a local patch (`patches/route.js`)](#2-lobechat-mcp-session-retry-requires-a-local-patch-patchesroutejs)

---

## 1. RAG demo: the two indexers are mutually destructive on the `rag-demo` Qdrant collection

**Where:** `docs/rag-demo/index_docs.py`, `docs/rag-demo/index_docs_fastembed.py`, `docs/rag-demo/query.py`

**Symptom:** Either the MCP server's `qdrant-find` tool returns no/garbled results, **or** `docs/rag-demo/query.py` returns no results — but never both work at the same time after a fresh re-index.

**Root cause:** Both indexer scripts target the same Qdrant collection `rag-demo`
(`http://localhost:47010`) using the same embedding model
(`sentence-transformers/all-MiniLM-L6-v2`, 384-dim), but they write **incompatible
vector layouts**:

- `index_docs.py` uses Haystack's `QdrantDocumentStore` with
  `recreate_index=True`. Haystack's default is to write **unnamed vectors**.
  `query.py` reads from this layout via `QdrantEmbeddingRetriever`.

- `index_docs_fastembed.py` deletes and recreates the collection with a
  **named vector slot** `fast-all-minilm-l6-v2` and a payload shape
  `{"document": <chunk>, "metadata": {"file_path": ...}}`. This is the layout
  `mcp-server-qdrant` (the `qdrant-mcp` server registered in MCPHub) expects
  for `qdrant-find` / `qdrant-store`.

Because both scripts call `recreate_index` / `delete_collection` on the same
collection name, whichever one ran last wins. There is no shared state telling
a reader which layout currently lives in Qdrant.

**Consequences:**
- After running `index_docs.py`, the `qdrant-mcp` MCP server returns empty
  results — its fastembed embedder cannot match against unnamed Haystack
  vectors. The `RAG Sage` LobeChat agent (see `docs/agent-rag-sage.md`) stops
  grounding.
- After running `index_docs_fastembed.py`, `query.py` returns no documents —
  the Haystack retriever can't find unnamed vectors because there aren't any.

**Workarounds:**
- Pick one indexer for any given window and stick with it.
- For MCP-driven RAG (the production path used by `RAG Sage` in LobeChat):
  run `index_docs_fastembed.py` and accept that `query.py` will not work
  until re-indexed.
- For local smoke testing of retrieval quality without MCP:
  run `index_docs.py` and use `query.py`, knowing the MCP server is then
  unusable until re-indexed.

**Possible fixes (not yet implemented):**
- Split into two separate Qdrant collections (e.g., `rag-demo` for the
  MCP-compatible layout, `rag-demo-haystack` for the native Haystack layout),
  and update `query.py` plus any MCPHub references accordingly.
- Drop `index_docs.py` and have `query.py` read the named-vector layout
  directly via `qdrant-client`, so there is exactly one indexer and one query
  path. This loses some Haystack ergonomics on the read side but eliminates
  the conflict.

---

## 2. LobeChat MCP session retry requires a local patch (`patches/route.js`)

**Where:** `patches/route.js` (referenced from `CLAUDE.md` under "Key Configuration Files").

**Symptom:** Upstream LobeChat's MCP session handling does not retry cleanly
when a session is interrupted, so the stack ships with a hotfix patch applied
on top of the upstream image.

**Status:** This is a **carried patch**, not a fix that has been merged upstream.
That means:
- Every LobeChat image bump risks regressing the behavior if the patched file
  has moved or changed shape in the new version.
- Anyone rebuilding the stack from scratch must ensure the patch is applied
  (the patch lives in this repo at `patches/route.js`).

**Action items (not yet done):**
- Track the upstream LobeChat issue / PR that this patch corresponds to
  (link missing — needs to be added to the patch file header).
- On each LobeChat version bump, re-verify the patch still applies cleanly
  and that the underlying bug is still present.
- Once upstream merges an equivalent fix, delete the patch and pin to the
  fixed LobeChat version.

---

_Last reviewed: 2026-05-27._
