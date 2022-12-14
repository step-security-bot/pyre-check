(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* TODO(T132410158) Add a module-level doc comment. *)

open Core
open Pyre
open Ast

module Error = struct
  type t = {
    location: Location.t;
    file_name: string;
    content: string option;
  }
  [@@deriving equal]

  let pp formatter { location; file_name; content } =
    let column = location.Location.start.Location.column in
    let header = Format.asprintf "Could not parse file at %s:%a" file_name Location.pp location in
    match content with
    | Some content ->
        let indicator =
          if column > 0 then
            String.make (column - 1) ' ' ^ "^"
          else
            "^"
        in
        Format.fprintf formatter "%s\n  %s\n  %s" header content indicator
    | None -> Format.fprintf formatter "%s" header


  let show = Format.asprintf "%a" pp
end

exception Error of Error.t

let sanitize_input lines =
  (* Remove byte order mark from first line if it exists. *)
  let lines =
    match lines with
    | first_line :: rest ->
        let byte_order_mark =
          [0xEF; 0xBB; 0xBF] |> List.map ~f:Char.of_int_exn |> String.of_char_list
        in
        if String.is_prefix first_line ~prefix:byte_order_mark then
          String.drop_prefix first_line (String.length byte_order_mark) :: rest
        else
          lines
    | [] -> []
  in
  List.map ~f:(fun line -> String.rstrip line) lines
  |> String.concat ~sep:"\n"
  |> fun input -> input ^ "\n"


