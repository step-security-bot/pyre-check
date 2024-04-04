(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* BackwardAnalysis: implements a backward taint analysis on a function body.
 * This is used to infer the sink and taint-in-taint-out part of a model, by
 * propagating sinks up through the statements of the body.
 *
 * For instance, on the given function, we would infer the following taint
 * states, starting from the return statement:
 * ```
 * def foo(a, b):
 *   # {x -> SQL, a -> SQL, y -> LocalReturn, b -> LocalReturn }
 *   x = str(a)
 *   # {x -> SQL, y -> LocalReturn, b -> LocalReturn}
 *   sql(x)
 *   # {y -> LocalReturn, b -> LocalReturn}
 *   y = int(b)
 *   # {y -> LocalReturn}
 *   return y
 * ```
 *
 * We would infer that `a` leads to the sink `SQL`, and that calling `foo` with
 * a tainted `b` leads to the return value being tainted (which we call
 * taint-in-taint-out, tito for short).
 *)

open Core
open Ast
open Expression
open Pyre
open Domains
module CallGraph = Interprocedural.CallGraph
module PyrePysaApi = Analysis.PyrePysaApi

module type FUNCTION_CONTEXT = sig
  val qualifier : Reference.t

  val definition : Statement.Define.t Node.t

  val callable : Interprocedural.Target.t

  val debug : bool

  val profiler : TaintProfiler.t

  val pyre_api : PyrePysaApi.ReadOnly.t

  val taint_configuration : TaintConfiguration.Heap.t

  val class_interval_graph : Interprocedural.ClassIntervalSetGraph.SharedMemory.t

  val global_constants : Interprocedural.GlobalConstants.SharedMemory.ReadOnly.t

  val call_graph_of_define : CallGraph.DefineCallGraph.t

  val get_callee_model : Interprocedural.Target.t -> Model.t option

  val existing_model : Model.t

  val triggered_sinks : Issue.TriggeredSinkLocationMap.t

  val caller_class_interval : Interprocedural.ClassIntervalSet.t
end

