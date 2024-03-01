(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* PyrePysaApi provides the Pyre environment interfaces used by the Pysa OCaml codebase, including
   both taint analysis and model queries. *)

open Core

let absolute_source_path_of_qualifier ~lookup_source read_only_type_environment =
  let source_code_api =
    read_only_type_environment |> TypeEnvironment.ReadOnly.get_untracked_source_code_api
  in
  SourcePaths.absolute_source_path_of_qualifier ~lookup_source ~source_code_api


(* Private helper module for creating a TypeEnvironment the way Pysa wants to. *)
module PysaTypeEnvironment = struct
  let create ~configuration ~decorator_configuration =
    let configuration =
      (* In order to get an accurate call graph and type information, we need to ensure that we
         schedule a type check for external files. *)
      (* TODO(T180476103) Remove the need for this by using explicit_qualifiers, and delete this
         flag from the configuration + environment logic. *)
      { configuration with Configuration.Analysis.analyze_external_sources = true }
    in
    let () = DecoratorPreprocessing.setup_preprocessing decorator_configuration in
    let errors_environment =
      EnvironmentControls.create ~populate_call_graph:false configuration
      |> ErrorsEnvironment.create_with_ast_environment
    in
    ErrorsEnvironment.AssumeDownstreamNeverNeedsUpdates.type_environment errors_environment


  let qualifiers_and_definitions ~scheduler type_environment =
    Log.info "Starting type checking...";
    PyreProfiling.track_shared_memory_usage ~name:"Before legacy type check" ();
    let qualifiers =
      TypeEnvironment.AssumeGlobalModuleListing.global_module_paths_api type_environment
      |> GlobalModulePathsApi.type_check_qualifiers
    in
    Log.info "Found %d modules" (List.length qualifiers);
    let definitions = TypeEnvironment.collect_definitions ~scheduler type_environment qualifiers in
    Log.info "Found %d functions" (List.length definitions);
    qualifiers, definitions


  let populate ~scheduler type_environment definitions =
    let () = TypeEnvironment.populate_for_definitions ~scheduler type_environment definitions in
    Statistics.event
      ~section:`Memory
      ~name:"shared memory size post-typecheck"
      ~integers:["size", Memory.heap_size ()]
      ();
    PyreProfiling.track_shared_memory_usage ~name:"After legacy type check" ();
    ()
end

(* Api used in the top-level code of `pyre analyze`, where we need read-write access in order to
   perform operations like loading / saving the Pysa cache cache and scheduling type analysis in
   parallel. *)
module ReadWrite = struct
  type t = { type_environment: TypeEnvironment.t }

  (* Constructors *)

  (* Note: this function assumes that Cache.ml logic has initialized shared memory (which is global,
     and loading is purely side-effect based) from a cache dump already. *)
  let load_from_cache ~configuration =
    let type_environment =
      let controls = EnvironmentControls.create configuration in
      TypeEnvironment.AssumeAstEnvironment.load_without_dependency_keys controls
    in
    { type_environment }


  let create_with_cold_start
      ~scheduler
      ~configuration
      ~decorator_configuration
      ~callback_with_qualifiers_and_definitions
    =
    let type_environment = PysaTypeEnvironment.create ~configuration ~decorator_configuration in
    let qualifiers, definitions =
      PysaTypeEnvironment.qualifiers_and_definitions ~scheduler type_environment
    in
    let () =
      callback_with_qualifiers_and_definitions
        (TypeEnvironment.read_only type_environment |> absolute_source_path_of_qualifier)
        qualifiers
        definitions
    in
    PysaTypeEnvironment.populate ~scheduler type_environment definitions;
    { type_environment }


  (* Helpers to access underlying environment and configuration *)

  let read_write_type_environment { type_environment } = type_environment

  let read_write_module_tracker api =
    read_write_type_environment api
    |> TypeEnvironment.unannotated_global_environment
    |> UnannotatedGlobalEnvironment.AssumeAstEnvironment.ast_environment
    |> AstEnvironment.module_tracker


  let type_environment { type_environment } = TypeEnvironment.read_only type_environment

  let configuration api =
    type_environment api |> TypeEnvironment.ReadOnly.controls |> EnvironmentControls.configuration


  (* Interface used in cache management *)

  let module_paths api = read_write_module_tracker api |> ModuleTracker.module_paths

  (* Reload module paths from disk, ignoring any caches. Used by Pysa's cache invalidation logic. *)
  let module_paths_from_disk api =
    configuration api
    |> EnvironmentControls.create
    |> ModuleTracker.create
    |> ModuleTracker.module_paths


  let all_module_paths api = read_write_module_tracker api |> ModuleTracker.all_module_paths

  let artifact_path_of_module_path api module_path =
    let configuration = configuration api in
    ArtifactPaths.artifact_path_of_module_path ~configuration module_path


  let save api =
    read_write_type_environment api
    |> TypeEnvironment.AssumeAstEnvironment.store_without_dependency_keys


  (* Aggressively shrink shared memory by dropping all raw sources *)
  let purge_shared_memory api =
    Log.info "Purging shared memory...";
    let timer = Timer.start () in
    let ast_environment =
      read_write_type_environment api
      |> TypeEnvironment.unannotated_global_environment
      |> UnannotatedGlobalEnvironment.AssumeAstEnvironment.ast_environment
    in
    let qualifiers =
      read_write_type_environment api
      |> TypeEnvironment.AssumeGlobalModuleListing.global_module_paths_api
      |> GlobalModulePathsApi.explicit_qualifiers
    in
    AstEnvironment.remove_sources ast_environment qualifiers;
    Memory.SharedMemory.collect `aggressive;
    Statistics.performance
      ~name:"Purged shared memory"
      ~phase_name:"Purging shared memory"
      ~timer
      ();
    ()
