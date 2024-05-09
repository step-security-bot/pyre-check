(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* TODO(T132410158) Add a module-level doc comment. *)


module List = Core.List
module Exit_status = Hack_utils.Exit_status
module Measure = Hack_utils.Measure
module PrintSignal = Hack_utils.PrintSignal
module String_utils = Hack_utils.String_utils
open Hack_heap

(*****************************************************************************
 * Module building workers
 *
 * A worker is a subprocess executing an arbitrary function
 *
 * You should first create a fixed amount of workers and then use those
 * because the amount of workers is limited and to make the load-balancing
 * of tasks better (cf multiWorker.ml)
 *
 * On Unix, we "spawn" workers when initializing Hack. Then, this
 * worker, "fork" an ephemeral worker for each incoming request. The forked
 * wephemeral worker will die after processing a single request. (We use this
 * two-layer architecture because, *if* the long-lived worker was created when the
 * original process was still very small, those forks run much faster than forking
 * off the original process which will eventually have a large heap).
 *
 * A worker never handle more than one request at a time.
 *
 *****************************************************************************)

exception Worker_exited_abnormally of int * Unix.process_status
exception Worker_exception of string * Printexc.raw_backtrace
exception Worker_oomed
exception Worker_busy
exception Worker_killed

type send_job_failure =
  | Worker_already_exited of Unix.process_status
  | Other_send_job_failure of exn

exception Worker_failed_to_send_job of send_job_failure

(* The maximum amount of workers *)
let max_workers = 1000



(*****************************************************************************
 * The job executed by the worker.
 *
 * The 'serializer' is the job continuation: it is a function that must
 * be called at the end of the request in order to send back the result
 * to the master (this is "internal business", this is not visible outside
 * this module). The ephemeral worker will provide the expected function.
 * cf 'send_result' in 'ephemeral_worker_main'.
 *
 *****************************************************************************)

type request = Request of (serializer -> unit)
and serializer = { send: 'a. 'a -> unit }

(*****************************************************************************
 * Everything we need to know about a worker.
 *
 *****************************************************************************)

type t = {
  (* Sanity check: is the worker still available ? *)
  mutable killed: bool;

  (* Sanity check: is the worker currently busy ? *)
  mutable busy: bool;

  pid: int;
  ic: in_channel;
  oc: out_channel;

  (* File descriptor corresponding to ic, used for `select`. *)
  infd: Unix.file_descr;
}



(*****************************************************************************
 * The handle is what we get back when we start a job. It's a "future"
 * (sometimes called a "promise"). The scheduler uses the handle to retrieve
 * the result of the job when the task is done (cf multiWorker.ml).
 *
 *****************************************************************************)

type 'a handle = 'a delayed ref

and 'a delayed =
  | Processing of 'a ephemeral_worker
  | Cached of 'a
  | Failed of exn

and 'a ephemeral_worker = {
  worker: t;      (* The associated worker *)

  (* A blocking function that returns the job result. *)
  result: unit -> 'a;
}

