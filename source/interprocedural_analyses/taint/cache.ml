(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* Cache: implements caching capabilities for the taint analysis. This is what
 * powers the `--use-cache` command line option. This is basically implemented
 * by writing the shared memory into a file and restoring it later.
 *)

open Core
open Pyre
module TypeEnvironment = Analysis.TypeEnvironment
module AstEnvironment = Analysis.AstEnvironment
module FetchCallables = Interprocedural.FetchCallables
module ClassHierarchyGraph = Interprocedural.ClassHierarchyGraph

module InitialCallablesSharedMemory = Memory.Serializer (struct
  type t = FetchCallables.t

  module Serialized = struct
    type t = FetchCallables.t

    let prefix = Prefix.make ()

    let description = "Initial callables to analyze"
  end

  let serialize = Fn.id

  let deserialize = Fn.id
end)

module ClassHierarchyGraphSharedMemory = Memory.Serializer (struct
  type t = ClassHierarchyGraph.Heap.t

  module Serialized = struct
    type t = ClassHierarchyGraph.Heap.t

    let prefix = Prefix.make ()

    let description = "Class hierarchy graph"
  end

  let serialize = Fn.id

  let deserialize = Fn.id
end)

type error =
  | InvalidByCodeChange
  | InvalidByDecoratorChange
  | LoadError
  | NotFound
  | Disabled

type t = {
  status: (unit, error) Result.t;
  save_cache: bool;
  scheduler: Scheduler.t;
  configuration: Configuration.Analysis.t;
}

let get_save_directory ~configuration =
  PyrePath.create_relative
    ~root:(Configuration.Analysis.log_directory configuration)
    ~relative:".pysa_cache"


let get_shared_memory_save_path ~configuration =
  PyrePath.append (get_save_directory ~configuration) ~element:"sharedmem"


let exception_to_error ~error ~message ~f =
  try f () with
  | exception_ ->
      Log.error "Error %s:\n%s" message (Exn.to_string exception_);
      Error error


let ignore_result (_ : ('a, 'b) result) = ()

let initialize_shared_memory ~configuration =
  let path = get_shared_memory_save_path ~configuration in
  if not (PyrePath.file_exists path) then (
    Log.warning "Could not find a cached state.";
    Error NotFound)
  else
    exception_to_error ~error:LoadError ~message:"loading cached state" ~f:(fun () ->
        Log.info
          "Loading cached state from `%s`"
          (PyrePath.absolute (get_save_directory ~configuration));
        let _ = Memory.get_heap_handle configuration in
        Memory.load_shared_memory ~path:(PyrePath.absolute path) ~configuration;
        Log.info "Cached state successfully loaded.";
        Ok ())


let load_type_environment ~scheduler ~configuration =
  let open Result in
  let controls = Analysis.EnvironmentControls.create configuration in
  Log.info "Determining if source files have changed since cache was created.";
  exception_to_error ~error:LoadError ~message:"Loading type environment" ~f:(fun () ->
      Ok (TypeEnvironment.load controls))
  >>= fun type_environment ->
  let old_module_tracker =
    TypeEnvironment.ast_environment type_environment |> AstEnvironment.module_tracker
  in
  let new_module_tracker = Analysis.ModuleTracker.create controls in
  let changed_paths =
    let is_pysa_model path = String.is_suffix ~suffix:".pysa" (PyrePath.get_suffix_path path) in
    let is_taint_config path = String.is_suffix ~suffix:"taint.config" (PyrePath.absolute path) in
    Interprocedural.ChangedPaths.compute_locally_changed_paths
      ~scheduler
      ~configuration
      ~old_module_tracker
      ~new_module_tracker
    |> List.map ~f:ArtifactPath.raw
    |> List.filter ~f:(fun path -> not (is_pysa_model path || is_taint_config path))
  in
  match changed_paths with
  | [] -> Ok type_environment
  | _ ->
      Log.warning "Changes to source files detected, ignoring existing cache.";
      Error InvalidByCodeChange


let check_decorator_invalidation ~decorator_configuration:current_configuration =
  let open Analysis in
  match DecoratorPreprocessing.get_configuration () with
  | Some cached_configuration
    when DecoratorPreprocessing.Configuration.equal cached_configuration current_configuration ->
      Ok ()
  | Some _ ->
      (* We need to invalidate the cache since decorator modes (e.g, `@IgnoreDecorator` and
         `@SkipDecoratorInlining`) are implemented as an AST preprocessing step. Any change could
         lead to a change in the AST, which could lead to a different type environment and so on. *)
      Log.warning "Changes to decorator modes detected, ignoring existing cache.";
      Error InvalidByDecoratorChange
  | None ->
      Log.warning "Could not find cached decorator modes, ignoring existing cache.";
      Error LoadError