end

module ReadOnly = struct
  type t = {
    type_environment: TypeEnvironment.ReadOnly.t;
    global_module_paths_api: GlobalModulePathsApi.t;
  }

  let of_read_write_api { ReadWrite.type_environment } =
    {
      type_environment = TypeEnvironment.read_only type_environment;
      global_module_paths_api =
        TypeEnvironment.AssumeGlobalModuleListing.global_module_paths_api type_environment;
    }


  let create ~type_environment ~global_module_paths_api =
    { type_environment; global_module_paths_api }


  let type_environment { type_environment; _ } = type_environment

  let global_module_paths_api { global_module_paths_api; _ } = global_module_paths_api

  let global_resolution api = type_environment api |> TypeEnvironment.ReadOnly.global_resolution

  let unannotated_global_environment api =
    type_environment api |> TypeEnvironment.ReadOnly.unannotated_global_environment


  let source_code_api api =
    type_environment api |> TypeEnvironment.ReadOnly.get_untracked_source_code_api


  let contextless_resolution api =
    TypeCheck.resolution
      (global_resolution api)
      (* TODO(T65923817): Eliminate the need of creating a dummy context here *)
      (module TypeCheck.DummyContext)


  (* Interface to get source paths; used when dumping stats from Pysa *)

  let absolute_source_path_of_qualifier ~lookup_source api =
    type_environment api |> absolute_source_path_of_qualifier ~lookup_source


  let explicit_qualifiers api =
    global_module_paths_api api |> GlobalModulePathsApi.explicit_qualifiers


  let parse_annotation api = global_resolution api |> GlobalResolution.parse_annotation

  let get_class_summary api = global_resolution api |> GlobalResolution.get_class_summary

  let get_class_metadata api = global_resolution api |> GlobalResolution.get_class_metadata

  let class_hierarchy api = global_resolution api |> GlobalResolution.class_hierarchy

  let source_is_unit_test api = global_resolution api |> GlobalResolution.source_is_unit_test

  let immediate_parents api = global_resolution api |> GlobalResolution.immediate_parents

  let get_define_names api = global_resolution api |> GlobalResolution.get_define_names

  let parse_reference api = global_resolution api |> GlobalResolution.parse_reference

  let module_exists api = global_resolution api |> GlobalResolution.module_exists

  let class_exists api = global_resolution api |> GlobalResolution.class_exists

  let get_define_body api = global_resolution api |> GlobalResolution.get_define_body

  let resolve_define api = global_resolution api |> GlobalResolution.resolve_define

  let global api = global_resolution api |> GlobalResolution.global

  let overrides api = global_resolution api |> GlobalResolution.overrides

  let annotation_parser api = global_resolution api |> GlobalResolution.annotation_parser

  let get_typed_dictionary api = global_resolution api |> GlobalResolution.get_typed_dictionary

  let exists_matching_class_decorator api =
    unannotated_global_environment api
    |> UnannotatedGlobalEnvironment.ReadOnly.exists_matching_class_decorator


  let type_parameters_as_variables api =
    global_resolution api |> GlobalResolution.type_parameters_as_variables


  let source_of_qualifier api = source_code_api api |> SourceCodeApi.source_of_qualifier

  let relative_path_of_qualifier api =
    source_code_api api |> SourceCodeApi.relative_path_of_qualifier


  let decorated_define api define =
    AnnotatedDefine.create define
    |> AnnotatedDefine.decorate ~resolution:(global_resolution api)
    |> AnnotatedDefine.define


  let named_tuple_attributes api receiver_class =
    let global_resolution = global_resolution api in
    if NamedTuple.is_named_tuple ~global_resolution ~annotation:(Type.Primitive receiver_class) then
      NamedTuple.field_names_from_class_name ~global_resolution receiver_class
    else
      None


  let resolve_expression_to_annotation api =
    contextless_resolution api |> Resolution.resolve_expression_to_annotation


  let get_unannotated_global api =
    unannotated_global_environment api
    |> UnannotatedGlobalEnvironment.ReadOnly.get_unannotated_global


  let all_classes api =
    unannotated_global_environment api
    |> UnannotatedGlobalEnvironment.ReadOnly.GlobalApis.all_classes
         ~global_module_paths_api:(global_module_paths_api api)


  let all_unannotated_globals api =
    unannotated_global_environment api
    |> UnannotatedGlobalEnvironment.ReadOnly.GlobalApis.all_unannotated_globals
         ~global_module_paths_api:(global_module_paths_api api)