module Response = struct
  type 'a t =
    | Success of { result: 'a; stats: Measure.record_data }
    | Failure of { exn: string; backtrace: Printexc.raw_backtrace }
end


(*****************************************************************************
 * Entry point for spawned worker.
 *
 *****************************************************************************)

let ephemeral_worker_main ic oc =
  let start_user_time = ref 0.0 in
  let start_system_time = ref 0.0 in
  let send_response response =
    let s = Marshal.to_string response [Marshal.Closures] in
    output_string oc s;
    flush oc
  in
  let send_result result =
    let tm = Unix.times () in
    let end_user_time = tm.Unix.tms_utime +. tm.Unix.tms_cutime in
    let end_system_time = tm.Unix.tms_stime +. tm.Unix.tms_cstime in
    Measure.sample "worker_user_time" (end_user_time -. !start_user_time);
    Measure.sample "worker_system_time" (end_system_time -. !start_system_time);

    let stats = Measure.serialize (Measure.pop_global ()) in
    send_response (Response.Success { result; stats })
  in
  try
    Measure.push_global ();
    let Request do_process = Marshal.from_channel ic in
    let tm = Unix.times () in
    start_user_time := tm.Unix.tms_utime +. tm.Unix.tms_cutime;
    start_system_time := tm.Unix.tms_stime +. tm.Unix.tms_cstime;
    do_process { send = send_result };
    exit 0
  with
  | End_of_file ->
      exit 1
  | SharedMemory.Out_of_shared_memory ->
      Exit_status.(exit Out_of_shared_memory)
  | SharedMemory.Hash_table_full ->
      Exit_status.(exit Hash_table_full)
  | SharedMemory.Heap_full ->
      Exit_status.(exit Heap_full)
  | SharedMemory.Sql_assertion_failure err_num ->
      let exit_code = match err_num with
        | 11 -> Exit_status.Sql_corrupt
        | 14 -> Exit_status.Sql_cantopen
        | 21 -> Exit_status.Sql_misuse
        | _ -> Exit_status.Sql_assertion_failure
      in
      Exit_status.exit exit_code
  | exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      send_response (Response.Failure { exn = Base.Exn.to_string exn; backtrace });
      exit 0

let worker_main restore state infd outfd =
  restore state;
  let ic = Unix.in_channel_of_descr infd in
  let oc = Unix.out_channel_of_descr outfd in
  try
    while true do
      (* Wait for an incoming job : is there something to read?
         But we don't read it yet. It will be read by the forked ephemeral worker. *)
      let readyl, _, _ = Unix.select [infd] [] [] (-1.0) in
      if readyl = [] then exit 0;
      (* We fork an ephemeral worker for every incoming request.
         And let it die after one request. This is the quickest GC. *)
      match Unix.fork () with
      | 0 -> ephemeral_worker_main ic oc
      | pid ->
          (* Wait for the ephemeral worker termination... *)
          match snd (Unix.waitpid [] pid) with
          | Unix.WEXITED 0 -> ()
          | Unix.WEXITED 1 ->
              raise End_of_file
          | Unix.WEXITED code ->
              Printf.printf "Worker exited (code: %d)\n" code;
              flush stdout;
              Stdlib.exit code
          | Unix.WSIGNALED x ->
              let sig_str = PrintSignal.string_of_signal x in
              Printf.printf "Worker interrupted with signal: %s\n" sig_str;
              exit 2
          | Unix.WSTOPPED x ->
              Printf.printf "Worker stopped with signal: %d\n" x;
              exit 3
    done;
    assert false
  with End_of_file -> exit 0

(**************************************************************************
 * Creates a pool of workers.
 *
 **************************************************************************)


let current_worker_id = ref 0

(** Make a few workers. *)
let make ~nbr_procs ~gc_control ~heap_handle =
  if nbr_procs <= 0 then invalid_arg "Number of workers must be positive";
  if nbr_procs >= max_workers then failwith "Too many workers";
  let restore worker_id =
    current_worker_id := worker_id;
    SharedMemory.connect heap_handle;
    Gc.set gc_control
  in
  let fork worker_id =
    let parent_in, child_out = Unix.pipe () in
    let child_in, parent_out = Unix.pipe () in
    match Unix.fork () with
    | 0 ->
      Unix.close parent_in;
      Unix.close parent_out;
      worker_main restore worker_id child_in child_out
    | pid ->
      Unix.close child_in;
      Unix.close child_out;
      let ic = Unix.in_channel_of_descr parent_in in
      let oc = Unix.out_channel_of_descr parent_out in
      { busy = false; killed = false; pid; infd = parent_in; ic; oc }
  in
  let rec loop acc n =
    if n = 0 then acc
    else
      let worker = fork n in
      loop (worker :: acc) (n - 1)
  in
  (* Flush any buffers before forking workers, to avoid double output. *)
  flush_all ();
  loop [] nbr_procs

let current_worker_id () = !current_worker_id

(**************************************************************************
 * Send a job to a worker
 *
 **************************************************************************)

let call w (type a) (type b) (f : a -> b) (x : a) : b handle =
  if w.killed then raise Worker_killed;
  if w.busy then raise Worker_busy;
  (* Prepare ourself to read answer from the ephemeral_worker. *)
  let result () : b =
    match Marshal.from_channel w.ic with
    | Response.Success { result; stats } ->
      Measure.merge ~from:(Measure.deserialize stats) ();
      result
    | Response.Failure { exn; backtrace } ->
      raise (Worker_exception (exn, backtrace))
    | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      match Unix.waitpid [Unix.WNOHANG] w.pid with
      | 0, _ -> Printexc.raise_with_backtrace exn backtrace
      | _, Unix.WEXITED i when i = Exit_status.(exit_code Out_of_shared_memory) ->
          raise SharedMemory.Out_of_shared_memory
      | _, exit_status ->
          raise (Worker_exited_abnormally (w.pid, exit_status))
  in
  (* Mark the worker as busy. *)
  let ephemeral_worker = { result; worker = w; } in
  w.busy <- true;
  let request =
    Request (fun { send } -> send (f x))
  in
  (* Send the job to the ephemeral worker. *)
  let () =
    try
      Marshal.to_channel w.oc request [Marshal.Closures];
      flush w.oc
    with e ->
      match Unix.waitpid [Unix.WNOHANG] w.pid with
      | 0, _ ->
          raise (Worker_failed_to_send_job (Other_send_job_failure e))
      | _, status ->
          raise (Worker_failed_to_send_job (Worker_already_exited status))
  in
  (* And returned the 'handle'. *)
  ref (Processing ephemeral_worker)


(**************************************************************************
 * Read results from a handle.
 * This might block if the worker hasn't finished yet.
 *
 **************************************************************************)

let is_oom_failure msg =
  (String_utils.string_starts_with msg "Subprocess") &&
  (String_utils.is_substring "signaled -7" msg)

let get_result d =
  match !d with
  | Cached x -> x
  | Failed exn -> raise exn
  | Processing s ->
      try
        let res = s.result () in
        s.worker.busy <- false;
        d := Cached res;
        res
      with
      | Failure (msg) when is_oom_failure msg ->
          raise Worker_oomed
      | exn ->
          s.worker.busy <- false;
          d := Failed exn;
          raise exn


(*****************************************************************************
 * Our polling primitive on workers
 * Given a list of handle, returns the ones that are ready.
 *
 *****************************************************************************)

type 'a selected = {
  readys: 'a handle list;
  waiters: 'a handle list;
}

let get_processing ds =
  List.rev_filter_map
    ds
    ~f:(fun d -> match !d with Processing p -> Some p | _ -> None)

let select ds =
  let processing = get_processing ds in
  let fds = List.map ~f:(fun p -> p.worker.infd) processing in
  let ready_fds, _, _ =
    if fds = [] || List.length processing <> List.length ds then
      [], [], []
    else
      Unix.select fds [] [] ~-.1. in
  List.fold_right
    ~f:(fun d { readys ; waiters } ->
        match !d with
        | Cached _ | Failed _ ->
            { readys = d :: readys ; waiters }
        | Processing s when List.mem ~equal:(=) ready_fds s.worker.infd ->
            { readys = d :: readys ; waiters }
        | Processing _ ->
            { readys ; waiters = d :: waiters})
    ~init:{ readys = [] ; waiters = [] }
    ds

let get_worker h =
  match !h with
  | Processing {worker; _} -> worker
  | Cached _
  | Failed _ -> invalid_arg "Worker.get_worker"

(**************************************************************************
 * Worker termination
 **************************************************************************)

let kill w =
  if not w.killed then begin
    w.killed <- true;
    close_in w.ic;
    close_out w.oc;
    Unix.kill w.pid Sys.sigkill;
    let rec waitpid () =
      try ignore (Unix.waitpid [] w.pid)
      with Unix.Unix_error (Unix.EINTR, _, _) -> waitpid ()
    in
    waitpid ()
  end

let exception_backtrace = function
  | Worker_exception (_, backtrace) -> backtrace
  | _ -> Printexc.get_raw_backtrace ()
