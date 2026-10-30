(* Verbatim copy of the .html.json parsing layer from
   ocaml.org src/ocamlorg_package/lib/documentation.ml (lines 267-372),
   minus the Package dependency, plus a main that runs it over files. *)

type toc = { title : string; href : string; children : toc list }

type breadcrumb_kind =
  | Page
  | LeafPage
  | Module
  | ModuleType
  | Parameter of int
  | Class
  | ClassType
  | File
  | Source

let breadcrumb_kind_from_string s =
  match s with
  | "page" -> Page
  | "leaf-page" -> LeafPage
  | "module" -> Module
  | "module-type" -> ModuleType
  | "class" -> Class
  | "class-type" -> ClassType
  | "file" -> File
  | "source" -> Source
  | _ ->
      if String.starts_with ~prefix:"argument-" s then
        let i = List.hd (List.tl (String.split_on_char '-' s)) in
        Parameter (int_of_string i)
      else raise (Invalid_argument ("kind not recognized: " ^ s))

type breadcrumb = {
  name : string;
  href : string option;
  kind : breadcrumb_kind;
}

type t = {
  uses_katex : bool;
  toc : toc list;
  breadcrumbs : breadcrumb list;
  content : string;
}

let rec toc_of_json = function
  | `Assoc
      [
        ("title", `String title);
        ("href", `String href);
        ("children", `List children);
      ] ->
      { title; href; children = List.map toc_of_json children }
  | _ -> raise (Invalid_argument "malformed toc field")

let breadcrumb_from_json = function
  | `Assoc
      [ ("name", `String name); ("href", `String href); ("kind", `String kind) ]
    ->
      { name; href = Some href; kind = breadcrumb_kind_from_string kind }
  | `Assoc [ ("name", `String name); ("href", `Null); ("kind", `String kind) ]
    ->
      { name; href = None; kind = breadcrumb_kind_from_string kind }
  | _ -> raise (Invalid_argument "malformed breadcrumb field")

let doc_from_string s =
  match Yojson.Safe.from_string s with
  | `Assoc
      [
        ("header", `String header);
        ("type", `String _page_type);
        ("uses_katex", `Bool uses_katex);
        ("breadcrumbs", `List json_breadcrumbs);
        ("toc", `List json_toc);
        ("source_anchor", _);
        ("preamble", `String preamble);
        ("content", `String content);
      ] ->
      let breadcrumbs = List.map breadcrumb_from_json json_breadcrumbs in
      {
        uses_katex;
        breadcrumbs;
        toc = List.map toc_of_json json_toc;
        content = String.concat "" [ header; preamble; content ];
      }
  | `Assoc
      [
        ("type", `String "source");
        ("breadcrumbs", `List json_breadcrumbs);
        ("global_toc", _);
        ("header", `String header);
        ("content", `String content);
      ] ->
      let breadcrumbs = List.map breadcrumb_from_json json_breadcrumbs in
      let content = header ^ content in
      { uses_katex = false; breadcrumbs; toc = []; content }
  | _ -> raise (Invalid_argument "malformed .html.json file")

(* main: parse each file given on the command line; print PASS/FAIL per file
   and a final tally. *)
let () =
  let files = List.tl (Array.to_list Sys.argv) in
  let pass = ref 0 and fail = ref 0 in
  List.iter
    (fun f ->
      let ic = open_in_bin f in
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic;
      match doc_from_string s with
      | d ->
          incr pass;
          if !pass <= 3 then
            Printf.printf "PASS %s (breadcrumbs=%d toc=%d content=%dB)\n" f
              (List.length d.breadcrumbs) (List.length d.toc)
              (String.length d.content)
      | exception e ->
          incr fail;
          Printf.printf "FAIL %s: %s\n" f (Printexc.to_string e))
    files;
  Printf.printf "TOTAL: %d pass, %d fail\n" !pass !fail;
  if !fail > 0 then exit 1
