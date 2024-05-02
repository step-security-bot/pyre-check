(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2
open Test
open Ast.Expression

let expression_location_insensitive_equal left right =
  Expression.location_insensitive_compare left right |> Int.equal 0


let expression_print_to_sexp expression = Base.Sexp.to_string_hum (Expression.sexp_of_t expression)

let assert_parsed ~expected text _context =
  let open Ast.Statement in
  let check_ast (actual_ast : Ast.Statement.t list) =
    match Base.List.hd actual_ast with
    | Some { Ast.Node.value; _ } -> (
        match value with
        | Statement.Expression as_first_expression ->
            assert_equal
              ~cmp:expression_location_insensitive_equal
              ~printer:expression_print_to_sexp
              expected
              as_first_expression
        | _ ->
            let message =
              Stdlib.Format.asprintf
                "expected expression to be parsed but got: %a"
                Base.Sexp.pp_hum
                (Statement.sexp_of_statement value)
            in
            assert_failure message)
    | None ->
        let open Base in
        assert_failure
          (Printf.sprintf
             "expected parse result. expected %s but got %s"
             (expression_print_to_sexp expected)
             (Base.Sexp.to_string ([%sexp_of: Ast.Statement.t list] actual_ast)))
  in
  match PyreErrpyParser.parse_module text with
  | Result.Error error -> (
      match error with
      | PyreErrpyParser.ParserError.Recoverable recoverable -> check_ast recoverable.recovered_ast
      | PyreErrpyParser.ParserError.Unrecoverable message ->
          let message = Stdlib.Format.sprintf "Unexpected parsing failure: %s" message in
          assert_failure message)
  | Result.Ok actual_ast -> check_ast actual_ast


let assert_not_parsed text _context =
  match PyreErrpyParser.parse_module text with
  | Result.Ok _ ->
      let message = Stdlib.Format.asprintf "Unexpected parsing success of input: %s" text in
      assert_failure message
  | Result.Error error -> (
      match error with
      | PyreErrpyParser.ParserError.Recoverable _ -> ()
      | PyreErrpyParser.ParserError.Unrecoverable message ->
          let message = Stdlib.Format.sprintf "Unexpected errpy stacktrace thrown: %s" message in
          assert_failure message)


let test_name =
  let assert_parsed = assert_parsed in
  let assert_not_parsed = assert_not_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "x" ~expected:(+Expression.Name (Name.Identifier "x"));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "x1" ~expected:(+Expression.Name (Name.Identifier "x1"));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "x_y" ~expected:(+Expression.Name (Name.Identifier "x_y"));
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "$x";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "1x";
    ]


let test_attribute =
  let assert_parsed = assert_parsed in
  let assert_not_parsed = assert_not_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a.b"
           ~expected:
             (+Expression.Name
                 (Name.Attribute { Name.Attribute.base = !"a"; attribute = "b"; special = false }));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a  .  b"
           ~expected:
             (+Expression.Name
                 (Name.Attribute { Name.Attribute.base = !"a"; attribute = "b"; special = false }));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a.b.c"
           ~expected:
             (+Expression.Name
                 (Name.Attribute
                    {
                      Name.Attribute.base =
                        +Expression.Name
                           (Name.Attribute
                              { Name.Attribute.base = !"a"; attribute = "b"; special = false });
                      attribute = "c";
                      special = false;
                    }));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "1.0.b"
           ~expected:
             (+Expression.Name
                 (Name.Attribute
                    {
                      Name.Attribute.base = +Expression.Constant (Constant.Float 1.0);
                      attribute = "b";
                      special = false;
                    }));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a."
           ~expected:
             (+Expression.Name
                 (Name.Attribute { Name.Attribute.base = !"a"; attribute = ""; special = false }));
      (*TODO (T148669698): assert_not_parsed "a.async"; *)
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "a.1";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "1 .0 .a";
      (* TODO (T164371654): fix parsing issues *)
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "Foo().";
    ]


let test_constant =
  let assert_parsed = assert_parsed in
  let assert_not_parsed = assert_not_parsed in

  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "None" ~expected:(+Expression.Constant Constant.NoneLiteral);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "False" ~expected:(+Expression.Constant Constant.False);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "True" ~expected:(+Expression.Constant Constant.True);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "..." ~expected:(+Expression.Constant Constant.Ellipsis);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "1" ~expected:(+Expression.Constant (Constant.Integer 1));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "-1" ~expected:(+Expression.Constant (Constant.Integer (-1)));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "+1" ~expected:(+Expression.Constant (Constant.Integer 1));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "0" ~expected:(+Expression.Constant (Constant.Integer 0));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "00" ~expected:(+Expression.Constant (Constant.Integer 0));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "00_0" ~expected:(+Expression.Constant (Constant.Integer 0));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "0x1" ~expected:(+Expression.Constant (Constant.Integer 0x1));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "1_01" ~expected:(+Expression.Constant (Constant.Integer 101));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "(1)" ~expected:(+Expression.Constant (Constant.Integer 1));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "((1))" ~expected:(+Expression.Constant (Constant.Integer 1));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "0XaBc" ~expected:(+Expression.Constant (Constant.Integer 0xABC));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "0o13" ~expected:(+Expression.Constant (Constant.Integer 0o13));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "0b01" ~expected:(+Expression.Constant (Constant.Integer 0b01));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "0b0_1" ~expected:(+Expression.Constant (Constant.Integer 0b01));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "0b_0_1" ~expected:(+Expression.Constant (Constant.Integer 0b01));
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "1L";
      (*TODO (T148669698): assert_not_parsed "01";*)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "1.0" ~expected:(+Expression.Constant (Constant.Float 1.0));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "1_0.1_01" ~expected:(+Expression.Constant (Constant.Float 10.101));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed ".1" ~expected:(+Expression.Constant (Constant.Float 0.1));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "1." ~expected:(+Expression.Constant (Constant.Float 1.0));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "1e10" ~expected:(+Expression.Constant (Constant.Float 1e10));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "0.1j" ~expected:(+Expression.Constant (Constant.Complex 0.1));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "1e10j" ~expected:(+Expression.Constant (Constant.Complex 1e10));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "1e1_0j" ~expected:(+Expression.Constant (Constant.Complex 1e10));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "2j" ~expected:(+Expression.(Constant (Constant.Complex 2.0)));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "2J" ~expected:(+Expression.(Constant (Constant.Complex 2.0)));
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "0xZ";
      (*TODO (T148669698): assert_not_parsed "0_1";*)
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "0o9";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "1a3";
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "'foo'"
           ~expected:(+Expression.Constant (Constant.String (StringLiteral.create "foo")));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "'''docstring \"using single-quotes\" rest of docstring'''"
           ~expected:
             (+Expression.Constant
                 (Constant.String
                    (StringLiteral.create "docstring \"using single-quotes\" rest of docstring")));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "\"\"\"docstring 'using single-quotes' rest of docstring\"\"\""
           ~expected:
             (+Expression.Constant
                 (Constant.String
                    (StringLiteral.create "docstring 'using single-quotes' rest of docstring")));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "\"foo\""
           ~expected:(+Expression.Constant (Constant.String (StringLiteral.create "foo")));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "'''foo'''"
           ~expected:(+Expression.Constant (Constant.String (StringLiteral.create "foo")));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "\"\"\"foo\"\"\""
           ~expected:(+Expression.Constant (Constant.String (StringLiteral.create "foo")));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "r'foo'"
           ~expected:(+Expression.Constant (Constant.String (StringLiteral.create "foo")));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "R'foo'"
           ~expected:(+Expression.Constant (Constant.String (StringLiteral.create "foo")));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "b'foo'"
           ~expected:
             (+Expression.Constant (Constant.String (StringLiteral.create ~bytes:true "foo")));
      (* TODO (T164893550): assert_parsed "u'foo'" ~expected:(+Expression.Constant (Constant.String
         (StringLiteral.create "foo")));*)
      (* TODO (T164893550): assert_parsed "bR'foo'" ~expected:(+Expression.Constant (Constant.String
         (StringLiteral.create ~bytes:true "foo"))); *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "'foo' 'bar'"
           ~expected:(+Expression.Constant (Constant.String (StringLiteral.create "foobar")));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "\"'\""
           ~expected:(+Expression.Constant (Constant.String (StringLiteral.create "'")));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "'\"'"
           ~expected:(+Expression.Constant (Constant.String (StringLiteral.create "\"")));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "'''\n something \n'''"
           ~expected:
             (+Expression.Constant (Constant.String (StringLiteral.create "\n something \n")));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "\"\\\"\""
           ~expected:(+Expression.Constant (Constant.String (StringLiteral.create "\"")));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "\"\\'\""
           ~expected:(+Expression.Constant (Constant.String (StringLiteral.create "'")));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "\"\"\"\nfoo\"\"\""
           ~expected:(+Expression.Constant (Constant.String (StringLiteral.create "\nfoo")));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "\"f.o\\no\""
           ~expected:(+Expression.Constant (Constant.String (StringLiteral.create "f.o\no")));
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "ub'foo'";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "ur'foo'";
    ]


