(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open Pyre
open OUnit2
open Ast
open Analysis
open Statement
open Test
open ReadOnlyCheck
open ReadOnlyness

let test_forward_expression context =
  let global_resolution, type_environment =
    let source =
      {|
      from pyre_extensions import ReadOnly

      class Foo:
        readonly_attribute: ReadOnly[int]
    |}
    in
    let project = ScratchProject.setup ~context ["test.py", source] in
    ScratchProject.build_global_resolution project, ScratchProject.type_environment project
  in
  let dummy_statement_key = 0 in
  let type_resolution =
    TypeCheck.resolution_with_key
      ~global_resolution
      ~local_annotations:None
      ~parent:None
      ~statement_key:dummy_statement_key
      (* TODO(T65923817): Eliminate the need of creating a dummy context here *)
      (module TypeCheck.DummyContext)
  in
  let module Context = struct
    let qualifier = !&"test"

    let define =
      parse_single_define {|
      def foo() -> None: ...
    |}
      |> Node.create_with_default_location


    let error_map = Some (LocalErrorMap.empty ())

    let global_resolution = global_resolution

    let local_annotations =
      TypeEnvironment.TypeEnvironmentReadOnly.get_or_recompute_local_annotations
        type_environment
        (Node.value define |> Define.name)
  end
  in
  let module State = State (Context) in
  let assert_resolved
      ?(type_resolution = type_resolution)
      ?(resolution = Resolution.of_list [])
      expression
      expected_type
    =
    let { Resolved.resolved; _ } =
      parse_single_expression expression |> State.forward_expression ~type_resolution ~resolution
    in
    assert_equal ~cmp:[%compare.equal: t] ~printer:show expected_type resolved
  in
  assert_resolved "..." Mutable;
  assert_resolved "False" Mutable;
  assert_resolved "True" Mutable;
  assert_resolved "1.2" Mutable;
  assert_resolved "42" Mutable;
  assert_resolved "'hello'" Mutable;
  assert_resolved "b'hello'" Mutable;
  assert_resolved "None" Mutable;
  assert_resolved ~resolution:(Resolution.of_list [!&"x", ReadOnly]) "x" ReadOnly;
  assert_resolved ~resolution:(Resolution.of_list [!&"x", Mutable]) "x" Mutable;
  assert_resolved ~resolution:(Resolution.of_list []) "x" Mutable;
  assert_resolved ~resolution:(Resolution.of_list [!&"x", Mutable]) "x.y" Mutable;
  assert_resolved ~resolution:(Resolution.of_list [!&"x", ReadOnly]) "x.y" ReadOnly;
  assert_resolved ~resolution:(Resolution.of_list [!&"x", ReadOnly]) "x.y.z" ReadOnly;
  assert_resolved
    ~resolution:(Resolution.of_list [!&"x", Mutable])
    ~type_resolution:
      (TypeResolution.new_local
         type_resolution
         ~reference:!&"x"
         ~annotation:(Annotation.create_mutable (Type.Primitive "test.Foo")))
    "x.readonly_attribute"
    ReadOnly;
  ()


let test_check_arguments_against_parameters context =
  let open AttributeResolution in
  let open Type.Callable in
  let global_resolution, type_environment =
    let project = ScratchProject.setup ~context [] in
    ScratchProject.build_global_resolution project, ScratchProject.type_environment project
  in
  let module Context = struct
    let qualifier = !&"test"

    let define =
      parse_single_define {|
      def foo() -> None: ...
    |}
      |> Node.create_with_default_location


    let error_map = Some (LocalErrorMap.empty ())

    let global_resolution = global_resolution

    let local_annotations =
      TypeEnvironment.TypeEnvironmentReadOnly.get_or_recompute_local_annotations
        type_environment
        (Node.value define |> Define.name)
  end
  in
  let module State = State (Context) in
  let assert_arguments_against_parameters ~parameter_argument_mapping expected_error_kinds =
    let actual_error_kinds =
      State.check_arguments_against_parameters ~function_name:None parameter_argument_mapping
      |> List.map ~f:(function
             | { Error.kind = Error.ReadOnlynessMismatch mismatch; _ } -> mismatch
             | _ -> failwith "Expected ReadOnlyness mismatch")
    in
    assert_equal
      ~printer:[%show: Error.ReadOnly.readonlyness_mismatch list]
      ~cmp:[%compare.equal: Error.ReadOnly.readonlyness_mismatch list]
      expected_error_kinds
      actual_error_kinds
  in
  assert_arguments_against_parameters
    ~parameter_argument_mapping:
      (Parameter.Map.of_alist_exn
         [
           ( Named { name = "x"; annotation = Type.string; default = false },
             [
               make_matched_argument
                 {
                   Argument.WithPosition.resolved = ReadOnlyness.ReadOnly;
                   kind = Positional;
                   expression = None;
                   position = 1;
                 };
             ] );
           Named { name = "y"; annotation = Type.integer; default = false }, [Default];
         ])
    [
      IncompatibleParameterType
        {
          name = None;
          position = 1;
          callee = None;
          mismatch = { actual = ReadOnlyness.ReadOnly; expected = ReadOnlyness.Mutable };
        };
    ];
  assert_arguments_against_parameters
    ~parameter_argument_mapping:
      (Parameter.Map.of_alist_exn
         [
           ( Named { name = "y"; annotation = Type.integer; default = false },
             [
               make_matched_argument
                 {
                   Argument.WithPosition.resolved = ReadOnlyness.ReadOnly;
                   kind = Named (Node.create_with_default_location "y");
                   expression = None;
                   position = 1;
                 };
             ] );
         ])
    [
      IncompatibleParameterType
        {
          name = Some "y";
          position = 1;
          callee = None;
          mismatch = { actual = ReadOnlyness.ReadOnly; expected = ReadOnlyness.Mutable };
        };
    ];
  ()


let test_callable_data_list_for_callee context =
  let open AttributeResolution in
  let source =
    {|
    def foo(x: int) -> None: ...
    def bar(y: str) -> bool: ...

    my_union = foo if 1 + 1 == 2 else bar
  |}
  in
  let global_resolution =
    ScratchProject.setup ~context ["test.py", source] |> ScratchProject.build_global_resolution
  in
  let assert_callable_data_list ~callee expected_callable_data_list =
    let callee_type =
      Option.value_exn
        ~message:"Expected a valid global"
        (GlobalResolution.global global_resolution callee
        >>| fun { Global.annotation; _ } -> Annotation.annotation annotation)
    in
    assert_equal
      ~printer:[%show: callable_data_for_function_call list]
      ~cmp:[%compare.equal: callable_data_for_function_call list]
      expected_callable_data_list
      (callable_data_list_for_callee callee_type)
  in
  assert_callable_data_list
    ~callee:!&"test.foo"
    [
      {
        selected_signature =
          {
            annotation = Type.none;
            parameters =
              Defined [Named { name = "$parameter$x"; annotation = Type.integer; default = false }];
          };
        instantiated_return_type = Type.none;
        function_name = Some !&"test.foo";
      };
    ];
  (* TODO(T130377746): Support union types. *)
  assert_callable_data_list ~callee:!&"test.my_union" [];
  ()


let assert_readonly_errors ~context =
  let check ~environment ~source =
    source
    |> Preprocessing.defines ~include_toplevels:true
    |> List.concat_map
         ~f:
           (ReadOnlyCheck.readonly_errors_for_define
              ~type_environment:(TypeEnvironment.read_only environment)
              ~qualifier:!&"test")
  in
  assert_errors ~context ~check


let test_assignment context =
  let assert_readonly_errors = assert_readonly_errors ~context in
  assert_readonly_errors
    {|
      from pyre_extensions import ReadOnly

      def main() -> None:
        x: ReadOnly[int] = 42
        y = x
        z: int = y
    |}
    [
      "ReadOnly violation - Incompatible variable type [3001]: z is declared to have readonlyness \
       `ReadOnlyness.Mutable` but is used as readonlyness `ReadOnlyness.ReadOnly`.";
    ];
  assert_readonly_errors
    {|
      from pyre_extensions import ReadOnly

      def main() -> None:
        x = 42
        y = x
        z: ReadOnly[int] = y
    |}
    [];
  (* Treat constants, such as `42` or `...`, as assignable to mutable types. *)
  assert_readonly_errors
    {|
      from pyre_extensions import ReadOnly

      class Foo:
        # This is treated as `some_attribute: int = ...`.
        some_attribute: int

      def main() -> None:
        x: int = 42
    |}
    [];
  assert_readonly_errors
    {|
      from pyre_extensions import ReadOnly

      def expect_mutable_and_readonly(x: int, y: ReadOnly[int]) -> ReadOnly[int]: ...

      def main() -> None:
        x: ReadOnly[int] = 42
        y: int = expect_mutable_and_readonly(x, x)
    |}
    [
      "ReadOnly violation - Incompatible variable type [3001]: y is declared to have readonlyness \
       `ReadOnlyness.Mutable` but is used as readonlyness `ReadOnlyness.ReadOnly`.";
      "ReadOnly violation - Incompatible parameter type [3002]: In call \
       `test.expect_mutable_and_readonly`, for 1st positional only parameter expected \
       `ReadOnlyness.Mutable` but got `ReadOnlyness.ReadOnly`.";
    ];
  assert_readonly_errors
    {|
      from pyre_extensions import ReadOnly

      def foo(x: int) -> ReadOnly[int]: ...

      def main(x: int) -> None:
        y: int = foo(foo(x))
    |}
    [
      "ReadOnly violation - Incompatible variable type [3001]: y is declared to have readonlyness \
       `ReadOnlyness.Mutable` but is used as readonlyness `ReadOnlyness.ReadOnly`.";
      "ReadOnly violation - Incompatible parameter type [3002]: In call `test.foo`, for 1st \
       positional only parameter expected `ReadOnlyness.Mutable` but got `ReadOnlyness.ReadOnly`.";
    ];
  assert_readonly_errors
    {|
      from pyre_extensions import ReadOnly

      class Foo:
        mutable_attribute: int

      def main() -> None:
        readonly_foo: ReadOnly[Foo]
        mutable_foo: Foo

        x1: int = readonly_foo.mutable_attribute
        x2: int = mutable_foo.mutable_attribute
    |}
    [
      "ReadOnly violation - Incompatible variable type [3001]: x1 is declared to have readonlyness \
       `ReadOnlyness.Mutable` but is used as readonlyness `ReadOnlyness.ReadOnly`.";
    ];
  assert_readonly_errors
    {|
      from pyre_extensions import ReadOnly

      class Bar:
        bar_attribute: int

      class Foo:
        foo_attribute: Bar

      def main() -> None:
        readonly_foo: ReadOnly[Foo]
        mutable_foo: Foo

        x1: int = readonly_foo.foo_attribute.bar_attribute
        x2: int = mutable_foo.foo_attribute.bar_attribute
    |}
    [
      "ReadOnly violation - Incompatible variable type [3001]: x1 is declared to have readonlyness \
       `ReadOnlyness.Mutable` but is used as readonlyness `ReadOnlyness.ReadOnly`.";
    ];
  assert_readonly_errors
    {|
      from pyre_extensions import ReadOnly

      class Foo:
        readonly_attribute: ReadOnly[int]

      def main() -> None:
        readonly_foo: ReadOnly[Foo]
        mutable_foo: Foo

        x1: int = readonly_foo.readonly_attribute
        x2: int = mutable_foo.readonly_attribute
    |}
    [
      "ReadOnly violation - Incompatible variable type [3001]: x2 is declared to have readonlyness \
       `ReadOnlyness.Mutable` but is used as readonlyness `ReadOnlyness.ReadOnly`.";
      "ReadOnly violation - Incompatible variable type [3001]: x1 is declared to have readonlyness \
       `ReadOnlyness.Mutable` but is used as readonlyness `ReadOnlyness.ReadOnly`.";
    ];
  ()


let () =
  "readOnly"
  >::: [
         "forward_expression" >:: test_forward_expression;
         "check_arguments_against_parameters" >:: test_check_arguments_against_parameters;
         "callable_data_list_for_callee" >:: test_callable_data_list_for_callee;
         "assignment" >:: test_assignment;
       ]
  |> Test.run
