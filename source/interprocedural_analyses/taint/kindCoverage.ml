(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core

(* The kinds that are defined by a user, which are composed of sources, sinks, and transforms. They
   are used for computing the rule coverage. *)
module Sources = struct
  include Sources

  let rec from_source = function
    | Sources.Attach -> None
    | Sources.NamedSource _ as source -> Some source
    | Sources.ParametricSource { source_name; _ } -> Some (Sources.NamedSource source_name)
    | Sources.Transform _ as source -> from_source (Sources.discard_transforms source)
end

module Sinks = struct
  include Sinks

  let rec from_sink = function
    | Sinks.Attach -> None
    | Sinks.PartialSink partial_sink ->
        (* Rules only match sources against `TriggeredPartialSink` *)
        Some (Sinks.TriggeredPartialSink partial_sink)
    | Sinks.TriggeredPartialSink _ as sink -> Some sink
    | Sinks.LocalReturn -> None
    | Sinks.NamedSink _ as sink -> Some sink
    | Sinks.ParametricSink { sink_name; _ } -> Some (Sinks.NamedSink sink_name)
    | Sinks.ParameterUpdate _ -> None
    | Sinks.AddFeatureToArgument -> None
    | Sinks.Transform _ as sink -> from_sink (Sinks.discard_transforms sink)
    | Sinks.ExtraTraceSink -> None
end

module Transforms = struct
  module Set = Data_structures.SerializableSet.Make (TaintTransform)

  let from_transform = function
    | TaintTransform.Named _ as transform -> Some transform
    | TaintTransform.Sanitize _ ->
        (* Sanitizers are not user-defined taint transforms, although they are internally treated as
           taint transforms. *)
        None


  let from_transforms transforms = transforms |> List.filter_map ~f:from_transform |> Set.of_list
end

type t = {
  sources: Sources.Set.t;
  sinks: Sinks.Set.t;
  transforms: Transforms.Set.t;
}
[@@deriving eq, show]

let from_model
    {
      Model.forward = { source_taint };
      Model.backward = { taint_in_taint_out; sink_taint };
      Model.sanitizers = _;
      Model.modes = _;
    }
  =
  let collect_sinks =
    Domains.BackwardState.fold
      Domains.BackwardTaint.kind
      ~f:(fun sink so_far -> Sinks.Set.add sink so_far)
      ~init:Sinks.Set.empty
  in
  let sources =
    Domains.ForwardState.fold
      Domains.ForwardTaint.kind
      ~f:(fun source so_far -> Sources.Set.add source so_far)
      ~init:Sources.Set.empty
      source_taint
  in
  let sinks = Sinks.Set.union (collect_sinks taint_in_taint_out) (collect_sinks sink_taint) in
  let source_transforms =
    Sources.Set.fold
      (fun source so_far ->
        source
        |> Sources.get_named_transforms
        |> Transforms.from_transforms
        |> Transforms.Set.union so_far)
      sources
      Transforms.Set.empty
  in
  let sink_transforms =
    Sinks.Set.fold
      (fun sink so_far ->
        sink
        |> Sinks.get_named_transforms
        |> Transforms.from_transforms
        |> Transforms.Set.union so_far)
      sinks
      Transforms.Set.empty
  in
  {
    sources = sources |> Sources.Set.filter_map Sources.from_source;
    sinks = sinks |> Sinks.Set.filter_map Sinks.from_sink;
    transforms = Transforms.Set.union source_transforms sink_transforms;
  }


let from_rule { Rule.sources; sinks; transforms; _ } =
  {
    sources = sources |> Sources.Set.of_list |> Sources.Set.filter_map Sources.from_source;
    sinks = sinks |> Sinks.Set.of_list |> Sinks.Set.filter_map Sinks.from_sink;
    transforms =
      (* Not consider transforms from sources or sinks, since those should not have transforms. *)
      Transforms.Set.of_list transforms;
  }
