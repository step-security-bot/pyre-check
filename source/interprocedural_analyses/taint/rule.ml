(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core

type t = {
  sources: Sources.t list;
  sinks: Sinks.t list;
  transforms: TaintTransform.t list;
  code: int;
  name: string;
  message_format: string; (* format *)
}
[@@deriving compare, show]
