(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* Model: represents the model of a given callable.
 *
 * A model contains all the information the global fixpoint needs about a given
 * callable, which is:
 * - The set of sources returned by the callable;
 * - The set of sinks reached by the parameters of the callable;
 * - Whether a parameter propagates its taint to the return value, which we call
 * taint-in-taint-out (tito).
 *
 * For instance, for the following callable `foo`:
 * ```
 * def foo(x, y, cond):
 *   if cond:
 *     x = user_controlled()
 *   sql(str(y))
 *   return x
 * ```
 *
 * The model of `foo` would be:
 * - sources returned: UserControlled
 * - sinks: y -> SQL
 * - tito: x -> LocalReturn
 *)

open Core
open Pyre
open Interprocedural
open Domains

let json_to_string ~indent json =
  let lines = Yojson.Safe.to_string json |> Yojson.Safe.prettify |> String.split ~on:'\n' in
  match lines with
  | [line] -> line
  | lines ->
      lines
      |> List.map ~f:(fun line -> indent ^ line)
      |> String.concat ~sep:"\n"
      |> fun content -> "\n" ^ content


(*
 * Represents the result of the forward analysis. This contains "generations", i.e sources that
 * must be propagated to callers.
 *
 * For instance:
 * ```
 * def foo():
 *   return source()
 * ```
 * would generate: `Forward { LocalResult -> Source }`
 *
 * ```
 * def bar(l):
 *   l.append(source())
 * ```
 * would generate: `Forward { PositionalParameter(l) -> Source }`
 *)
module Forward = struct
  type t = { generations: ForwardState.t }

  let pp_inner formatter { generations } =
    if not (ForwardState.is_empty generations) then
      Format.fprintf
        formatter
        "\n  Generations: %s"
        (json_to_string
           ~indent:"    "
           (ForwardState.to_json
              ~expand_overrides:None
              ~is_valid_callee:(fun ~trace_kind:_ ~port:_ ~path:_ ~callee:_ -> true)
              ~trace_kind:(Some TraceKind.Source)
              ~resolve_module_path:None
              ~export_leaf_names:ExportLeafNames.Always
              generations))


  let pp formatter = Format.fprintf formatter "{%a\n}" pp_inner

  let show = Format.asprintf "%a" pp

  let empty = { generations = ForwardState.empty }

  let is_empty { generations } = ForwardState.is_empty generations

  let obscure = empty

  let join { generations = left } { generations = right } =
    { generations = ForwardState.join left right }


  let widen ~iteration ~previous:{ generations = prev } ~next:{ generations = next } =
    { generations = ForwardState.widen ~iteration ~prev ~next }


  let less_or_equal ~left:{ generations = left } ~right:{ generations = right } =
    ForwardState.less_or_equal ~left ~right
end

(** Represents the result of the backward analysis. This contains sinks that must be propagated to
    callers, as well as taint-in-taint-out information. *)
