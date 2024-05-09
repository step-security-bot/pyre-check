(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** Type-safe versions of the channels in Stdlib. *)

type 'a in_channel
type 'a out_channel
type ('in_, 'out) channel_pair = 'in_ in_channel * 'out out_channel

val to_channel :
  'a out_channel ->
  ?flags:Marshal.extern_flags list ->
  ?flush:bool ->
  'a -> unit

val from_channel : 'a in_channel -> 'a

val flush : 'a out_channel -> unit

(* This breaks the type safety, but is necessary in order to allow select() *)
val descr_of_in_channel : 'a in_channel -> Unix.file_descr
val descr_of_out_channel : 'a out_channel -> Unix.file_descr
val cast_in : 'a in_channel -> Stdlib.in_channel
val cast_out : 'a out_channel -> Stdlib.out_channel

val close_out : 'a out_channel -> unit
val output_string : 'a out_channel -> string -> unit

val close_in : 'a in_channel -> unit
val input_char : 'a in_channel -> char
val input_value : 'a in_channel -> 'b

(** Spawning new process *)

(* Handler upon spawn and forked process. *)
type ('in_, 'out) handle = {
  channels : ('in_, 'out) channel_pair;
  pid : int;
}

(* Fork and run a function that communicates via the typed channels *)
val fork :
  (* Where the daemon's output should go *)
  (Unix.file_descr * Unix.file_descr) ->
  ('param -> ('input, 'output) channel_pair -> unit) ->
  'param ->
  ('output, 'input) handle

(* Close the typed channels associated to a 'spawned' child. *)
val close : ('a, 'b) handle -> unit

(* Kill a 'spawned' child and close the associated typed channels. *)
val kill : ('a, 'b) handle -> unit

(* Kill a 'spawned' child and close the associated typed channels, then wait for its termination. *)
(* Unlike `kill`, this API makes sure the terminated children do not become zombie processes. *)
val kill_and_wait : ('a, 'b) handle -> unit
