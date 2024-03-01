(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* CallResolution: utility functions to resolve types, ignoring untracked types
 * (i.e, when annotation refer to undefined symbols).
 *)

open Core
open Ast
open Expression
open Pyre
module PyrePysaApi = Analysis.PyrePysaApi
module AnnotatedAttribute = Analysis.AnnotatedAttribute

(* Evaluates to the representation of literal strings, integers and enums. *)
let extract_constant_name { Node.value = expression; _ } =
  match expression with
  | Expression.Constant (Constant.String literal) -> Some literal.value
  | Expression.Constant (Constant.Integer i) -> Some (string_of_int i)
  | Expression.Constant Constant.False -> Some "False"
  | Expression.Constant Constant.True -> Some "True"
  | Expression.Name name -> (
      let name = name_to_reference name >>| Reference.delocalize >>| Reference.last in
      match name with
      (* Heuristic: All uppercase names tend to be enums, so only taint the field in those cases. *)
      | Some name
        when String.for_all name ~f:(fun character ->
                 (not (Char.is_alpha character)) || Char.is_uppercase character) ->
          Some name
      | _ -> None)
  | _ -> None


(* Check whether `successor` extends `predecessor`.
 * Returns false on untracked types.
 * Returns `reflexive` if `predecessor` and `successor` are equal. *)
let has_transitive_successor_ignoring_untracked ~pyre_api ~reflexive ~predecessor ~successor =
  if String.equal predecessor successor then
    reflexive
  else
    try PyrePysaApi.ReadOnly.has_transitive_successor pyre_api ~successor predecessor with
    | Analysis.ClassHierarchy.Untracked untracked_type ->
        Log.warning
          "Found untracked type `%s` when checking whether `%s` is a subclass of `%s`. This could \
           lead to false negatives."
          untracked_type
          successor
          predecessor;
        false


(* Evaluates to whether the provided expression is a superclass of define. *)
let is_super ~pyre_in_context ~define expression =
  match expression.Node.value with
  | Expression.Call { callee = { Node.value = Name (Name.Identifier "super"); _ }; _ } -> true
  | _ ->
      (* We also support explicit calls to superclass constructors. *)
      let annotation =
        PyrePysaApi.InContext.resolve_expression_to_type pyre_in_context expression
      in
      if Type.is_meta annotation then
        let type_parameter = Type.single_parameter annotation in
        match type_parameter with
        | Type.Parametric { name = parent_name; _ }
        | Type.Primitive parent_name ->
            let class_name =
              Reference.prefix define.Node.value.Statement.Define.signature.name >>| Reference.show
            in
            class_name
            >>| (fun class_name ->
                  has_transitive_successor_ignoring_untracked
                    ~pyre_api:(PyrePysaApi.InContext.pyre_api pyre_in_context)
                    ~reflexive:false
                    ~predecessor:class_name
                    ~successor:parent_name)
            |> Option.value ~default:false
        | _ -> false
      else
        false


(* A nonlocal variable is neither global nor local *)
let is_nonlocal ~pyre_in_context ~define variable =
  let define_list = Reference.as_list (Reference.delocalize define) in
  let variable_list = Reference.as_list (Reference.delocalize variable) in
  let is_prefix = List.is_prefix ~equal:String.equal ~prefix:define_list variable_list in
  let is_global = PyrePysaApi.InContext.is_global pyre_in_context ~reference:variable in
  let is_nonlocal = (not is_prefix) && (not is_global) && Reference.is_local variable in
  is_nonlocal


(* Resolve an expression into a type. Untracked types are resolved into `Any`. *)
let resolve_ignoring_untracked ~pyre_in_context expression =
  try PyrePysaApi.InContext.resolve_expression_to_type pyre_in_context expression with
  | Analysis.ClassHierarchy.Untracked untracked_type ->
      Log.warning
        "Found untracked type `%s` when resolving the type of `%a`. This could lead to false \
         negatives."
        untracked_type
        Expression.pp
        (Ast.Expression.delocalize expression);
      Type.Any


(* Resolve an attribute access into a type. Untracked types are resolved into `Any`. *)
let resolve_attribute_access_ignoring_untracked ~pyre_in_context ~base_type ~attribute =
  try PyrePysaApi.InContext.resolve_attribute_access pyre_in_context ~base_type ~attribute with
  | Analysis.ClassHierarchy.Untracked untracked_type ->
      Log.warning
        "Found untracked type `%s` when resolving the type of attribute `%s` in `%a`. This could \
         lead to false negatives."
        untracked_type
        attribute
        Type.pp
        base_type;
      Type.Any


let defining_attribute ~pyre_in_context parent_type attribute =
  Type.split parent_type
  |> fst
  |> Type.primitive_name
  >>= fun class_name ->
  let instantiated_attribute =
    PyrePysaApi.ReadOnly.attribute_from_class_name
      (PyrePysaApi.InContext.pyre_api pyre_in_context)
      ~transitive:true
      ~name:attribute
      ~instantiated:parent_type
      class_name
  in
  instantiated_attribute
  >>= fun instantiated_attribute ->
  if AnnotatedAttribute.defined instantiated_attribute then
    Some instantiated_attribute
  else
    PyrePysaApi.InContext.fallback_attribute pyre_in_context ~name:attribute class_name


let strip_optional annotation =
  annotation |> Type.optional_value |> Option.value ~default:annotation


(* Convert `TypeVar["X", bound="Y"]` to `Y` *)
let unbind_type_variable = function
  | Type.Variable { constraints = Type.Record.Variable.Bound bound; _ } -> bound
  | annotation -> annotation


(* Convert `ReadOnly[X]` back to just `X` *)
let strip_readonly annotation =
  if Type.ReadOnly.is_readonly annotation then
    Type.ReadOnly.strip_readonly annotation
  else
    annotation


let extract_coroutine_value annotation =
  annotation |> Type.coroutine_value |> Option.value ~default:annotation


(* Resolve an expression into a type, ignoring
 * errors related to accessing `None`, `ReadOnly`, and bound `TypeVar`s. *)
let rec resolve_ignoring_errors ~pyre_in_context expression =
  let resolve_expression_to_type expression =
    match resolve_ignoring_untracked ~pyre_in_context expression, Node.value expression with
    | ( Type.Callable ({ Type.Callable.kind = Anonymous; _ } as callable),
        Expression.Name (Name.Identifier function_name) )
      when function_name |> String.is_prefix ~prefix:"$local_" ->
        (* Treat nested functions as named callables. *)
        Type.Callable { callable with kind = Named (Reference.create function_name) }
    | annotation, _ -> annotation
  in
  let annotation =
    match Node.value expression with
    | Expression.Name (Name.Attribute { base; attribute; _ }) -> (
        let base_type =
          resolve_ignoring_errors ~pyre_in_context base
          |> fun annotation -> Type.optional_value annotation |> Option.value ~default:annotation
        in
        match defining_attribute ~pyre_in_context base_type attribute with
        | Some _ ->
            resolve_attribute_access_ignoring_untracked ~pyre_in_context ~base_type ~attribute
        | None -> resolve_expression_to_type expression
        (* Lookup the base_type for the attribute you were interested in *))
    | _ -> resolve_expression_to_type expression
  in
  annotation |> strip_optional |> strip_readonly |> unbind_type_variable