module Backward = struct
  type t = {
    taint_in_taint_out: BackwardState.t;
    sink_taint: BackwardState.t;
  }

  let pp_inner formatter { taint_in_taint_out; sink_taint } =
    let () =
      if not (BackwardState.is_empty sink_taint) then
        Format.fprintf
          formatter
          "\n  Sinks: %s"
          (json_to_string
             ~indent:"    "
             (BackwardState.to_json
                ~expand_overrides:None
                ~is_valid_callee:(fun ~trace_kind:_ ~port:_ ~path:_ ~callee:_ -> true)
                ~trace_kind:(Some TraceKind.Sink)
                ~resolve_module_path:None
                ~export_leaf_names:ExportLeafNames.Always
                sink_taint))
    in
    let () =
      if not (BackwardState.is_empty taint_in_taint_out) then
        Format.fprintf
          formatter
          "\n  Taint-in-taint-out: %s"
          (json_to_string
             ~indent:"    "
             (BackwardState.to_json
                ~expand_overrides:None
                ~is_valid_callee:(fun ~trace_kind:_ ~port:_ ~path:_ ~callee:_ -> false)
                ~trace_kind:None
                ~resolve_module_path:None
                ~export_leaf_names:ExportLeafNames.Always
                taint_in_taint_out))
    in
    ()


  let pp formatter = Format.fprintf formatter "{%a\n}" pp_inner

  let show = Format.asprintf "%a" pp

  let empty = { sink_taint = BackwardState.empty; taint_in_taint_out = BackwardState.empty }

  let is_empty { sink_taint; taint_in_taint_out } =
    BackwardState.is_empty sink_taint && BackwardState.is_empty taint_in_taint_out


  let obscure = empty

  let join
      { sink_taint = sink_taint_left; taint_in_taint_out = tito_left }
      { sink_taint = sink_taint_right; taint_in_taint_out = tito_right }
    =
    {
      sink_taint = BackwardState.join sink_taint_left sink_taint_right;
      taint_in_taint_out = BackwardState.join tito_left tito_right;
    }


  let widen
      ~iteration
      ~previous:{ sink_taint = sink_taint_previous; taint_in_taint_out = tito_previous }
      ~next:{ sink_taint = sink_taint_next; taint_in_taint_out = tito_next }
    =
    let sink_taint =
      BackwardState.widen ~iteration ~prev:sink_taint_previous ~next:sink_taint_next
    in
    let taint_in_taint_out = BackwardState.widen ~iteration ~prev:tito_previous ~next:tito_next in
    { sink_taint; taint_in_taint_out }


  let less_or_equal
      ~left:{ sink_taint = sink_taint_left; taint_in_taint_out = tito_left }
      ~right:{ sink_taint = sink_taint_right; taint_in_taint_out = tito_right }
    =
    BackwardState.less_or_equal ~left:sink_taint_left ~right:sink_taint_right
    && BackwardState.less_or_equal ~left:tito_left ~right:tito_right
end

(* Represents "parameter sources", i.e sources that must be instantiated on the
 * body of the modeled function. Those can only be provided by user models.
 *
 * For instance:
 * ```
 * # .pysa
 * def foo(x: TaintSource[Test]): ...
 * ```
 *
 * ```
 * # .py
 * def foo(x):
 *   sink(x) # Issue since x is tainted
 * ```
 *)
module ParameterSources = struct
  type t = { parameter_sources: ForwardState.t }

  let pp_inner formatter { parameter_sources } =
    if not (ForwardState.is_empty parameter_sources) then
      Format.fprintf
        formatter
        "\n  Parameter Sources: %s"
        (json_to_string
           ~indent:"    "
           (ForwardState.to_json
              ~expand_overrides:None
              ~is_valid_callee:(fun ~trace_kind:_ ~port:_ ~path:_ ~callee:_ -> false)
              ~trace_kind:None
              ~resolve_module_path:None
              ~export_leaf_names:ExportLeafNames.Always
              parameter_sources))


  let pp formatter = Format.fprintf formatter "{%a\n}" pp_inner

  let show = Format.asprintf "%a" pp

  let empty = { parameter_sources = ForwardState.empty }

  let is_empty { parameter_sources } = ForwardState.is_empty parameter_sources

  let join { parameter_sources = left } { parameter_sources = right } =
    { parameter_sources = ForwardState.join left right }


  let widen ~iteration ~previous:{ parameter_sources = prev } ~next:{ parameter_sources = next } =
    { parameter_sources = ForwardState.widen ~iteration ~prev ~next }


  let less_or_equal ~left:{ parameter_sources = left } ~right:{ parameter_sources = right } =
    ForwardState.less_or_equal ~left ~right
end