let try_load ~scheduler ~configuration ~decorator_configuration ~enabled =
  if not enabled then
    { status = Error Disabled; save_cache = false; scheduler; configuration }
  else
    let open Result in
    let status =
      initialize_shared_memory ~configuration
      >>= fun () ->
      match check_decorator_invalidation ~decorator_configuration with
      | Ok _ -> Ok ()
      | Error error ->
          (* If there exist updates to certain decorators, it wastes memory and might not be safe to
             leave the old type environment in the shared memory. *)
          Log.info "Reset shared memory";
          Memory.reset_shared_memory ();
          Error error
    in
    { status; save_cache = true; scheduler; configuration }


let save_type_environment ~scheduler ~configuration ~environment =
  exception_to_error ~error:() ~message:"saving type environment to cache" ~f:(fun () ->
      Memory.SharedMemory.collect `aggressive;
      let module_tracker = TypeEnvironment.module_tracker environment in
      Interprocedural.ChangedPaths.save_current_paths ~scheduler ~configuration ~module_tracker;
      TypeEnvironment.store environment;
      Log.info "Saved type environment to cache shared memory.";
      Ok ())


let type_environment { status; save_cache; scheduler; configuration } f =
  let compute_and_save_environment () =
    let environment = f () in
    if save_cache then
      save_type_environment ~scheduler ~configuration ~environment |> ignore_result;
    environment
  in
  match status with
  | Ok _ -> (
      match load_type_environment ~scheduler ~configuration with
      | Ok environment -> environment
      | Error _ ->
          Log.info "Reset shared memory due to failing to load the type environment";
          Memory.reset_shared_memory ();
          compute_and_save_environment ())
  | Error _ -> compute_and_save_environment ()


let load_initial_callables () =
  exception_to_error ~error:LoadError ~message:"loading initial callables from cache" ~f:(fun () ->
      Log.info "Loading initial callables from cache...";
      let initial_callables = InitialCallablesSharedMemory.load () in
      Log.info "Loaded initial callables from cache.";
      Ok initial_callables)


let ensure_save_directory_exists ~configuration =
  let directory = PyrePath.absolute (get_save_directory ~configuration) in
  try Core_unix.mkdir directory with
  (* [mkdir] on MacOSX returns [EISDIR] instead of [EEXIST] if the directory already exists. *)
  | Core_unix.Unix_error ((EEXIST | EISDIR), _, _) -> ()
  | e -> raise e


let save_shared_memory ~configuration =
  exception_to_error ~error:() ~message:"saving cached state to file" ~f:(fun () ->
      let path = get_shared_memory_save_path ~configuration in
      Log.info "Saving shared memory state to cache file...";
      ensure_save_directory_exists ~configuration;
      Memory.SharedMemory.collect `aggressive;
      Memory.save_shared_memory ~path:(PyrePath.absolute path) ~configuration;
      Log.info "Saved shared memory state to cache file: `%s`" (PyrePath.absolute path);
      Ok ())


let save { save_cache; configuration; _ } =
  if save_cache then
    save_shared_memory ~configuration |> ignore


let save_initial_callables ~initial_callables =
  exception_to_error ~error:() ~message:"saving initial callables to cache" ~f:(fun () ->
      Memory.SharedMemory.collect `aggressive;
      InitialCallablesSharedMemory.store initial_callables;
      Log.info "Saved initial callables to cache shared memory.";
      Ok ())


let initial_callables { status; save_cache; _ } f =
  let initial_callables =
    match status with
    | Ok _ -> load_initial_callables () |> Result.ok
    | Error _ -> None
  in
  match initial_callables with
  | Some initial_callables -> initial_callables
  | None ->
      let callables = f () in
      if save_cache then
        save_initial_callables ~initial_callables:callables |> ignore_result;
      callables


let load_class_hierarchy_graph () =
  exception_to_error
    ~error:LoadError
    ~message:"loading class hierarchy graph from cache"
    ~f:(fun () ->
      Log.info "Loading class hierarchy graph from cache...";
      let class_hierarchy_graph = ClassHierarchyGraphSharedMemory.load () in
      Log.info "Loaded class hierarchy graph from cache.";
      Ok class_hierarchy_graph)


let save_class_hierarchy_graph ~class_hierarchy_graph =
  exception_to_error ~error:() ~message:"saving class hierarchy graph to cache" ~f:(fun () ->
      Memory.SharedMemory.collect `aggressive;
      ClassHierarchyGraphSharedMemory.store class_hierarchy_graph;
      Log.info "Saved class hierarchy graph to cache shared memory.";
      Ok ())


let class_hierarchy_graph { status; save_cache; _ } f =
  let class_hierarchy_graph =
    match status with
    | Ok _ -> load_class_hierarchy_graph () |> Result.ok
    | Error _ -> None
  in
  match class_hierarchy_graph with
  | Some class_hierarchy_graph -> class_hierarchy_graph
  | None ->
      let class_hierarchy_graph = f () in
      if save_cache then
        save_class_hierarchy_graph ~class_hierarchy_graph |> ignore_result;
      class_hierarchy_graph
