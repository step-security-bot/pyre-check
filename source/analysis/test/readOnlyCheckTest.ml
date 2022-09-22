(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open OUnit2
open Analysis
open Test
open ReadOnlyCheck

let test_less_or_equal _ =
  let open ReadOnlyness in
  let assert_less_or_equal ~expected ~left ~right =
    assert_bool_equals ~expected (less_or_equal ~left ~right)
  in
  assert_less_or_equal ~left:Mutable ~right:ReadOnly ~expected:true;
  assert_less_or_equal ~left:ReadOnly ~right:Mutable ~expected:false;
  assert_less_or_equal ~left:Mutable ~right:Mutable ~expected:true;
  assert_less_or_equal ~left:ReadOnly ~right:ReadOnly ~expected:true;
  ()


let test_join _ =
  let open ReadOnlyness in
  let assert_join ~expected left right =
    let assert_equal = assert_equal ~cmp:[%compare.equal: t] ~printer:show in
    assert_equal expected (join left right);
    assert_equal expected (join right left)
  in
  assert_join Mutable ReadOnly ~expected:ReadOnly;
  assert_join ReadOnly Mutable ~expected:ReadOnly;
  assert_join Mutable Mutable ~expected:Mutable;
  assert_join ReadOnly ReadOnly ~expected:ReadOnly;
  ()


let () = "readOnly" >::: ["less_or_equal" >:: test_less_or_equal; "join" >:: test_join] |> Test.run
