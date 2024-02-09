(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open OUnit2
open Ast
open Analysis
open Expression
open Statement
open Test

let resolve_define resolution define =
  match GlobalResolution.resolve_define resolution ~implementation:(Some define) ~overloads:[] with
  | { decorated = Ok (Callable { implementation; _ }); _ } -> implementation
  | _ -> failwith "impossible"


let assert_resolved_return_annotation_equal resolution define expected_return_annotation =
  let resolved = resolve_define resolution define in
  assert_equal
    ~cmp:Type.equal
    ~printer:Type.show
    expected_return_annotation
    resolved.Type.Callable.annotation


let assert_resolved_parameters_equal resolution define expected_parameters =
  let resolved = resolve_define resolution define in
  assert_equal
    ~printer:Type.Callable.show_parameters
    ~cmp:Type.Callable.equal_parameters
    expected_parameters
    resolved.Type.Callable.parameters


let create_define ~decorators ~parameters ~return_annotation =
  {
    Define.Signature.name = !&"define";
    parameters;
    decorators;
    return_annotation;
    async = false;
    generator = false;
    parent = None;
    nesting_define = None;
  }


let test_apply_decorators context =
  let resolution = ScratchProject.setup ~context [] |> ScratchProject.build_global_resolution in
  (* Contextlib related tests *)
  assert_resolved_return_annotation_equal
    resolution
    (create_define ~decorators:[] ~parameters:[] ~return_annotation:(Some !"str"))
    Type.string;
  assert_resolved_return_annotation_equal
    resolution
    (create_define
       ~decorators:[!"contextlib.contextmanager"]
       ~parameters:[]
       ~return_annotation:
         (Some
            (+Expression.Constant (Constant.String (StringLiteral.create "typing.Iterator[str]")))))
    (Type.parametric "contextlib._GeneratorContextManager" [Single Type.string]);
  assert_resolved_return_annotation_equal
    resolution
    (create_define
       ~decorators:[!"contextlib.contextmanager"]
       ~parameters:[]
       ~return_annotation:
         (Some
            (+Expression.Constant
                (Constant.String (StringLiteral.create "typing.Generator[str, None, None]")))))
    (Type.parametric "contextlib._GeneratorContextManager" [Single Type.string]);

  let create_parameter ~name = Parameter.create ~location:Location.any ~name () in
  (* Custom decorators. *)
  assert_resolved_parameters_equal
    resolution
    (create_define
       ~decorators:[!"_strip_first_parameter_"]
       ~parameters:[create_parameter ~name:"self"; create_parameter ~name:"other"]
       ~return_annotation:None)
    (Type.Callable.Defined
       [Type.Callable.Parameter.Named { name = "other"; annotation = Type.Top; default = false }])


let () = "resolvedCallable" >::: ["apply_decorators" >:: test_apply_decorators] |> Test.run
