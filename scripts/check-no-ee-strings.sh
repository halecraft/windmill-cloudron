#!/usr/bin/env bash
# check-no-ee-strings.sh
#
# Grep-budget verification: ensures no user-visible "EE" / "enterprise" /
# "license" strings survive in the built frontend bundle or release Rust
# binary. Used by:
#   - Phase 7 manual verification (defang-ee plan)
#   - CI step
#   - setup-hooks.sh pre-commit hook
#
# Exits 0 if clean, 1 if forbidden strings found.
#
# Scope:
#   1. windmill/frontend/build/    (built SvelteKit bundle, if present)
#   2. windmill/backend/target/release/windmill  (release binary, if present)
#   3. Source-level guard: windmill/frontend/src and windmill/backend/{src,**/src}
#      for FORBIDDEN_PATTERNS introduced after the defang-ee plan landed.
#
# Allowed matches (excluded from the search):
#   - LICENSE-* / NOTICE / COPYING files
#   - source map files (*.map)
#   - *.lock files
#   - test fixtures / generated docs (openapi-*.yaml)
#   - Comments containing "defang-ee" (acknowledged context)
#   - .jj-plan/*.md (the plan itself naturally references EE)
#
# Run from repo root.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Forbidden user-facing phrases. Order matters only for readability of failures.
FORBIDDEN_PATTERNS=(
    "Enterprise Edition"
    "enterprise version"
    "enterprise license"
    "EE only"
    "(EE)"
    "enterprise feature"
    "enterprise license required"
    "is only available with an enterprise"
    "available only in the enterprise"
    "available only on Windmill Enterprise"
    "Windmill Enterprise Edition"
)

# Directories / globs to skip.
EXCLUDES=(
    --exclude-dir=node_modules
    --exclude-dir=.git
    --exclude-dir=.jj
    --exclude-dir=.jj-plan
    --exclude-dir=target
    --exclude-dir=.svelte-kit
    --exclude-dir=.sqlx
    --exclude-dir=tests
    --exclude-dir=test
    --exclude-dir=inkeep
    --exclude="LICENSE*"
    --exclude="NOTICE"
    --exclude="COPYING*"
    --exclude="*.lock"
    --exclude="*.map"
    --exclude="openapi-*.yaml"
    --exclude="openapi-*.json"
    --exclude="*.md"
    --exclude="corpus.json"
    --exclude="*.gen.ts"
    --exclude="*.gen.js"
    --exclude-dir=gen
)

FOUND=0
FOUND_LOG="$(mktemp -t check-no-ee-strings.XXXXXX)"
trap 'rm -f "$FOUND_LOG"' EXIT

scan_path() {
    local path="$1"
    local label="$2"

    if [ ! -e "$path" ]; then
        echo "[check-no-ee-strings] skip: $label (not present at $path)"
        return 0
    fi

    echo "[check-no-ee-strings] scanning: $label ($path)"

    for pat in "${FORBIDDEN_PATTERNS[@]}"; do
        # -F: fixed-string (don't treat parens as regex metachars)
        # -r -n -I: recursive, line numbers, skip binary
        # We DO want binary scan for compiled artifacts; handle that separately
        # below for build/ and target/release/.
        if [ -d "$path" ]; then
            grep -rnIF "${EXCLUDES[@]}" -- "$pat" "$path" >>"$FOUND_LOG" 2>/dev/null
        else
            grep -aF -- "$pat" "$path" >>"$FOUND_LOG" 2>/dev/null
        fi
    done
}

# 1. Source guards.
scan_path "windmill/frontend/src" "frontend source"
scan_path "windmill/backend/src" "backend main source"

# Backend per-crate src dirs (one level deep). Skip _oss.rs siblings of *_ee.rs
# because some doc-comments there reference EE for upstream-rebase parity but
# never reach a user.
for crate_src in windmill/backend/windmill-*/src windmill/backend/parsers/*/src; do
    [ -d "$crate_src" ] || continue
    scan_path "$crate_src" "$(basename "$(dirname "$crate_src")") source"
done

# 2. Built artifacts (when present).
scan_path "windmill/frontend/build" "frontend build output"

if [ -f "windmill/backend/target/release/windmill" ]; then
    echo "[check-no-ee-strings] scanning: release binary (string-extracting)"
    for pat in "${FORBIDDEN_PATTERNS[@]}"; do
        # `strings` extracts printable runs from the binary.
        if command -v strings >/dev/null 2>&1; then
            strings "windmill/backend/target/release/windmill" \
                | grep -F -- "$pat" \
                | sed "s|^|windmill/backend/target/release/windmill (binary): |" \
                >>"$FOUND_LOG" 2>/dev/null
        else
            grep -aF -- "$pat" "windmill/backend/target/release/windmill" \
                | sed "s|^|windmill/backend/target/release/windmill (binary): |" \
                >>"$FOUND_LOG" 2>/dev/null
        fi
    done
fi

# Filter the found list: drop lines that contain "defang-ee" (acknowledged
# context), or that are inside test source files we couldn't pre-exclude.
FILTERED_LOG="$(mktemp -t check-no-ee-strings-filtered.XXXXXX)"
trap 'rm -f "$FOUND_LOG" "$FILTERED_LOG"' EXIT

# Filter:
#   - "defang-ee" markers (acknowledged context)
#   - test fixtures we couldn't pre-exclude
#   - Rust doc-comment / regular comment lines (`///`, `//!`, `//`) — these are
#     developer-facing source documentation, never reach the user-facing UI or
#     job logs. Format from grep is `path:lineno:content`, so we match the
#     content portion (third+ fields).
grep -v \
    -e "defang-ee" \
    -e "/tests/" \
    -e "/test/" \
    -e "_test\." \
    -e "\.test\." \
    -e ":[[:space:]]*///" \
    -e ":[[:space:]]*//!" \
    -e ":[[:space:]]*//[^/]" \
    "$FOUND_LOG" >"$FILTERED_LOG" || true

if [ -s "$FILTERED_LOG" ]; then
    echo ""
    echo "[check-no-ee-strings] FAIL: forbidden EE/enterprise/license strings found:"
    echo ""
    cat "$FILTERED_LOG"
    echo ""
    echo "[check-no-ee-strings] If a hit is intentional (e.g. neutralized error"
    echo "string still includes the word 'license' for legal reasons), add a"
    echo "'defang-ee' marker comment on the same line, or extend the EXCLUDES"
    echo "list in scripts/check-no-ee-strings.sh."
    FOUND=1
else
    echo "[check-no-ee-strings] OK: no forbidden strings found."
fi

exit $FOUND