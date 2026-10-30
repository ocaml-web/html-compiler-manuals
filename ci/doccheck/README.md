# doccheck — `.html.json` parser-fidelity guard

`check.ml` is a **verbatim copy** of the `.html.json` parsing layer from
ocaml.org (`src/ocamlorg_package/lib/documentation.ml`, `doc_from_string` and its
helpers), with the `Package` dependency dropped and a `main` added that runs it
over files given on the command line.

The build pipeline (`scripts/build-odoc-sherlodoc.sh`) runs this executable over
every `*.html.json` emitted by `odoc_driver --json-output`. It exits non-zero if
any page fails to parse.

The `.html.json` fragment format is **explicitly unstable** and must move in
lockstep with ocaml.org's parser (consumer RFC: ocaml/ocaml.org#3909). When this
checker starts failing after an odoc/sherlodoc upgrade, **refresh `check.ml` from
ocaml.org's current `documentation.ml`** — do not patch the generated output to
fit a stale parser.
