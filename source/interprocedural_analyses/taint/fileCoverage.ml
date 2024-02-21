(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open Data_structures
open Pyre

module File = struct
  module T = struct
    type t = { name: string } [@@deriving compare, sexp, hash, show]
  end

  include T
  module Set = SerializableSet.Make (T)

  let from_callable ~resolve_module_path ~resolution callable =
    Interprocedural.Target.get_module_and_definition callable ~resolution
    >>| fst
    >>= resolve_module_path
    >>= function
    | { Interprocedural.RepositoryPath.filename = Some filename; _ } ->
        (* Omitting absolute paths, since they are less useful than relative paths, which are
           machine independent. *)
        Some { name = filename }
    | _ -> None
end

type t = { (* Any file that contains a callable that is analyzed. *)
           files: File.Set.t }

let empty = { files = File.Set.empty }

let union { files = files_left } { files = files_right } =
  { files = File.Set.union files_left files_right }


(* Add the files that contain any of the given callables. *)
let from_callables ~scheduler ~resolution ~resolve_module_path ~callables =
  Scheduler.map_reduce
    scheduler
    ~policy:
      (Scheduler.Policy.fixed_chunk_size
         ~minimum_chunks_per_worker:1
         ~minimum_chunk_size:50000
         ~preferred_chunk_size:100000
         ())
    ~initial:empty
    ~map:(fun callables ->
      let files =
        callables
        |> List.filter_map ~f:(File.from_callable ~resolution ~resolve_module_path)
        |> File.Set.of_list
      in
      { files })
    ~reduce:union
    ~inputs:callables
    ()


let write_to_file ~path { files; _ } =
  let out_channel = Out_channel.create (PyrePath.absolute path) in
  File.Set.iter (fun { File.name } -> Printf.fprintf out_channel "%s\n" name) files