let test_unary_operators =
  let assert_parsed = assert_parsed in
  let assert_not_parsed = assert_not_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "not x"
           ~expected:
             (+Expression.UnaryOperator
                 { UnaryOperator.operator = UnaryOperator.Not; operand = !"x" });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "~x"
           ~expected:
             (+Expression.UnaryOperator
                 { UnaryOperator.operator = UnaryOperator.Invert; operand = !"x" });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "+x"
           ~expected:
             (+Expression.UnaryOperator
                 { UnaryOperator.operator = UnaryOperator.Positive; operand = !"x" });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "-x"
           ~expected:
             (+Expression.UnaryOperator
                 { UnaryOperator.operator = UnaryOperator.Negative; operand = !"x" });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "+-x"
           ~expected:
             (+Expression.UnaryOperator
                 {
                   UnaryOperator.operator = UnaryOperator.Positive;
                   operand =
                     +Expression.UnaryOperator
                        { UnaryOperator.operator = UnaryOperator.Negative; operand = !"x" };
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "not ~x"
           ~expected:
             (+Expression.UnaryOperator
                 {
                   UnaryOperator.operator = UnaryOperator.Not;
                   operand =
                     +Expression.UnaryOperator
                        { UnaryOperator.operator = UnaryOperator.Invert; operand = !"x" };
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "-(not x)"
           ~expected:
             (+Expression.UnaryOperator
                 {
                   UnaryOperator.operator = UnaryOperator.Negative;
                   operand =
                     +Expression.UnaryOperator
                        { UnaryOperator.operator = UnaryOperator.Not; operand = !"x" };
                 });
      (* `not` has higher precedence than `and`/`or` *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "not x and y"
           ~expected:
             (+Expression.BooleanOperator
                 {
                   BooleanOperator.left =
                     +Expression.UnaryOperator
                        { UnaryOperator.operator = UnaryOperator.Not; operand = !"x" };
                   operator = BooleanOperator.And;
                   right = !"y";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "not x or y"
           ~expected:
             (+Expression.BooleanOperator
                 {
                   BooleanOperator.left =
                     +Expression.UnaryOperator
                        { UnaryOperator.operator = UnaryOperator.Not; operand = !"x" };
                   operator = BooleanOperator.Or;
                   right = !"y";
                 });
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "not";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "x not";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "x~";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "x+";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "x-";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "+ not x";
    ]


let test_boolean_operators =
  let assert_parsed = assert_parsed in
  let assert_not_parsed = assert_not_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "True and False"
           ~expected:
             (+Expression.BooleanOperator
                 {
                   BooleanOperator.left = +Expression.Constant Constant.True;
                   operator = BooleanOperator.And;
                   right = +Expression.Constant Constant.False;
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "True or False"
           ~expected:
             (+Expression.BooleanOperator
                 {
                   BooleanOperator.left = +Expression.Constant Constant.True;
                   operator = BooleanOperator.Or;
                   right = +Expression.Constant Constant.False;
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "1 and 2 and 3"
           ~expected:
             (+Expression.BooleanOperator
                 {
                   BooleanOperator.left =
                     +Expression.BooleanOperator
                        {
                          BooleanOperator.left = +Expression.Constant (Constant.Integer 1);
                          operator = BooleanOperator.And;
                          right = +Expression.Constant (Constant.Integer 2);
                        };
                   operator = BooleanOperator.And;
                   right = +Expression.Constant (Constant.Integer 3);
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "1 or 2 or 3"
           ~expected:
             (+Expression.BooleanOperator
                 {
                   BooleanOperator.left =
                     +Expression.BooleanOperator
                        {
                          BooleanOperator.left = +Expression.Constant (Constant.Integer 1);
                          operator = BooleanOperator.Or;
                          right = +Expression.Constant (Constant.Integer 2);
                        };
                   operator = BooleanOperator.Or;
                   right = +Expression.Constant (Constant.Integer 3);
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "1 and 2 or 3"
           ~expected:
             (+Expression.BooleanOperator
                 {
                   BooleanOperator.left =
                     +Expression.BooleanOperator
                        {
                          BooleanOperator.left = +Expression.Constant (Constant.Integer 1);
                          operator = BooleanOperator.And;
                          right = +Expression.Constant (Constant.Integer 2);
                        };
                   operator = BooleanOperator.Or;
                   right = +Expression.Constant (Constant.Integer 3);
                 });
      (* `and` has higher precedence than `or` *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "1 or 2 and 3"
           ~expected:
             (+Expression.BooleanOperator
                 {
                   BooleanOperator.left = +Expression.Constant (Constant.Integer 1);
                   operator = BooleanOperator.Or;
                   right =
                     +Expression.BooleanOperator
                        {
                          BooleanOperator.left = +Expression.Constant (Constant.Integer 2);
                          operator = BooleanOperator.And;
                          right = +Expression.Constant (Constant.Integer 3);
                        };
                 });
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "and";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "or";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "and or";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "True and";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "and True";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "True or";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "or True";
    ]


let test_await_yield =
  let assert_parsed = assert_parsed in
  (*let assert_not_parsed = assert_not_parsed in*)
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "await x" ~expected:(+Expression.Await !"x");
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "(yield)" ~expected:(+Expression.Yield None);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "(yield 1)"
           ~expected:(+Expression.Yield (Some (+Expression.Constant (Constant.Integer 1))));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "(yield from x)" ~expected:(+Expression.YieldFrom !"x");
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "(yield (await x))"
           ~expected:(+Expression.Yield (Some (+Expression.Await !"x")));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "await (yield from x)"
           ~expected:(+Expression.Await (+Expression.YieldFrom !"x"));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "await (yield x)"
           ~expected:(+Expression.Await (+Expression.Yield (Some !"x")));
      (*TODO (T148669698): assert_not_parsed "await"; *)
      (* Standalone yield/yield from expressions are required to be protected with parenthesis. *)
      (*TODO (T148669698): assert_not_parsed "yield"; *)
      (*TODO (T148669698): assert_not_parsed "yield from"; *)
    ]


let test_container_literals =
  let assert_parsed = assert_parsed in
  let assert_not_parsed = assert_not_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_parsed "()" ~expected:(+Expression.Tuple []);
      (* The outer parens will *NOT* be interpreted as another layer of tuple. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "(())" ~expected:(+Expression.Tuple []);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "((),)" ~expected:(+Expression.Tuple [+Expression.Tuple []]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "1,"
           ~expected:(+Expression.Tuple [+Expression.Constant (Constant.Integer 1)]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "(1,)"
           ~expected:(+Expression.Tuple [+Expression.Constant (Constant.Integer 1)]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "1,2"
           ~expected:
             (+Expression.Tuple
                 [
                   +Expression.Constant (Constant.Integer 1);
                   +Expression.Constant (Constant.Integer 2);
                 ]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "1,2,"
           ~expected:
             (+Expression.Tuple
                 [
                   +Expression.Constant (Constant.Integer 1);
                   +Expression.Constant (Constant.Integer 2);
                 ]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "(1,2)"
           ~expected:
             (+Expression.Tuple
                 [
                   +Expression.Constant (Constant.Integer 1);
                   +Expression.Constant (Constant.Integer 2);
                 ]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "(\n\t1,\n\t2\n)"
           ~expected:
             (+Expression.Tuple
                 [
                   +Expression.Constant (Constant.Integer 1);
                   +Expression.Constant (Constant.Integer 2);
                 ]);
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_parsed "[]" ~expected:(+Expression.List []);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "[[]]" ~expected:(+Expression.List [+Expression.List []]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "[1]"
           ~expected:(+Expression.List [+Expression.Constant (Constant.Integer 1)]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "[1,]"
           ~expected:(+Expression.List [+Expression.Constant (Constant.Integer 1)]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "[1,2]"
           ~expected:
             (+Expression.List
                 [
                   +Expression.Constant (Constant.Integer 1);
                   +Expression.Constant (Constant.Integer 2);
                 ]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "[1,2,]"
           ~expected:
             (+Expression.List
                 [
                   +Expression.Constant (Constant.Integer 1);
                   +Expression.Constant (Constant.Integer 2);
                 ]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "[\n\t1,\n\t2\n]"
           ~expected:
             (+Expression.List
                 [
                   +Expression.Constant (Constant.Integer 1);
                   +Expression.Constant (Constant.Integer 2);
                 ]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "{1}" ~expected:(+Expression.Set [+Expression.Constant (Constant.Integer 1)]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "{1,}"
           ~expected:(+Expression.Set [+Expression.Constant (Constant.Integer 1)]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "{1,2}"
           ~expected:
             (+Expression.Set
                 [
                   +Expression.Constant (Constant.Integer 1);
                   +Expression.Constant (Constant.Integer 2);
                 ]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "{1,2,}"
           ~expected:
             (+Expression.Set
                 [
                   +Expression.Constant (Constant.Integer 1);
                   +Expression.Constant (Constant.Integer 2);
                 ]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "{\n\t1,\n\t2\n}"
           ~expected:
             (+Expression.Set
                 [
                   +Expression.Constant (Constant.Integer 1);
                   +Expression.Constant (Constant.Integer 2);
                 ]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "{}" ~expected:(+Expression.Dictionary []);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "{{}}" ~expected:(+Expression.Set [+Expression.Dictionary []]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "{1:2}"
           ~expected:
             (+Expression.Dictionary
                 [
                   KeyValue
                     {
                       key = +Expression.Constant (Constant.Integer 1);
                       value = +Expression.Constant (Constant.Integer 2);
                     };
                 ]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "{1:2,}"
           ~expected:
             (+Expression.Dictionary
                 [
                   KeyValue
                     {
                       key = +Expression.Constant (Constant.Integer 1);
                       value = +Expression.Constant (Constant.Integer 2);
                     };
                 ]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "{1:2,3:4}"
           ~expected:
             (+Expression.Dictionary
                 [
                   KeyValue
                     {
                       key = +Expression.Constant (Constant.Integer 1);
                       value = +Expression.Constant (Constant.Integer 2);
                     };
                   KeyValue
                     {
                       key = +Expression.Constant (Constant.Integer 3);
                       value = +Expression.Constant (Constant.Integer 4);
                     };
                 ]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "{1:2,3:4,}"
           ~expected:
             (+Expression.Dictionary
                 [
                   KeyValue
                     {
                       key = +Expression.Constant (Constant.Integer 1);
                       value = +Expression.Constant (Constant.Integer 2);
                     };
                   KeyValue
                     {
                       key = +Expression.Constant (Constant.Integer 3);
                       value = +Expression.Constant (Constant.Integer 4);
                     };
                 ]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "{\n\t1:2,\n\t3:4\n}"
           ~expected:
             (+Expression.Dictionary
                 [
                   KeyValue
                     {
                       key = +Expression.Constant (Constant.Integer 1);
                       value = +Expression.Constant (Constant.Integer 2);
                     };
                   KeyValue
                     {
                       key = +Expression.Constant (Constant.Integer 3);
                       value = +Expression.Constant (Constant.Integer 4);
                     };
                 ]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "{**foo}" ~expected:(+Expression.Dictionary [Splat !"foo"]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "{**foo, **bar}"
           ~expected:(+Expression.Dictionary [Splat !"foo"; Splat !"bar"]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "{**foo, 1:2}"
           ~expected:
             (+Expression.Dictionary
                 [
                   Splat !"foo";
                   KeyValue
                     {
                       key = +Expression.Constant (Constant.Integer 1);
                       value = +Expression.Constant (Constant.Integer 2);
                     };
                 ]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "{1:2,**foo}"
           ~expected:
             (+Expression.Dictionary
                 [
                   KeyValue
                     {
                       key = +Expression.Constant (Constant.Integer 1);
                       value = +Expression.Constant (Constant.Integer 2);
                     };
                   Splat !"foo";
                 ]);
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "(1,2";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "[1,2";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "{1,2";
    ]


let test_comprehensions =
  let assert_parsed = assert_parsed in
  let assert_not_parsed = assert_not_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "(a for a in b)"
           ~expected:
             (+Expression.Generator
                 {
                   Comprehension.element = !"a";
                   generators =
                     [
                       {
                         Comprehension.Generator.target = !"a";
                         iterator = !"b";
                         conditions = [];
                         async = false;
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "(a for a in (b for b in c))"
           ~expected:
             (+Expression.Generator
                 {
                   Comprehension.element = !"a";
                   generators =
                     [
                       {
                         Comprehension.Generator.target = !"a";
                         iterator =
                           +Expression.Generator
                              {
                                Comprehension.element = !"b";
                                generators =
                                  [
                                    {
                                      Comprehension.Generator.target = !"b";
                                      iterator = !"c";
                                      conditions = [];
                                      async = false;
                                    };
                                  ];
                              };
                         conditions = [];
                         async = false;
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "(c for a in b for c in a)"
           ~expected:
             (+Expression.Generator
                 {
                   Comprehension.element = !"c";
                   generators =
                     [
                       {
                         Comprehension.Generator.target = !"a";
                         iterator = !"b";
                         conditions = [];
                         async = false;
                       };
                       {
                         Comprehension.Generator.target = !"c";
                         iterator = !"a";
                         conditions = [];
                         async = false;
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "(a for a in b if True)"
           ~expected:
             (+Expression.Generator
                 {
                   Comprehension.element = !"a";
                   generators =
                     [
                       {
                         Comprehension.Generator.target = !"a";
                         iterator = !"b";
                         conditions = [+Expression.Constant Constant.True];
                         async = false;
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "(a for a in b if True if False)"
           ~expected:
             (+Expression.Generator
                 {
                   Comprehension.element = !"a";
                   generators =
                     [
                       {
                         Comprehension.Generator.target = !"a";
                         iterator = !"b";
                         conditions =
                           [+Expression.Constant Constant.True; +Expression.Constant Constant.False];
                         async = false;
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "(a async for a in b)"
           ~expected:
             (+Expression.Generator
                 {
                   Comprehension.element = !"a";
                   generators =
                     [
                       {
                         Comprehension.Generator.target = !"a";
                         iterator = !"b";
                         conditions = [];
                         async = true;
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "[a for a in b]"
           ~expected:
             (+Expression.ListComprehension
                 {
                   Comprehension.element = !"a";
                   generators =
                     [
                       {
                         Comprehension.Generator.target = !"a";
                         iterator = !"b";
                         conditions = [];
                         async = false;
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "{a for a in b}"
           ~expected:
             (+Expression.SetComprehension
                 {
                   Comprehension.element = !"a";
                   generators =
                     [
                       {
                         Comprehension.Generator.target = !"a";
                         iterator = !"b";
                         conditions = [];
                         async = false;
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "{a:0 for a in b}"
           ~expected:
             (+Expression.DictionaryComprehension
                 {
                   Comprehension.element =
                     { key = !"a"; value = +Expression.Constant (Constant.Integer 0) };
                   generators =
                     [
                       {
                         Comprehension.Generator.target = !"a";
                         iterator = !"b";
                         conditions = [];
                         async = false;
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "(*a for a in b)";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "[*a for a in b]";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "{*a for a in b}";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "{**a for a in b}";
      (*TODO (T148669698): assert_not_parsed "[i+1 for i in (j := stuff)]";*)
      (*TODO (T148669698): assert_not_parsed "[i+1 for i in range(2) for j in (k := stuff)]";*)
      (*TODO (T148669698): assert_not_parsed "[i+1 for i in [j for j in (k := stuff)]]";*)
      (*TODO (T148669698): assert_not_parsed "[i+1 for i in (lambda: (j := stuff))()]";*)
    ]


let test_starred =
  let assert_parsed = assert_parsed in
  let assert_not_parsed = assert_not_parsed in

  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "( *a, )"
           ~expected:(+Expression.Tuple [+Expression.Starred (Starred.Once !"a")]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "(a, *b)"
           ~expected:(+Expression.Tuple [!"a"; +Expression.Starred (Starred.Once !"b")]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "( *a, b )"
           ~expected:(+Expression.Tuple [+Expression.Starred (Starred.Once !"a"); !"b"]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "( *a, *b )"
           ~expected:
             (+Expression.Tuple
                 [+Expression.Starred (Starred.Once !"a"); +Expression.Starred (Starred.Once !"b")]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "[*a]" ~expected:(+Expression.List [+Expression.Starred (Starred.Once !"a")]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "[*a,]"
           ~expected:(+Expression.List [+Expression.Starred (Starred.Once !"a")]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "[*a, b]"
           ~expected:(+Expression.List [+Expression.Starred (Starred.Once !"a"); !"b"]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "[a, *b]"
           ~expected:(+Expression.List [!"a"; +Expression.Starred (Starred.Once !"b")]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "[*a, *b]"
           ~expected:
             (+Expression.List
                 [+Expression.Starred (Starred.Once !"a"); +Expression.Starred (Starred.Once !"b")]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "{*a}" ~expected:(+Expression.Set [+Expression.Starred (Starred.Once !"a")]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "{*a,}" ~expected:(+Expression.Set [+Expression.Starred (Starred.Once !"a")]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "{*a, b}"
           ~expected:(+Expression.Set [+Expression.Starred (Starred.Once !"a"); !"b"]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "{a, *b}"
           ~expected:(+Expression.Set [!"a"; +Expression.Starred (Starred.Once !"b")]);
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "{*a, *b}"
           ~expected:
             (+Expression.Set
                 [+Expression.Starred (Starred.Once !"a"); +Expression.Starred (Starred.Once !"b")]);
      (* Star expressions cannot appear out-of-context. *)
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "*x";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "**x";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "*(x)";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "*[x]";
      (*TODO (T148669698): assert_not_parsed "( *x )";*)
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "( **x )";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "[**x]";
    ]


let test_binary_operators =
  let assert_parsed = assert_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x + y"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"x"; attribute = "__add__"; special = true });
                   arguments = [{ Call.Argument.name = None; value = !"y" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x - y"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"x"; attribute = "__sub__"; special = true });
                   arguments = [{ Call.Argument.name = None; value = !"y" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x * y"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"x"; attribute = "__mul__"; special = true });
                   arguments = [{ Call.Argument.name = None; value = !"y" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x @ y"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"x"; attribute = "__matmul__"; special = true });
                   arguments = [{ Call.Argument.name = None; value = !"y" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x / y"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"x"; attribute = "__truediv__"; special = true });
                   arguments = [{ Call.Argument.name = None; value = !"y" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x % y"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"x"; attribute = "__mod__"; special = true });
                   arguments = [{ Call.Argument.name = None; value = !"y" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x ** y"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"x"; attribute = "__pow__"; special = true });
                   arguments = [{ Call.Argument.name = None; value = !"y" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x >> y"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"x"; attribute = "__rshift__"; special = true });
                   arguments = [{ Call.Argument.name = None; value = !"y" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x << y"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"x"; attribute = "__lshift__"; special = true });
                   arguments = [{ Call.Argument.name = None; value = !"y" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x | y"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"x"; attribute = "__or__"; special = true });
                   arguments = [{ Call.Argument.name = None; value = !"y" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x ^ y"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"x"; attribute = "__xor__"; special = true });
                   arguments = [{ Call.Argument.name = None; value = !"y" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x & y"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"x"; attribute = "__and__"; special = true });
                   arguments = [{ Call.Argument.name = None; value = !"y" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x // y"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           {
                             Name.Attribute.base = !"x";
                             attribute = "__floordiv__";
                             special = true;
                           });
                   arguments = [{ Call.Argument.name = None; value = !"y" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x + y + z"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           {
                             Name.Attribute.base =
                               +Expression.Call
                                  {
                                    Call.callee =
                                      +Expression.Name
                                         (Name.Attribute
                                            {
                                              Name.Attribute.base = !"x";
                                              attribute = "__add__";
                                              special = true;
                                            });
                                    arguments = [{ Call.Argument.name = None; value = !"y" }];
                                  };
                             attribute = "__add__";
                             special = true;
                           });
                   arguments = [{ Call.Argument.name = None; value = !"z" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x + (y + z)"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"x"; attribute = "__add__"; special = true });
                   arguments =
                     [
                       {
                         Call.Argument.name = None;
                         value =
                           +Expression.Call
                              {
                                Call.callee =
                                  +Expression.Name
                                     (Name.Attribute
                                        {
                                          Name.Attribute.base = !"y";
                                          attribute = "__add__";
                                          special = true;
                                        });
                                arguments = [{ Call.Argument.name = None; value = !"z" }];
                              };
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x + y * z"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"x"; attribute = "__add__"; special = true });
                   arguments =
                     [
                       {
                         Call.Argument.name = None;
                         value =
                           +Expression.Call
                              {
                                Call.callee =
                                  +Expression.Name
                                     (Name.Attribute
                                        {
                                          Name.Attribute.base = !"y";
                                          attribute = "__mul__";
                                          special = true;
                                        });
                                arguments = [{ Call.Argument.name = None; value = !"z" }];
                              };
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x * -y"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"x"; attribute = "__mul__"; special = true });
                   arguments =
                     [
                       {
                         Call.Argument.name = None;
                         value =
                           +Expression.UnaryOperator
                              { UnaryOperator.operator = UnaryOperator.Negative; operand = !"y" };
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x + y.z"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"x"; attribute = "__add__"; special = true });
                   arguments =
                     [
                       {
                         Call.Argument.name = None;
                         value =
                           +Expression.Name
                              (Name.Attribute
                                 { Name.Attribute.base = !"y"; attribute = "z"; special = false });
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "x < y + z"
           ~expected:
             (+Expression.ComparisonOperator
                 {
                   ComparisonOperator.left = !"x";
                   operator = ComparisonOperator.LessThan;
                   right =
                     +Expression.Call
                        {
                          Call.callee =
                            +Expression.Name
                               (Name.Attribute
                                  {
                                    Name.Attribute.base = !"y";
                                    attribute = "__add__";
                                    special = true;
                                  });
                          arguments = [{ Call.Argument.name = None; value = !"z" }];
                        };
                 });
    ]


let test_comparison_operators =
  let assert_parsed = assert_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a == b"
           ~expected:
             (+Expression.ComparisonOperator
                 {
                   ComparisonOperator.left = !"a";
                   operator = ComparisonOperator.Equals;
                   right = !"b";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a != b"
           ~expected:
             (+Expression.ComparisonOperator
                 {
                   ComparisonOperator.left = !"a";
                   operator = ComparisonOperator.NotEquals;
                   right = !"b";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a < b"
           ~expected:
             (+Expression.ComparisonOperator
                 {
                   ComparisonOperator.left = !"a";
                   operator = ComparisonOperator.LessThan;
                   right = !"b";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a <= b"
           ~expected:
             (+Expression.ComparisonOperator
                 {
                   ComparisonOperator.left = !"a";
                   operator = ComparisonOperator.LessThanOrEquals;
                   right = !"b";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a > b"
           ~expected:
             (+Expression.ComparisonOperator
                 {
                   ComparisonOperator.left = !"a";
                   operator = ComparisonOperator.GreaterThan;
                   right = !"b";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a >= b"
           ~expected:
             (+Expression.ComparisonOperator
                 {
                   ComparisonOperator.left = !"a";
                   operator = ComparisonOperator.GreaterThanOrEquals;
                   right = !"b";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a is b"
           ~expected:
             (+Expression.ComparisonOperator
                 { ComparisonOperator.left = !"a"; operator = ComparisonOperator.Is; right = !"b" });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a is not b"
           ~expected:
             (+Expression.ComparisonOperator
                 {
                   ComparisonOperator.left = !"a";
                   operator = ComparisonOperator.IsNot;
                   right = !"b";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a in b"
           ~expected:
             (+Expression.ComparisonOperator
                 { ComparisonOperator.left = !"a"; operator = ComparisonOperator.In; right = !"b" });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a not in b"
           ~expected:
             (+Expression.ComparisonOperator
                 {
                   ComparisonOperator.left = !"a";
                   operator = ComparisonOperator.NotIn;
                   right = !"b";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a < b < c"
           ~expected:
             (+Expression.BooleanOperator
                 {
                   BooleanOperator.left =
                     +Expression.ComparisonOperator
                        {
                          ComparisonOperator.left = !"a";
                          operator = ComparisonOperator.LessThan;
                          right = !"b";
                        };
                   operator = BooleanOperator.And;
                   right =
                     +Expression.ComparisonOperator
                        {
                          ComparisonOperator.left = !"b";
                          operator = ComparisonOperator.LessThan;
                          right = !"c";
                        };
                 });
      (* Comparisions bind tighter than `not` *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "not a in b"
           ~expected:
             (+Expression.UnaryOperator
                 {
                   UnaryOperator.operator = UnaryOperator.Not;
                   operand =
                     +Expression.ComparisonOperator
                        {
                          ComparisonOperator.left = !"a";
                          operator = ComparisonOperator.In;
                          right = !"b";
                        };
                 });
      (* Comparisions bind tighter than `and`/`or` *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a < b and b < c"
           ~expected:
             (+Expression.BooleanOperator
                 {
                   BooleanOperator.left =
                     +Expression.ComparisonOperator
                        {
                          ComparisonOperator.left = !"a";
                          operator = ComparisonOperator.LessThan;
                          right = !"b";
                        };
                   operator = BooleanOperator.And;
                   right =
                     +Expression.ComparisonOperator
                        {
                          ComparisonOperator.left = !"b";
                          operator = ComparisonOperator.LessThan;
                          right = !"c";
                        };
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a < b or b < c"
           ~expected:
             (+Expression.BooleanOperator
                 {
                   BooleanOperator.left =
                     +Expression.ComparisonOperator
                        {
                          ComparisonOperator.left = !"a";
                          operator = ComparisonOperator.LessThan;
                          right = !"b";
                        };
                   operator = BooleanOperator.Or;
                   right =
                     +Expression.ComparisonOperator
                        {
                          ComparisonOperator.left = !"b";
                          operator = ComparisonOperator.LessThan;
                          right = !"c";
                        };
                 });
      (* Comparisions bind looser than `+`/`-` *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "+a >= -b"
           ~expected:
             (+Expression.ComparisonOperator
                 {
                   ComparisonOperator.left =
                     +Expression.UnaryOperator
                        { UnaryOperator.operator = UnaryOperator.Positive; operand = !"a" };
                   operator = ComparisonOperator.GreaterThanOrEquals;
                   right =
                     +Expression.UnaryOperator
                        { UnaryOperator.operator = UnaryOperator.Negative; operand = !"b" };
                 });
    ]


let test_fstring =
  let assert_parsed ~expected text =
    assert_parsed ~expected:(+Expression.FormatString expected) text
  in
  let literal value = Substring.Literal (+value) in
  let format value = Substring.Format (+value) in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_parsed "f'foo'" ~expected:[literal "foo"];
      (*TODO (T148669698): assert_parsed "F'foo'" ~expected:[literal "foo"];*)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "f'foo' f'bar'" ~expected:[literal "foobar"];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "f'foo' 'bar'" ~expected:[literal "foobar"];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "f'{  3.14  }'"
           ~expected:[format (Expression.Constant (Constant.Float 3.14))];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "f'{3.14:10.10}'"
           ~expected:[format (Expression.Constant (Constant.Float 3.14))];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "f'{3.14:.10f}'"
           ~expected:[format (Expression.Constant (Constant.Float 3.14))];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "f'{3.14!s:10.10}'"
           ~expected:[format (Expression.Constant (Constant.Float 3.14))];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "f'{3.14!r:10.10}'"
           ~expected:[format (Expression.Constant (Constant.Float 3.14))];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "f'{3.14!a:10.10}'"
           ~expected:[format (Expression.Constant (Constant.Float 3.14))];
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_parsed "f'a{{'" ~expected:[literal "a{"];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "f'a{{b}}c'" ~expected:[literal "a{b}c"];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "f'{\"{{}}\"}'"
           ~expected:[format (Expression.Constant (Constant.String (StringLiteral.create "{{}}")))];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "f\"{'''x'''}\""
           ~expected:[format (Expression.Constant (Constant.String (StringLiteral.create "x")))];
      (* The `=` syntax was added in Python 3.8. *)
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "f'{x=}'"
           ~expected:[literal "x="; format (Expression.Name (Name.Identifier "x"))];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "f'{x=!r:^20}'"
           ~expected:[literal "x="; format (Expression.Name (Name.Identifier "x"))];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "f'{3.14!a:{w}.{p}}'"
           ~expected:[format (Expression.Constant (Constant.Float 3.14))];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "f'a{b}c'"
           ~expected:[literal "a"; format (Expression.Name (Name.Identifier "b")); literal "c"];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "f'a{\"b\"}c'"
           ~expected:
             [
               literal "a";
               format (Expression.Constant (Constant.String (StringLiteral.create "b")));
               literal "c";
             ];
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "f'{f\"a{b}c\"}'"
           ~expected:
             [
               format
                 (Expression.FormatString
                    [literal "a"; format (Expression.Name (Name.Identifier "b")); literal "c"]);
             ];
      (*TODO (T148669698):assert_parsed "f'''\n{b}\nc'''" ~expected:[literal "\n"; format
        (Expression.Name (Name.Identifier "b")); literal "\nc"];*)
      (*TODO (T148669698):assert_not_parsed "f'' b''";*)
      (*TODO (T148669698):assert_not_parsed "f'{\"x'";*)
      (*TODO (T148669698):assert_not_parsed "f'{\"x}'";*)
      (*TODO (T148669698):assert_not_parsed "f'{(\"x'";*)
      (*TODO (T148669698):assert_not_parsed "f'{(\"x)'";*)
      (*TODO (T148669698):assert_not_parsed "f'{((}'";*)
      (*TODO (T148669698):assert_not_parsed "f'{a[4)}'";*)
      (*TODO (T148669698):assert_not_parsed "f'{a(4]}'";*)
      (*TODO (T148669698):assert_not_parsed "f'{a[4}'";*)
      (*TODO (T148669698):assert_not_parsed "f'{a(4}'";*)
      (*TODO (T148669698):assert_not_parsed "f'{1#}'";*)
      (*TODO (T148669698):assert_not_parsed "f'{#}'";*)
      (*TODO (T148669698):assert_not_parsed "f'{}'";*)
      (*TODO (T148669698):assert_not_parsed "f'{,}'";*)
      (*TODO (T148669698):assert_not_parsed "f'{\n}'";*)
      (*TODO (T148669698):assert_not_parsed "f'{\\'a\\'}'";*)
    ]


let test_ternary_walrus =
  let assert_parsed = assert_parsed in
  let assert_not_parsed = assert_not_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "1 if 2 else 3"
           ~expected:
             (+Expression.Ternary
                 {
                   Ternary.target = +Expression.Constant (Constant.Integer 1);
                   test = +Expression.Constant (Constant.Integer 2);
                   alternative = +Expression.Constant (Constant.Integer 3);
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "1 if 2 else 3 if 4 else 5"
           ~expected:
             (+Expression.Ternary
                 {
                   Ternary.target = +Expression.Constant (Constant.Integer 1);
                   test = +Expression.Constant (Constant.Integer 2);
                   alternative =
                     +Expression.Ternary
                        {
                          Ternary.target = +Expression.Constant (Constant.Integer 3);
                          test = +Expression.Constant (Constant.Integer 4);
                          alternative = +Expression.Constant (Constant.Integer 5);
                        };
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "(a := 1)"
           ~expected:
             (+Expression.WalrusOperator
                 { WalrusOperator.target = !"a"; value = +Expression.Constant (Constant.Integer 1) });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "(a := (b := 1))"
           ~expected:
             (+Expression.WalrusOperator
                 {
                   WalrusOperator.target = !"a";
                   value =
                     +Expression.WalrusOperator
                        {
                          WalrusOperator.target = !"b";
                          value = +Expression.Constant (Constant.Integer 1);
                        };
                 });
      (* Standalone assignment expressions are required to be protected with parenthesis. *)
      (*TODO (T148669698): assert_not_parsed "a := 1";*)
      (*TODO (T148669698): assert_not_parsed "(a := 1) := 2"; *)
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "(a.b := 1)";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "(a[b] := 1)";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "((a, b) := 1)";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "([a, b] := 1)";
    ]


let test_call =
  let assert_parsed = assert_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed "foo()" ~expected:(+Expression.Call { Call.callee = !"foo"; arguments = [] });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "foo(x)"
           ~expected:
             (+Expression.Call
                 { Call.callee = !"foo"; arguments = [{ Call.Argument.name = None; value = !"x" }] });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "foo(x,)"
           ~expected:
             (+Expression.Call
                 { Call.callee = !"foo"; arguments = [{ Call.Argument.name = None; value = !"x" }] });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "foo(x=y)"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee = !"foo";
                   arguments = [{ Call.Argument.name = Some (+"x"); value = !"y" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "foo(x=y,)"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee = !"foo";
                   arguments = [{ Call.Argument.name = Some (+"x"); value = !"y" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "foo(x, y)"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee = !"foo";
                   arguments =
                     [
                       { Call.Argument.name = None; value = !"x" };
                       { Call.Argument.name = None; value = !"y" };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "foo((x, y))"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee = !"foo";
                   arguments =
                     [{ Call.Argument.name = None; value = +Expression.Tuple [!"x"; !"y"] }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "foo(x,y=z)"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee = !"foo";
                   arguments =
                     [
                       { Call.Argument.name = None; value = !"x" };
                       { Call.Argument.name = Some (+"y"); value = !"z" };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a.foo(x)"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"a"; attribute = "foo"; special = false });
                   arguments = [{ Call.Argument.name = None; value = !"x" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "foo(1, a = 2, *args, **kwargs)"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee = !"foo";
                   arguments =
                     [
                       {
                         Call.Argument.name = None;
                         value = +Expression.Constant (Constant.Integer 1);
                       };
                       {
                         Call.Argument.name = None;
                         value = +Expression.Starred (Starred.Once !"args");
                       };
                       {
                         Call.Argument.name = Some (+"a");
                         value = +Expression.Constant (Constant.Integer 2);
                       };
                       {
                         Call.Argument.name = None;
                         value = +Expression.Starred (Starred.Twice !"kwargs");
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "foo(x) + y"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           {
                             Name.Attribute.base =
                               +Expression.Call
                                  {
                                    Call.callee = !"foo";
                                    arguments = [{ Call.Argument.name = None; value = !"x" }];
                                  };
                             attribute = "__add__";
                             special = true;
                           });
                   arguments = [{ Call.Argument.name = None; value = !"y" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "foo(x) > y"
           ~expected:
             (+Expression.ComparisonOperator
                 {
                   ComparisonOperator.left =
                     +Expression.Call
                        {
                          Call.callee = !"foo";
                          arguments = [{ Call.Argument.name = None; value = !"x" }];
                        };
                   operator = ComparisonOperator.GreaterThan;
                   right = !"y";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "not foo(x)"
           ~expected:
             (+Expression.UnaryOperator
                 {
                   UnaryOperator.operator = UnaryOperator.Not;
                   UnaryOperator.operand =
                     +Expression.Call
                        {
                          Call.callee = !"foo";
                          arguments = [{ Call.Argument.name = None; value = !"x" }];
                        };
                 });
    ]


let test_subscript =
  let assert_parsed = assert_parsed in
  let assert_not_parsed = assert_not_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a[b]"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"a"; attribute = "__getitem__"; special = true });
                   arguments = [{ Call.Argument.name = None; value = !"b" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a.__getitem__(b)"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           {
                             Name.Attribute.base = !"a";
                             attribute = "__getitem__";
                             special = false;
                           });
                   arguments = [{ Call.Argument.name = None; value = !"b" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a[(b)]"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"a"; attribute = "__getitem__"; special = true });
                   arguments = [{ Call.Argument.name = None; value = !"b" }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a[1 < 2]"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"a"; attribute = "__getitem__"; special = true });
                   arguments =
                     [
                       {
                         Call.Argument.name = None;
                         value =
                           +Expression.ComparisonOperator
                              {
                                ComparisonOperator.left = +Expression.Constant (Constant.Integer 1);
                                operator = ComparisonOperator.LessThan;
                                right = +Expression.Constant (Constant.Integer 2);
                              };
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a[b,c]"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"a"; attribute = "__getitem__"; special = true });
                   arguments =
                     [{ Call.Argument.name = None; value = +Expression.Tuple [!"b"; !"c"] }];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a[b].c"
           ~expected:
             (+Expression.Name
                 (Name.Attribute
                    {
                      Name.Attribute.base =
                        +Expression.Call
                           {
                             Call.callee =
                               +Expression.Name
                                  (Name.Attribute
                                     {
                                       Name.Attribute.base = !"a";
                                       attribute = "__getitem__";
                                       special = true;
                                     });
                             arguments = [{ Call.Argument.name = None; value = !"b" }];
                           };
                      attribute = "c";
                      special = false;
                    }));
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a[:]"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"a"; attribute = "__getitem__"; special = true });
                   arguments =
                     [
                       {
                         Call.Argument.name = None;
                         value =
                           +Expression.Call
                              {
                                Call.callee = !"slice";
                                arguments =
                                  [
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant Constant.NoneLiteral;
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant Constant.NoneLiteral;
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant Constant.NoneLiteral;
                                    };
                                  ];
                              };
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a[::]"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"a"; attribute = "__getitem__"; special = true });
                   arguments =
                     [
                       {
                         Call.Argument.name = None;
                         value =
                           +Expression.Call
                              {
                                Call.callee = !"slice";
                                arguments =
                                  [
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant Constant.NoneLiteral;
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant Constant.NoneLiteral;
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant Constant.NoneLiteral;
                                    };
                                  ];
                              };
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a[1:]"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"a"; attribute = "__getitem__"; special = true });
                   arguments =
                     [
                       {
                         Call.Argument.name = None;
                         value =
                           +Expression.Call
                              {
                                Call.callee = !"slice";
                                arguments =
                                  [
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant (Constant.Integer 1);
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant Constant.NoneLiteral;
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant Constant.NoneLiteral;
                                    };
                                  ];
                              };
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a[:1]"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"a"; attribute = "__getitem__"; special = true });
                   arguments =
                     [
                       {
                         Call.Argument.name = None;
                         value =
                           +Expression.Call
                              {
                                Call.callee = !"slice";
                                arguments =
                                  [
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant Constant.NoneLiteral;
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant (Constant.Integer 1);
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant Constant.NoneLiteral;
                                    };
                                  ];
                              };
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a[::1]"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"a"; attribute = "__getitem__"; special = true });
                   arguments =
                     [
                       {
                         Call.Argument.name = None;
                         value =
                           +Expression.Call
                              {
                                Call.callee = !"slice";
                                arguments =
                                  [
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant Constant.NoneLiteral;
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant Constant.NoneLiteral;
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant (Constant.Integer 1);
                                    };
                                  ];
                              };
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a[1:1]"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"a"; attribute = "__getitem__"; special = true });
                   arguments =
                     [
                       {
                         Call.Argument.name = None;
                         value =
                           +Expression.Call
                              {
                                Call.callee = !"slice";
                                arguments =
                                  [
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant (Constant.Integer 1);
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant (Constant.Integer 1);
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant Constant.NoneLiteral;
                                    };
                                  ];
                              };
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a[1::1]"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"a"; attribute = "__getitem__"; special = true });
                   arguments =
                     [
                       {
                         Call.Argument.name = None;
                         value =
                           +Expression.Call
                              {
                                Call.callee = !"slice";
                                arguments =
                                  [
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant (Constant.Integer 1);
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant Constant.NoneLiteral;
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant (Constant.Integer 1);
                                    };
                                  ];
                              };
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a[:1:1]"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"a"; attribute = "__getitem__"; special = true });
                   arguments =
                     [
                       {
                         Call.Argument.name = None;
                         value =
                           +Expression.Call
                              {
                                Call.callee = !"slice";
                                arguments =
                                  [
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant Constant.NoneLiteral;
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant (Constant.Integer 1);
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant (Constant.Integer 1);
                                    };
                                  ];
                              };
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a[1:1:1]"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"a"; attribute = "__getitem__"; special = true });
                   arguments =
                     [
                       {
                         Call.Argument.name = None;
                         value =
                           +Expression.Call
                              {
                                Call.callee = !"slice";
                                arguments =
                                  [
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant (Constant.Integer 1);
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant (Constant.Integer 1);
                                    };
                                    {
                                      Call.Argument.name = None;
                                      value = +Expression.Constant (Constant.Integer 1);
                                    };
                                  ];
                              };
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "a[:1,2]"
           ~expected:
             (+Expression.Call
                 {
                   Call.callee =
                     +Expression.Name
                        (Name.Attribute
                           { Name.Attribute.base = !"a"; attribute = "__getitem__"; special = true });
                   arguments =
                     [
                       {
                         Call.Argument.name = None;
                         value =
                           +Expression.Tuple
                              [
                                +Expression.Call
                                   {
                                     Call.callee = !"slice";
                                     arguments =
                                       [
                                         {
                                           Call.Argument.name = None;
                                           value = +Expression.Constant Constant.NoneLiteral;
                                         };
                                         {
                                           Call.Argument.name = None;
                                           value = +Expression.Constant (Constant.Integer 1);
                                         };
                                         {
                                           Call.Argument.name = None;
                                           value = +Expression.Constant Constant.NoneLiteral;
                                         };
                                       ];
                                   };
                                +Expression.Constant (Constant.Integer 2);
                              ];
                       };
                     ];
                 });
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "a[]";
      labeled_test_case __FUNCTION__ __LINE__ @@ assert_not_parsed "a[:::]";
    ]


let test_lambda =
  let assert_parsed = assert_parsed in
  test_list
    [
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "lambda: 1"
           ~expected:
             (+Expression.Lambda
                 { Lambda.parameters = []; body = +Expression.Constant (Constant.Integer 1) });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "lambda x: x"
           ~expected:
             (+Expression.Lambda
                 {
                   Lambda.parameters = [+{ Parameter.name = "x"; value = None; annotation = None }];
                   body = !"x";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "lambda x,: x"
           ~expected:
             (+Expression.Lambda
                 {
                   Lambda.parameters = [+{ Parameter.name = "x"; value = None; annotation = None }];
                   body = !"x";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "lambda x: x is y"
           ~expected:
             (+Expression.Lambda
                 {
                   Lambda.parameters = [+{ Parameter.name = "x"; value = None; annotation = None }];
                   body =
                     +Expression.ComparisonOperator
                        {
                          ComparisonOperator.left = !"x";
                          operator = ComparisonOperator.Is;
                          right = !"y";
                        };
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "lambda x,y=1: x"
           ~expected:
             (+Expression.Lambda
                 {
                   Lambda.parameters =
                     [
                       +{ Parameter.name = "x"; value = None; annotation = None };
                       +{
                          Parameter.name = "y";
                          value = Some (+Expression.Constant (Constant.Integer 1));
                          annotation = None;
                        };
                     ];
                   body = !"x";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "lambda *args, **kwargs: args"
           ~expected:
             (+Expression.Lambda
                 {
                   Lambda.parameters =
                     [
                       +{ Parameter.name = "*args"; value = None; annotation = None };
                       +{ Parameter.name = "**kwargs"; value = None; annotation = None };
                     ];
                   body = !"args";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "lambda x, /: x"
           ~expected:
             (+Expression.Lambda
                 {
                   Lambda.parameters =
                     [
                       +{ Parameter.name = "x"; value = None; annotation = None };
                       +{ Parameter.name = "/"; value = None; annotation = None };
                     ];
                   body = !"x";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "lambda *, x: x"
           ~expected:
             (+Expression.Lambda
                 {
                   Lambda.parameters =
                     [
                       +{ Parameter.name = "*"; value = None; annotation = None };
                       +{ Parameter.name = "x"; value = None; annotation = None };
                     ];
                   body = !"x";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "lambda *args, x: x"
           ~expected:
             (+Expression.Lambda
                 {
                   Lambda.parameters =
                     [
                       +{ Parameter.name = "*args"; value = None; annotation = None };
                       +{ Parameter.name = "x"; value = None; annotation = None };
                     ];
                   body = !"x";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "lambda x, /, y, z=1, *, w=2: x"
           ~expected:
             (+Expression.Lambda
                 {
                   Lambda.parameters =
                     [
                       +{ Parameter.name = "x"; value = None; annotation = None };
                       +{ Parameter.name = "/"; value = None; annotation = None };
                       +{ Parameter.name = "y"; value = None; annotation = None };
                       +{
                          Parameter.name = "z";
                          value = Some (+Expression.Constant (Constant.Integer 1));
                          annotation = None;
                        };
                       +{ Parameter.name = "*"; value = None; annotation = None };
                       +{
                          Parameter.name = "w";
                          value = Some (+Expression.Constant (Constant.Integer 2));
                          annotation = None;
                        };
                     ];
                   body = !"x";
                 });
      labeled_test_case __FUNCTION__ __LINE__
      @@ assert_parsed
           "lambda x, y=1, /, z=2, *, u, v=3, **w: x"
           ~expected:
             (+Expression.Lambda
                 {
                   Lambda.parameters =
                     [
                       +{ Parameter.name = "x"; value = None; annotation = None };
                       +{
                          Parameter.name = "y";
                          value = Some (+Expression.Constant (Constant.Integer 1));
                          annotation = None;
                        };
                       +{ Parameter.name = "/"; value = None; annotation = None };
                       +{
                          Parameter.name = "z";
                          value = Some (+Expression.Constant (Constant.Integer 2));
                          annotation = None;
                        };
                       +{ Parameter.name = "*"; value = None; annotation = None };
                       +{ Parameter.name = "u"; value = None; annotation = None };
                       +{
                          Parameter.name = "v";
                          value = Some (+Expression.Constant (Constant.Integer 3));
                          annotation = None;
                        };
                       +{ Parameter.name = "**w"; value = None; annotation = None };
                     ];
                   body = !"x";
                 });
      (*TODO (T148669698): assert_not_parsed "lambda x=1, y: x"; assert_not_parsed "lambda *x, *, y:
        x";*)
    ]


let () =
  "parse_expression"
  >::: [
         test_name;
         test_attribute;
         test_constant;
         test_unary_operators;
         test_boolean_operators;
         test_await_yield;
         test_container_literals;
         test_comprehensions;
         test_starred;
         test_binary_operators;
         test_comparison_operators;
         test_fstring;
         test_ternary_walrus;
         test_call;
         test_subscript;
         test_lambda;
       ]
  |> Test.run