module Sanitizers = struct
  type t = {
    (* `global` applies to all parameters and the return value.
     * For callables:
     * - sources are only sanitized in the forward trace;
     * - sinks are only sanitized in the backward trace;
     * - titos are sanitized in both traces (using sanitize taint transforms).
     * For attribute models, sanitizers are applied on attribute accesses, in both traces.
     *)
    global: Sanitize.t;
    (* Sanitizers applying to all parameters, in both traces. *)
    parameters: Sanitize.t;
    (* Map from parameter or return value to sanitizers applying in both traces. *)
    roots: Sanitize.RootMap.t;
  }

  let pp_inner formatter { global; parameters; roots } =
    let () =
      if not (Sanitize.is_empty global) then
        Format.fprintf
          formatter
          "\n  Global Sanitizer: %s"
          (json_to_string ~indent:"    " (Sanitize.to_json global))
    in
    let () =
      if not (Sanitize.is_empty parameters) then
        Format.fprintf
          formatter
          "\n  Parameters Sanitizer: %s"
          (json_to_string ~indent:"    " (Sanitize.to_json parameters))
    in
    let () =
      if not (Sanitize.RootMap.is_bottom roots) then
        Format.fprintf
          formatter
          "\n  Sanitizers: %s"
          (json_to_string ~indent:"    " (Sanitize.RootMap.to_json roots))
    in
    ()


  let pp formatter = Format.fprintf formatter "{%a\n}" pp_inner

  let show = Format.asprintf "%a" pp

  let empty =
    { global = Sanitize.empty; parameters = Sanitize.empty; roots = Sanitize.RootMap.bottom }


  let is_empty { global; parameters; roots } =
    Sanitize.is_empty global && Sanitize.is_empty parameters && Sanitize.RootMap.is_bottom roots


  let join
      { global = global_left; parameters = parameters_left; roots = roots_left }
      { global = global_right; parameters = parameters_right; roots = roots_right }
    =
    {
      global = Sanitize.join global_left global_right;
      parameters = Sanitize.join parameters_left parameters_right;
      roots = Sanitize.RootMap.join roots_left roots_right;
    }


  let widen ~iteration:_ ~previous ~next = join previous next

  let less_or_equal
      ~left:{ global = global_left; parameters = parameters_left; roots = roots_left }
      ~right:{ global = global_right; parameters = parameters_right; roots = roots_right }
    =
    Sanitize.less_or_equal ~left:global_left ~right:global_right
    && Sanitize.less_or_equal ~left:parameters_left ~right:parameters_right
    && Sanitize.RootMap.less_or_equal ~left:roots_left ~right:roots_right
end

