(* OCaml port of cdp_search_test.py, extended to a parity check.
   Drives a real headless Chrome over the Chrome DevTools Protocol (using the
   `cdp` library for JSON-RPC framing + response/event demux) to verify that the
   odoc/sherlodoc static-HTML search can find every top-level module documented
   in 5.3/api (stdlib + compiler-libs).

   For each module M it types "M." into the generated page's search bar, lets the
   sherlodoc Web Worker answer, reads the rendered results from the DOM, and
   checks that M appears as a dotted path segment in some result.

   Transport note: `cdp` is transport-agnostic, so we bring our own --
   cohttp-lwt-unix for the /json discovery and websocket-lwt-unix for the socket.

   Usage: parity_test [PAGE_URL] [MODULES_FILE] [CDP_PORT]
   Defaults: http://127.0.0.1:8777/ocaml/Stdlib/index.html  parity_modules.txt  9222 *)

let ( let* ) = Lwt.bind

let host = "127.0.0.1"

(* ---- CDP discovery: find the page target's websocket debugger URL ---- *)
let discover_ws_url port =
  let uri = Uri.of_string (Printf.sprintf "http://%s:%d/json" host port) in
  let* _resp, body = Cohttp_lwt_unix.Client.get uri in
  let* body = Cohttp_lwt.Body.to_string body in
  let targets = Yojson.Basic.from_string body in
  let open Yojson.Basic.Util in
  let pages =
    to_list targets
    |> List.filter (fun t -> member "type" t |> to_string_option = Some "page")
  in
  match pages with
  | t :: _ -> Lwt.return (member "webSocketDebuggerUrl" t |> to_string)
  | [] -> Lwt.fail_with "no CDP page target (is Chrome running with --remote-debugging-port?)"

(* ---- JSON-RPC over the websocket, correlated by id via Cdp_envelope ---- *)
let next_id = ref 0

let call conn ~name ~params =
  incr next_id;
  let id = !next_id in
  let req = Cdp_envelope.request ~id ~name ~params () in
  let content = Yojson.Basic.to_string req in
  let* () =
    Websocket_lwt_unix.write conn
      (Websocket.Frame.create ~opcode:Websocket.Frame.Opcode.Text ~content ())
  in
  let rec loop () =
    let* fr = Websocket_lwt_unix.read conn in
    match fr.Websocket.Frame.opcode with
    | Websocket.Frame.Opcode.Close -> Lwt.fail_with "websocket closed by browser"
    | Websocket.Frame.Opcode.Ping ->
        let* () =
          Websocket_lwt_unix.write conn
            (Websocket.Frame.create ~opcode:Websocket.Frame.Opcode.Pong
               ~content:fr.Websocket.Frame.content ())
        in
        loop ()
    | _ -> (
        match Cdp_envelope.parse (Yojson.Basic.from_string fr.Websocket.Frame.content) with
        | Ok (Cdp_envelope.Response { id = rid; outcome; _ }) when rid = id -> (
            match outcome with
            | Ok j -> Lwt.return j
            | Error e -> Lwt.fail_with ("CDP error: " ^ e.Cdp_envelope.message))
        | _ -> loop () (* event, or a response to another id: skip *))
  in
  loop ()

(* ---- Runtime.evaluate helpers (result is Cdp_json.t = Yojson.Basic.t) ---- *)
let evaluate conn expr =
  let params =
    `Assoc
      [ ("expression", `String expr); ("returnByValue", `Bool true); ("awaitPromise", `Bool true) ]
  in
  let* j = call conn ~name:"Runtime.evaluate" ~params:(Some params) in
  Lwt.return (Yojson.Basic.Util.(j |> member "result" |> member "value"))

let eval_bool conn expr =
  let* v = evaluate conn expr in
  Lwt.return (match v with `Bool b -> b | _ -> false)

let eval_string conn expr =
  let* v = evaluate conn expr in
  Lwt.return (match v with `String s -> s | _ -> "")

