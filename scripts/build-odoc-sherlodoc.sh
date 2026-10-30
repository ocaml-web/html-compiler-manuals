#!/usr/bin/env bash
# Build native odoc HTML + client-side sherlodoc search AND the .html.json
# fragment tree (the format ocaml-docs-ci emits and ocaml.org consumes) for one
# OCaml minor release, verify the fragments parse with ocaml.org's own reader,
# and package the result as a tarball.
#
# Usage: scripts/build-odoc-sherlodoc.sh <minor> [outdir]
#   <minor>   OCaml minor version, e.g. 5.3  (floor is 5.3 — the odoc toolchain
#             does not support older compilers)
#   [outdir]  HTML output directory (default: _out)
#
# Generalized from the verified prototype prototypes/sherlodoc/reproduce_v2.sh.
# One `odoc_driver` run emits both halves; see that script and its README for the
# provenance. Consumer-side RFC: ocaml/ocaml.org#3909, CI companion: issue #14.
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <minor> [outdir]" >&2
  exit 2
fi

MINOR="$1"
OUTDIR="${2:-_out}"

# Repo root, so ci/doccheck and the tarball land in predictable places
# regardless of the caller's cwd.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SWITCH_DIR="${SWITCH_DIR:-$REPO_ROOT/_switch}"
TARBALL="${TARBALL:-$REPO_ROOT/ocaml-$MINOR-odoc-sherlodoc-html.tar.gz}"

# 1. Resolve <minor> to a concrete compiler package. opam needs an exact version
#    (`5.3` is not a package version). Prefer the newest released
#    ocaml-base-compiler patch for this minor; fall back to ocaml-variants.
pick_newest() { tr ' ' '\n' | grep -E "^${MINOR//./\\.}\\." | sort -V | tail -n1; }

BASE_VERSIONS="$(opam show -f all-versions ocaml-base-compiler 2>/dev/null || true)"
COMPILER_VERSION="$(printf '%s' "$BASE_VERSIONS" | pick_newest || true)"
COMPILER_PKG=""
if [ -n "$COMPILER_VERSION" ]; then
  COMPILER_PKG="ocaml-base-compiler.$COMPILER_VERSION"
else
  VARIANT_VERSIONS="$(opam show -f all-versions ocaml-variants 2>/dev/null || true)"
  COMPILER_VERSION="$(printf '%s' "$VARIANT_VERSIONS" | pick_newest || true)"
  if [ -n "$COMPILER_VERSION" ]; then
    COMPILER_PKG="ocaml-variants.$COMPILER_VERSION"
  fi
fi

if [ -z "$COMPILER_PKG" ]; then
  echo "ERROR: no ocaml-base-compiler or ocaml-variants package for OCaml $MINOR" \
       "found in the current opam repositories." >&2
  echo "       (A manual/ dir can exist here before the compiler is released on" \
       "opam; that version cannot get odoc docs yet.)" >&2
  exit 1
fi
echo ">> OCaml $MINOR -> $COMPILER_PKG"

# 2. Isolated switch. odoc-driver pulls odoc, sherlodoc and odoc-md with it;
#    yojson and dune ride along, which is all the parser check below needs.
if [ ! -d "$SWITCH_DIR/_opam" ]; then
  mkdir -p "$SWITCH_DIR"
  opam switch create "$SWITCH_DIR" "$COMPILER_PKG" odoc-driver -y
fi

# GOTCHA (from reproduce_v2.sh): pin the switch via OPAMSWITCH, not
# `opam exec --switch` alone. `opam exec --switch=` puts the switch's binaries on
# PATH but does NOT override an inherited OPAMSWITCH/OPAM_SWITCH_PREFIX (e.g. set
# by direnv). odoc_driver makes its own opam queries, which then resolve the
# WRONG switch: odoc reads another compiler's .cmt files and crashes in
# Cmt_format.read (magic mismatch) under `odoc classify`.
export OPAMSWITCH="$SWITCH_DIR"
unset OPAM_SWITCH_PREFIX
RUN() { opam exec -- "$@"; }

# 3. The whole pipeline in one command: odoc for every package in the switch
#    (`ocaml` selects its dependency closure; the real content lands under
#    ocaml-compiler/<library>/), sherlodoc DBs, search assets wired in the
#    correct order. --json-output additionally emits one .html.json per page
#    plus per-package sidebar.json and status.json.
rm -rf "$OUTDIR"
RUN odoc_driver ocaml --json-output --html-dir "$OUTDIR"

N_HTML="$(find "$OUTDIR" -name '*.html' | wc -l)"
N_JSON="$(find "$OUTDIR" -name '*.html.json' | wc -l)"
echo ">> pages (html):      $N_HTML"
echo ">> pages (html.json): $N_JSON"

# 4. Parser-fidelity check: ci/doccheck/check.ml is a verbatim copy of
#    doc_from_string and helpers from ocaml.org. Every .html.json must parse, or
#    the exit status is non-zero. (See ci/doccheck/README.md for lockstep rules.)
RUN dune build --root ci/doccheck
find "$OUTDIR" -name '*.html.json' -print0 \
  | xargs -0 ci/doccheck/_build/default/check.exe

# 5. Package the standalone tree (both halves plus search assets).
tar czf "$TARBALL" -C "$OUTDIR" .
echo ">> wrote $TARBALL"