module Mode = struct
  let name = "modes"

  type t =
    | Obscure
    | SkipObscure (* Don't treat as obscure *)
    | SkipAnalysis (* Don't analyze at all *)
    | SkipDecoratorWhenInlining
    | SkipOverrides (* Don't analyze any override *)
    | AnalyzeAllOverrides
      (* Force analyzing all overrides, regardless of SkipOverrides or maximum overrides *)
    | Entrypoint
    | IgnoreDecorator
    | SkipModelBroadening
  [@@deriving compare, equal]

  let pp formatter = function
    | Obscure -> Format.fprintf formatter "Obscure"
    | SkipObscure -> Format.fprintf formatter "SkipObscure"
    | SkipAnalysis -> Format.fprintf formatter "SkipAnalysis"
    | SkipDecoratorWhenInlining -> Format.fprintf formatter "SkipDecoratorWhenInlining"
    | SkipOverrides -> Format.fprintf formatter "SkipOverrides"
    | AnalyzeAllOverrides -> Format.fprintf formatter "AnalyzeAllOverrides"
    | Entrypoint -> Format.fprintf formatter "Entrypoint"
    | IgnoreDecorator -> Format.fprintf formatter "IgnoreDecorator"
    | SkipModelBroadening -> Format.fprintf formatter "SkipModelBroadening"


  let show = Format.asprintf "%a" pp

  let to_json mode = `String (show mode)

  let from_string = function
    | "Obscure" -> Some Obscure
    | "SkipObscure" -> Some SkipObscure
    | "SkipAnalysis" -> Some SkipAnalysis
    | "SkipDecoratorWhenInlining" -> Some SkipDecoratorWhenInlining
    | "SkipOverrides" -> Some SkipOverrides
    | "Entrypoint" -> Some Entrypoint
    | "IgnoreDecorator" -> Some IgnoreDecorator
    | "SkipModelBroadening" -> Some SkipModelBroadening
    | "AnalyzeAllOverrides" -> Some AnalyzeAllOverrides
    | _ -> None
end

module ModeSet = struct
  module T = Abstract.SetDomain.Make (Mode)
  include T

  let empty = T.bottom

  let is_empty = T.is_bottom

  let equal left right = T.less_or_equal ~left ~right && T.less_or_equal ~left:right ~right:left

  let to_json modes = `List (modes |> T.elements |> List.map ~f:Mode.to_json)

  let pp_inner formatter modes =
    if not (is_empty modes) then
      Format.fprintf formatter "\n  Modes: %s" (json_to_string ~indent:"    " (to_json modes))


  let pp formatter = Format.fprintf formatter "{%a\n}" pp_inner

  let resolve_conflicting_modes result =
    let resolve_conflicts ~to_keep ~to_discard result =
      if contains to_keep result && contains to_discard result then
        remove to_discard result
      else
        result
    in
    (* If a mode set has both `to_keep` and `to_discard`, we expect it to keep `to_keep` and discard
       `to_discard`. *)
    result
    |> resolve_conflicts ~to_keep:SkipObscure ~to_discard:Obscure
    |> resolve_conflicts ~to_keep:AnalyzeAllOverrides ~to_discard:SkipOverrides


  let join_user_modes left right = join left right |> resolve_conflicting_modes
end

type t = {
  forward: Forward.t;
  backward: Backward.t;
  parameter_sources: ParameterSources.t;
  sanitizers: Sanitizers.t;
  modes: ModeSet.t;
}

let pp formatter { forward; backward; parameter_sources; sanitizers; modes } =
  Format.fprintf
    formatter
    "{%a%a%a%a%a\n}"
    Forward.pp_inner
    forward
    Backward.pp_inner
    backward
    ParameterSources.pp_inner
    parameter_sources
    Sanitizers.pp_inner
    sanitizers
    ModeSet.pp_inner
    modes


let show = Format.asprintf "%a" pp

let is_empty ~with_modes { forward; backward; parameter_sources; sanitizers; modes } =
  Forward.is_empty forward
  && Backward.is_empty backward
  && ParameterSources.is_empty parameter_sources
  && Sanitizers.is_empty sanitizers
  && ModeSet.equal with_modes modes


let empty_model =
  {
    forward = Forward.empty;
    backward = Backward.empty;
    parameter_sources = ParameterSources.empty;
    sanitizers = Sanitizers.empty;
    modes = ModeSet.empty;
  }


let empty_skip_model =
  {
    forward = Forward.empty;
    backward = Backward.empty;
    parameter_sources = ParameterSources.empty;
    sanitizers = Sanitizers.empty;
    modes = ModeSet.singleton SkipAnalysis;
  }


let obscure_model =
  {
    forward = Forward.obscure;
    backward = Backward.obscure;
    parameter_sources = ParameterSources.empty;
    sanitizers = Sanitizers.empty;
    modes = ModeSet.singleton Obscure;
  }


let is_obscure { modes; _ } = ModeSet.contains Obscure modes

let remove_obscureness ({ modes; _ } as model) = { model with modes = ModeSet.remove Obscure modes }

let remove_sinks model =
  { model with backward = { model.backward with sink_taint = BackwardState.empty } }


let add_obscure_sink ~pyre_api ~call_target model =
  let real_target =
    match call_target with
    | Target.Function _ -> Some call_target
    | Target.Method _ -> Some call_target
    | Target.Override method_name -> Some (Target.Method method_name)
    | Target.Object _ -> None
  in
  match real_target with
  | None -> model
  | Some real_target -> (
      match Target.get_module_and_definition ~pyre_api real_target with
      | None ->
          let () = Log.warning "Found no definition for %a" Target.pp_pretty real_target in
          model
      | Some (_, { value = { signature = { parameters; _ }; _ }; _ }) ->
          let open Domains in
          let sink =
            BackwardTaint.singleton CallInfo.declaration (Sinks.NamedSink "Obscure") Frame.initial
            |> BackwardState.Tree.create_leaf
          in
          let parameters = AccessPath.normalize_parameters parameters in
          let add_parameter_sink sink_taint { AccessPath.NormalizedParameter.root; _ } =
            BackwardState.assign ~root ~path:[] sink sink_taint
          in
          let sink_taint =
            List.fold_left ~init:model.backward.sink_taint ~f:add_parameter_sink parameters
          in
          { model with backward = { model.backward with sink_taint } })


let join left right =
  {
    forward = Forward.join left.forward right.forward;
    backward = Backward.join left.backward right.backward;
    parameter_sources = ParameterSources.join left.parameter_sources right.parameter_sources;
    sanitizers = Sanitizers.join left.sanitizers right.sanitizers;
    modes = ModeSet.join left.modes right.modes;
  }


let widen ~iteration ~previous ~next =
  {
    forward = Forward.widen ~iteration ~previous:previous.forward ~next:next.forward;
    backward = Backward.widen ~iteration ~previous:previous.backward ~next:next.backward;
    parameter_sources =
      ParameterSources.widen
        ~iteration
        ~previous:previous.parameter_sources
        ~next:next.parameter_sources;
    sanitizers = Sanitizers.widen ~iteration ~previous:previous.sanitizers ~next:next.sanitizers;
    modes = ModeSet.widen ~iteration ~prev:previous.modes ~next:next.modes;
  }


let less_or_equal ~left ~right =
  Forward.less_or_equal ~left:left.forward ~right:right.forward
  && Backward.less_or_equal ~left:left.backward ~right:right.backward
  && ParameterSources.less_or_equal ~left:left.parameter_sources ~right:right.parameter_sources
  && Sanitizers.less_or_equal ~left:left.sanitizers ~right:right.sanitizers
  && ModeSet.less_or_equal ~left:left.modes ~right:right.modes


let for_override_model
    ~callable
    {
      forward = { generations };
      backward = { sink_taint; taint_in_taint_out };
      parameter_sources = { parameter_sources };
      sanitizers;
      modes;
    }
  =
  {
    forward = { generations = ForwardState.for_override_model ~callable generations };
    backward =
      {
        sink_taint = BackwardState.for_override_model ~callable sink_taint;
        taint_in_taint_out = BackwardState.for_override_model ~callable taint_in_taint_out;
      };
    parameter_sources =
      { parameter_sources = ForwardState.for_override_model ~callable parameter_sources };
    sanitizers;
    modes;
  }


let apply_sanitizers
    ~taint_configuration
    {
      forward = { generations };
      backward = { taint_in_taint_out; sink_taint };
      parameter_sources;
      sanitizers = { global; parameters; roots } as sanitizers;
      modes;
    }
  =
  (* Apply the global sanitizer. *)
  (* Here, we are applying the legacy behavior of sanitizers, where we only
   * sanitize the forward trace or the backward trace. *)
  let generations =
    (* @SanitizeSingleTrace(TaintSource[...]) *)
    ForwardState.apply_sanitizers
      ~taint_configuration
      ~sanitize_source:true
      ~sanitizer:global
      generations
  in
  let taint_in_taint_out =
    (* @SanitizeSingleTrace(TaintInTaintOut[...]) *)
    BackwardState.apply_sanitizers
      ~taint_configuration
      ~sanitize_tito:true
      ~insert_location:TaintTransformOperation.InsertLocation.Back
      ~sanitizer:global
      taint_in_taint_out
  in
  let sink_taint =
    (* @SanitizeSingleTrace(TaintSink[...]) *)
    BackwardState.apply_sanitizers
      ~taint_configuration
      ~sanitize_sink:true
      ~sanitizer:global
      sink_taint
  in

  (* Apply the parameters sanitizer. *)
  (* Here, we apply sanitizers both in the forward and backward trace. *)
  (* Note that by design, sanitizing a specific source or sink also sanitizes
   * taint-in-taint-out for that source/sink. *)
  let generations =
    (* Sanitize(Parameters[TaintSource[...]]) *)
    ForwardState.apply_sanitizers
      ~taint_configuration
      ~sanitize_source:true
      ~roots:RootSelector.AllParameters
      ~sanitizer:parameters
      generations
  in
  let sink_taint =
    (* Sanitize(Parameters[TaintSource[...]]) *)
    BackwardState.apply_sanitizers
      ~taint_configuration
      ~sanitize_source:true
      ~ignore_if_sanitize_all:true
      ~roots:RootSelector.AllParameters
      ~sanitizer:parameters
      sink_taint
  in
  let taint_in_taint_out =
    (* Sanitize(Parameters[TaintSource[...]]) *)
    BackwardState.apply_sanitizers
      ~taint_configuration
      ~sanitize_source:true
      ~ignore_if_sanitize_all:true
      ~sanitizer:parameters
      taint_in_taint_out
  in
  let taint_in_taint_out =
    (* Sanitize(Parameters[TaintInTaintOut[...]]) *)
    BackwardState.apply_sanitizers
      ~taint_configuration
      ~sanitize_tito:true
      ~insert_location:TaintTransformOperation.InsertLocation.Back
      ~sanitizer:parameters
      taint_in_taint_out
  in
  let sink_taint =
    (* Sanitize(Parameters[TaintSink[...]]) *)
    BackwardState.apply_sanitizers
      ~taint_configuration
      ~sanitize_sink:true
      ~roots:RootSelector.AllParameters
      ~sanitizer:parameters
      sink_taint
  in
  let taint_in_taint_out =
    (* Sanitize(Parameters[TaintSink[...]]) *)
    BackwardState.apply_sanitizers
      ~taint_configuration
      ~sanitize_sink:true
      ~ignore_if_sanitize_all:true
      ~sanitizer:parameters
      taint_in_taint_out
  in

  (* Apply the return sanitizer. *)
  let sanitize_return sanitizer (generations, taint_in_taint_out, sink_taint) =
    let generations =
      (* def foo() -> Sanitize[TaintSource[...]] *)
      ForwardState.apply_sanitizers
        ~taint_configuration
        ~sanitize_source:true
        ~roots:(RootSelector.Root AccessPath.Root.LocalResult)
        ~sanitizer
        generations
    in
    let taint_in_taint_out =
      (* def foo() -> Sanitize[TaintSource[...]] *)
      BackwardState.apply_sanitizers
        ~taint_configuration
        ~sanitize_source:true
        ~ignore_if_sanitize_all:true
        ~sanitizer
        taint_in_taint_out
    in
    let taint_in_taint_out =
      (* def foo() -> Sanitize[TaintInTaintOut[...]] *)
      BackwardState.apply_sanitizers
        ~taint_configuration
        ~sanitize_tito:true
        ~insert_location:TaintTransformOperation.InsertLocation.Back
        ~sanitizer
        taint_in_taint_out
    in
    let generations =
      (* def foo() -> Sanitize[TaintSink[...]] *)
      ForwardState.apply_sanitizers
        ~taint_configuration
        ~sanitize_sink:true
        ~ignore_if_sanitize_all:true
        ~roots:(RootSelector.Root AccessPath.Root.LocalResult)
        ~sanitizer
        generations
    in
    let taint_in_taint_out =
      (* def foo() -> Sanitize[TaintSink[...]] *)
      BackwardState.apply_sanitizers
        ~taint_configuration
        ~sanitize_sink:true
        ~ignore_if_sanitize_all:true
        ~sanitizer
        taint_in_taint_out
    in
    generations, taint_in_taint_out, sink_taint
  in

  (* Apply the parameter-specific sanitizers. *)
  let sanitize_parameter (parameter, sanitizer) (generations, taint_in_taint_out, sink_taint) =
    let generations =
      (* def foo(self: Sanitize[TaintSource[...]]) *)
      ForwardState.apply_sanitizers
        ~taint_configuration
        ~sanitize_source:true
        ~roots:(RootSelector.Root parameter)
        ~sanitizer
        generations
    in
    let sink_taint =
      (* def foo(x: Sanitize[TaintSource[...]]): ... *)
      BackwardState.apply_sanitizers
        ~taint_configuration
        ~sanitize_source:true
        ~ignore_if_sanitize_all:true
        ~roots:(RootSelector.Root parameter)
        ~sanitizer
        sink_taint
    in
    let taint_in_taint_out =
      (* def foo(x: Sanitize[TaintSource[...]]): ... *)
      BackwardState.apply_sanitizers
        ~taint_configuration
        ~sanitize_source:true
        ~ignore_if_sanitize_all:true
        ~roots:(RootSelector.Root parameter)
        ~sanitizer
        taint_in_taint_out
    in
    let taint_in_taint_out =
      (* def foo(x: Sanitize[TaintInTaintOut[...]]): ... *)
      BackwardState.apply_sanitizers
        ~taint_configuration
        ~sanitize_tito:true
        ~insert_location:TaintTransformOperation.InsertLocation.Back
        ~roots:(RootSelector.Root parameter)
        ~sanitizer
        taint_in_taint_out
    in
    let sink_taint =
      (* def foo(x: Sanitize[TaintSink[...]]): ... *)
      BackwardState.apply_sanitizers
        ~taint_configuration
        ~sanitize_sink:true
        ~roots:(RootSelector.Root parameter)
        ~sanitizer
        sink_taint
    in
    let generations =
      (* def foo(self: Sanitize[TaintSink[...]]) *)
      ForwardState.apply_sanitizers
        ~taint_configuration
        ~sanitize_sink:true
        ~roots:(RootSelector.Root parameter)
        ~sanitizer
        generations
    in
    let taint_in_taint_out =
      (* def foo(x: Sanitize[TaintSink[...]]): ... *)
      BackwardState.apply_sanitizers
        ~taint_configuration
        ~sanitize_sink:true
        ~ignore_if_sanitize_all:true
        ~roots:(RootSelector.Root parameter)
        ~sanitizer
        taint_in_taint_out
    in
    generations, taint_in_taint_out, sink_taint
  in

  let sanitize_root (root, sanitizer) (generations, taint_in_taint_out, sink_taint) =
    match root with
    | AccessPath.Root.LocalResult ->
        sanitize_return sanitizer (generations, taint_in_taint_out, sink_taint)
    | PositionalParameter _
    | NamedParameter _
    | StarParameter _
    | StarStarParameter _ ->
        sanitize_parameter (root, sanitizer) (generations, taint_in_taint_out, sink_taint)
    | Variable _
    | CapturedVariable _ ->
        failwith "unexpected"
  in
  let generations, taint_in_taint_out, sink_taint =
    Sanitize.RootMap.fold
      Sanitize.RootMap.KeyValue
      ~f:sanitize_root
      ~init:(generations, taint_in_taint_out, sink_taint)
      roots
  in
  {
    forward = { generations };
    backward = { sink_taint; taint_in_taint_out };
    parameter_sources;
    sanitizers;
    modes;
  }


let should_externalize { forward; backward; parameter_sources; sanitizers; _ } =
  (not (Forward.is_empty forward))
  || (not (Backward.is_empty backward))
  || (not (ParameterSources.is_empty parameter_sources))
  || not (Sanitizers.is_empty sanitizers)


(* For every frame, convert the may breadcrumbs into must breadcrumbs. *)
let may_breadcrumbs_to_must
    {
      forward = { generations };
      backward = { taint_in_taint_out; sink_taint };
      parameter_sources = { parameter_sources };
      sanitizers;
      modes;
    }
  =
  let generations = ForwardState.may_breadcrumbs_to_must generations in
  let parameter_sources = ForwardState.may_breadcrumbs_to_must parameter_sources in
  let taint_in_taint_out = BackwardState.may_breadcrumbs_to_must taint_in_taint_out in
  let sink_taint = BackwardState.may_breadcrumbs_to_must sink_taint in
  {
    forward = { generations };
    backward = { taint_in_taint_out; sink_taint };
    parameter_sources = { parameter_sources };
    sanitizers;
    modes;
  }


(* Within every local taint, join every frame with the frame in the same local taint of the `Attach`
   kind. *)
let join_every_frame_with_attach
    {
      forward = { generations };
      backward = { taint_in_taint_out; sink_taint };
      parameter_sources = { parameter_sources };
      sanitizers;
      modes;
    }
  =
  let generations = ForwardState.join_every_frame_with generations ~frame_kind:Sources.Attach in
  let parameter_sources =
    ForwardState.join_every_frame_with parameter_sources ~frame_kind:Sources.Attach
  in
  let taint_in_taint_out =
    BackwardState.join_every_frame_with taint_in_taint_out ~frame_kind:Sinks.Attach
  in
  let sink_taint = BackwardState.join_every_frame_with sink_taint ~frame_kind:Sinks.Attach in
  {
    forward = { generations };
    backward = { taint_in_taint_out; sink_taint };
    parameter_sources = { parameter_sources };
    sanitizers;
    modes;
  }


(* A special case of join, only used for user-provided models. *)
let join_user_models ({ modes = left_modes; _ } as left) ({ modes = right_modes; _ } as right) =
  let join_user_modes model =
    { model with modes = ModeSet.join_user_modes left_modes right_modes }
  in
  join left right |> join_user_modes |> join_every_frame_with_attach |> may_breadcrumbs_to_must


let to_json
    ~expand_overrides
    ~is_valid_callee
    ~resolve_module_path
    ~resolve_callable_location
    ~export_leaf_names
    callable
    {
      forward = { generations };
      backward = { sink_taint; taint_in_taint_out };
      parameter_sources = { parameter_sources };
      sanitizers =
        { global = global_sanitizer; parameters = parameters_sanitizer; roots = root_sanitizers };
      modes;
    }
  =
  let callable_name = Target.external_name callable in
  let model_json = ["callable", `String callable_name] in
  let model_json =
    match resolve_callable_location with
    | Some resolve_callable_location when Target.is_function_or_method callable ->
        let location_json =
          resolve_callable_location callable
          >>| (fun { Ast.Location.WithModule.module_reference; start = { line; _ }; _ } ->
                Domains.module_path_to_json ~resolve_module_path module_reference
                @ ["callable_line", `Int line])
          |> Option.value ~default:[]
        in
        model_json @ location_json
    | _ -> model_json
  in
  let model_json =
    if not (ForwardState.is_empty generations) then
      model_json
      @ [
          ( (* Use "sources" instead of "generations" for backward compatibility. *)
            "sources",
            ForwardState.to_json
              ~expand_overrides
              ~is_valid_callee
              ~trace_kind:(Some TraceKind.Source)
              ~resolve_module_path
              ~export_leaf_names
              generations );
        ]
    else
      model_json
  in
  let model_json =
    if not (BackwardState.is_empty sink_taint) then
      model_json
      @ [
          ( "sinks",
            BackwardState.to_json
              ~expand_overrides
              ~is_valid_callee
              ~trace_kind:(Some TraceKind.Sink)
              ~resolve_module_path
              ~export_leaf_names
              sink_taint );
        ]
    else
      model_json
  in
  let model_json =
    if not (BackwardState.is_empty taint_in_taint_out) then
      model_json
      @ [
          ( "tito",
            BackwardState.to_json
              ~expand_overrides
              ~is_valid_callee:(fun ~trace_kind:_ ~port:_ ~path:_ ~callee:_ -> false)
                (* should only contain CallInfo.Tito *)
              ~trace_kind:None
              ~resolve_module_path
              ~export_leaf_names
              taint_in_taint_out );
        ]
    else
      model_json
  in
  let model_json =
    if not (ForwardState.is_empty parameter_sources) then
      model_json
      @ [
          ( "parameter_sources",
            ForwardState.to_json
              ~expand_overrides
              ~is_valid_callee:(fun ~trace_kind:_ ~port:_ ~path:_ ~callee:_ -> false)
                (* should only contain CallInfo.Declaration *)
              ~trace_kind:None
              ~resolve_module_path
              ~export_leaf_names
              parameter_sources );
        ]
    else
      model_json
  in
  let model_json =
    if not (Sanitize.is_empty global_sanitizer) then
      model_json @ ["global_sanitizer", Sanitize.to_json global_sanitizer]
    else
      model_json
  in
  let model_json =
    if not (Sanitize.is_empty parameters_sanitizer) then
      model_json @ ["parameters_sanitizer", Sanitize.to_json parameters_sanitizer]
    else
      model_json
  in
  let model_json =
    if not (Sanitize.RootMap.is_bottom root_sanitizers) then
      model_json @ ["sanitizers", Sanitize.RootMap.to_json root_sanitizers]
    else
      model_json
  in
  let model_json =
    if not (ModeSet.is_empty modes) then
      model_json @ ["modes", ModeSet.to_json modes]
    else
      model_json
  in
  `Assoc model_json


module WithTarget = struct
  type nonrec t = {
    model: t;
    target: Target.t;
  }
end

module WithCallTarget = struct
  type nonrec t = {
    model: t;
    call_target: CallGraph.CallTarget.t;
  }
end
