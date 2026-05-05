#!/usr/bin/env bash
# refresh-inkeep-corpus.sh
#
# Regenerates the embedded Windmill docs corpus consumed by /api/inkeep.
#
# Stages (Unix-pipe-style; each is independently testable):
#   fetch     — download https://www.windmill.dev/llms.txt
#   parse     — extract `- <Title>: <URL>` entries
#   strip     — fetch each page and convert HTML to plain text
#   build     — assemble {upstream_version, generated_at, entries: [...]} JSON
#   write     — atomic-replace windmill/backend/windmill-api/src/inkeep/corpus.json
#
# Required network egress: www.windmill.dev (HTTPS).
# Tool deps: bash, curl, python3 (stdlib only — uses html.parser).
# Run from repo root.
#
# Output schema:
#   {
#     "upstream_version": "<CARGO_PKG_VERSION at refresh time>",
#     "generated_at":     "<ISO-8601>",
#     "entries": [
#       {"title": "...", "url": "https://www.windmill.dev/docs/...", "body": "<plain-text, ≤10KB>"},
#       ...
#     ]
#   }
#
# Refresh-on-rebase ordering: this runs *after* the rebase against the version
# we're about to ship, never before. See TECHNICAL.md §9.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORPUS_DIR="$REPO_ROOT/windmill/backend/windmill-api/src/inkeep"
CORPUS_FILE="$CORPUS_DIR/corpus.json"
LLMS_URL="https://www.windmill.dev/llms.txt"
MAX_BODY_BYTES=10240
USER_AGENT="windmill-cloudron-corpus-refresh/1.0"

mkdir -p "$CORPUS_DIR"

# Stage: extract upstream version from windmill/backend/Cargo.toml
UPSTREAM_VERSION="$(
  awk -F\" '/^version[[:space:]]*=/ {print $2; exit}' \
    "$REPO_ROOT/windmill/backend/Cargo.toml"
)"
GENERATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "[refresh-inkeep-corpus] upstream version: $UPSTREAM_VERSION"
echo "[refresh-inkeep-corpus] generated at:     $GENERATED_AT"
echo "[refresh-inkeep-corpus] target file:      $CORPUS_FILE"

# Stage: fetch — grab the catalog
TMPDIR_REFRESH="$(mktemp -d -t inkeep-corpus.XXXXXX)"
trap 'rm -rf "$TMPDIR_REFRESH"' EXIT

LLMS_TXT="$TMPDIR_REFRESH/llms.txt"
echo "[refresh-inkeep-corpus] fetching $LLMS_URL"
curl -fsSL --max-time 30 -A "$USER_AGENT" -o "$LLMS_TXT" "$LLMS_URL"

# Stage: parse — extract `- <Title>: <URL>` entries into TSV
ENTRIES_TSV="$TMPDIR_REFRESH/entries.tsv"
python3 - "$LLMS_TXT" >"$ENTRIES_TSV" <<'PY'
import re, sys
pat = re.compile(r"^\s*-\s+(?P<title>[^:]+?):\s+(?P<url>https?://\S+)\s*$")
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        m = pat.match(line)
        if not m:
            continue
        title = m.group("title").strip()
        url = m.group("url").strip()
        # Tab-separated: title<TAB>url
        print(f"{title}\t{url}")
PY

ENTRY_COUNT="$(wc -l <"$ENTRIES_TSV" | tr -d ' ')"
echo "[refresh-inkeep-corpus] catalog entries:   $ENTRY_COUNT"
if [ "$ENTRY_COUNT" -lt 1 ]; then
    echo "[refresh-inkeep-corpus] ERROR: no entries parsed from llms.txt" >&2
    exit 1
fi

# Stage: strip — fetch each page, convert HTML to plain text, truncate.
PAGES_DIR="$TMPDIR_REFRESH/pages"
mkdir -p "$PAGES_DIR"

i=0
while IFS=$'\t' read -r title url; do
    i=$((i + 1))
    page_html="$PAGES_DIR/$i.html"
    page_txt="$PAGES_DIR/$i.txt"
    page_meta="$PAGES_DIR/$i.meta"

    printf "%s\t%s\n" "$title" "$url" >"$page_meta"

    if ! curl -fsSL --max-time 20 -A "$USER_AGENT" -o "$page_html" "$url"; then
        echo "[refresh-inkeep-corpus]   WARN: fetch failed for $url; skipping" >&2
        : >"$page_txt"
        continue
    fi

    python3 - "$page_html" "$page_txt" "$MAX_BODY_BYTES" <<'PY'
import sys
from html.parser import HTMLParser

src, dst, max_bytes = sys.argv[1], sys.argv[2], int(sys.argv[3])

class Stripper(HTMLParser):
    SKIP_TAGS = {"script", "style", "noscript", "svg", "nav", "header", "footer"}
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.skip_depth = 0
    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP_TAGS:
            self.skip_depth += 1
    def handle_endtag(self, tag):
        if tag in self.SKIP_TAGS and self.skip_depth > 0:
            self.skip_depth -= 1
    def handle_data(self, data):
        if self.skip_depth == 0:
            self.parts.append(data)

with open(src, encoding="utf-8", errors="replace") as f:
    html = f.read()

s = Stripper()
s.feed(html)
text = " ".join(" ".join(p.split()) for p in s.parts if p.strip())
# Byte-budget truncate (UTF-8 safe via decode-after-truncate fallback).
b = text.encode("utf-8")
if len(b) > max_bytes:
    b = b[:max_bytes]
    text = b.decode("utf-8", errors="ignore")
with open(dst, "w", encoding="utf-8") as out:
    out.write(text)
PY

    if [ $((i % 10)) -eq 0 ]; then
        echo "[refresh-inkeep-corpus]   processed $i / $ENTRY_COUNT"
    fi
done <"$ENTRIES_TSV"

# Stage: build — assemble final JSON.
echo "[refresh-inkeep-corpus] building corpus json"
python3 - "$PAGES_DIR" "$ENTRY_COUNT" "$UPSTREAM_VERSION" "$GENERATED_AT" "$CORPUS_FILE.tmp" <<'PY'
import json, os, sys

pages_dir, entry_count, upstream_version, generated_at, dest = sys.argv[1:6]
entry_count = int(entry_count)

entries = []
for i in range(1, entry_count + 1):
    meta_path = os.path.join(pages_dir, f"{i}.meta")
    txt_path = os.path.join(pages_dir, f"{i}.txt")
    if not (os.path.exists(meta_path) and os.path.exists(txt_path)):
        continue
    with open(meta_path, encoding="utf-8") as f:
        meta = f.read().rstrip("\n")
    if "\t" not in meta:
        continue
    title, url = meta.split("\t", 1)
    with open(txt_path, encoding="utf-8") as f:
        body = f.read()
    if not body.strip():
        continue
    entries.append({"title": title, "url": url, "body": body})

out = {
    "upstream_version": upstream_version,
    "generated_at": generated_at,
    "entries": entries,
}
with open(dest, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
print(f"[refresh-inkeep-corpus] entries with body: {len(entries)}")
PY

# Stage: write — atomic replace.
mv "$CORPUS_FILE.tmp" "$CORPUS_FILE"

CORPUS_BYTES="$(wc -c <"$CORPUS_FILE" | tr -d ' ')"
echo "[refresh-inkeep-corpus] wrote $CORPUS_FILE ($CORPUS_BYTES bytes)"
echo "[refresh-inkeep-corpus] done."