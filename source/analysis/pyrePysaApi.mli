(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module ReadWrite : sig
  type t = { type_environment: TypeEnvironment.t }

  val load_from_cache : configuration:Configuration.Analysis.t -> t

  val create_with_cold_start
    :  scheduler:Scheduler.t ->
    configuration:Configuration.Analysis.t ->
    decorator_configuration:DecoratorPreprocessing.Configuration.t ->
    callback_with_qualifiers_and_definitions:
      ((lookup_source:(ArtifactPath.t -> SourcePath.t option) -> Ast.Reference.t -> string option) ->
      Ast.Reference.t list ->
      Ast.Reference.t list ->
      unit) ->
    t

  val configuration : t -> Configuration.Analysis.t

  val module_paths : t -> Ast.ModulePath.t list

  val module_paths_from_disk : t -> Ast.ModulePath.t list

  val all_module_paths : t -> Ast.ModulePath.t list

  val artifact_path_of_module_path : t -> Ast.ModulePath.t -> ArtifactPath.t

  val save : t -> unit

  val purge_shared_memory : t -> unit
end

module ReadOnly : sig
  type t = {
    type_environment: TypeEnvironment.TypeEnvironmentReadOnly.t;
    global_module_paths_api: GlobalModulePathsApi.t;
  }

  val of_read_write_api : ReadWrite.t -> t

  val create
    :  type_environment:TypeEnvironment.TypeEnvironmentReadOnly.t ->
    global_module_paths_api:GlobalModulePathsApi.t ->
    t

  val absolute_source_path_of_qualifier
    :  lookup_source:(ArtifactPath.t -> SourcePath.t option) ->
    t ->
    Ast.Reference.t ->
    string option

  val explicit_qualifiers : t -> Ast.Reference.t list

  val parse_annotation
    :  t ->
    ?validation:SharedMemoryKeys.ParseAnnotationKey.type_validation_policy ->
    Ast.Expression.t ->
    Type.t

  val get_class_summary : t -> string -> ClassSummary.t Ast.Node.t option

  val get_class_metadata : t -> string -> ClassSuccessorMetadataEnvironment.class_metadata option

  val class_hierarchy : t -> (module ClassHierarchy.Handler)

  val source_is_unit_test : t -> source:Ast.Source.t -> bool

  val immediate_parents : t -> string -> string list

  val get_define_names_for_qualifier : t -> Ast.Reference.t -> Ast.Reference.t list

  val parse_reference : t -> Ast.Reference.t -> Type.t

  val module_exists : t -> Ast.Reference.t -> bool

  val class_exists : t -> string -> bool

  val get_define_body : t -> Ast.Reference.t -> Ast.Statement.Define.t Ast.Node.t option

  val resolve_define
    :  t ->
    implementation:Ast.Statement.Define.Signature.t option ->
    overloads:Ast.Statement.Define.Signature.t list ->
    AttributeResolution.resolved_define

  val global : t -> Ast.Reference.t -> AttributeResolution.Global.t option

  val overrides : t -> string -> name:string -> AnnotatedAttribute.instantiated option

  val annotation_parser : t -> AnnotatedCallable.annotation_parser

  val get_typed_dictionary : t -> Type.t -> Type.t Type.Record.TypedDictionary.record option

  val less_or_equal : t -> left:Type.t -> right:Type.t -> bool

  val resolve_exports : t -> ?from:Ast.Reference.t -> Ast.Reference.t -> ResolvedReference.t option

  val successors : t -> string -> string list

  val location_of_global : t -> Ast.Reference.t -> Ast.Location.WithModule.t option

  val get_function_definition : t -> Ast.Reference.t -> FunctionDefinition.t option

  val attribute_from_class_name
    :  t ->
    ?transitive:bool ->
    ?accessed_through_class:bool ->
    ?accessed_through_readonly:bool ->
    ?special_method:bool ->
    string ->
    name:string ->
    instantiated:Type.t ->
    AnnotatedAttribute.instantiated option

  val has_transitive_successor : t -> successor:string -> string -> bool

  val exists_matching_class_decorator
    :  t ->
    ?dependency:SharedMemoryKeys.DependencyKey.registered ->
    names:string list ->
    ClassSummary.t Ast.Node.t ->
    bool

  val type_parameters_as_variables : t -> string -> Type.Variable.t list option

  val source_of_qualifier : t -> Ast.Reference.t -> Ast.Source.t option

  val relative_path_of_qualifier : t -> Ast.Reference.t -> string option

  val decorated_define : t -> Ast.Statement.Define.t Ast.Node.t -> Ast.Statement.Define.t Ast.Node.t

  val named_tuple_attributes : t -> string -> string list option

  val resolve_expression_to_annotation : t -> Ast.Expression.t -> Annotation.t

  val get_unannotated_global
    :  t ->
    ?dependency:SharedMemoryKeys.DependencyKey.registered ->
    Ast.Reference.t ->
    Ast.UnannotatedGlobal.t option

  val all_classes : t -> string list

  val all_unannotated_globals : t -> Ast.Reference.t list
end

module InContext : sig
  type t = {
    pyre_api: ReadOnly.t;
    resolution: Resolution.t;
  }

  val create_at_global_scope : ReadOnly.t -> t

  val create_at_statement_key
    :  ReadOnly.t ->
    define:Ast.Statement.Define.t ->
    statement_key:int ->
    t

  val pyre_api : t -> ReadOnly.t

  val is_global : t -> reference:Ast.Reference.t -> bool

  val resolve_reference : t -> Ast.Reference.t -> Type.t

  val resolve_assignment : t -> Ast.Statement.Assign.t -> t

  val resolve_expression_to_type : t -> Ast.Expression.t -> Type.t

  val resolve_attribute_access : t -> base_type:Type.t -> attribute:string -> Type.t

  val fallback_attribute
    :  t ->
    ?accessed_through_class:bool ->
    ?instantiated:Type.t option ->
    name:string ->
    string ->
    AnnotatedAttribute.instantiated option

  val redirect_special_calls : t -> Ast.Expression.Call.t -> Ast.Expression.Call.t

  val resolve_generators : t -> Ast.Expression.Comprehension.Generator.t list -> t
end
