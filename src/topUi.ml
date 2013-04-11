open Tools.Ops
module Buffer = OcamlBuffer (* fixme *)

let init_top_view current_buffer_ref toplevel_buffer =
  let top_view = Gui.open_toplevel_view toplevel_buffer in
  (* marks in the top viewwhere message from different sources are
     printed. Useful for not mixing them, and keeping locations *)
  let stdout_mark, ocaml_mark, prompt_mark =
    let create_top_mark () =
      `MARK (toplevel_buffer#create_mark
          toplevel_buffer#end_iter
          ~left_gravity:false)
    in
    create_top_mark (), create_top_mark (), create_top_mark ()
  in
  ignore @@ toplevel_buffer#connect#changed ~callback:(fun () ->
      ignore @@ top_view#scroll_mark_onscreen prompt_mark);
  let replace_marks () =
    toplevel_buffer#insert ~iter:toplevel_buffer#end_iter "\n";
    toplevel_buffer#move_mark stdout_mark
      ~where:toplevel_buffer#end_iter#backward_char;
    toplevel_buffer#insert ~iter:toplevel_buffer#end_iter
      ~tags:[Buffer.Tags.invisible] " ";
    toplevel_buffer#move_mark ocaml_mark
      ~where:toplevel_buffer#end_iter#backward_char;
    toplevel_buffer#move_mark prompt_mark
      ~where:toplevel_buffer#end_iter;
  in
  let insert_top ?tags mark text =
    let iter = toplevel_buffer#get_iter_at_mark mark in
    toplevel_buffer#insert ~iter ?tags text
  in
  let display_top_query phrase =
    (* toplevel_buffer#insert ~iter:toplevel_buffer#end_iter "\n# "; *)
    insert_top ~tags:[Buffer.Tags.phrase] prompt_mark phrase;
    let phrase_len = String.length phrase in
    if phrase_len > 0 && phrase.[phrase_len - 1] <> '\n' then
      insert_top ~tags:[Buffer.Tags.phrase] prompt_mark "\n"
  in
  let display_stdout response =
    let rec disp_lines = function
      | [] -> ()
      | line::rest ->
          let offset =
            (toplevel_buffer#get_iter_at_mark stdout_mark)#line_offset
          in
          let line =
            if offset >= 1024 then ""
            else if offset + String.length line <= 1024 then line
            else
              let s = String.sub line 0 (1024 - offset) in
              String.blit "..." 0 s (1024 - offset - 3) 3;
              s
          in
          insert_top ~tags:[Buffer.Tags.stdout] stdout_mark line;
          if rest <> [] then
            (insert_top ~tags:[Buffer.Tags.stdout] stdout_mark "\n";
             disp_lines rest)
    in
    let delim = Str.regexp "\r?\n" in
    let lines = Str.split_delim delim response in
    disp_lines lines
  in
  let display_top_response response =
    let rec disp_lines = function
      | [] -> ()
      | line::rest ->
          insert_top ocaml_mark line;
          if rest <> [] then
            (insert_top ocaml_mark "\n";
             disp_lines rest)
    in
    let delim = Str.regexp "\r?\n" in
    let lines = Str.split_delim delim response in
    disp_lines lines
  in
  let handle_response response buf start_mark end_mark =
    Tools.debug "Was supposed to parse and analyse %S" response;
    let error_regex =
      Str.regexp "^Characters \\([0-9]+\\)-\\([0-9]+\\)"
    in
    try
      let _i = Str.search_forward error_regex response 0 in
      let start_char, end_char =
        int_of_string @@ Str.matched_group 1 response,
        int_of_string @@ Str.matched_group 2 response
      in
      Tools.debug "Parsed error from ocaml: chars %d-%d" start_char end_char;
      let start = (buf#get_iter_at_mark start_mark)#forward_chars start_char in
      let stop = (buf#get_iter_at_mark start_mark)#forward_chars end_char in
      let errmark = GSourceView2.source_mark ~category:"error" () in
      buf#apply_tag Buffer.Tags.error ~start ~stop
    with Not_found -> ()
  in
  let topeval top =
    let buf = !current_buffer_ref.Buffer.gbuffer in
    let rec get_phrases (start:GText.iter) (stop:GText.iter) =
      match start#forward_search ~limit:stop ";;" with
      | Some (a,b) ->
          (buf#get_text ~start ~stop:a (),
           `MARK (buf#create_mark start), `MARK (buf#create_mark a))
          :: get_phrases b stop
      | None ->
          [buf#get_text ~start ~stop (),
           `MARK (buf#create_mark start), `MARK (buf#create_mark stop)]
    in
    let rec eval_phrases = function
      | [] -> ()
      | (phrase,start_mark,stop_mark) :: rest ->
          let trimmed = String.trim phrase in
          if trimmed = "" then
            (buf#delete_mark start_mark;
             buf#delete_mark stop_mark;
             eval_phrases rest)
          else
            (display_top_query trimmed;
             replace_marks ();
             Top.query top phrase @@ fun response ->
               handle_response response buf start_mark stop_mark;
               buf#delete_mark start_mark; (* really, not the Gc's job ? *)
               buf#delete_mark stop_mark;
               eval_phrases rest)
    in
    let start, stop =
      if buf#has_selection then buf#selection_bounds
      else buf#start_iter, buf#end_iter
    in
    let phrases = get_phrases start stop in
    eval_phrases phrases
  in
  let top_ref = ref None in
  let rec top_start () =
    let schedule f = GMain.Idle.add @@ fun () ->
        try f (); false with
          e ->
            Printf.eprintf "Error in toplevel interaction: %s%!"
              (Tools.printexc e);
            raise e
    in
    let resp_handler = function
      | Top.Message m -> display_top_response m
      | Top.User u -> display_stdout u
      | Top.Exited ->
          toplevel_buffer#insert ~iter:toplevel_buffer#end_iter
            "\t\t*** restarting ocaml ***\n";
    in
    replace_marks ();
    Top.start schedule resp_handler status_change_hook
  and status_change_hook = function
    | Top.Dead ->
        Gui.Controls.disable `EXECUTE;
        Gui.Controls.disable `STOP;
        top_ref := Some (top_start ())
    | Top.Ready ->
        Gui.Controls.enable `EXECUTE;
        Gui.Controls.disable `STOP
    | Top.Busy _ ->
        Gui.Controls.disable `EXECUTE;
        Gui.Controls.enable `STOP
  in
  Gui.Controls.bind `EXECUTE (fun () ->
    topeval @@ match !top_ref with
      | Some top -> top
      | None -> let top = top_start () in
          top_ref := Some top; top);
  Gui.Controls.bind `STOP (fun () ->
    match !top_ref with
    | Some top -> Top.stop top
    | None -> ());
  Gui.Controls.bind `RESTART (fun () ->
    match !top_ref with
    | Some top -> Top.kill top
    | None -> ());
  Gui.Controls.bind `CLEAR (fun () ->
    toplevel_buffer#delete
      ~start:toplevel_buffer#start_iter
      ~stop:toplevel_buffer#end_iter);
  top_ref := Some (top_start ())