end

(* This module represents the API Pysa uses when it needs to interact with Pyre inside of a context
   with a non-global resolution. Any Pysa code that has to traverse what is in essence a typed AST
   (the actual mechanism is to use fixpoint states keyed on statement ids) will rely on this.

   The global `pyre_api` is packaged alongside the resolution for convenience because it is always
   sensible to ask for global information inside of a traversal (this is analagous to how Pyre
   allows you to extract a `GlobalResolution.t` from a `Resolution.t`). *)
module InContext = struct
  type t = {
    pyre_api: ReadOnly.t;
    resolution: Resolution.t;
  }

  let create_at_global_scope pyre_api =
    { pyre_api; resolution = ReadOnly.contextless_resolution pyre_api }


  let create_at_statement_key pyre_api ~definition ~statement_key =
    let { Ast.Node.value = { Ast.Statement.Define.signature = { name; parent; _ }; _ }; _ } =
      definition
    in
    let local_annotations =
      TypeEnvironment.ReadOnly.get_local_annotations (ReadOnly.type_environment pyre_api) name
    in
    let resolution =
      TypeCheck.resolution_at_key
        ~global_resolution:(ReadOnly.global_resolution pyre_api)
        ~local_annotations
        ~parent
        ~statement_key
        (* TODO(T65923817): Eliminate the need of creating a dummy context here *)
        (module TypeCheck.DummyContext)
    in
    { pyre_api; resolution }


  let pyre_api { pyre_api; _ } = pyre_api

  let resolution { resolution; _ } = resolution

  let global_resolution pyre_in_context = pyre_api pyre_in_context |> ReadOnly.global_resolution

  let resolve_reference { resolution; _ } = Resolution.resolve_reference resolution

  let resolve_assignment { pyre_api; resolution } assign =
    { pyre_api; resolution = Resolution.resolve_assignment resolution assign }


  let resolve_generators pyre_in_context generators =
    let resolve_generator pyre_in_context generator =
      resolve_assignment pyre_in_context (Ast.Statement.Statement.generator_assignment generator)
    in
    List.fold generators ~init:pyre_in_context ~f:resolve_generator
end
