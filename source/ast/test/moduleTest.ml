(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open OUnit2
open Ast
open Test

let test_empty_stub _ =
  assert_true (Module.create_for_testing ~stub:true |> Module.empty_stub);
  assert_false (Module.create_for_testing ~stub:false |> Module.empty_stub)


let test_exports context =
  let assert_exports ?(is_stub = false) ~expected source_text =
    let actual =
      let handle = if is_stub then "test.pyi" else "test.py" in
      parse ~handle source_text |> Module.create |> Module.get_all_exports
    in
    let expected = List.sort expected ~compare:[%compare: Identifier.t * Module.Export.t] in
    assert_equal
      ~ctxt:context
      ~cmp:[%compare.equal: (Identifier.t * Module.Export.t) list]
      ~printer:(fun exports ->
        Sexp.to_string_hum [%message (exports : (Identifier.t * Module.Export.t) list)])
      expected
      actual
  in

  let open Module.Export in
  assert_exports
    {|
      import a.b
      import c.d as e
      from f.g import h
      from i.j import k as l
    |}
    ~expected:
      [
        "a", Module !&"a";
        "e", Module !&"c.d";
        "h", NameAlias { from = !&"f.g"; name = "h" };
        "l", NameAlias { from = !&"i.j"; name = "k" };
      ];
  assert_exports
    {|
      import a.b
      import c.d as e
      from f.g import h
      from i.j import k as l
    |}
    ~is_stub:true
    ~expected:["e", Module !&"c.d"; "l", NameAlias { from = !&"i.j"; name = "k" }];
  assert_exports
    {|
       from typing import Any
       def foo() -> None: pass
       def bar(x: str) -> Any:
         return x
       def __getattr__(name: str) -> Any: ...
    |}
    ~expected:
      [
        "Any", NameAlias { from = !&"typing"; name = "Any" };
        "foo", Name (Name.Define { is_getattr_any = false });
        "bar", Name (Name.Define { is_getattr_any = false });
        "__getattr__", Name (Name.Define { is_getattr_any = true });
      ];
  assert_exports
    {|
       import typing
       def __getattr__(name) -> typing.Any: ...
    |}
    ~expected:
      ["typing", Module !&"typing"; "__getattr__", Name (Name.Define { is_getattr_any = true })];
  (* Unannotated __getattr__ doesn't count *)
  assert_exports
    {|
       def __getattr__(name): ...
    |}
    ~expected:["__getattr__", Name (Name.Define { is_getattr_any = false })];
  (* __getattr__ with wrong annotations doesn't count *)
  assert_exports
    {|
       def __getattr__(name: int) -> Any: ...
    |}
    ~expected:["__getattr__", Name (Name.Define { is_getattr_any = false })];
  assert_exports
    {|
       def __getattr__(name: str) -> int: ...
    |}
    ~expected:["__getattr__", Name (Name.Define { is_getattr_any = false })];
  (* __getattr__ with wrong param count doesn't count *)
  assert_exports
    {|
       def __getattr__(name: str, value: int) -> Any: ...
    |}
    ~expected:["__getattr__", Name (Name.Define { is_getattr_any = false })];
  assert_exports
    {|
       class Bar: pass
       baz = 42
    |}
    ~expected:["Bar", Name Name.Class; "baz", Name Name.GlobalVariable];
  assert_exports
    {|
       if derp():
         x = 42
       else:
         if herp():
           y = 43
         z = 44
    |}
    ~expected:
      ["x", Name Name.GlobalVariable; "y", Name Name.GlobalVariable; "z", Name Name.GlobalVariable];
  assert_exports
    {|
       try:
         try:
           x = 42
         except:
           y = 43
       except:
         z = 43
       finally:
         w = 44
    |}
    ~expected:
      [
        "x", Name Name.GlobalVariable;
        "y", Name Name.GlobalVariable;
        "z", Name Name.GlobalVariable;
        "w", Name Name.GlobalVariable;
      ];
  assert_exports
    {|
       import foo
       foo = 42
    |} (* Last definition wins *)
    ~expected:["foo", Name Name.GlobalVariable];
  assert_exports
    {|
       if derp():
         from bar import foo
       else:
         foo = 42
    |}
    (* Unfortunately since we don't really follow control we can't really join the two. *)
    ~expected:["foo", Name Name.GlobalVariable];
  ()


let () = "module" >::: ["empty_stub" >:: test_empty_stub; "exports" >:: test_exports] |> Test.run
