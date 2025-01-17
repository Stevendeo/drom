(**************************************************************************)
(*                                                                        *)
(*    Copyright 2020 OCamlPro & Origin Labs                               *)
(*                                                                        *)
(*  All rights reserved. This file is distributed under the terms of the  *)
(*  GNU Lesser General Public License version 2.1, with the special       *)
(*  exception on linking described in the file LICENSE.                   *)
(*                                                                        *)
(**************************************************************************)

open EzCompat

(* Management of .drom file of hashes *)

type t =
  { mutable hashes : string StringMap.t;
    mutable modified : bool;
    mutable files : (bool * string * string * int) list;
    (* for git *)
    mutable to_add : StringSet.t;
    mutable to_remove : StringSet.t ;
    mutable skel_version : string option;
  }

let load () =
  let version = ref None in
  let hashes =
    if Sys.file_exists ".drom" then (
      let map = ref StringMap.empty in
      (* Printf.eprintf "Loading .drom\n%!"; *)
      Array.iteri
        (fun i line ->
           try
             if line <> "" && line.[0] <> '#' then
               let digest, filename =
                 if String.contains line ':' then
                   EzString.cut_at line ':'
                 else
                   EzString.cut_at line ' '
                   (* only for backward compat *)
               in
               if digest = "version" then
                 version := Some filename
               else
                 let digest = Digest.from_hex digest in
                 map := StringMap.add filename digest !map
           with exn ->
             Printf.eprintf "Error loading .drom at line %d: %s\n%!"
               (i+1) (Printexc.to_string exn);
             Printf.eprintf " on line: %s\n%!" line;
             exit 2
        )
        (EzFile.read_lines ".drom");
      !map
    ) else
      StringMap.empty
  in
  { hashes;
    files = [];
    modified = false;
    to_add = StringSet.empty;
    to_remove = StringSet.empty;
    skel_version = !version ;
  }

let write t ~record ~perm file content =
  t.files <- (record, file, content, perm) :: t.files;
  t.modified <- true

let get t file = StringMap.find file t.hashes

let update ?(git = true) t file hash =
  t.hashes <- StringMap.add file hash t.hashes;
  if git then t.to_add <- StringSet.add file t.to_add;
  t.modified <- true

let remove t file =
  t.hashes <- StringMap.remove file t.hashes;
  t.to_remove <- StringSet.add file t.to_remove;
  t.modified <- true

let rename t src_file dst_file =
  match get t src_file with
  | exception Not_found -> ()
  | digest ->
    remove t src_file;
    update t dst_file digest

(* only compare the 3 user permissions. Does it work on Windows ? *)
let perm_equal p1 p2 =
  ( p1 lsr 6 ) land 7 = ( p2 lsr 6 ) land 7

let digest_content ?(perm=0o644) ~file content =
  let content =
    if Filename.check_suffix file ".sh" then
      String.concat "" (EzString.split content '\r')
    else
      content
  in
  let perm = ( perm lsr 6 ) land 7 in
  Digest.string (Printf.sprintf "%s.%d" content perm)

let digest_file file =
  let content = EzFile.read_file file in
  let perm = ( Unix.lstat file ). Unix.st_perm in
  digest_content ~perm content

let save ?(git = true) t =
  if t.modified then begin
    List.iter
      (fun (record, file, content, perm) ->
        let dirname = Filename.dirname file in
        if not (Sys.file_exists dirname) then EzFile.make_dir ~p:true dirname;
        EzFile.write_file file content;
        Unix.chmod file perm;
        if record then update t file (digest_content ~file ~perm content))
      t.files;

    let b = Buffer.create 1000 in
    Printf.bprintf b
      "# Keep this file in your GIT repo to help drom track generated files\n";
    Printf.bprintf b "# begin version\n%!";
    Printf.bprintf b "version:%s\n%!" Version.version;
    Printf.bprintf b "# end version\n%!";
    StringMap.iter
      (fun filename hash ->
        if Sys.file_exists filename then begin
          if filename = "." then begin
            Printf.bprintf b "\n# hash of toml configuration files\n";
            Printf.bprintf b "# used for generation of all files\n"
          end else begin
            Printf.bprintf b "\n# begin context for %s\n" filename;
            Printf.bprintf b "# file %s\n" filename
          end;
          Printf.bprintf b "%s:%s\n" (Digest.to_hex hash) filename;
          Printf.bprintf b "# end context for %s\n" filename
        end)
      t.hashes;
    EzFile.write_file ".drom" (Buffer.contents b);

    if git && Sys.file_exists ".git" then (
      let to_remove = ref [] in
      StringSet.iter
        (fun file ->
          if not (Sys.file_exists file) then to_remove := file :: !to_remove)
        t.to_remove;
      if !to_remove <> [] then Git.run ("rm" :: "-f" :: !to_remove);

      let to_add = ref [] in
      StringSet.iter
        (fun file -> if Sys.file_exists file then to_add := file :: !to_add)
        t.to_add;
      Git.run ("add" :: ".drom" :: !to_add)
    );
    t.to_add <- StringSet.empty;
    t.to_remove <- StringSet.empty;
    t.modified <- false
  end

let with_ctxt ?git f =
  let t = load () in
  begin
    match t.skel_version with
    | None -> ()
    | Some version ->
        if VersionCompare.compare version Version.version > 0 then begin
          Printf.eprintf
            "Error: you cannot update this project files:\n%!";
          Printf.eprintf
            "  Your version: %s\n%!" Version.version;
          Printf.eprintf
            "  Minimal version to update files: %s\n%!" version;
          Printf.eprintf
            "  (to force acceptance, update the version line in .drom file)\n%!";
          exit 2
        end
  end;
  match f t with
  | res ->
    save ?git t;
    res
  | exception exn ->
    let bt = Printexc.get_raw_backtrace () in
    save t;
    Printexc.raise_with_backtrace exn bt
