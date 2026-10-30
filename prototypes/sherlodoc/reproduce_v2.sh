#!/usr/bin/env bash
# v2 of the prototype: run odoc's own driver instead of the hand-rolled
# odig -> sherlodoc -> html-generate pipeline of reproduce.sh, and verify that
# the --json-output tree parses with ocaml.org's .html.json reader.
#
# One command produces BOTH a standalone odoc HTML site with client-side
# sherlodoc search AND the .html.json fragment tree (the format ocaml-docs-ci
# emits and ocaml.org consumes for /p/ docs). See the "v2" section of
# README.md; consumer-side RFC: ocaml/ocaml.org#3909, CI companion: #14.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

OCAML_VERSION="${OCAML_VERSION:-ocaml-base-compiler.5.3.0}"

# 1. Isolated switch. odoc-driver pulls odoc, sherlodoc and odoc-md with it
#    (all 3.2.1 at the time of writing); yojson and dune ride along, which is
#    all the parser check below needs.
if [ ! -d _switch/_opam ]; then
  mkdir -p _switch
  opam switch create ./_switch "$OCAML_VERSION" odoc-driver -y
fi

# GOTCHA: pin the switch via OPAMSWITCH, not `opam exec --switch` alone.
# `opam exec --switch=` puts the switch's binaries on PATH but does NOT
# override an inherited OPAMSWITCH/OPAM_SWITCH_PREFIX (e.g. set by direnv).
# odoc_driver makes its own opam queries, which then resolve the WRONG
# switch: odoc ends up reading another compiler's .cmt files and crashes in
# Cmt_format.read (magic mismatch) under `odoc classify`.
export OPAMSWITCH="$HERE/_switch"
unset OPAM_SWITCH_PREFIX
RUN() { opam exec -- "$@"; }

# 2. The whole v1 pipeline in one command: odoc for every package in the
#    switch (`ocaml` selects its dependency closure; the real content lands
#    under ocaml-compiler/<library>/), sherlodoc DBs, search assets wired in
#    the correct order. --json-output additionally emits one .html.json per
#    page plus per-package sidebar.json and status.json.
RUN odoc_driver ocaml --json-output --html-dir _html_v2

echo "pages (html):      $(find _html_v2 -name '*.html' | wc -l)"
echo "pages (html.json): $(find _html_v2 -name '*.html.json' | wc -l)"

# 3. Parser-fidelity check: doccheck/check.ml is a verbatim copy of
#    doc_from_string and its helpers from ocaml.org
#    (src/ocamlorg_package/lib/documentation.ml). Every .html.json page must
#    parse, or the exit status is non-zero.
RUN dune build --root doccheck
find _html_v2 -name '*.html.json' -print0 \
  | xargs -0 doccheck/_build/default/check.exe

cat <<EOF

Done. Serve the native-HTML half and try the search:

  python3 -m http.server 8777 --bind 127.0.0.1 --directory "\$PWD/_html_v2"
  xdg-open http://127.0.0.1:8777/ocaml-compiler/stdlib/Stdlib/index.html
EOF
