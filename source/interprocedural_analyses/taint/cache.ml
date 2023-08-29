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
module ClassIntervalSetGraph = Interprocedural.ClassIntervalSetGraph
module SaveLoadSharedMemory = Interprocedural.SaveLoadSharedMemory
module Usage = SaveLoadSharedMemory.Usage

module Entry = struct
  type t =
    | TypeEnvironment
    | InitialCallables
    | ClassHierarchyGraph
    | ClassIntervalGraph
    | PreviousAnalysisSetup
    | OverrideGraph
    | CallGraph
    | GlobalConstants
  [@@deriving compare, show { with_path = false }]

  let show_pretty = function
    | TypeEnvironment -> "type environment"
    | InitialCallables -> "initial callables"
    | ClassHierarchyGraph -> "class hierarchy graph"
    | ClassIntervalGraph -> "class interval graph"
    | PreviousAnalysisSetup -> "previous analysis setup"
    | OverrideGraph -> "override graph"
    | CallGraph -> "call graph"
    | GlobalConstants -> "global constants"
end

module EntryStatus = struct
  module Map = Caml.Map.Make (Entry)

  type t = Usage.t Map.t

  let empty = Map.empty

  let add ~name ~usage = Map.add name usage

  let get = Map.find

  let to_json entry_status =
    let accumulate name usage so_far = (Entry.show name, `String (Usage.show usage)) :: so_far in
    `Assoc (Map.fold accumulate entry_status [])
end

module AnalysisSetup = struct
  type t = {
    maximum_overrides: int option;
    attribute_targets: Interprocedural.Target.Set.t;
    skip_analysis_targets: Interprocedural.Target.Set.t;
    skip_overrides_targets: Ast.Reference.SerializableSet.t;
    skipped_overrides: Interprocedural.OverrideGraph.skipped_overrides;
    initial_callables: FetchCallables.t;
    whole_program_call_graph: Interprocedural.CallGraph.WholeProgramCallGraph.t;
  }
end

module SharedMemoryStatus = struct
  type t =
    | InvalidByDecoratorChange
    | InvalidByCodeChange
    | TypeEnvironmentLoadError
    | LoadError
    | NotFound
    | Disabled
    | Loaded of {
        entry_status: EntryStatus.t;
        previous_analysis_setup: AnalysisSetup.t;
      }

  let to_json = function
    | InvalidByDecoratorChange -> `String "InvalidByDecoratorChange"
    | InvalidByCodeChange -> `String "InvalidByCodeChange"
    | TypeEnvironmentLoadError -> `String "TypeEnvironmentLoadError"
    | LoadError -> `String "LoadError"
    | NotFound -> `String "NotFound"
    | Disabled -> `String "Disabled"
    | Loaded { entry_status; _ } -> `Assoc ["Loaded", EntryStatus.to_json entry_status]


  let set_entry_usage ~entry ~usage status =
    match status with
    | Loaded ({ entry_status; _ } as loaded) ->
        let entry_status = EntryStatus.add ~name:entry ~usage entry_status in
        Loaded { loaded with entry_status }
    | _ -> status
end

module PreviousAnalysisSetupSharedMemory = struct
  let entry = Entry.PreviousAnalysisSetup

  module T = SaveLoadSharedMemory.MakeSingleValue (struct
    type t = AnalysisSetup.t

    let prefix = Hack_parallel.Std.Prefix.make ()

    let name = Entry.show_pretty entry
  end)

  let load_from_cache entry_status =
    match T.load_from_cache () with
    | Ok previous_analysis_setup ->
        let entry_status =
          EntryStatus.add ~name:entry ~usage:SaveLoadSharedMemory.Usage.Used entry_status
        in
        SharedMemoryStatus.Loaded { entry_status; previous_analysis_setup }
    | Error error ->
        Log.info
          "Reset shared memory due to failing to load the previous analysis setup: %s"
          (SaveLoadSharedMemory.Usage.show error);
        Memory.reset_shared_memory ();
        SharedMemoryStatus.LoadError


  let save_to_cache = T.save_to_cache
end

type t = {
  status: SharedMemoryStatus.t;
  save_cache: bool;
  scheduler: Scheduler.t;
  configuration: Configuration.Analysis.t;
}

let metadata_to_json { status; save_cache; _ } =
  `Assoc ["shared_memory_status", SharedMemoryStatus.to_json status; "save_cache", `Bool save_cache]


let get_save_directory ~configuration =
  PyrePath.create_relative
    ~root:(Configuration.Analysis.log_directory configuration)
    ~relative:".pysa_cache"


let get_shared_memory_save_path ~configuration =
  PyrePath.append (get_save_directory ~configuration) ~element:"sharedmem"


let ignore_result (_ : ('a, 'b) result) = ()

let initialize_shared_memory ~configuration =
  let path = get_shared_memory_save_path ~configuration in
  if not (PyrePath.file_exists path) then (
    Log.warning "Could not find a cached state.";
    Error SharedMemoryStatus.NotFound)
  else
    SaveLoadSharedMemory.exception_to_error
      ~error:SharedMemoryStatus.LoadError
      ~message:"loading cached state"
      ~f:(fun () ->
        Log.info
          "Loading cached state from `%s`"
          (PyrePath.absolute (get_save_directory ~configuration));
        let _ = Memory.get_heap_handle configuration in
        Memory.load_shared_memory ~path:(PyrePath.absolute path) ~configuration;
        Log.info "Cached state successfully loaded.";
        Ok ())


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
      Error SharedMemoryStatus.InvalidByDecoratorChange
  | None ->
      Log.warning "Could not find cached decorator modes, ignoring existing cache.";
      Error SharedMemoryStatus.LoadError


let try_load ~scheduler ~configuration ~decorator_configuration ~enabled =
  let save_cache = enabled in
  if not enabled then
    { status = SharedMemoryStatus.Disabled; save_cache; scheduler; configuration }
  else
    let open Result in
    let status =
      match initialize_shared_memory ~configuration with
      | Ok () -> (
          match check_decorator_invalidation ~decorator_configuration with
          | Ok () ->
              let entry_status = EntryStatus.empty in
              PreviousAnalysisSetupSharedMemory.load_from_cache entry_status
          | Error error ->
              (* If there exist updates to certain decorators, it wastes memory and might not be
                 safe to leave the old type environment in the shared memory. *)
              Log.info "Reset shared memory";
              Memory.reset_shared_memory ();
              error)
      | Error error -> error
    in
    { status; save_cache; scheduler; configuration }


let load_type_environment ~scheduler ~configuration =
  let open Result in
  let controls = Analysis.EnvironmentControls.create configuration in
  Log.info "Determining if source files have changed since cache was created.";
  SaveLoadSharedMemory.exception_to_error
    ~error:SharedMemoryStatus.TypeEnvironmentLoadError
    ~message:"Loading type environment"
    ~f:(fun () -> Ok (TypeEnvironment.load controls))
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
      Error SharedMemoryStatus.InvalidByCodeChange


let save_type_environment ~scheduler ~configuration ~environment =
  SaveLoadSharedMemory.exception_to_error
    ~error:()
    ~message:"saving type environment to cache"
    ~f:(fun () ->
      Memory.SharedMemory.collect `aggressive;
      let module_tracker = TypeEnvironment.module_tracker environment in
      Interprocedural.ChangedPaths.save_current_paths ~scheduler ~configuration ~module_tracker;
      TypeEnvironment.store environment;
      Log.info "Saved type environment to cache shared memory.";
      Ok ())


let type_environment ({ status; save_cache; scheduler; configuration } as cache) f =
  let compute_and_save_environment () =
    let environment = f () in
    if save_cache then
      save_type_environment ~scheduler ~configuration ~environment |> ignore_result;
    environment
  in
  let environment, status =
    match status with
    | Loaded _ -> (
        match load_type_environment ~scheduler ~configuration with
        | Ok environment ->
            let status =
              SharedMemoryStatus.set_entry_usage
                ~entry:Entry.TypeEnvironment
                ~usage:Usage.Used
                status
            in
            environment, status
        | Error error_status ->
            Log.info "Reset shared memory due to failing to load the type environment";
            Memory.reset_shared_memory ();
            compute_and_save_environment (), error_status)
    | _ -> compute_and_save_environment (), status
  in
  environment, { cache with status }


let ensure_save_directory_exists ~configuration =
  let directory = PyrePath.absolute (get_save_directory ~configuration) in
  try Core_unix.mkdir directory with
  (* [mkdir] on MacOSX returns [EISDIR] instead of [EEXIST] if the directory already exists. *)
  | Core_unix.Unix_error ((EEXIST | EISDIR), _, _) -> ()
  | e -> raise e


let save_shared_memory ~configuration =
  SaveLoadSharedMemory.exception_to_error
    ~error:()
    ~message:"saving cached state to file"
    ~f:(fun () ->
      let path = get_shared_memory_save_path ~configuration in
      Log.info "Saving shared memory state to cache file...";
      ensure_save_directory_exists ~configuration;
      Memory.SharedMemory.collect `aggressive;
      Memory.save_shared_memory ~path:(PyrePath.absolute path) ~configuration;
      Log.info "Saved shared memory state to cache file: `%s`" (PyrePath.absolute path);
      Ok ())


let save
    ~maximum_overrides
    ~attribute_targets
    ~skip_analysis_targets
    ~skip_overrides_targets
    ~skipped_overrides
    ~override_graph_shared_memory
    ~initial_callables
    ~call_graph_shared_memory
    ~whole_program_call_graph
    ~global_constants
    { save_cache; configuration; _ }
  =
  if save_cache then
    let () =
      Interprocedural.OverrideGraph.SharedMemory.save_to_cache override_graph_shared_memory
    in
    let () =
      Interprocedural.CallGraph.DefineCallGraphSharedMemory.save_to_cache call_graph_shared_memory
    in
    let () = Interprocedural.GlobalConstants.SharedMemory.save_to_cache global_constants in
    let () =
      PreviousAnalysisSetupSharedMemory.save_to_cache
        {
          AnalysisSetup.maximum_overrides;
          attribute_targets;
          skip_analysis_targets;
          skip_overrides_targets;
          skipped_overrides;
          initial_callables;
          whole_program_call_graph;
        }
    in
    save_shared_memory ~configuration |> ignore


let set_entry_usage ~entry ~usage ({ status; _ } as cache) =
  let status = SharedMemoryStatus.set_entry_usage ~entry ~usage status in
  { cache with status }


module type CacheEntryType = sig
  type t

  val entry : Entry.t

  val prefix : Hack_parallel.Std.Prefix.t
end

module MakeCacheEntry (CacheEntry : CacheEntryType) = struct
  module T = SaveLoadSharedMemory.MakeSingleValue (struct
    type t = CacheEntry.t

    let prefix = CacheEntry.prefix

    let name = Entry.show_pretty CacheEntry.entry
  end)

  let load_or_compute ({ save_cache; status; _ } as cache) f =
    let value, cache =
      match status with
      | Loaded _ ->
          let value, usage =
            match T.load_from_cache () with
            | Ok value -> value, Usage.Used
            | Error error -> f (), error
          in
          let cache = set_entry_usage ~entry:CacheEntry.entry ~usage cache in
          value, cache
      | _ -> f (), cache
    in
    if save_cache then T.save_to_cache value;
    value, cache
end

module ClassHierarchyGraphSharedMemory = MakeCacheEntry (struct
  type t = ClassHierarchyGraph.Heap.t

  let entry = Entry.ClassHierarchyGraph

  let prefix = Hack_parallel.Std.Prefix.make ()
end)

module ClassIntervalGraphSharedMemory = MakeCacheEntry (struct
  type t = ClassIntervalSetGraph.Heap.t

  let entry = Entry.ClassIntervalGraph

  let prefix = Hack_parallel.Std.Prefix.make ()
end)

let initial_callables ({ status; _ } as cache) compute_value =
  match status with
  | Loaded
      ({ entry_status; previous_analysis_setup = { AnalysisSetup.initial_callables; _ }; _ } as
      loaded) ->
      let entry_status =
        EntryStatus.add
          ~name:Entry.InitialCallables
          ~usage:SaveLoadSharedMemory.Usage.Used
          entry_status
      in
      let status = SharedMemoryStatus.Loaded { loaded with entry_status } in
      initial_callables, { cache with status }
  | _ -> compute_value (), cache


let class_hierarchy_graph = ClassHierarchyGraphSharedMemory.load_or_compute

let class_interval_graph = ClassIntervalGraphSharedMemory.load_or_compute

module OverrideGraphSharedMemory = struct
  let is_reusable
      ~skip_overrides_targets
      ~maximum_overrides
      {
        AnalysisSetup.maximum_overrides = previous_maximum_overrides;
        skip_overrides_targets = previous_skip_overrides_targets;
        _;
      }
    =
    let no_change_in_skip_overrides =
      Ast.Reference.SerializableSet.equal previous_skip_overrides_targets skip_overrides_targets
    in
    let no_change_in_maximum_overrides =
      Option.equal Int.equal maximum_overrides previous_maximum_overrides
    in
    no_change_in_skip_overrides && no_change_in_maximum_overrides


  let load_or_compute_if_unloadable
      ~skip_overrides_targets
      ~previous_analysis_setup:{ AnalysisSetup.skipped_overrides; _ }
      ~maximum_overrides
      entry_status
      compute_value
    =
    match Interprocedural.OverrideGraph.SharedMemory.load_from_cache () with
    | Ok override_graph_shared_memory ->
        let override_graph_heap =
          Interprocedural.OverrideGraph.SharedMemory.to_heap override_graph_shared_memory
        in
        ( {
            Interprocedural.OverrideGraph.override_graph_heap;
            override_graph_shared_memory;
            skipped_overrides;
          },
          EntryStatus.add
            ~name:Entry.OverrideGraph
            ~usage:SaveLoadSharedMemory.Usage.Used
            entry_status )
    | Error error ->
        ( compute_value ~skip_overrides_targets ~maximum_overrides (),
          EntryStatus.add ~name:Entry.OverrideGraph ~usage:error entry_status )


  let remove_previous () =
    match Interprocedural.OverrideGraph.SharedMemory.load_from_cache () with
    | Ok override_graph_shared_memory ->
        Log.info "Removing the previous override graph.";
        Interprocedural.OverrideGraph.SharedMemory.cleanup override_graph_shared_memory
    | Error _ -> Log.warning "Failed to remove the previous override graph."


  let load_or_compute_if_stale_or_unloadable
      ~skip_overrides_targets
      ~maximum_overrides
      ({ status; _ } as cache)
      compute_value
    =
    match status with
    | Loaded ({ previous_analysis_setup; entry_status } as loaded) ->
        let reusable =
          is_reusable ~skip_overrides_targets ~maximum_overrides previous_analysis_setup
        in
        if reusable then
          let () = Log.info "Try to reuse the override graph from the previous run." in
          let value, entry_status =
            load_or_compute_if_unloadable
              ~skip_overrides_targets
              ~previous_analysis_setup
              ~maximum_overrides
              entry_status
              compute_value
          in
          let status = SharedMemoryStatus.Loaded { loaded with entry_status } in
          value, { cache with status }
        else
          let () = Log.info "Override graph from the previous run is stale." in
          let () = remove_previous () in
          let cache =
            set_entry_usage
              ~entry:Entry.OverrideGraph
              ~usage:(SaveLoadSharedMemory.Usage.Unused Stale)
              cache
          in
          compute_value ~skip_overrides_targets ~maximum_overrides (), cache
    | _ -> compute_value ~skip_overrides_targets ~maximum_overrides (), cache
end

let override_graph = OverrideGraphSharedMemory.load_or_compute_if_stale_or_unloadable

module CallGraphSharedMemory = struct
  let compare_attribute_targets ~previous_attribute_targets ~attribute_targets =
    let is_equal = Interprocedural.Target.Set.equal attribute_targets previous_attribute_targets in
    if not is_equal then
      Log.info "Detected changes in the attribute targets";
    is_equal


  let compare_skip_analysis_targets ~previous_skip_analysis_targets ~skip_analysis_targets =
    let is_equal =
      Interprocedural.Target.Set.equal skip_analysis_targets previous_skip_analysis_targets
    in
    if not is_equal then
      Log.info "Detected changes in the skip analysis targets";
    is_equal


  let is_reusable
      ~attribute_targets
      ~skip_analysis_targets
      entry_status
      {
        AnalysisSetup.attribute_targets = previous_attribute_targets;
        skip_analysis_targets = previous_skip_analysis_targets;
        _;
      }
    =
    (* Technically we should also compare the changes in the definitions, but such comparison is
       unnecessary because we invalidate the cache when there is a source code change -- which
       implies no change in the definitions. *)
    EntryStatus.get Entry.OverrideGraph entry_status == SaveLoadSharedMemory.Usage.Used
    && compare_attribute_targets ~previous_attribute_targets ~attribute_targets
    && compare_skip_analysis_targets ~previous_skip_analysis_targets ~skip_analysis_targets


  let remove_previous () =
    match Interprocedural.CallGraph.DefineCallGraphSharedMemory.load_from_cache () with
    | Ok call_graph_shared_memory ->
        Log.info "Removing the previous call graph.";
        Interprocedural.CallGraph.DefineCallGraphSharedMemory.cleanup call_graph_shared_memory
    | Error _ -> Log.warning "Failed to remove the previous call graph."


  let load_or_compute_if_not_loadable
      ~attribute_targets
      ~skip_analysis_targets
      ~definitions
      ~previous_analysis_setup:{ AnalysisSetup.whole_program_call_graph; _ }
      compute_value
    =
    match Interprocedural.CallGraph.DefineCallGraphSharedMemory.load_from_cache () with
    | Ok define_call_graphs ->
        ( { Interprocedural.CallGraph.whole_program_call_graph; define_call_graphs },
          SaveLoadSharedMemory.Usage.Used )
    | Error error -> compute_value ~attribute_targets ~skip_analysis_targets ~definitions (), error


  let load_or_recompute
      ~attribute_targets
      ~skip_analysis_targets
      ~definitions
      ({ status; _ } as cache)
      compute_value
    =
    match status with
    | Loaded ({ previous_analysis_setup; entry_status } as loaded) ->
        let reusable =
          is_reusable ~attribute_targets ~skip_analysis_targets entry_status previous_analysis_setup
        in
        if reusable then
          let () = Log.info "Try to reuse the call graph from the previous run." in
          let value, usage =
            load_or_compute_if_not_loadable
              ~attribute_targets
              ~skip_analysis_targets
              ~definitions
              ~previous_analysis_setup
              compute_value
          in
          let entry_status = EntryStatus.add ~name:Entry.CallGraph ~usage entry_status in
          let status = SharedMemoryStatus.Loaded { loaded with entry_status } in
          value, { cache with status }
        else
          let () = Log.info "Call graph from the previous run is stale." in
          let () = remove_previous () in
          let cache =
            set_entry_usage
              ~entry:Entry.CallGraph
              ~usage:(SaveLoadSharedMemory.Usage.Unused Stale)
              cache
          in
          compute_value ~attribute_targets ~skip_analysis_targets ~definitions (), cache
    | _ -> compute_value ~attribute_targets ~skip_analysis_targets ~definitions (), cache
end

let call_graph = CallGraphSharedMemory.load_or_recompute

module GlobalConstantsSharedMemory = struct
  let load_or_compute_if_not_loadable compute_value =
    match Interprocedural.GlobalConstants.SharedMemory.load_from_cache () with
    | Ok global_constants -> global_constants, SaveLoadSharedMemory.Usage.Used
    | Error error -> compute_value (), error


  let load_or_recompute_if_stale_or_not_loadable ({ status; _ } as cache) compute_value =
    match status with
    | Loaded ({ entry_status; _ } as loaded) ->
        let () = Log.info "Trying to reuse the global constants from the previous run." in
        let value, usage = load_or_compute_if_not_loadable compute_value in
        let entry_status = EntryStatus.add ~name:Entry.GlobalConstants ~usage entry_status in
        let status = SharedMemoryStatus.Loaded { loaded with entry_status } in
        value, { cache with status }
    | _ -> compute_value (), cache
end

let global_constants = GlobalConstantsSharedMemory.load_or_recompute_if_stale_or_not_loadable
