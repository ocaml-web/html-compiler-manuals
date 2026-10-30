#!/usr/bin/env bash
# Reproduce the odig -> sherlodoc -> js static-HTML search prototype end to end,
# indexing the OCaml standard library AND compiler-libs, then generating odoc
# HTML wired to the client-side (serverless) search.
#
# Nothing here is committed as a build artifact; everything is regenerated.
# Requires: opam. Creates an isolated local switch in ./_switch so your global
# switch is untouched.
#
# Usage:  ./reproduce.sh            # full pipeline, leaves a servable ./_html
#         PORT=8777 ./reproduce.sh  # also pick the local server port
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

OCAML_VERSION="${OCAML_VERSION:-ocaml-base-compiler.5.3.0}"
PORT="${PORT:-8777}"

# 1. Isolated switch with the tooling (compiles a compiler the first time).
if [ ! -d _switch/_opam ]; then
  mkdir -p _switch
  opam switch create ./_switch "$OCAML_VERSION" sherlodoc odig odoc -y
fi
RUN() { opam exec --switch=./_switch -- "$@"; }

# 2. Generate odoc docs for the whole switch (includes the `ocaml` package =
#    stdlib, with compiler-libs under ocaml/compiler-libs/).
RUN odig odoc

CACHE="$(RUN sh -c 'echo $OPAM_SWITCH_PREFIX')/var/cache/odig/odoc"

# 3. Collect stdlib + compiler-libs .odocl into a file-list (drop hidden __
#    aliases; stdlib submodules live inside stdlib.odocl, so nothing is lost).
mkdir -p _html
find "$CACHE/ocaml" -name '*.odocl' | grep -v '__' > _html/odocls.txt
echo "indexing $(wc -l < _html/odocls.txt) odocl units (stdlib + compiler-libs)"

# 4. Build the client-side JS database and emit the search engine.
#    NOTE: released sherlodoc (3.2.1) does NOT support repeating --db, so the
#    marshal DB (handy for CLI checks) is a separate pass.
RUN sherlodoc index --format js --file-list _html/odocls.txt --db _html/db.js
RUN sherlodoc js > _html/sherlodoc.js
RUN sherlodoc index --format marshal --file-list _html/odocls.txt --db _html/sherlodoc.marshal

# 5. Generate odoc HTML wired to the search assets.
#    IMPORTANT: db.js MUST come before sherlodoc.js. The worker importScripts()
#    in flag order and sherlodoc.js calls sherlodoc_db() at load, so the DB has
#    to be defined first. (The upstream README's order is reversed and fails
#    with "sherlodoc_db is not a function" on 3.2.1 -- see README.md.)
RUN odoc support-files -o _html
for u in ocaml/stdlib.odocl \
         ocaml/compiler-libs/typedtree.odocl \
         ocaml/compiler-libs/cmt_format.odocl \
         ocaml/compiler-libs/env.odocl; do
  RUN odoc html-generate --search-uri db.js --search-uri sherlodoc.js -o _html "$CACHE/$u"
done

# 6. CLI smoke test (uses the marshal DB).
echo "== CLI smoke test =="
RUN sherlodoc search --db _html/sherlodoc.marshal "List.map" | head -3
RUN sherlodoc search --db _html/sherlodoc.marshal ": Env.t" | head -3

cat <<EOF

Done. Serve and open in a browser:

  python3 -m http.server $PORT --bind 127.0.0.1 --directory "$HERE/_html"
  xdg-open http://127.0.0.1:$PORT/ocaml/Stdlib/index.html

Then click the search box (or press '/') and try:  List.map   : Env.t   : ('a -> 'b) -> 'a list -> 'b list

Optional headless-browser check of the live page (needs google-chrome + python3-websocket):
  echo "PORT=$PORT" > /tmp/sherlo_port
  google-chrome --headless=new --disable-gpu --no-sandbox \\
    --remote-allow-origins='*' --remote-debugging-port=9222 --user-data-dir=/tmp/chrome-sherlo about:blank &
  python3 cdp_search_test.py
EOF