(* ---- the page interactions, mirroring cdp_search_test.py ---- *)
let js_set query =
  (* clear previous results, focus (lazily creates the Web Worker), type, fire input *)
  let q = Yojson.Basic.to_string (`String query) in
  Printf.sprintf
    {|(() => { const i=document.querySelector(".search-bar"); if(!i) return false;
       const r=document.querySelector(".search-result"); if(r) r.innerHTML="";
       i.focus(); i.dispatchEvent(new Event("focus"));
       i.value=%s; i.dispatchEvent(new Event("input",{bubbles:true})); return true; })()|}
    q

let js_read =
  {|(() => { const r=document.querySelector(".search-result"); return r ? r.innerText : ""; })()|}

(* poll until the worker has rendered something (results or "No result...") *)
let rec poll conn n =
  if n <= 0 then Lwt.return ""
  else
    let* txt = eval_string conn js_read in
    if String.trim txt <> "" then
      let* () = Lwt_unix.sleep 0.4 in
      eval_string conn js_read
    else
      let* () = Lwt_unix.sleep 0.3 in
      poll conn (n - 1)

(* dotted-path-segment match: does M appear as a whole segment in the results? *)
let tokens s =
  let buf = Buffer.create 32 and acc = ref [] in
  let flush () =
    if Buffer.length buf > 0 then (acc := Buffer.contents buf :: !acc; Buffer.clear buf)
  in
  String.iter
    (fun c ->
      match c with
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> Buffer.add_char buf c
      | _ -> flush ())
    s;
  flush ();
  !acc

let found_segment m txt = List.mem m (tokens txt)

let check conn m =
  let* _ = eval_bool conn (js_set (m ^ ".")) in
  let* txt = poll conn 40 in
  Lwt.return (found_segment m txt)

(* ---- modules file: "Name" for real modules, "Name<TAB>pseudo" to exclude ---- *)
let read_modules path =
  let ic = open_in path in
  let rec loop real pseudo =
    match input_line ic with
    | exception End_of_file -> close_in ic; (List.rev real, List.rev pseudo)
    | line ->
        let line = String.trim line in
        if line = "" || String.length line > 0 && line.[0] = '#' then loop real pseudo
        else (
          match String.split_on_char '\t' line with
          | [ name ] -> loop (name :: real) pseudo
          | name :: _ -> loop real (name :: pseudo)
          | [] -> loop real pseudo)
  in
  loop [] []

let () =
  let page =
    if Array.length Sys.argv > 1 then Sys.argv.(1)
    else "http://127.0.0.1:8777/ocaml/Stdlib/index.html"
  in
  let modules_file = if Array.length Sys.argv > 2 then Sys.argv.(2) else "parity_modules.txt" in
  let port = if Array.length Sys.argv > 3 then int_of_string Sys.argv.(3) else 9222 in
  let real, pseudo = read_modules modules_file in
  Printf.printf "Parity check: %d real modules (+%d excluded pseudo-pages)\n" (List.length real)
    (List.length pseudo);
  Printf.printf "Page: %s\n%!" page;
  Lwt_main.run
    (let* ws_url = discover_ws_url port in
     let client = `TCP (`IP (Ipaddr.of_string_exn host), `Port port) in
     (* provide our own masking-key source so we don't need mirage-crypto-rng
        (localhost traffic: no crypto strength required) *)
     Random.self_init ();
     let random_string n = String.init n (fun _ -> Char.chr (Random.int 256)) in
     let* conn = Websocket_lwt_unix.connect ~random_string client (Uri.of_string ws_url) in
     let* _ = call conn ~name:"Page.navigate" ~params:(Some (`Assoc [ ("url", `String page) ])) in
     let* () = Lwt_unix.sleep 2.0 in
     (* sanity: the search bar must exist on the loaded page *)
     let* has_bar = eval_bool conn {|!!document.querySelector(".search-bar")|} in
     if not has_bar then Lwt.fail_with "no .search-bar on page (wrong URL or not odoc output?)"
     else
       let* found, missing =
         Lwt_list.fold_left_s
           (fun (f, miss) m ->
             let* ok = check conn m in
             if ok then Lwt.return (m :: f, miss)
             else (
               Printf.printf "  MISS  %s\n%!" m;
               Lwt.return (f, m :: miss)))
           ([], []) real
       in
       (* confirm the excluded pseudo-pages are indeed absent (sanity) *)
       let* pseudo_present =
         Lwt_list.filter_s (fun m -> check conn m) pseudo
       in
       let n = List.length real in
       let nmiss = List.length missing in
       Printf.printf "\n==== PARITY: %d/%d real modules found ====\n" (n - nmiss) n;
       if nmiss > 0 then
         Printf.printf "Missing: %s\n" (String.concat " " (List.rev missing));
       Printf.printf "Excluded pseudo-pages absent as expected: %s\n"
         (if pseudo_present = [] then "yes"
          else "NO (unexpectedly present: " ^ String.concat " " pseudo_present ^ ")");
       ignore found;
       let* () = Websocket_lwt_unix.close_transport conn in
       if nmiss = 0 then Lwt.return (print_endline "RESULT: full parity \xe2\x9c\x93")
       else Lwt.return (exit 1))