module State (FunctionContext : FUNCTION_CONTEXT) = struct
  type t = { taint: BackwardState.t }

  let pyre_api = FunctionContext.pyre_api

  let bottom = { taint = BackwardState.bottom }

  let pp formatter { taint } = BackwardState.pp formatter taint

  let show = Format.asprintf "%a" pp

  let less_or_equal ~left:{ taint = left; _ } ~right:{ taint = right; _ } =
    BackwardState.less_or_equal ~left ~right


  let join { taint = left } { taint = right; _ } =
    let taint = BackwardState.join left right in
    { taint }


  let widen ~previous:{ taint = prev; _ } ~next:{ taint = next; _ } ~iteration =
    let taint = BackwardState.widen ~iteration ~prev ~next in
    { taint }


  let profiler = FunctionContext.profiler

  let class_interval_graph = FunctionContext.class_interval_graph

  let log format =
    if FunctionContext.debug then
      Log.dump format
    else
      Log.log ~section:`Taint format


  let get_call_callees ~location ~call =
    let callees =
      match
        CallGraph.DefineCallGraph.resolve_call FunctionContext.call_graph_of_define ~location ~call
      with
      | Some callees -> callees
      | None ->
          (* That can happen if that statement is not reachable by the forward analysis. *)
          Log.warning
            "Could not find callees for `%a` at `%a:%a` in the call graph. This is most likely \
             dead code."
            Expression.pp
            (Node.create_with_default_location (Expression.Call call) |> Ast.Expression.delocalize)
            Reference.pp
            FunctionContext.qualifier
            Location.pp
            location;
          CallGraph.CallCallees.unresolved ()
    in
    log
      "Resolved callees for call `%a` at %a:@,%a"
      Expression.pp
      (Node.create_with_default_location (Expression.Call call))
      Location.pp
      location
      CallGraph.CallCallees.pp
      callees;
    callees


  let get_attribute_access_callees ~location ~attribute =
    let callees =
      CallGraph.DefineCallGraph.resolve_attribute_access
        FunctionContext.call_graph_of_define
        ~location
        ~attribute
    in
    let () =
      match callees with
      | Some callees ->
          log
            "Resolved attribute access callees for `%s` at %a:@,%a"
            attribute
            Location.pp
            location
            CallGraph.AttributeAccessCallees.pp
            callees
      | _ -> ()
    in
    callees


  let get_string_format_callees ~location =
    CallGraph.DefineCallGraph.resolve_string_format FunctionContext.call_graph_of_define ~location


  let is_constructor () =
    let { Node.value = { Statement.Define.signature = { name; _ }; _ }; _ } =
      FunctionContext.definition
    in
    match Reference.last name with
    | "__init__" -> true
    | _ -> false


  let is_setitem () =
    let { Node.value = { Statement.Define.signature = { name; _ }; _ }; _ } =
      FunctionContext.definition
    in
    String.equal (Reference.last name) "__setitem__"


  let first_parameter () =
    let { Node.value = { Statement.Define.signature = { parameters; _ }; _ }; _ } =
      FunctionContext.definition
    in
    match parameters with
    | { Node.value = { Parameter.name; _ }; _ } :: _ -> Some (AccessPath.Root.Variable name)
    | _ -> None


  (* This is where we can observe access paths reaching into LocalReturn and record the extraneous
     paths for more precise tito. *)
  let initial_taint =
    let {
      TaintConfiguration.Heap.analysis_model_constraints = { maximum_tito_collapse_depth; _ };
      _;
    }
      =
      FunctionContext.taint_configuration
    in
    let local_return_leaf =
      BackwardState.Tree.create_leaf
        (Domains.local_return_taint ~output_path:[] ~collapse_depth:maximum_tito_collapse_depth)
    in
    (* We handle constructors, __setitem__ methods, and property setters specially and track
       effects. *)
    if
      is_constructor ()
      || is_setitem ()
      || Statement.Define.is_property_setter (Node.value FunctionContext.definition)
    then
      match first_parameter () with
      | Some root -> BackwardState.assign ~root ~path:[] local_return_leaf BackwardState.bottom
      | _ -> BackwardState.bottom
    else
      BackwardState.assign
        ~root:AccessPath.Root.LocalResult
        ~path:[]
        local_return_leaf
        BackwardState.bottom


  let transform_non_leaves new_path taint =
    let infer_output_path sink paths =
      match Sinks.discard_transforms sink with
      | Sinks.LocalReturn ->
          let open Features.ReturnAccessPathTree in
          fold
            Path
            ~f:(fun (current_path, collapse_depth) paths ->
              let to_take = min collapse_depth (List.length new_path) in
              let new_path = List.take new_path to_take in
              let new_collapse_depth = collapse_depth - to_take in
              create_leaf new_collapse_depth
              |> prepend new_path
              |> prepend current_path
              |> join paths)
            ~init:bottom
            paths
          |> limit_depth
      | _ -> paths
    in
    BackwardTaint.transform_call_info
      CallInfo.Tito
      Features.ReturnAccessPathTree.Self
      (Context (BackwardTaint.kind, Map))
      ~f:infer_output_path
      taint


  let read_tree = BackwardState.Tree.read ~transform_non_leaves

  let get_taint access_path { taint; _ } =
    match access_path with
    | None -> BackwardState.Tree.empty
    | Some { AccessPath.root; path } -> BackwardState.read ~transform_non_leaves ~root ~path taint


  let store_taint ?(weak = false) ~root ~path taint { taint = state_taint } =
    { taint = BackwardState.assign ~weak ~root ~path taint state_taint }


  let analyze_definition ~define:_ state = state

  type call_target_result = {
    arguments_taint: BackwardState.Tree.t list;
    implicit_argument_taint: CallModel.ImplicitArgument.Backward.t;
    captures_taint: BackwardState.Tree.t list;
    captures: CallModel.ArgumentMatches.t list;
    state: t;
  }

  let join_call_target_results
      {
        arguments_taint = left_arguments_taint;
        implicit_argument_taint = left_implicit_argument_taint;
        captures_taint = left_captures_taint;
        captures = left_captures;
        state = left_state;
      }
      {
        arguments_taint = right_arguments_taint;
        implicit_argument_taint = right_implicit_argument_taint;
        captures_taint = right_captures_taint;
        captures = right_captures;
        state = right_state;
      }
    =
    let arguments_taint =
      List.map2_exn left_arguments_taint right_arguments_taint ~f:BackwardState.Tree.join
    in
    let captures_taint =
      if List.length left_captures_taint > List.length right_captures_taint then
        left_captures_taint
      else
        right_captures_taint
    in
    let implicit_argument_taint =
      CallModel.ImplicitArgument.Backward.join
        left_implicit_argument_taint
        right_implicit_argument_taint
    in
    let state = join left_state right_state in
    let captures =
      if List.length left_captures > List.length right_captures then
        left_captures
      else
        right_captures
    in
    { arguments_taint; implicit_argument_taint; captures_taint; captures; state }


  let add_extra_traces_for_transforms
      ~argument_access_path
      ~named_transforms
      ~sink_trees
      ~tito_roots
      taint
    =
    let extra_traces =
      CallModel.ExtraTraceForTransforms.from_sink_trees
        ~argument_access_path
        ~named_transforms
        ~tito_roots
        ~sink_trees
    in
    BackwardState.Tree.transform
      BackwardTaint.Self
      Map
      ~f:(BackwardTaint.add_extra_traces ~extra_traces)
      taint


  let apply_call_target
      ?(apply_tito = true)
      ~pyre_in_context
      ~call_location
      ~self
      ~callee
      ~arguments
      ~state:initial_state
      ~call_taint
      ~is_implicit_new
      ({
         CallGraph.CallTarget.target;
         index = _;
         return_type;
         receiver_class;
         is_class_method;
         is_static_method;
         _;
       } as call_target)
    =
    let arguments =
      match CallGraph.ImplicitArgument.implicit_argument ~is_implicit_new call_target with
      | CalleeBase -> { Call.Argument.name = None; value = Option.value_exn self } :: arguments
      | Callee -> { Call.Argument.name = None; value = callee } :: arguments
      | None -> arguments
    in
    let triggered_taint =
      Issue.TriggeredSinkLocationMap.get FunctionContext.triggered_sinks ~location:call_location
    in
    let taint_model =
      TaintProfiler.track_model_fetch
        ~profiler
        ~analysis:TaintProfiler.Backward
        ~call_target:target
        ~f:(fun () ->
          CallModel.at_callsite
            ~pyre_in_context
            ~get_callee_model:FunctionContext.get_callee_model
            ~call_target:target
            ~arguments)
    in
    log
      "Backward analysis of call to `%a` with arguments (%a)@,Call site model:@,%a"
      Interprocedural.Target.pp_pretty
      target
      Ast.Expression.pp_expression_argument_list
      arguments
      Model.pp
      taint_model;
    let taint_model =
      {
        taint_model with
        backward =
          {
            taint_model.backward with
            sink_taint = BackwardState.join taint_model.backward.sink_taint triggered_taint;
          };
      }
    in
    let call_taint =
      BackwardState.Tree.add_local_breadcrumbs
        (Features.type_breadcrumbs (Option.value_exn return_type))
        call_taint
    in
    let get_argument_taint ~pyre_in_context ~argument:{ Call.Argument.value = argument; _ } =
      let global_sink =
        GlobalModel.from_expression
          ~pyre_in_context
          ~call_graph:FunctionContext.call_graph_of_define
          ~get_callee_model:FunctionContext.get_callee_model
          ~qualifier:FunctionContext.qualifier
          ~expression:argument
          ~interval:FunctionContext.caller_class_interval
        |> GlobalModel.get_sinks
        |> SinkTreeWithHandle.join
      in
      let access_path = AccessPath.of_expression argument in
      get_taint access_path initial_state |> BackwardState.Tree.join global_sink
    in
    let convert_tito_path_to_taint
        ~sink_trees
        ~tito_roots
        ~kind
        (tito_path, tito_taint)
        argument_taint
      =
      let breadcrumbs = BackwardTaint.joined_breadcrumbs tito_taint in
      let tito_depth =
        BackwardTaint.fold TraceLength.Self tito_taint ~f:TraceLength.join ~init:TraceLength.bottom
      in
      let taint_to_propagate =
        match Sinks.discard_transforms kind with
        | Sinks.LocalReturn -> call_taint
        (* Attach nodes shouldn't affect analysis. *)
        | Sinks.Attach -> BackwardState.Tree.empty
        | Sinks.ParameterUpdate n -> (
            match List.nth arguments n with
            | None -> BackwardState.Tree.empty
            | Some argument -> get_argument_taint ~pyre_in_context ~argument)
        | _ -> Format.asprintf "unexpected kind for tito: %a" Sinks.pp kind |> failwith
      in
      let taint_to_propagate =
        match kind with
        | Sinks.Transform { local = transforms; global; _ } when TaintTransforms.is_empty global ->
            (* Apply tito transforms and source- and sink-specific sanitizers. *)
            let taint_to_propagate =
              BackwardState.Tree.apply_transforms
                ~taint_configuration:FunctionContext.taint_configuration
                transforms
                TaintTransformOperation.InsertLocation.Front
                TaintTransforms.Order.Backward
                taint_to_propagate
            in
            let named_transforms = TaintTransforms.discard_sanitize_transforms transforms in
            if List.is_empty named_transforms then
              taint_to_propagate
            else
              let breadcrumb = CallModel.transform_tito_depth_breadcrumb tito_taint in
              let taint_to_propagate =
                BackwardState.Tree.add_local_breadcrumb
                  ~add_on_tito:false
                  breadcrumb
                  taint_to_propagate
              in
              add_extra_traces_for_transforms
                ~argument_access_path:tito_path
                ~named_transforms
                ~sink_trees
                ~tito_roots
                taint_to_propagate
        | Sinks.Transform _ -> failwith "unexpected non-empty `global` transforms in tito"
        | _ -> taint_to_propagate
      in
      let transform_existing_tito ~callee_collapse_depth kind frame =
        match Sinks.discard_transforms kind with
        | Sinks.LocalReturn ->
            frame
            |> Frame.transform TraceLength.Self Map ~f:(fun depth -> max depth (1 + tito_depth))
            |> Frame.transform Features.CollapseDepth.Self Map ~f:(fun collapse_depth ->
                   min collapse_depth callee_collapse_depth)
        | _ -> frame
      in
      CallModel.return_paths_and_collapse_depths ~kind ~tito_taint
      |> List.fold
           ~f:(fun taint (return_path, collapse_depth) ->
             let taint_to_propagate = read_tree return_path taint_to_propagate in
             (if Features.CollapseDepth.should_collapse collapse_depth then
                BackwardState.Tree.collapse_to
                  ~breadcrumbs:(Features.tito_broadening_set ())
                  ~depth:collapse_depth
                  taint_to_propagate
             else
               taint_to_propagate)
             |> BackwardState.Tree.add_local_breadcrumbs breadcrumbs
             |> BackwardState.Tree.transform_call_info
                  CallInfo.Tito
                  Frame.Self
                  (Context (BackwardTaint.kind, Map))
                  ~f:(transform_existing_tito ~callee_collapse_depth:collapse_depth)
             |> BackwardState.Tree.prepend tito_path
             |> BackwardState.Tree.join taint)
           ~init:argument_taint
    in
    let convert_tito_tree_to_taint
        ~argument
        ~sink_trees
        ~kind
        ~pair:{ CallModel.TaintInTaintOutMap.TreeRootsPair.tree = tito_tree; roots = tito_roots }
        taint_tree
      =
      BackwardState.Tree.fold
        BackwardState.Tree.Path
        tito_tree
        ~init:BackwardState.Tree.bottom
        ~f:(convert_tito_path_to_taint ~sink_trees ~tito_roots ~kind)
      |> BackwardState.Tree.transform Features.TitoPositionSet.Element Add ~f:argument.Node.location
      |> BackwardState.Tree.add_local_breadcrumb (Features.tito ())
      |> BackwardState.Tree.join taint_tree
    in
    let call_info_intervals =
      {
        Domains.ClassIntervals.is_self_call = Ast.Expression.is_self_call ~callee;
        is_cls_call = Ast.Expression.is_cls_call ~callee;
        caller_interval = FunctionContext.caller_class_interval;
        receiver_interval =
          receiver_class
          >>| Interprocedural.ClassIntervalSetGraph.SharedMemory.of_class class_interval_graph
          |> Option.value ~default:Interprocedural.ClassIntervalSet.top;
      }
    in
    let analyze_argument
        (arguments_taint, state)
        { CallModel.ArgumentMatches.argument; sink_matches; tito_matches; sanitize_matches }
      =
      let location =
        Location.with_module ~module_reference:FunctionContext.qualifier argument.Node.location
      in
      let sink_trees =
        CallModel.sink_trees_of_argument
          ~pyre_in_context
          ~transform_non_leaves
          ~model:taint_model
          ~location
          ~call_target
          ~arguments
          ~sink_matches
          ~is_class_method
          ~is_static_method
          ~call_info_intervals
      in
      let taint_in_taint_out =
        if apply_tito then
          CallModel.taint_in_taint_out_mapping
            ~transform_non_leaves
            ~taint_configuration:FunctionContext.taint_configuration
            ~ignore_local_return:(BackwardState.Tree.is_bottom call_taint)
            ~model:taint_model
            ~tito_matches
            ~sanitize_matches
          |> CallModel.TaintInTaintOutMap.fold
               ~init:BackwardState.Tree.empty
               ~f:(convert_tito_tree_to_taint ~argument ~sink_trees)
        else
          BackwardState.Tree.empty
      in
      let sink_taint = SinkTreeWithHandle.join sink_trees in
      let taint = BackwardState.Tree.join sink_taint taint_in_taint_out in
      let state =
        match AccessPath.of_expression argument with
        | Some { AccessPath.root; path } ->
            let breadcrumbs_to_add =
              BackwardState.Tree.filter_by_kind ~kind:Sinks.AddFeatureToArgument sink_taint
              |> BackwardTaint.joined_breadcrumbs
            in
            if Features.BreadcrumbSet.is_bottom breadcrumbs_to_add then
              state
            else
              let taint =
                BackwardState.read state.taint ~root ~path
                |> BackwardState.Tree.add_local_breadcrumbs breadcrumbs_to_add
              in
              { taint = BackwardState.assign ~root ~path taint state.taint }
        | None -> state
      in
      taint :: arguments_taint, state
    in
    let analyze_argument_matches argument_matches initial_state =
      argument_matches |> List.rev |> List.fold ~f:analyze_argument ~init:([], initial_state)
    in
    let _, captures =
      CallModel.match_captures
        ~model:taint_model
        ~captures_taint:ForwardState.empty
        ~location:call_location
    in
    let captures_taint, _ = analyze_argument_matches captures initial_state in

    let arguments_taint, state =
      analyze_argument_matches
        (CallModel.match_actuals_to_formals ~model:taint_model ~arguments)
        initial_state
    in
    (* Extract the taint for implicit arguments. *)
    let implicit_argument_taint, arguments_taint =
      match CallGraph.ImplicitArgument.implicit_argument ~is_implicit_new call_target with
      | CalleeBase -> (
          match arguments_taint with
          | self_taint :: arguments_taint ->
              CallModel.ImplicitArgument.Backward.CalleeBase self_taint, arguments_taint
          | _ -> failwith "missing taint for self argument")
      | Callee -> (
          match arguments_taint with
          | callee_taint :: arguments_taint ->
              CallModel.ImplicitArgument.Backward.Callee callee_taint, arguments_taint
          | _ -> failwith "missing taint for callee argument")
      | None -> CallModel.ImplicitArgument.Backward.None, arguments_taint
    in
    { arguments_taint; implicit_argument_taint; captures_taint; captures; state }


  let apply_obscure_call ~apply_tito ~callee ~arguments ~state:initial_state ~call_taint =
    log
      "Backward analysis of obscure call to `%a` with arguments (%a)"
      Expression.pp
      callee
      Ast.Expression.pp_expression_argument_list
      arguments;
    let obscure_taint =
      if apply_tito then
        BackwardState.Tree.collapse ~breadcrumbs:(Features.tito_broadening_set ()) call_taint
        |> BackwardTaint.add_local_breadcrumb (Features.obscure_unknown_callee ())
        |> BackwardTaint.transform_call_info
             CallInfo.Tito
             Features.CollapseDepth.Self
             Map
             ~f:Features.CollapseDepth.approximate
        |> BackwardState.Tree.create_leaf
      else
        BackwardState.Tree.empty
    in
    let compute_argument_taint { Call.Argument.value = argument; _ } =
      let taint = obscure_taint in
      let taint =
        match argument.Node.value with
        | Starred (Starred.Once _)
        | Starred (Starred.Twice _) ->
            BackwardState.Tree.prepend [Abstract.TreeDomain.Label.AnyIndex] taint
        | _ -> taint
      in
      let taint =
        BackwardState.Tree.transform
          Features.TitoPositionSet.Element
          Add
          ~f:argument.Node.location
          taint
      in
      taint
    in
    let arguments_taint = List.map ~f:compute_argument_taint arguments in
    {
      arguments_taint;
      implicit_argument_taint = CallModel.ImplicitArgument.Backward.Callee obscure_taint;
      captures_taint = [];
      captures = [];
      state = initial_state;
    }


  let apply_constructor_targets
      ~pyre_in_context
      ~call_location
      ~callee
      ~arguments
      ~new_targets
      ~init_targets
      ~state:initial_state
      ~call_taint
    =
    let is_object_new = CallGraph.CallCallees.is_object_new new_targets in
    let is_object_init = CallGraph.CallCallees.is_object_init init_targets in

    (* If both `is_object_new` and `is_object_init` are true, this is probably a stub
     * class (e.g, `class X: ...`), in which case, we treat it as an obscure call. *)

    (* Call `__init__`. Add the `self` implicit argument. *)
    let {
      arguments_taint = init_arguments_taint;
      implicit_argument_taint;
      captures_taint = _;
      captures = _;
      state;
    }
      =
      if is_object_init && not is_object_new then
        {
          arguments_taint = List.map arguments ~f:(fun _ -> BackwardState.Tree.bottom);
          implicit_argument_taint = CallModel.ImplicitArgument.Backward.CalleeBase call_taint;
          captures_taint = [];
          captures = [];
          state = initial_state;
        }
      else
        let call_expression =
          Expression.Call { Call.callee; arguments } |> Node.create ~location:call_location
        in
        List.map init_targets ~f:(fun target ->
            apply_call_target
              ~pyre_in_context
              ~call_location
              ~self:(Some call_expression)
              ~callee
              ~arguments
              ~state:initial_state
              ~call_taint
              ~is_implicit_new:false
              target)
        |> List.fold
             ~f:join_call_target_results
             ~init:
               {
                 arguments_taint = List.map arguments ~f:(fun _ -> BackwardState.Tree.bottom);
                 implicit_argument_taint = CallModel.ImplicitArgument.Backward.None;
                 captures_taint = [];
                 captures = [];
                 state = bottom;
               }
    in
    let base_taint =
      match implicit_argument_taint with
      | CalleeBase taint -> taint
      | None -> BackwardState.Tree.bottom
      | Callee _ ->
          (* T122799408: This is a rare case, which is handled with a simple workaround. See
             function `dunder_call_partial_constructor` in
             `source/interprocedural_analyses/taint/test/integration/partial.py`. *)
          BackwardState.Tree.bottom
    in

    (* Call `__new__`. *)
    let call_target_result =
      if is_object_new then
        {
          arguments_taint = init_arguments_taint;
          implicit_argument_taint = CallModel.ImplicitArgument.Backward.None;
          captures_taint = [];
          captures = [];
          state;
        }
      else (* Add the `cls` implicit argument. *)
        let {
          arguments_taint = new_arguments_taint;
          implicit_argument_taint;
          captures_taint = _;
          captures = _;
          state;
        }
          =
          List.map new_targets ~f:(fun target ->
              apply_call_target
                ~pyre_in_context
                ~call_location
                ~self:(Some callee)
                ~callee
                ~arguments
                ~state
                ~call_taint:base_taint
                ~is_implicit_new:true
                target)
          |> List.fold
               ~f:join_call_target_results
               ~init:
                 {
                   arguments_taint = List.map arguments ~f:(fun _ -> BackwardState.Tree.bottom);
                   implicit_argument_taint = CallModel.ImplicitArgument.Backward.None;
                   captures_taint = [];
                   captures = [];
                   state = bottom;
                 }
        in
        let callee_taint =
          match implicit_argument_taint with
          | CallModel.ImplicitArgument.Backward.CalleeBase taint -> taint
          | Callee _
          | None ->
              failwith "Expect implicit argument `CalleeBase` from calling `__new__`"
        in
        {
          arguments_taint =
            List.map2_exn init_arguments_taint new_arguments_taint ~f:BackwardState.Tree.join;
          implicit_argument_taint = CallModel.ImplicitArgument.Backward.Callee callee_taint;
          captures_taint = [];
          captures = [];
          state;
        }
    in

    call_target_result


  let apply_callees_and_return_arguments_taint
      ?(apply_tito = true)
      ~pyre_in_context
      ~callee
      ~call_location
      ~arguments
      ~state:initial_state
      ~call_taint
      {
        CallGraph.CallCallees.call_targets;
        new_targets;
        init_targets;
        higher_order_parameters = _;
        unresolved;
      }
    =
    let call_taint =
      (* Add index breadcrumb if appropriate. *)
      match callee.Node.value, arguments with
      | Expression.Name (Name.Attribute { attribute = "get"; _ }), index :: _ ->
          let label = AccessPath.get_index index.Call.Argument.value in
          BackwardState.Tree.add_local_first_index label call_taint
      | _ -> call_taint
    in

    let call_targets, unresolved, call_taint =
      (* Specially handle super.__init__ calls and explicit calls to superclass' `__init__` in
         constructors for tito. *)
      match Node.value callee with
      | Name (Name.Attribute { base; attribute; _ })
        when is_constructor ()
             && String.equal attribute "__init__"
             && Interprocedural.CallResolution.is_super
                  ~pyre_in_context
                  ~define:FunctionContext.definition
                  base ->
          (* If the super call is `object.__init__`, this is likely due to a lack of type
             information for that constructor - we treat that case as obscure to not lose argument
             taint for these calls. *)
          let call_targets, unresolved =
            match call_targets with
            | [
             {
               CallGraph.CallTarget.target =
                 Interprocedural.Target.Method
                   { class_name = "object"; method_name = "__init__"; kind = Normal };
               _;
             };
            ] ->
                [], true
            | _ -> call_targets, unresolved
          in
          let call_taint =
            BackwardState.Tree.create_leaf
              (Domains.local_return_taint
                 ~output_path:[]
                 ~collapse_depth:
                   FunctionContext.taint_configuration.analysis_model_constraints
                     .maximum_tito_collapse_depth)
            |> BackwardState.Tree.join call_taint
          in
          call_targets, unresolved, call_taint
      | _ -> call_targets, unresolved, call_taint
    in

    (* Extract the implicit self, if any *)
    let self =
      match callee.Node.value with
      | Expression.Name (Name.Attribute { base; _ }) -> Some base
      | _ ->
          (* Default to a benign self if we don't understand/retain information of what self is. *)
          Expression.Constant Constant.NoneLiteral
          |> Node.create ~location:callee.Node.location
          |> Option.some
    in

    (* Apply regular call targets. *)
    let call_target_result =
      List.map
        call_targets
        ~f:
          (apply_call_target
             ~apply_tito
             ~pyre_in_context
             ~call_location
             ~self
             ~callee
             ~arguments
             ~state:initial_state
             ~call_taint
             ~is_implicit_new:false)
      |> List.fold
           ~f:join_call_target_results
           ~init:
             {
               arguments_taint = List.map arguments ~f:(fun _ -> BackwardState.Tree.bottom);
               implicit_argument_taint = CallModel.ImplicitArgument.Backward.None;
               captures_taint = [];
               captures = [];
               state = bottom;
             }
    in

    (* Apply an obscure call if the call was not fully resolved. *)
    let call_target_result =
      if unresolved then
        apply_obscure_call ~apply_tito ~callee ~arguments ~state:initial_state ~call_taint
        |> join_call_target_results call_target_result
      else
        call_target_result
    in

    (* Apply constructor calls, if any. *)
    let call_target_result =
      match new_targets, init_targets with
      | [], [] -> call_target_result
      | _ ->
          apply_constructor_targets
            ~pyre_in_context
            ~call_location
            ~callee
            ~arguments
            ~new_targets
            ~init_targets
            ~state:initial_state
            ~call_taint
          |> join_call_target_results call_target_result
    in

    call_target_result


  let rec analyze_arguments ~pyre_in_context ~arguments ~arguments_taint ~state =
    (* Explicitly analyze arguments from right to left (opposite of forward analysis). *)
    List.zip_exn arguments arguments_taint
    |> List.rev
    |> List.fold
         ~init:state
         ~f:(fun state ({ Call.Argument.value = argument; _ }, argument_taint) ->
           analyze_unstarred_expression ~pyre_in_context argument_taint argument state)


  and analyze_callee
      ~(pyre_in_context : PyrePysaApi.InContext.t)
      ~is_property_call
      ~callee
      ~implicit_argument_taint
      ~state
    =
    (* Special case: `x.foo()` where foo is a property returning a callable. *)
    let analyze ~base_taint ~callee_taint =
      match callee.Node.value with
      | Expression.Name (Name.Attribute { base; attribute; special }) ->
          (* If we are already analyzing a call of a property, then ignore properties
           * to avoid infinite recursion. *)
          let resolve_properties = not is_property_call in
          analyze_attribute_access
            ~pyre_in_context
            ~location:callee.Node.location
            ~resolve_properties
            ~base
            ~attribute
            ~special
            ~base_taint
            ~attribute_taint:callee_taint
            ~state
      | _ -> analyze_expression ~pyre_in_context ~taint:callee_taint ~state ~expression:callee
    in
    let callee_is_property =
      match is_property_call, callee.Node.value with
      | false, Expression.Name (Name.Attribute { attribute; _ }) ->
          get_attribute_access_callees ~location:callee.Node.location ~attribute |> Option.is_some
      | _ -> false
    in
    if callee_is_property then
      let base_taint, callee_taint =
        match implicit_argument_taint with
        | CallModel.ImplicitArgument.Backward.Callee taint -> BackwardState.Tree.bottom, taint
        | CalleeBase taint -> taint, BackwardState.Tree.bottom
        | None -> BackwardState.Tree.bottom, BackwardState.Tree.bottom
      in
      analyze ~base_taint ~callee_taint
    else
      match implicit_argument_taint with
      | CallModel.ImplicitArgument.Backward.Callee callee_taint ->
          analyze ~base_taint:BackwardState.Tree.bottom ~callee_taint
      | CalleeBase taint -> (
          match callee.Node.value with
          | Expression.Name (Name.Attribute { base; _ }) ->
              analyze_expression ~pyre_in_context ~taint ~state ~expression:base
          | _ -> state)
      | None -> state


  and analyze_attribute_access
      ~(pyre_in_context : PyrePysaApi.InContext.t)
      ~location
      ~resolve_properties
      ~base
      ~attribute
      ~special
      ~base_taint:initial_base_taint
      ~attribute_taint
      ~state
    =
    let expression =
      Expression.Name (Name.Attribute { base; attribute; special }) |> Node.create ~location
    in
    let attribute_access_callees =
      if resolve_properties then get_attribute_access_callees ~location ~attribute else None
    in

    let base_taint_property_call, state_property_call =
      match attribute_access_callees with
      | Some { property_targets = _ :: _ as property_targets; _ } ->
          let {
            arguments_taint = _;
            implicit_argument_taint;
            captures_taint = _;
            captures = _;
            state;
          }
            =
            apply_callees_and_return_arguments_taint
              ~pyre_in_context
              ~callee:expression
              ~call_location:location
              ~arguments:[]
              ~state
              ~call_taint:attribute_taint
              (CallGraph.CallCallees.create ~call_targets:property_targets ())
          in
          let base_taint =
            match implicit_argument_taint with
            | CallModel.ImplicitArgument.Backward.CalleeBase taint -> taint
            | _ -> failwith "Expect `CalleeBase` for attribute access"
          in
          base_taint, state
      | _ -> BackwardState.Tree.bottom, bottom
    in

    let base_taint_attribute, state_attribute =
      match attribute_access_callees with
      | Some { is_attribute = true; _ }
      | None ->
          let global_model =
            GlobalModel.from_expression
              ~pyre_in_context
              ~call_graph:FunctionContext.call_graph_of_define
              ~get_callee_model:FunctionContext.get_callee_model
              ~qualifier:FunctionContext.qualifier
              ~expression
              ~interval:FunctionContext.caller_class_interval
          in
          let add_tito_features taint =
            let attribute_breadcrumbs =
              global_model |> GlobalModel.get_tito |> BackwardState.Tree.joined_breadcrumbs
            in
            BackwardState.Tree.add_local_breadcrumbs attribute_breadcrumbs taint
          in

          let apply_attribute_sanitizers taint =
            let sanitizer = GlobalModel.get_sanitize global_model in
            let taint =
              let sanitizers =
                { SanitizeTransformSet.sources = sanitizer.sources; sinks = sanitizer.sinks }
              in
              BackwardState.Tree.apply_sanitize_transforms
                ~taint_configuration:FunctionContext.taint_configuration
                sanitizers
                TaintTransformOperation.InsertLocation.Front
                taint
            in
            taint
          in

          let base_taint =
            attribute_taint
            |> add_tito_features
            |> BackwardState.Tree.prepend [Abstract.TreeDomain.Label.Index attribute]
            |> apply_attribute_sanitizers
          in
          base_taint, state
      | _ -> BackwardState.Tree.bottom, bottom
    in

    let base_taint =
      initial_base_taint
      |> BackwardState.Tree.join base_taint_property_call
      |> BackwardState.Tree.join base_taint_attribute
    in
    let state = join state_property_call state_attribute in
    analyze_expression ~pyre_in_context ~taint:base_taint ~state ~expression:base


  and analyze_arguments_with_higher_order_parameters
      ~(pyre_in_context : PyrePysaApi.InContext.t)
      ~arguments
      ~arguments_taint
      ~state
      ~higher_order_parameters
    =
    (* If we have functions `fn1`, `fn2`, `fn3` getting passed into `hof`, we use the following strategy:
     * hof(q, fn1, x, fn2, y, fn3) gets translated into (analyzed backwards)
     * if rand():
     *   $all = {q, x, y}
     *   $result_fn1 = fn1( *all, **all)
     *   $result_fn2 = fn2( *all, **all)
     *   $result_fn3 = fn3( *all, **all)
     * else:
     *   $result_fn1 = fn1
     *   $result_fn2 = fn2
     *   $result_fn3 = fn3
     * hof(q, $result_fn1, x, $result_fn2, y, $result_fn3)
     *)
    let arguments_and_taints = List.zip_exn arguments arguments_taint in

    let higher_order_parameters =
      higher_order_parameters
      |> CallGraph.HigherOrderParameterMap.to_list
      |> List.filter_map
           ~f:(fun ({ CallGraph.HigherOrderParameter.index; _ } as higher_order_parameter) ->
             match List.nth arguments_and_taints index with
             | Some ({ Call.Argument.value = argument; _ }, taint) ->
                 Some (higher_order_parameter, argument, taint)
             | None -> None)
    in

    let non_function_arguments_taint =
      let function_argument_indices =
        List.fold
          ~init:Int.Set.empty
          ~f:(fun indices ({ CallGraph.HigherOrderParameter.index; _ }, _, _) ->
            Set.add indices index)
          higher_order_parameters
      in
      List.filteri arguments_and_taints ~f:(fun index _ ->
          not (Set.mem function_argument_indices index))
    in

    (* Simulate if branch. *)
    let all_taint, if_branch_state =
      let analyze_function_call
          (all_taint, state)
          ( { CallGraph.HigherOrderParameter.call_targets; index = _; unresolved },
            ({ Node.location = argument_location; _ } as argument),
            argument_taint )
        =
        (* Simulate $result = fn( *all, **all) *)
        let all_argument =
          Expression.Name (Name.Identifier "$all") |> Node.create ~location:argument_location
        in
        let arguments =
          [
            {
              Call.Argument.value =
                Expression.Starred (Starred.Once all_argument)
                |> Node.create ~location:argument_location;
              name = None;
            };
            {
              Call.Argument.value =
                Expression.Starred (Starred.Twice all_argument)
                |> Node.create ~location:argument_location;
              name = None;
            };
          ]
        in
        let { arguments_taint; implicit_argument_taint; captures_taint; captures; state } =
          apply_callees_and_return_arguments_taint
            ~pyre_in_context
            ~callee:argument
            ~call_location:argument_location
            ~arguments
            ~call_taint:argument_taint
            ~state
            (CallGraph.CallCallees.create ~call_targets ~unresolved ())
        in
        let state =
          analyze_callee
            ~pyre_in_context
            ~is_property_call:false
            ~callee:argument
            ~implicit_argument_taint
            ~state
        in
        let state =
          List.fold
            ~init:state
            ~f:(fun state (capture, capture_taint) ->
              analyze_expression
                ~pyre_in_context
                ~taint:capture_taint
                ~state
                ~expression:capture.value)
            (List.zip_exn (CallModel.captures_as_arguments captures) captures_taint)
        in
        let all_taint =
          arguments_taint
          |> List.fold ~f:BackwardState.Tree.join ~init:BackwardState.Tree.bottom
          |> read_tree [Abstract.TreeDomain.Label.AnyIndex]
          |> BackwardState.Tree.add_local_breadcrumb (Features.lambda ())
          |> BackwardState.Tree.join all_taint
        in
        all_taint, state
      in
      List.fold
        ~init:(BackwardState.Tree.bottom, state)
        ~f:analyze_function_call
        higher_order_parameters
    in

    (* Simulate else branch. *)
    let else_branch_state =
      let analyze_function_expression state (_, argument, argument_taint) =
        analyze_expression ~pyre_in_context ~taint:argument_taint ~state ~expression:argument
      in
      List.fold ~init:state ~f:analyze_function_expression higher_order_parameters
    in

    (* Join both branches. *)
    let state = join else_branch_state if_branch_state in

    (* Analyze arguments. *)
    List.fold
      non_function_arguments_taint
      ~init:state
      ~f:(fun state ({ Call.Argument.value = argument; _ }, argument_taint) ->
        let argument_taint = BackwardState.Tree.join argument_taint all_taint in
        analyze_unstarred_expression ~pyre_in_context argument_taint argument state)


  and apply_callees
      ?(apply_tito = true)
      ~(pyre_in_context : PyrePysaApi.InContext.t)
      ~is_property
      ~callee
      ~call_location
      ~arguments
      ~state:initial_state
      ~call_taint
      callees
    =
    let { arguments_taint; implicit_argument_taint; captures_taint; captures; state } =
      apply_callees_and_return_arguments_taint
        ~apply_tito
        ~pyre_in_context
        ~callee
        ~call_location
        ~arguments
        ~state:initial_state
        ~call_taint
        callees
    in
    let state =
      if CallGraph.HigherOrderParameterMap.is_empty callees.higher_order_parameters then
        analyze_arguments
          ~pyre_in_context
          ~arguments:(arguments @ CallModel.captures_as_arguments captures)
          ~arguments_taint:(arguments_taint @ captures_taint)
          ~state
      else
        analyze_arguments_with_higher_order_parameters
          ~pyre_in_context
          ~arguments:(arguments @ CallModel.captures_as_arguments captures)
          ~arguments_taint:(arguments_taint @ captures_taint)
          ~state
          ~higher_order_parameters:callees.higher_order_parameters
    in

    let state =
      analyze_callee
        ~pyre_in_context
        ~is_property_call:is_property
        ~callee
        ~implicit_argument_taint
        ~state
    in
    state


  and analyze_dictionary_entry
      ~(pyre_in_context : PyrePysaApi.InContext.t)
      taint
      state
      { Dictionary.Entry.key; value }
    =
    let key_taint = read_tree [AccessPath.dictionary_keys] taint in
    let state = analyze_expression ~pyre_in_context ~taint:key_taint ~state ~expression:key in
    let field_name = AccessPath.get_index key in
    let value_taint = read_tree [field_name] taint in
    analyze_expression ~pyre_in_context ~taint:value_taint ~state ~expression:value


  and analyze_reverse_list_element
      ~total
      ~(pyre_in_context : PyrePysaApi.InContext.t)
      taint
      reverse_position
      state
      expression
    =
    let position = total - reverse_position - 1 in
    let index_name = Abstract.TreeDomain.Label.Index (string_of_int position) in
    let value_taint = read_tree [index_name] taint in
    analyze_expression ~pyre_in_context ~taint:value_taint ~state ~expression


  and analyze_generators ~(pyre_in_context : PyrePysaApi.InContext.t) ~state generators =
    let handle_generator state ({ Comprehension.Generator.conditions; _ } as generator) =
      let state =
        List.fold conditions ~init:state ~f:(fun state condition ->
            analyze_expression
              ~pyre_in_context
              ~taint:BackwardState.Tree.empty
              ~state
              ~expression:condition)
      in
      let { Statement.Assign.target; value; _ } =
        Statement.Statement.generator_assignment generator
      in
      analyze_assignment ~pyre_in_context ~target ~value state
    in
    List.fold ~f:handle_generator generators ~init:state


  and analyze_comprehension
      ~(pyre_in_context : PyrePysaApi.InContext.t)
      taint
      { Comprehension.element; generators; _ }
      state
    =
    let pyre_in_context = PyrePysaApi.InContext.resolve_generators pyre_in_context generators in
    let element_taint = read_tree [Abstract.TreeDomain.Label.AnyIndex] taint in
    let state =
      analyze_expression ~pyre_in_context ~taint:element_taint ~state ~expression:element
    in
    analyze_generators ~pyre_in_context ~state generators


  (* Skip through * and **. Used at call sites where * and ** are handled explicitly *)
  and analyze_unstarred_expression
      ~(pyre_in_context : PyrePysaApi.InContext.t)
      taint
      expression
      state
    =
    match expression.Node.value with
    | Starred (Starred.Once expression)
    | Starred (Starred.Twice expression) ->
        analyze_expression ~pyre_in_context ~taint ~state ~expression
    | _ -> analyze_expression ~pyre_in_context ~taint ~state ~expression


  and analyze_getitem_call_target
      ~(pyre_in_context : PyrePysaApi.InContext.t)
      ~index_number
      ~location
      ~base
      ~taint
      ~state
      ~state_before_index_access
      call_target
    =
    let analyze_getitem receiver_class =
      let named_tuple_attributes =
        PyrePysaApi.ReadOnly.named_tuple_attributes pyre_api receiver_class
      in
      match named_tuple_attributes, index_number with
      | Some named_tuple_attributes, Some index_number ->
          List.nth named_tuple_attributes index_number
          (* Access an attribute of a named tuple via indices *)
          >>| (fun attribute ->
                analyze_attribute_access
                  ~pyre_in_context
                  ~location
                  ~resolve_properties:false
                  ~base
                  ~attribute
                  ~special:false
                  ~base_taint:BackwardState.Tree.bottom
                  ~attribute_taint:taint
                  ~state)
          (* Access an attribute of a named tuple via invalid indices *)
          |> Option.value ~default:bottom
      | Some _, None ->
          (* Access a named tuple with unknown indices *)
          Lazy.force state_before_index_access
      | None, _ ->
          (* Not access a named tuple *)
          Lazy.force state_before_index_access
    in
    match call_target with
    | {
        CallGraph.CallTarget.target = Method { method_name = "__getitem__"; _ };
        receiver_class = Some receiver_class;
        _;
      }
    | {
        CallGraph.CallTarget.target = Override { method_name = "__getitem__"; _ };
        receiver_class = Some receiver_class;
        _;
      } ->
        (* Potentially access a named tuple *)
        analyze_getitem receiver_class
    | _ ->
        (* Not access a named tuple *)
        Lazy.force state_before_index_access


  and analyze_call ~pyre_in_context ~location ~taint ~state ~callee ~arguments =
    let { Call.callee; arguments } =
      CallGraph.redirect_special_calls ~pyre_in_context { Call.callee; arguments }
    in
    let callees = get_call_callees ~location ~call:{ Call.callee; arguments } in

    let add_type_breadcrumbs taint =
      let type_breadcrumbs = CallModel.type_breadcrumbs_of_calls callees.call_targets in
      BackwardState.Tree.add_local_breadcrumbs type_breadcrumbs taint
    in

    match { Call.callee; arguments } with
    | {
     callee =
       { Node.value = Name (Name.Attribute { base; attribute = "__setitem__"; _ }); _ } as callee;
     arguments =
       [{ Call.Argument.value = index; name = None }; { Call.Argument.value; name = None }] as
       arguments;
    } ->
        let is_dict_setitem = CallGraph.CallCallees.is_mapping_method callees in
        let is_sequence_setitem = CallGraph.CallCallees.is_sequence_method callees in
        let use_custom_tito =
          is_dict_setitem
          || is_sequence_setitem
          || not (CallGraph.CallCallees.is_partially_resolved callees)
        in
        let state =
          (* Process the custom model of `__setitem__`. We treat `e.__setitem__(k, v)` as `e =
             e.__setitem__(k, v)` where method `__setitem__` returns the updated self. Due to
             modeling with the assignment, the user-provided models of `__setitem__` will be
             ignored, if they are inconsistent with treating `__setitem__` as returning an updated
             self. In the case that the call target is a dict or list, only propagate sources and
             sinks, and ignore tito propagation. *)
          let taint = compute_assignment_taint ~pyre_in_context base state |> fst in
          apply_callees
            ~apply_tito:(not use_custom_tito)
            ~pyre_in_context
            ~is_property:false
            ~call_location:location
            ~state
            ~callee
            ~arguments
            ~call_taint:taint
            callees
        in
        if use_custom_tito then
          (* Use the hardcoded behavior of `__setitem__` for any subtype of dict or list, and for
             unresolved calls. This is incorrect, but can lead to higher SNR, because we assume in
             most cases, we run into an expression whose type is exactly `dict`, rather than a
             (strict) subtype of `dict` that overrides `__setitem__`. *)
          let state =
            if not is_sequence_setitem then
              (* Since we smash the taint of ALL keys, we do a weak update here to avoid removing
                 the taint in `**keys`. That is, we join the state before analyzing the assignment
                 to `**keys` and the state afterwards. *)
              analyze_assignment
                ~weak:true
                ~pyre_in_context
                ~fields:[AccessPath.dictionary_keys]
                ~target:base
                ~value:index
                state
            else
              analyze_expression
                ~pyre_in_context
                ~taint:BackwardState.Tree.bottom
                ~state
                ~expression:index
          in
          analyze_assignment
            ~pyre_in_context
            ~fields:[AccessPath.get_index index]
            ~target:base
            ~value
            state
        else
          state
    | {
     callee = { Node.value = Name (Name.Attribute { base; attribute = "__getitem__"; _ }); _ };
     arguments =
       [
         {
           Call.Argument.value = { Node.value = argument_expression; _ } as argument_value;
           name = None;
         };
       ];
    } ->
        let taint = add_type_breadcrumbs taint in
        let index = AccessPath.get_index argument_value in
        let state_before_index_access =
          lazy
            (let taint =
               BackwardState.Tree.prepend [index] taint
               |> BackwardState.Tree.add_local_first_index index
             in
             analyze_expression ~pyre_in_context ~taint ~state ~expression:base)
        in
        let state =
          if List.is_empty callees.call_targets then
            (* This call may be unresolved, because for example the receiver type is unknown *)
            Lazy.force state_before_index_access
          else
            let index_number =
              match argument_expression with
              | Expression.Constant (Constant.Integer i) -> Some i
              | _ -> None
            in
            List.fold callees.call_targets ~init:bottom ~f:(fun state_so_far call_target ->
                analyze_getitem_call_target
                  ~index_number
                  ~pyre_in_context
                  ~location
                  ~base
                  ~taint
                  ~state
                  ~state_before_index_access
                  call_target
                |> join state_so_far)
        in
        analyze_expression
          ~pyre_in_context
          ~taint:BackwardState.Tree.bottom
          ~state
          ~expression:argument_value
    (* Special case `__iter__` and `__next__` as being a random index access (this pattern is the
       desugaring of `for element in x`). *)
    | {
     callee = { Node.value = Name (Name.Attribute { base; attribute = "__next__"; _ }); _ };
     arguments = [];
    } ->
        let taint = add_type_breadcrumbs taint in
        analyze_expression ~pyre_in_context ~taint ~state ~expression:base
    | {
     callee =
       { Node.value = Name (Name.Attribute { base; attribute = "__iter__"; special = true }); _ };
     arguments = [];
    } ->
        let label =
          (* For dictionaries, the default iterator is keys. *)
          if CallGraph.CallCallees.is_mapping_method callees then
            AccessPath.dictionary_keys
          else
            Abstract.TreeDomain.Label.AnyIndex
        in
        let taint = BackwardState.Tree.prepend [label] taint in
        analyze_expression ~pyre_in_context ~taint ~state ~expression:base
    (* We special-case object.__setattr__, which is sometimes used in order to work around
       dataclasses being frozen post-initialization. *)
    | {
     callee =
       {
         Node.value =
           Name
             (Name.Attribute
               {
                 base = { Node.value = Name (Name.Identifier "object"); _ };
                 attribute = "__setattr__";
                 _;
               });
         _;
       };
     arguments =
       [
         { Call.Argument.value = self; name = None };
         {
           Call.Argument.value =
             {
               Node.value =
                 Expression.Constant (Constant.String { value = attribute; kind = String });
               _;
             };
           name = None;
         };
         { Call.Argument.value; name = None };
       ];
    } ->
        analyze_assignment
          ~pyre_in_context
          ~target:
            (Expression.Name (Name.Attribute { base = self; attribute; special = true })
            |> Node.create ~location)
          ~value
          state
    (* `getattr(a, "field", default)` should evaluate to the join of `a.field` and `default`. *)
    | {
     callee = { Node.value = Name (Name.Identifier "getattr"); _ };
     arguments =
       [
         { Call.Argument.value = base; name = None };
         {
           Call.Argument.value =
             {
               Node.value =
                 Expression.Constant (Constant.String { StringLiteral.value = attribute; _ });
               _;
             };
           name = None;
         };
         { Call.Argument.value = default; name = _ };
       ];
    } ->
        let attribute_expression =
          Expression.Name (Name.Attribute { base; attribute; special = false })
          |> Node.create ~location
        in
        let state =
          analyze_expression ~pyre_in_context ~state ~expression:attribute_expression ~taint
        in
        analyze_expression ~pyre_in_context ~state ~expression:default ~taint
    (* `zip(a, b, ...)` creates a taint object whose first index has a's taint, second index has b's
       taint, etc. *)
    | { callee = { Node.value = Name (Name.Identifier "zip"); _ }; arguments = lists } ->
        let taint = BackwardState.Tree.read [Abstract.TreeDomain.Label.AnyIndex] taint in
        let analyze_zipped_list index state { Call.Argument.value; _ } =
          let index_name = Abstract.TreeDomain.Label.Index (string_of_int index) in
          let taint =
            BackwardState.Tree.read [index_name] taint
            |> BackwardState.Tree.prepend [Abstract.TreeDomain.Label.AnyIndex]
          in
          analyze_expression ~pyre_in_context ~state ~taint ~expression:value
        in
        List.foldi lists ~init:state ~f:analyze_zipped_list
    (* dictionary .keys(), .values() and .items() functions are special, as they require handling of
       DictionaryKeys taint. *)
    | {
     callee = { Node.value = Name (Name.Attribute { base; attribute = "values"; _ }); _ };
     arguments = [];
    }
      when CallGraph.CallCallees.is_mapping_method callees ->
        let taint =
          taint
          |> BackwardState.Tree.read [Abstract.TreeDomain.Label.AnyIndex]
          |> BackwardState.Tree.prepend [Abstract.TreeDomain.Label.AnyIndex]
        in
        analyze_expression ~pyre_in_context ~taint ~state ~expression:base
    | {
     callee = { Node.value = Name (Name.Attribute { base; attribute = "keys"; _ }); _ };
     arguments = [];
    }
      when CallGraph.CallCallees.is_mapping_method callees ->
        let taint =
          taint
          |> BackwardState.Tree.read [Abstract.TreeDomain.Label.AnyIndex]
          |> BackwardState.Tree.prepend [AccessPath.dictionary_keys]
        in
        analyze_expression ~pyre_in_context ~taint ~state ~expression:base
    | {
     callee =
       {
         Node.value =
           Name
             (Name.Attribute
               {
                 base = { Node.value = Name (Name.Identifier identifier); _ } as base;
                 attribute = "update";
                 _;
               });
         _;
       };
     arguments =
       [
         {
           Call.Argument.value =
             { Node.value = Expression.Dictionary { Dictionary.entries; keywords = [] }; _ };
           name = None;
         };
       ];
    }
      when CallGraph.CallCallees.is_mapping_method callees
           && Option.is_some (Dictionary.string_literal_keys entries) ->
        let entries = Option.value_exn (Dictionary.string_literal_keys entries) in
        let access_path =
          Some { AccessPath.root = AccessPath.Root.Variable identifier; path = [] }
        in
        let dict_taint =
          let global_taint =
            GlobalModel.from_expression
              ~pyre_in_context
              ~call_graph:FunctionContext.call_graph_of_define
              ~get_callee_model:FunctionContext.get_callee_model
              ~qualifier:FunctionContext.qualifier
              ~expression:base
              ~interval:FunctionContext.caller_class_interval
            |> GlobalModel.get_sinks
            |> SinkTreeWithHandle.join
          in
          BackwardState.Tree.join global_taint (get_taint access_path state)
        in
        let override_taint_from_update (taint, state) (key, value) =
          let path = [Abstract.TreeDomain.Label.Index key] in
          let value_taint =
            BackwardState.Tree.read ~transform_non_leaves path dict_taint
            |> BackwardState.Tree.transform
                 Features.TitoPositionSet.Element
                 Add
                 ~f:value.Node.location
          in
          (* update backwards is overwriting the old key taint with bottom *)
          let taint =
            BackwardState.Tree.assign ~tree:taint path ~subtree:BackwardState.Tree.bottom
          in
          let state =
            analyze_expression ~pyre_in_context ~taint:value_taint ~state ~expression:value
          in
          taint, state
        in
        let taint, state =
          List.fold entries ~init:(dict_taint, state) ~f:override_taint_from_update
        in
        store_taint ~root:(AccessPath.Root.Variable identifier) ~path:[] taint state
    | {
     callee =
       {
         Node.value =
           Name
             (Name.Attribute
               {
                 base = { Node.value = Name (Name.Identifier identifier); _ };
                 attribute = "pop";
                 _;
               });
         _;
       };
     arguments =
       [
         {
           Call.Argument.value =
             { Node.value = Expression.Constant (Constant.String { StringLiteral.value; _ }); _ };
           name = None;
         };
       ];
    }
      when CallGraph.CallCallees.is_mapping_method callees ->
        let access_path =
          Some { AccessPath.root = AccessPath.Root.Variable identifier; path = [] }
        in
        let old_taint = get_taint access_path state in
        let new_taint =
          BackwardState.Tree.assign
            ~tree:old_taint
            [Abstract.TreeDomain.Label.Index value]
            ~subtree:(add_type_breadcrumbs taint)
        in
        store_taint ~root:(AccessPath.Root.Variable identifier) ~path:[] new_taint state
    | {
     callee = { Node.value = Name (Name.Attribute { base; attribute = "items"; _ }); _ };
     arguments = [];
    }
      when CallGraph.CallCallees.is_mapping_method callees ->
        (* When we're faced with an assign of the form `k, v = d.items().__iter__().__next__()`, the
           taint we analyze d.items() under will be {* -> {0 -> k, 1 -> v} }. We want to analyze d
           itself under the taint of `{* -> v, $keys -> k}`. *)
        let item_taint = BackwardState.Tree.read [Abstract.TreeDomain.Label.AnyIndex] taint in
        let key_taint =
          BackwardState.Tree.read [Abstract.TreeDomain.Label.create_int_index 0] item_taint
        in
        let value_taint =
          BackwardState.Tree.read [Abstract.TreeDomain.Label.create_int_index 1] item_taint
        in
        let taint =
          BackwardState.Tree.join
            (BackwardState.Tree.prepend [AccessPath.dictionary_keys] key_taint)
            (BackwardState.Tree.prepend [Abstract.TreeDomain.Label.AnyIndex] value_taint)
        in
        analyze_expression ~pyre_in_context ~taint ~state ~expression:base
    | {
     callee = { Node.value = Name (Name.Attribute { base; attribute = "get"; _ }); _ };
     arguments =
       {
         Call.Argument.value =
           {
             Node.value = Expression.Constant (Constant.String { StringLiteral.value = index; _ });
             _;
           };
         name = None;
       }
       :: (([] | [_]) as optional_arguments);
    }
      when CallGraph.CallCallees.is_mapping_method callees ->
        let index = Abstract.TreeDomain.Label.Index index in
        let taint = add_type_breadcrumbs taint in
        let state =
          match optional_arguments with
          | [{ Call.Argument.value = default_expression; _ }] ->
              let taint =
                BackwardState.Tree.transform
                  Features.TitoPositionSet.Element
                  Add
                  ~f:default_expression.Node.location
                  taint
              in
              analyze_expression ~pyre_in_context ~taint ~state ~expression:default_expression
          | [] -> state
          | _ -> failwith "unreachable"
        in
        let taint =
          taint
          |> BackwardState.Tree.prepend [index]
          |> BackwardState.Tree.add_local_first_index index
          |> BackwardState.Tree.transform Features.TitoPositionSet.Element Add ~f:base.Node.location
        in
        analyze_expression ~pyre_in_context ~taint ~state ~expression:base
    | {
     Call.callee =
       {
         Node.value =
           Name
             (Name.Attribute
               { base = { Node.value = Expression.Name name; _ }; attribute = "gather"; _ });
         _;
       };
     arguments;
    }
      when String.equal "asyncio" (Name.last name) ->
        analyze_expression
          ~pyre_in_context
          ~taint
          ~state
          ~expression:
            {
              Node.location;
              value =
                Expression.Tuple
                  (List.map arguments ~f:(fun argument -> argument.Call.Argument.value));
            }
    (* Special case `"{}".format(s)` and `"%s" % (s,)` for Literal String Sinks *)
    | {
        callee =
          {
            Node.value =
              Name
                (Name.Attribute
                  {
                    base =
                      {
                        Node.value = Constant (Constant.String { StringLiteral.value; _ });
                        location;
                      };
                    attribute = "__mod__";
                    _;
                  });
            _;
          };
        arguments;
      }
    | {
        callee =
          {
            Node.value =
              Name
                (Name.Attribute
                  {
                    base =
                      {
                        Node.value = Constant (Constant.String { StringLiteral.value; _ });
                        location;
                      };
                    attribute = "format";
                    _;
                  });
            _;
          };
        arguments;
      } ->
        let arguments_formatted_string =
          List.map ~f:(fun call_argument -> call_argument.value) arguments
        in
        analyze_joined_string
          ~pyre_in_context
          ~taint
          ~state
          ~location
          ~breadcrumbs:(Features.BreadcrumbSet.singleton (Features.format_string ()))
          ~increase_trace_length:true
          ~string_literal:value
          arguments_formatted_string
    (* Special case `"str" + s` and `s + "str"` for Literal String Sinks *)
    | {
     callee =
       { Node.value = Name (Name.Attribute { base = expression; attribute = "__add__"; _ }); _ };
     arguments =
       [
         {
           Call.Argument.value =
             { Node.value = Expression.Constant (Constant.String { StringLiteral.value; _ }); _ };
           name = None;
         };
       ];
    } ->
        analyze_joined_string
          ~pyre_in_context
          ~taint
          ~state
          ~location
          ~breadcrumbs:(Features.BreadcrumbSet.singleton (Features.string_concat_left_hand_side ()))
          ~increase_trace_length:true
          ~string_literal:value
          [expression]
    | {
     callee =
       {
         Node.value =
           Name
             (Name.Attribute
               {
                 base = { Node.value = Constant (Constant.String { StringLiteral.value; _ }); _ };
                 attribute = "__add__";
                 _;
               });
         _;
       };
     arguments = [{ Call.Argument.value = expression; name = None }];
    } ->
        analyze_joined_string
          ~pyre_in_context
          ~taint
          ~state
          ~location
          ~breadcrumbs:
            (Features.BreadcrumbSet.singleton (Features.string_concat_right_hand_side ()))
          ~increase_trace_length:true
          ~string_literal:value
          [expression]
    | {
     callee =
       {
         Node.value =
           Name
             (Name.Attribute
               { base; attribute = ("__add__" | "__mod__" | "format") as function_name; _ });
         _;
       };
     arguments;
    }
      when CallGraph.CallCallees.is_string_method callees ->
        let globals_to_constants = function
          | { Node.value = Expression.Name (Name.Identifier identifier); _ } as value -> (
              let as_reference = identifier |> Reference.create |> Reference.delocalize in
              let global_string =
                Interprocedural.GlobalConstants.SharedMemory.ReadOnly.get
                  FunctionContext.global_constants
                  as_reference
              in
              match global_string with
              | Some global_string ->
                  global_string
                  |> (fun string_literal -> Expression.Constant (Constant.String string_literal))
                  |> Node.create ~location:value.location
              | _ -> value)
          | value -> value
        in
        let breadcrumbs =
          match function_name with
          | "__mod__"
          | "format" ->
              Features.BreadcrumbSet.singleton (Features.format_string ())
          | _ -> Features.BreadcrumbSet.empty
        in
        let substrings =
          arguments
          |> List.map ~f:(fun argument -> argument.Call.Argument.value)
          |> List.cons base
          |> List.map ~f:globals_to_constants
        in
        let string_literal, substrings = CallModel.arguments_for_string_format substrings in
        analyze_joined_string
          ~pyre_in_context
          ~taint
          ~state
          ~location
          ~breadcrumbs
          ~increase_trace_length:true
          ~string_literal
          substrings
    | {
     Call.callee = { Node.value = Name (Name.Identifier "reveal_taint"); _ };
     arguments = [{ Call.Argument.value = expression; _ }];
    } ->
        begin
          match AccessPath.of_expression expression with
          | None ->
              Log.dump
                "%a: Revealed backward taint for `%s`: expression is too complex"
                Location.WithModule.pp
                (Location.with_module location ~module_reference:FunctionContext.qualifier)
                (Transform.sanitize_expression expression |> Expression.show)
          | access_path ->
              let taint = get_taint access_path state in
              Log.dump
                "%a: Revealed backward taint for `%s`: %s"
                Location.WithModule.pp
                (Location.with_module location ~module_reference:FunctionContext.qualifier)
                (Transform.sanitize_expression expression |> Expression.show)
                (BackwardState.Tree.show taint)
        end;
        state
    | { Call.callee = { Node.value = Name (Name.Identifier "super"); _ }; arguments } -> (
        match arguments with
        | [_; Call.Argument.{ value = object_; _ }] ->
            analyze_expression ~pyre_in_context ~taint ~state ~expression:object_
        | _ -> (
            (* Use implicit self *)
            match first_parameter () with
            | Some root -> store_taint ~weak:true ~root ~path:[] taint state
            | None -> state))
    | _ ->
        apply_callees
          ~pyre_in_context
          ~is_property:false
          ~call_location:location
          ~state
          ~callee
          ~arguments
          ~call_taint:taint
          callees


  and analyze_joined_string
      ~(pyre_in_context : PyrePysaApi.InContext.t)
      ~taint
      ~state
      ~location
      ~breadcrumbs
      ~increase_trace_length
      ~string_literal
      substrings
    =
    let triggered_taint =
      Issue.TriggeredSinkLocationMap.get FunctionContext.triggered_sinks ~location
    in
    let location_with_module =
      Location.with_module ~module_reference:FunctionContext.qualifier location
    in
    let state = { taint = BackwardState.join state.taint triggered_taint } in
    let taint =
      let literal_string_sinks =
        FunctionContext.taint_configuration.implicit_sinks.literal_string_sinks
      in
      if List.is_empty literal_string_sinks then
        taint
      else
        List.fold
          literal_string_sinks
          ~f:(fun taint { TaintConfiguration.sink_kind; pattern } ->
            if Re2.matches pattern string_literal then
              BackwardTaint.singleton (CallInfo.origin location_with_module) sink_kind Frame.initial
              |> BackwardState.Tree.create_leaf
              |> BackwardState.Tree.join taint
            else
              taint)
          ~init:taint
    in
    let taint =
      taint
      |> BackwardState.Tree.collapse ~breadcrumbs:(Features.tito_broadening_set ())
      |> BackwardTaint.add_local_breadcrumbs breadcrumbs
      |> BackwardState.Tree.create_leaf
    in
    let analyze_stringify_callee
        ~taint_to_join
        ~state_to_join
        ~call_target
        ~call_location
        ~base
        ~base_state
      =
      let {
        arguments_taint = _;
        implicit_argument_taint;
        captures_taint = _;
        captures = _;
        state = new_state;
      }
        =
        let callees = CallGraph.CallCallees.create ~call_targets:[call_target] () in
        let callee =
          let callee_from_method_name method_name =
            {
              Node.value =
                Expression.Name (Name.Attribute { base; attribute = method_name; special = false });
              location = call_location;
            }
          in
          match call_target.target with
          | Interprocedural.Target.Method { method_name; _ } -> callee_from_method_name method_name
          | Override { method_name; _ } -> callee_from_method_name method_name
          | Function { name; _ } ->
              { Node.value = Name (Name.Identifier name); location = call_location }
          | Object _ -> failwith "callees should be either methods or functions"
        in
        apply_callees_and_return_arguments_taint
          ~pyre_in_context
          ~callee
          ~call_location
          ~arguments:[]
          ~state:base_state
          ~call_taint:taint
          callees
      in
      let new_taint =
        match implicit_argument_taint with
        | CallModel.ImplicitArgument.Backward.CalleeBase self_taint ->
            BackwardState.Tree.join taint_to_join self_taint
        | None -> taint_to_join
        | _ -> failwith "Expect `CalleeBase` or `None` for stringify callee"
      in
      new_taint, join state_to_join new_state
    in
    let analyze_nested_expression state ({ Node.location = expression_location; _ } as expression) =
      let new_taint, new_state =
        match get_string_format_callees ~location:expression_location with
        | Some { CallGraph.StringFormatCallees.stringify_targets = _ :: _ as stringify_targets; _ }
          ->
            List.fold
              stringify_targets
              ~init:(taint, state)
              ~f:(fun (taint_to_join, state_to_join) call_target ->
                analyze_stringify_callee
                  ~taint_to_join
                  ~state_to_join
                  ~call_target
                  ~call_location:expression_location
                  ~base:expression
                  ~base_state:state)
        | _ -> taint, state
      in
      let new_taint =
        new_taint
        |> BackwardState.Tree.transform Features.TitoPositionSet.Element Add ~f:expression_location
        |> BackwardState.Tree.add_local_breadcrumb (Features.tito ())
      in
      let new_taint =
        if increase_trace_length then
          BackwardState.Tree.transform
            Domains.TraceLength.Self
            Map
            ~f:TraceLength.increase
            new_taint
        else
          new_taint
      in
      analyze_expression ~pyre_in_context ~taint:new_taint ~state:new_state ~expression
    in
    List.fold (List.rev substrings) ~f:analyze_nested_expression ~init:state


  and analyze_expression
      ~(pyre_in_context : PyrePysaApi.InContext.t)
      ~taint
      ~state
      ~expression:({ Node.location; _ } as expression)
    =
    log
      "Backward analysis of expression: `%a` with backward taint: %a"
      Expression.pp
      expression
      BackwardState.Tree.pp
      taint;
    match expression.Node.value with
    | Await expression -> analyze_expression ~pyre_in_context ~taint ~state ~expression
    | BooleanOperator { left; operator = _; right } ->
        analyze_expression ~pyre_in_context ~taint ~state ~expression:right
        |> fun state -> analyze_expression ~pyre_in_context ~taint ~state ~expression:left
    | ComparisonOperator ({ left; operator = _; right } as comparison) -> (
        match ComparisonOperator.override ~location comparison with
        | Some override -> analyze_expression ~pyre_in_context ~taint ~state ~expression:override
        | None ->
            let taint =
              BackwardState.Tree.add_local_breadcrumbs (Features.type_bool_scalar_set ()) taint
            in
            analyze_expression ~pyre_in_context ~taint ~state ~expression:right
            |> fun state -> analyze_expression ~pyre_in_context ~taint ~state ~expression:left)
    | Call { callee; arguments } ->
        analyze_call ~pyre_in_context ~location ~taint ~state ~callee ~arguments
    | Constant _ -> state
    | Dictionary { Dictionary.entries; keywords } ->
        let state =
          List.fold ~f:(analyze_dictionary_entry ~pyre_in_context taint) entries ~init:state
        in
        let analyze_dictionary_keywords state keywords =
          analyze_expression ~pyre_in_context ~taint ~state ~expression:keywords
        in
        List.fold keywords ~f:analyze_dictionary_keywords ~init:state
    | DictionaryComprehension
        { Comprehension.element = { Dictionary.Entry.key; value }; generators; _ } ->
        let pyre_in_context = PyrePysaApi.InContext.resolve_generators pyre_in_context generators in
        let state =
          analyze_expression
            ~pyre_in_context
            ~taint:(read_tree [AccessPath.dictionary_keys] taint)
            ~state
            ~expression:key
        in
        let state =
          analyze_expression
            ~pyre_in_context
            ~taint:(read_tree [Abstract.TreeDomain.Label.AnyIndex] taint)
            ~state
            ~expression:value
        in
        analyze_generators ~pyre_in_context ~state generators
    | Generator comprehension -> analyze_comprehension ~pyre_in_context taint comprehension state
    | Lambda { parameters = _; body } ->
        (* Ignore parameter bindings and pretend body is inlined *)
        analyze_expression ~pyre_in_context ~taint ~state ~expression:body
    | List list ->
        let total = List.length list in
        List.rev list
        |> List.foldi ~f:(analyze_reverse_list_element ~total ~pyre_in_context taint) ~init:state
    | ListComprehension comprehension ->
        analyze_comprehension ~pyre_in_context taint comprehension state
    | Name (Name.Identifier identifier) ->
        let taint =
          BackwardState.Tree.add_local_type_breadcrumbs ~pyre_in_context ~expression taint
        in
        store_taint ~weak:true ~root:(AccessPath.Root.Variable identifier) ~path:[] taint state
    | Name (Name.Attribute { base; attribute = "__dict__"; _ }) ->
        analyze_expression ~pyre_in_context ~taint ~state ~expression:base
    | Name (Name.Attribute { base; attribute; special }) ->
        analyze_attribute_access
          ~pyre_in_context
          ~location
          ~resolve_properties:true
          ~base
          ~attribute
          ~special
          ~base_taint:BackwardState.Tree.bottom
          ~attribute_taint:taint
          ~state
    | Set set ->
        let element_taint = read_tree [Abstract.TreeDomain.Label.AnyIndex] taint in
        List.fold
          set
          ~f:(fun state expression ->
            analyze_expression ~pyre_in_context ~taint:element_taint ~state ~expression)
          ~init:state
    | SetComprehension comprehension ->
        analyze_comprehension ~pyre_in_context taint comprehension state
    | Starred (Starred.Once expression)
    | Starred (Starred.Twice expression) ->
        let taint = BackwardState.Tree.prepend [Abstract.TreeDomain.Label.AnyIndex] taint in
        analyze_expression ~pyre_in_context ~taint ~state ~expression
    | FormatString substrings ->
        let substrings =
          List.map substrings ~f:(function
              | Substring.Format expression -> expression
              | Substring.Literal { Node.value; location } ->
                  Expression.Constant (Constant.String { StringLiteral.value; kind = String })
                  |> Node.create ~location)
        in
        let string_literal, substrings = CallModel.arguments_for_string_format substrings in
        analyze_joined_string
          ~pyre_in_context
          ~taint
          ~state
          ~location
          ~breadcrumbs:(Features.BreadcrumbSet.singleton (Features.format_string ()))
          ~increase_trace_length:false
          ~string_literal
          substrings
    | Ternary { target; test; alternative } ->
        let state_then = analyze_expression ~pyre_in_context ~taint ~state ~expression:target in
        let state_else =
          analyze_expression ~pyre_in_context ~taint ~state ~expression:alternative
        in
        join state_then state_else
        |> fun state ->
        analyze_expression ~pyre_in_context ~taint:BackwardState.Tree.empty ~state ~expression:test
    | Tuple list ->
        let total = List.length list in
        List.rev list
        |> List.foldi ~f:(analyze_reverse_list_element ~total ~pyre_in_context taint) ~init:state
    | UnaryOperator { operator = _; operand } ->
        analyze_expression ~pyre_in_context ~taint ~state ~expression:operand
    | WalrusOperator { target; value } ->
        let state = analyze_assignment ~pyre_in_context ~target ~value state in
        analyze_expression ~pyre_in_context ~taint ~state ~expression:value
    | Yield None -> state
    | Yield (Some expression)
    | YieldFrom expression ->
        let access_path = { AccessPath.root = AccessPath.Root.LocalResult; path = [] } in
        let return_taint = get_taint (Some access_path) state in
        analyze_expression ~pyre_in_context ~taint:return_taint ~state ~expression


  (* Returns the taint, and whether to collapse one level (due to star expression) *)
  and compute_assignment_taint ~(pyre_in_context : PyrePysaApi.InContext.t) target state =
    match target.Node.value with
    | Expression.Starred (Once target | Twice target) ->
        (* This is approximate. Unless we can get the tuple type on the right to tell how many total
           elements there will be, we just pick up the entire collection. *)
        let taint, _ = compute_assignment_taint ~pyre_in_context target state in
        taint, true
    | List targets
    | Tuple targets ->
        let compute_tuple_target_taint position taint_accumulator target =
          let taint, collapse = compute_assignment_taint ~pyre_in_context target state in
          let index_taint =
            if collapse then
              taint
            else
              let index_name = Abstract.TreeDomain.Label.Index (string_of_int position) in
              BackwardState.Tree.prepend [index_name] taint
          in
          BackwardState.Tree.join index_taint taint_accumulator
        in
        let taint =
          List.foldi targets ~f:compute_tuple_target_taint ~init:BackwardState.Tree.empty
        in
        taint, false
    | Call
        {
          callee = { Node.value = Name (Name.Attribute { base; attribute = "__getitem__"; _ }); _ };
          arguments = [{ Call.Argument.value = index; _ }];
        } ->
        let taint =
          compute_assignment_taint ~pyre_in_context base state
          |> fst
          |> BackwardState.Tree.read [AccessPath.get_index index]
        in
        taint, false
    | _ ->
        let taint =
          let local_taint =
            let access_path = AccessPath.of_expression target in
            get_taint access_path state
          in
          let global_taint =
            GlobalModel.from_expression
              ~pyre_in_context
              ~call_graph:FunctionContext.call_graph_of_define
              ~get_callee_model:FunctionContext.get_callee_model
              ~qualifier:FunctionContext.qualifier
              ~expression:target
              ~interval:FunctionContext.caller_class_interval
            |> GlobalModel.get_sinks
            |> SinkTreeWithHandle.join
          in
          BackwardState.Tree.join local_taint global_taint
        in
        taint, false


  and analyze_assignment
      ?(weak = false)
      ~(pyre_in_context : PyrePysaApi.InContext.t)
      ?(fields = [])
      ~target
      ~value
      state
    =
    let taint =
      compute_assignment_taint ~pyre_in_context target state
      |> fst
      |> read_tree fields
      |> BackwardState.Tree.add_local_type_breadcrumbs ~pyre_in_context ~expression:target
    in
    let state =
      let rec clear_taint state target =
        match Node.value target with
        | Expression.Tuple items -> List.fold items ~f:clear_taint ~init:state
        | _ -> (
            match AccessPath.of_expression target with
            | Some { root; path } ->
                {
                  taint =
                    BackwardState.assign
                      ~root
                      ~path:(path @ fields)
                      BackwardState.Tree.empty
                      state.taint;
                }
            | None -> state)
      in
      if weak then (* Weak updates do not remove the taint. *)
        state
      else
        clear_taint state target
    in
    analyze_expression ~pyre_in_context ~taint ~state ~expression:value


  let analyze_statement ~pyre_in_context state { Node.value = statement; location } =
    match statement with
    | Statement.Statement.Assign
        { value = { Node.value = Expression.Constant Constant.Ellipsis; _ }; _ } ->
        state
    | Assign { target = { Node.location; value = target_value } as target; value; _ } -> (
        let target_global_model =
          GlobalModel.from_expression
            ~pyre_in_context
            ~call_graph:FunctionContext.call_graph_of_define
            ~get_callee_model:FunctionContext.get_callee_model
            ~qualifier:FunctionContext.qualifier
            ~expression:target
            ~interval:FunctionContext.caller_class_interval
        in
        if GlobalModel.is_sanitized target_global_model then
          analyze_expression
            ~pyre_in_context
            ~taint:BackwardState.Tree.bottom
            ~state
            ~expression:value
        else
          match target_value with
          | Expression.Name (Name.Attribute { base; attribute; _ }) ->
              let attribute_access_callees = get_attribute_access_callees ~location ~attribute in

              let property_call_state =
                match attribute_access_callees with
                | Some { property_targets = _ :: _ as property_targets; _ } ->
                    (* Treat `a.property = x` as `a = a.property(x)` *)
                    let taint = compute_assignment_taint ~pyre_in_context base state |> fst in
                    apply_callees
                      ~pyre_in_context
                      ~is_property:true
                      ~callee:target
                      ~call_location:location
                      ~arguments:[{ name = None; value }]
                      ~state
                      ~call_taint:taint
                      (CallGraph.CallCallees.create ~call_targets:property_targets ())
                | _ -> bottom
              in

              let attribute_state =
                match attribute_access_callees with
                | Some { is_attribute = true; _ }
                | None ->
                    analyze_assignment ~pyre_in_context ~target ~value state
                | _ -> bottom
              in

              join property_call_state attribute_state
          | _ -> analyze_assignment ~pyre_in_context ~target ~value state)
    | Assert { test; _ } ->
        analyze_expression ~pyre_in_context ~taint:BackwardState.Tree.empty ~state ~expression:test
    | Break
    | Class _
    | Continue ->
        state
    | Define define -> analyze_definition ~define state
    | Delete expressions ->
        let process_expression state expression =
          match AccessPath.of_expression expression with
          | Some { AccessPath.root; path } ->
              { taint = BackwardState.assign ~root ~path BackwardState.Tree.bottom state.taint }
          | _ -> state
        in
        List.fold expressions ~init:state ~f:process_expression
    | Expression expression ->
        analyze_expression ~pyre_in_context ~taint:BackwardState.Tree.empty ~state ~expression
    | For _
    | Global _
    | If _
    | Import _
    | Match _
    | Nonlocal _
    | Pass
    | Raise { expression = None; _ } ->
        state
    | Raise { expression = Some expression; _ } ->
        analyze_expression ~pyre_in_context ~taint:BackwardState.Tree.empty ~state ~expression
    | Return { expression = Some expression; _ } ->
        let access_path = { AccessPath.root = AccessPath.Root.LocalResult; path = [] } in
        let return_taint = get_taint (Some access_path) state in
        let return_sink =
          CallModel.return_sink
            ~pyre_in_context
            ~location:(Location.with_module ~module_reference:FunctionContext.qualifier location)
            ~callee:FunctionContext.callable
            ~sink_model:FunctionContext.existing_model.Model.backward.sink_taint
          |> BackwardState.Tree.add_local_breadcrumb (Features.propagated_return_sink ())
        in
        analyze_expression
          ~pyre_in_context
          ~taint:(BackwardState.Tree.join return_taint return_sink)
          ~state
          ~expression
    | Return { expression = None; _ }
    | Try _
    | With _
    | While _ ->
        state


  let backward ~statement_key state ~statement =
    TaintProfiler.track_statement_analysis
      ~profiler
      ~analysis:TaintProfiler.Backward
      ~statement
      ~f:(fun () ->
        log
          "Backward analysis of statement: `%a`@,With backward state: %a"
          Statement.pp
          statement
          pp
          state;
        let pyre_in_context =
          PyrePysaApi.InContext.create_at_statement_key
            pyre_api
            ~define:(Ast.Node.value FunctionContext.definition)
            ~statement_key
        in
        analyze_statement ~pyre_in_context state statement)


  let forward ~statement_key:_ _ ~statement:_ = failwith "Don't call me"
end

(* Split the inferred entry state into externally visible taint_in_taint_out parts and
   sink_taint. *)
let extract_tito_and_sink_models
    define
    ~pyre_api
    ~is_constructor
    ~taint_configuration:
      {
        TaintConfiguration.Heap.analysis_model_constraints =
          {
            maximum_model_sink_tree_width;
            maximum_model_tito_tree_width;
            maximum_trace_length;
            maximum_tito_depth;
            _;
          };
        _;
      }
    ~existing_backward
    ~apply_broadening
    entry_taint
  =
  (* Simplify trees by keeping only essential structure and merging details back into that. *)
  let simplify ~shape_breadcrumbs ~limit_breadcrumbs tree =
    if apply_broadening then
      tree
      |> BackwardState.Tree.shape
           ~mold_with_return_access_paths:is_constructor
           ~breadcrumbs:shape_breadcrumbs
      |> BackwardState.Tree.limit_to
           ~breadcrumbs:limit_breadcrumbs
           ~width:maximum_model_sink_tree_width
      |> BackwardState.Tree.transform_call_info
           CallInfo.Tito
           Features.ReturnAccessPathTree.Self
           Map
           ~f:Features.ReturnAccessPathTree.limit_width
    else
      tree
  in
  let add_type_breadcrumbs annotation tree =
    let type_breadcrumbs =
      annotation
      >>| PyrePysaApi.ReadOnly.parse_annotation pyre_api
      |> Features.type_breadcrumbs_from_annotation ~pyre_api
    in
    BackwardState.Tree.add_local_breadcrumbs type_breadcrumbs tree
  in
  let split_and_simplify model (parameter, qualified_name, annotation) =
    let partition =
      BackwardState.read ~root:(AccessPath.Root.Variable qualified_name) ~path:[] entry_taint
      |> BackwardState.Tree.partition BackwardTaint.kind By ~f:Sinks.discard_transforms
    in
    let taint_in_taint_out =
      let breadcrumbs_to_attach, via_features_to_attach =
        BackwardState.extract_features_to_attach
          ~root:parameter
          ~attach_to_kind:Sinks.Attach
          existing_backward.Model.Backward.taint_in_taint_out
      in
      let candidate_tree =
        Map.Poly.find partition Sinks.LocalReturn
        |> Option.value ~default:BackwardState.Tree.empty
        |> simplify
             ~shape_breadcrumbs:(Features.model_tito_shaping_set ())
             ~limit_breadcrumbs:(Features.model_tito_broadening_set ())
        |> add_type_breadcrumbs annotation
      in
      let candidate_tree =
        match maximum_tito_depth with
        | Some maximum_tito_depth ->
            BackwardState.Tree.prune_maximum_length maximum_tito_depth candidate_tree
        | _ -> candidate_tree
      in
      let candidate_tree =
        candidate_tree
        |> BackwardState.Tree.add_local_breadcrumbs breadcrumbs_to_attach
        |> BackwardState.Tree.add_via_features via_features_to_attach
      in
      if apply_broadening then
        BackwardState.Tree.limit_to
          ~breadcrumbs:(Features.model_tito_broadening_set ())
          ~width:maximum_model_tito_tree_width
          candidate_tree
      else
        candidate_tree
    in
    let sink_taint =
      let simplify_sink_taint ~key:sink ~data:sink_tree accumulator =
        match sink with
        | Sinks.LocalReturn
        (* For now, we don't propagate partial sinks at all. *)
        | Sinks.PartialSink _
        | Sinks.Attach ->
            accumulator
        | _ ->
            let sink_tree =
              match maximum_trace_length with
              | Some maximum_trace_length ->
                  (* We limit by maximum_trace_length - 1, since the distance will be incremented by
                     one when the taint is propagated. *)
                  BackwardState.Tree.prune_maximum_length (maximum_trace_length - 1) sink_tree
              | _ -> sink_tree
            in
            let sink_tree =
              sink_tree
              |> simplify
                   ~shape_breadcrumbs:(Features.model_sink_shaping_set ())
                   ~limit_breadcrumbs:(Features.model_sink_broadening_set ())
              |> add_type_breadcrumbs annotation
            in
            let sink_tree =
              match Sinks.discard_transforms sink with
              | Sinks.ExtraTraceSink ->
                  CallModel.ExtraTraceForTransforms.prune ~sink_tree ~tito_tree:taint_in_taint_out
              | _ -> sink_tree
            in
            BackwardState.Tree.join accumulator sink_tree
      in
      Map.Poly.fold ~init:BackwardState.Tree.empty ~f:simplify_sink_taint partition
    in
    let sink_taint =
      let breadcrumbs_to_attach, via_features_to_attach =
        BackwardState.extract_features_to_attach
          ~root:parameter
          ~attach_to_kind:Sinks.Attach
          existing_backward.Model.Backward.sink_taint
      in
      sink_taint
      |> BackwardState.Tree.add_local_breadcrumbs breadcrumbs_to_attach
      |> BackwardState.Tree.add_via_features via_features_to_attach
    in
    Model.Backward.
      {
        taint_in_taint_out =
          BackwardState.assign ~root:parameter ~path:[] taint_in_taint_out model.taint_in_taint_out;
        sink_taint = BackwardState.assign ~root:parameter ~path:[] sink_taint model.sink_taint;
      }
  in
  let { Statement.Define.signature = { parameters; _ }; captures; _ } = define in
  let normalized_parameters =
    parameters
    |> AccessPath.normalize_parameters
    |> List.map ~f:(fun { AccessPath.NormalizedParameter.root; qualified_name; original } ->
           root, qualified_name, original.Node.value.Parameter.annotation)
  in
  let captures =
    List.map captures ~f:(fun capture ->
        ( AccessPath.Root.CapturedVariable { name = capture.name; user_defined = false },
          capture.name,
          None ))
  in
  List.append normalized_parameters captures
  |> List.fold ~f:split_and_simplify ~init:Model.Backward.empty


let run
    ?(profiler = TaintProfiler.none)
    ~taint_configuration
    ~pyre_api
    ~class_interval_graph
    ~global_constants
    ~qualifier
    ~callable
    ~define
    ~cfg
    ~call_graph_of_define
    ~get_callee_model
    ~existing_model
    ~triggered_sinks
    ()
  =
  let timer = Timer.start () in
  (* Apply decorators to make sure we match parameters up correctly. Decorators are not applied in
     the forward analysis, because in case a decorator changes the parameters of the decorated
     function, the user-defined models of the function may no longer be applicable to the resultant
     function of the application (e.g., T132302522). *)
  let define = PyrePysaApi.ReadOnly.decorated_define pyre_api define in
  let module FunctionContext = struct
    let qualifier = qualifier

    let definition = define

    let callable = callable

    let debug = Statement.Define.dump define.value

    let profiler = profiler

    let pyre_api = pyre_api

    let taint_configuration = taint_configuration

    let class_interval_graph = class_interval_graph

    let global_constants = global_constants

    let call_graph_of_define = call_graph_of_define

    let get_callee_model = get_callee_model

    let existing_model = existing_model

    let triggered_sinks = triggered_sinks

    let caller_class_interval =
      Interprocedural.ClassIntervalSetGraph.SharedMemory.of_definition
        class_interval_graph
        definition
  end
  in
  let module State = State (FunctionContext) in
  let module Fixpoint = Analysis.Fixpoint.Make (State) in
  let initial = State.{ taint = initial_taint } in
  let () =
    State.log "Backward analysis of callable: `%a`" Interprocedural.Target.pp_pretty callable
  in
  let entry_state =
    (* TODO(T156333229): hide side effect work behind feature flag *)
    match define.value.signature.parameters, define.value.captures with
    | [], [] ->
        (* Without parameters or captures, the inferred model will always be empty. *)
        let () =
          State.log "Skipping backward analysis since the callable has no parameters or captures"
        in
        None
    | _ ->
        TaintProfiler.track_duration ~profiler ~name:"Backward analysis - fixpoint" ~f:(fun () ->
            Alarm.with_alarm
              ~max_time_in_seconds:60
              ~event_name:"backward taint analysis"
              ~callable:(Interprocedural.Target.show_pretty callable)
              (fun () -> Fixpoint.backward ~cfg ~initial |> Fixpoint.entry)
              ())
  in
  let () =
    match entry_state with
    | Some entry_state -> State.log "Entry state:@,%a" State.pp entry_state
    | None -> State.log "No entry state found"
  in
  let apply_broadening =
    not (Model.ModeSet.contains Model.Mode.SkipModelBroadening existing_model.Model.modes)
  in
  let extract_model State.{ taint; _ } =
    let model =
      TaintProfiler.track_duration ~profiler ~name:"Backward analysis - extract model" ~f:(fun () ->
          extract_tito_and_sink_models
            ~pyre_api
            ~is_constructor:(State.is_constructor ())
            ~taint_configuration:FunctionContext.taint_configuration
            ~existing_backward:existing_model.Model.backward
            ~apply_broadening
            define.value
            taint)
    in
    let () = State.log "Backward Model:@,%a" Model.Backward.pp model in
    model
  in
  Statistics.performance
    ~randomly_log_every:1000
    ~always_log_time_threshold:1.0 (* Seconds *)
    ~name:"Backward analysis"
    ~normals:["callable", Interprocedural.Target.show_pretty callable]
    ~section:`Taint
    ~timer
    ();

  entry_state >>| extract_model |> Option.value ~default:Model.Backward.empty