(* Transform parsed expressions and statements into their AST. *)
module ParserToAst = struct
  open ParserExpression
  open ParserStatement
  module AstExpression = Ast.Expression
  module AstStatement = Ast.Statement.Statement

  let rec convert_expression { Node.location; value } =
    let convert_entry { Dictionary.Entry.key; value } =
      {
        AstExpression.Dictionary.Entry.key = convert_expression key;
        value = convert_expression value;
      }
    in
    let convert_generator { Comprehension.Generator.target; iterator; conditions; async } =
      {
        AstExpression.Comprehension.Generator.target = convert_expression target;
        iterator = convert_expression iterator;
        conditions = List.map ~f:convert_expression conditions;
        async;
      }
    in
    match value with
    | Expression.Await expression ->
        AstExpression.Expression.Await (convert_expression expression) |> Node.create ~location
    | BooleanOperator { left; operator; right } ->
        AstExpression.Expression.BooleanOperator
          { left = convert_expression left; operator; right = convert_expression right }
        |> Node.create ~location
    | Call { callee; arguments } ->
        AstExpression.Expression.Call
          { callee = convert_expression callee; arguments = List.map ~f:convert_argument arguments }
        |> Node.create ~location
    | ComparisonOperator { left; operator; right } ->
        AstExpression.Expression.ComparisonOperator
          { left = convert_expression left; operator; right = convert_expression right }
        |> Node.create ~location
    | Constant value -> AstExpression.Expression.Constant value |> Node.create ~location
    | Dictionary { Dictionary.entries; keywords } ->
        AstExpression.Expression.Dictionary
          {
            entries = List.map ~f:convert_entry entries;
            keywords = List.map ~f:convert_expression keywords;
          }
        |> Node.create ~location
    | DictionaryComprehension { Comprehension.element; generators } ->
        AstExpression.Expression.DictionaryComprehension
          { element = convert_entry element; generators = List.map ~f:convert_generator generators }
        |> Node.create ~location
    | Generator { Comprehension.element; generators } ->
        AstExpression.Expression.Generator
          {
            element = convert_expression element;
            generators = List.map ~f:convert_generator generators;
          }
        |> Node.create ~location
    | FormatString substrings ->
        let convert_substring { Substring.value; location; _ } =
          (* FIXME: The legacy parser no longer has the capability of parsing expressions in
             fstrings. *)
          AstExpression.Substring.Literal (Node.create ~location value)
        in
        AstExpression.Expression.FormatString (List.map substrings ~f:convert_substring)
        |> Node.create ~location
    | Lambda { Lambda.parameters; body } ->
        AstExpression.Expression.Lambda
          { parameters = List.map ~f:convert_parameter parameters; body = convert_expression body }
        |> Node.create ~location
    | List expression_list ->
        AstExpression.Expression.List (List.map ~f:convert_expression expression_list)
        |> Node.create ~location
    | ListComprehension { Comprehension.element; generators } ->
        AstExpression.Expression.ListComprehension
          {
            element = convert_expression element;
            generators = List.map ~f:convert_generator generators;
          }
        |> Node.create ~location
    | Name (Name.Attribute { base; attribute; special }) ->
        AstExpression.Expression.Name
          (AstExpression.Name.Attribute { base = convert_expression base; attribute; special })
        |> Node.create ~location
    | Name (Name.Identifier name) ->
        AstExpression.Expression.Name (AstExpression.Name.Identifier name) |> Node.create ~location
    | Parenthesis expression -> convert_expression expression
    | Set expression_list ->
        AstExpression.Expression.Set (List.map ~f:convert_expression expression_list)
        |> Node.create ~location
    | SetComprehension { Comprehension.element; generators } ->
        AstExpression.Expression.SetComprehension
          {
            element = convert_expression element;
            generators = List.map ~f:convert_generator generators;
          }
        |> Node.create ~location
    | Starred (Once expression) ->
        AstExpression.Expression.Starred (Once (convert_expression expression))
        |> Node.create ~location
    | Starred (Twice expression) ->
        AstExpression.Expression.Starred (Twice (convert_expression expression))
        |> Node.create ~location
    | Ternary { target; test; alternative } ->
        AstExpression.Expression.Ternary
          {
            target = convert_expression target;
            test = convert_expression test;
            alternative = convert_expression alternative;
          }
        |> Node.create ~location
    | Tuple expression_list ->
        AstExpression.Expression.Tuple (List.map ~f:convert_expression expression_list)
        |> Node.create ~location
    | UnaryOperator { UnaryOperator.operator; operand } ->
        AstExpression.Expression.UnaryOperator { operator; operand = convert_expression operand }
        |> Node.create ~location
    | WalrusOperator { target; value } ->
        AstExpression.Expression.WalrusOperator
          { target = convert_expression target; value = convert_expression value }
        |> Node.create ~location
    | Yield expression ->
        AstExpression.Expression.Yield (expression >>| convert_expression) |> Node.create ~location
    | YieldFrom expression ->
        AstExpression.Expression.YieldFrom (expression |> convert_expression)
        |> Node.create ~location


  and convert_argument { Call.Argument.name; value } =
    { AstExpression.Call.Argument.name; value = convert_expression value }


  and convert_parameter { Node.location; value = { Parameter.name; value; annotation } } =
    {
      AstExpression.Parameter.name;
      value = value >>| convert_expression;
      annotation = annotation >>| convert_expression;
    }
    |> Node.create ~location


  and convert_statement { Node.location; value } =
    let value =
      match value with
      | Statement.Assign { target; annotation; value } ->
          AstStatement.Assign
            {
              target = convert_expression target;
              annotation = annotation >>| convert_expression;
              value = convert_expression value;
            }
      | Assert { test; message } ->
          AstStatement.Assert
            {
              test = convert_expression test;
              message = message >>| convert_expression;
              origin = Ast.Statement.Assert.Origin.Assertion;
            }
      | Break -> AstStatement.Break
      | Class { name; base_arguments; body; decorators } ->
          AstStatement.Class
            {
              name;
              base_arguments = List.map ~f:convert_argument base_arguments;
              body = List.map ~f:convert_statement body;
              decorators = List.map ~f:convert_expression decorators;
              top_level_unbound_names = [];
            }
      | Continue -> AstStatement.Continue
      | Define { signature; body } ->
          let body = List.map ~f:convert_statement body in
          let convert_signature
              {
                ParserStatement.Define.Signature.name;
                parameters;
                decorators;
                return_annotation;
                async;
                parent;
              }
            =
            {
              Ast.Statement.Define.Signature.name;
              parameters = List.map ~f:convert_parameter parameters;
              decorators = List.map ~f:convert_expression decorators;
              return_annotation = return_annotation >>| convert_expression;
              async;
              generator = Ast.Statement.is_generator body;
              parent;
              nesting_define = None;
            }
          in
          AstStatement.Define
            { signature = convert_signature signature; captures = []; unbound_names = []; body }
      | Delete expressions -> AstStatement.Delete (List.map ~f:convert_expression expressions)
      | Expression expression -> AstStatement.Expression (convert_expression expression)
      | For { target; iterator; body; orelse; async } ->
          AstStatement.For
            {
              target = convert_expression target;
              iterator = convert_expression iterator;
              body = List.map ~f:convert_statement body;
              orelse = List.map ~f:convert_statement orelse;
              async;
            }
      | Global identifiers -> AstStatement.Global identifiers
      | If { test; body; orelse } ->
          AstStatement.If
            {
              test = convert_expression test;
              body = List.map ~f:convert_statement body;
              orelse = List.map ~f:convert_statement orelse;
            }
      | Import { from; imports } -> AstStatement.Import { from; imports }
      | Nonlocal identifiers -> AstStatement.Nonlocal identifiers
      | Pass -> AstStatement.Pass
      | Raise { expression; from } ->
          AstStatement.Raise
            { expression = expression >>| convert_expression; from = from >>| convert_expression }
      | Return { is_implicit; expression } ->
          AstStatement.Return { is_implicit; expression = expression >>| convert_expression }
      | Try { body; handlers; orelse; finally } ->
          let convert_handler { ParserStatement.Try.Handler.kind; name; body } =
            {
              Ast.Statement.Try.Handler.kind = kind >>| convert_expression;
              name;
              body = List.map ~f:convert_statement body;
            }
          in
          AstStatement.Try
            {
              body = List.map ~f:convert_statement body;
              handlers = List.map ~f:convert_handler handlers;
              orelse = List.map ~f:convert_statement orelse;
              finally = List.map ~f:convert_statement finally;
            }
      | With { items; body; async } ->
          let convert_item (resource, target) =
            convert_expression resource, target >>| convert_expression
          in
          AstStatement.With
            {
              items = List.map ~f:convert_item items;
              body = List.map ~f:convert_statement body;
              async;
            }
      | While { test; body; orelse } ->
          AstStatement.While
            {
              test = convert_expression test;
              body = List.map ~f:convert_statement body;
              orelse = List.map ~f:convert_statement orelse;
            }
    in
    Node.create ~location value
end

let parse ?start_line ?start_column ?relative lines =
  let input = sanitize_input lines in
  let file_name = Option.value relative ~default:"$invalid_path" in
  let buffer =
    let buffer = Lexing.from_string input in
    buffer.Lexing.lex_curr_p <-
      {
        Lexing.pos_fname = file_name;
        pos_lnum = Option.value start_line ~default:1;
        pos_bol = -Option.value start_column ~default:0;
        pos_cnum = 0;
      };
    buffer
  in
  let state = Lexer.State.initial () in
  try
    Generator.parse (Lexer.read state) buffer
    |> List.map ~f:ParserToAst.convert_statement
    |> Result.return
  with
  | Generator.Error
  | Failure _ ->
      let location =
        Location.create ~start:buffer.Lexing.lex_curr_p ~stop:buffer.Lexing.lex_curr_p
      in
      let line_number = location.Location.start.Location.line - 1 in
      let content = List.nth (String.split ~on:'\n' input) line_number in
      Error { Error.location; file_name; content }


let parse_exn ?start_line ?start_column ?relative lines =
  match parse ?start_line ?start_column ?relative lines with
  | Ok statements -> statements
  | Error error -> raise (Error error)
