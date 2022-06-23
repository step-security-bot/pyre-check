(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open Ast
open Analysis

let module_of_path ~module_tracker path =
  match ModuleTracker.ReadOnly.lookup_path module_tracker path with
  | ModuleTracker.PathLookup.Found { ModulePath.qualifier; _ } -> Some qualifier
  | _ -> None


let instantiate_error
    ~build_system
    ~configuration:{ Configuration.Analysis.show_error_traces; _ }
    ~ast_environment
    error
  =
  AnalysisError.instantiate
    ~show_error_traces
    ~lookup:(PathLookup.instantiate_path ~build_system ~ast_environment)
    error


let instantiate_errors ~build_system ~configuration ~ast_environment errors =
  List.map errors ~f:(instantiate_error ~build_system ~configuration ~ast_environment)


let process_display_type_error_request
    ~configuration
    ~state:{ ServerState.errors_environment; build_system; _ }
    paths
  =
  let errors_environment = ErrorsEnvironment.read_only errors_environment in
  let module_tracker = ErrorsEnvironment.ReadOnly.module_tracker errors_environment in
  let modules =
    match paths with
    | [] -> ModuleTracker.ReadOnly.project_qualifiers module_tracker
    | _ ->
        let get_module_for_source_path path =
          let path = PyrePath.create_absolute path |> SourcePath.create in
          match BuildSystem.lookup_artifact build_system path with
          | [] -> None
          | artifact_path :: _ ->
              (* If the same source file is mapped to more than one artifact paths, all of the
                 artifact paths will likely contain the same set of type errors. It does not matter
                 which artifact path is picked.

                 NOTE (grievejia): It is possible for the type errors to differ. We may need to
                 reconsider how this is handled in the future. *)
              module_of_path ~module_tracker artifact_path
        in
        List.filter_map paths ~f:get_module_for_source_path
  in
  let errors =
    let get_type_error = ErrorsEnvironment.ReadOnly.get_errors_for_qualifier errors_environment in
    List.concat_map modules ~f:get_type_error |> List.sort ~compare:AnalysisError.compare
  in
  Response.TypeErrors
    (instantiate_errors
       errors
       ~build_system
       ~configuration
       ~ast_environment:(ErrorsEnvironment.ReadOnly.ast_environment errors_environment))


let create_info_response
    {
      ServerProperties.socket_path;
      configuration = { Configuration.Analysis.project_root; local_root; _ };
      _;
    }
  =
  Response.Info
    {
      version = Version.version ();
      pid = Unix.getpid () |> Pid.to_int;
      socket = PyrePath.absolute socket_path;
      global_root = PyrePath.show project_root;
      relative_local_root = PyrePath.get_relative_to_root ~root:project_root ~path:local_root;
    }


let process_incremental_update_request
    ~properties:({ ServerProperties.configuration; critical_files; _ } as properties)
    ~state:({ ServerState.errors_environment; subscriptions; build_system; _ } as state)
    paths
  =
  let open Lwt.Infix in
  let paths = List.map paths ~f:PyrePath.create_absolute in
  let subscriptions = ServerState.Subscriptions.all subscriptions in
  let read_only_errors_environment = ErrorsEnvironment.read_only errors_environment in
  match CriticalFile.find critical_files ~within:paths with
  | Some path ->
      let message =
        Format.asprintf
          "Pyre server needs to restart as it is notified on potential changes in `%a`"
          PyrePath.pp
          path
      in
      StartupNotification.produce ~log_path:configuration.log_directory message;
      Subscription.batch_send subscriptions ~response:(lazy (Response.Error message))
      >>= fun () -> Stop.log_and_stop_waiting_server ~reason:"critical file update" ~properties ()
  | None ->
      let source_paths = List.map paths ~f:SourcePath.create in
      let create_status_update_response status = lazy (Response.StatusUpdate status) in
      let create_type_errors_response =
        lazy
          (let errors =
             ErrorsEnvironment.ReadOnly.get_all_errors read_only_errors_environment
             |> List.sort ~compare:AnalysisError.compare
           in
           Response.TypeErrors
             (instantiate_errors
                errors
                ~build_system
                ~configuration
                ~ast_environment:
                  (ErrorsEnvironment.ReadOnly.ast_environment read_only_errors_environment)))
      in
      Subscription.batch_send
        ~response:(create_status_update_response Response.ServerStatus.Rebuilding)
        subscriptions
      >>= fun () ->
      BuildSystem.update build_system source_paths
      >>= fun changed_paths_from_rebuild ->
      Subscription.batch_send
        ~response:(create_status_update_response Response.ServerStatus.Rechecking)
        subscriptions
      >>= fun () ->
      let changed_paths =
        List.concat_map source_paths ~f:(BuildSystem.lookup_artifact build_system)
        |> List.append changed_paths_from_rebuild
        |> List.dedup_and_sort ~compare:ArtifactPath.compare
      in
      let () =
        Scheduler.with_scheduler ~configuration ~f:(fun scheduler ->
            Service.IncrementalCheck.recheck
              ~configuration
              ~scheduler
              ~environment:errors_environment
              changed_paths)
      in
      Subscription.batch_send ~response:create_type_errors_response subscriptions
      >>= fun () -> Lwt.return state


let process_request
    ~properties:({ ServerProperties.configuration; _ } as properties)
    ~state:({ ServerState.errors_environment; build_system; _ } as state)
    request
  =
  match request with
  | Request.DisplayTypeError paths ->
      let response = process_display_type_error_request ~configuration ~state paths in
      Lwt.return (state, response)
  | Request.IncrementalUpdate paths ->
      let open Lwt.Infix in
      process_incremental_update_request ~properties ~state paths
      >>= fun new_state -> Lwt.return (new_state, Response.Ok)
  | Request.Query query_text ->
      let response =
        Response.Query
          (Query.parse_and_process_request
             ~build_system
             ~environment:
               (ErrorsEnvironment.read_only errors_environment
               |> ErrorsEnvironment.ReadOnly.type_environment)
             query_text)
      in
      Lwt.return (state, response)
