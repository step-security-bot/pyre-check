(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

val infer
  :  environment:Analysis.TypeEnvironment.ReadOnly.t ->
  TaintResult.call_model Interprocedural.Target.Map.t
