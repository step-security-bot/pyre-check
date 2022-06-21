(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

let type_check ~configuration ~environment ~source =
  let { Ast.Source.module_path = { Ast.ModulePath.qualifier; _ }; _ } = source in
  let scheduler = Scheduler.create_sequential () in
  Analysis.TypeEnvironment.populate_for_modules ~scheduler environment [qualifier];
  Analysis.Postprocessing.run
    ~scheduler
    ~configuration
    ~environment:(Analysis.TypeEnvironment.read_only environment)
    [qualifier]


let assert_type_errors = Test.assert_errors ~check:type_check ~debug:true

let assert_strict_type_errors = Test.assert_errors ~check:type_check ~debug:false ~strict:true

let assert_default_type_errors = Test.assert_errors ~check:type_check ~debug:false
