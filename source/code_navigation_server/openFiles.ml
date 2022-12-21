(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* Provides the data structure and APIs for tracking the open files in a CodeNav server's state. *)

open Core

type overlay =
  | Overlay of string
  | Root
[@@deriving compare, equal]

type t = overlay list String.Table.t

let source_path_of_string path = PyrePath.create_absolute path |> SourcePath.create

let string_of_source_path source_path = SourcePath.raw source_path |> PyrePath.absolute

let open_file open_files ~source_path ~overlay_id : unit =
  let overlay =
    match overlay_id with
    | None -> Root
    | Some overlay_id -> Overlay overlay_id
  in
  let path = string_of_source_path source_path in
  match String.Table.find open_files path with
  | None -> String.Table.set open_files ~key:path ~data:[overlay]
  | Some overlays when List.mem overlays overlay ~equal:equal_overlay -> ()
  | Some overlays -> String.Table.set open_files ~key:path ~data:(overlay :: overlays)


let close_file open_files ~source_path ~overlay_id : (unit, Response.ErrorKind.t) Result.t =
  let path = SourcePath.raw source_path |> PyrePath.absolute in
  let overlay =
    match overlay_id with
    | None -> Root
    | Some overlay_id -> Overlay overlay_id
  in
  match String.Table.find open_files path with
  | Some overlays when List.mem overlays overlay ~equal:equal_overlay ->
      let overlays = List.filter overlays ~f:(fun id -> not (equal_overlay overlay id)) in
      let () =
        if List.is_empty overlays then
          String.Table.remove open_files path
        else
          String.Table.set open_files ~key:path ~data:overlays
      in
      Result.Ok ()
  | _ -> Result.Error (Response.ErrorKind.UntrackedFileClosed { path })


let open_files open_files : SourcePath.t list =
  String.Table.keys open_files |> List.map ~f:source_path_of_string


let contains open_files ~source_path ~overlay_id =
  let overlay =
    match overlay_id with
    | None -> Root
    | Some overlay_id -> Overlay overlay_id
  in

  let path = string_of_source_path source_path in
  match String.Table.find open_files path with
  | None -> false
  | Some overlays -> List.mem overlays overlay ~equal:equal_overlay


let create () = String.Table.create ()
