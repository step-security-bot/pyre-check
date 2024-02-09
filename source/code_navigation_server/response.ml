(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* TODO(T132410158) Add a module-level doc comment. *)

open Base

module ErrorKind = struct
  type t =
    | InvalidRequest of string
    | ModuleNotTracked of { path: string }
    | ClientAlreadyRegistered of { client_id: string }
    | ClientNotRegistered of { client_id: string }
    | FileNotOpened of { path: string }
  [@@deriving sexp, compare, yojson { strict = false }]
end

module HoverContent = struct
  module Kind = struct
    type t = PlainText [@@deriving sexp, compare, yojson { strict = false }]
  end

  type t = {
    value: string option;
    docstring: string option;
  }
  [@@deriving sexp, compare, yojson { strict = false }]
end

module DefinitionLocation = struct
  type t = {
    path: string;
    range: Ast.Location.t;
  }
  [@@deriving sexp, compare, yojson { strict = false }]
end

module DocumentSymbolItem = struct
  type t = { label: string } [@@deriving sexp, compare, yojson { strict = false }]
end

module CompletionItem = struct
  module CompletionItemKind = struct
    type t =
      | Simple
      | Method
      | Property
      | Variable
    [@@deriving sexp, compare, yojson { strict = false }]

    let to_yojson = function
      | Simple -> `String "SIMPLE"
      | Method -> `String "METHOD"
      | Property -> `String "PROPERTY"
      | Variable -> `String "VARIABLE"
  end

  type t = {
    label: string;
    kind: CompletionItemKind.t;
    detail: string;
  }
  [@@deriving sexp, compare, yojson { strict = false }]
end

module Status = struct
  type t =
    | Idle
    | BusyBuilding
    | BusyChecking of { client_id: string option }
    | Stop of { message: string }
  [@@deriving sexp, compare, yojson { strict = false }]
end

type t =
  | Ok
  | Error of ErrorKind.t
  | TypeErrors of { errors: Analysis.AnalysisError.Instantiated.t list }
  | Hover of { contents: HoverContent.t list }
  | LocationOfDefinition of { definitions: DefinitionLocation.t list }
  | GetDocumentSymbol of { document_symbol_items: DocumentSymbolItem.t list }
      (** TODO: T166374635 Create structure for document symbol response *)
  | Completion of { completions: CompletionItem.t list }
  | ServerStatus of Status.t
  | Info of {
      (* All fields are required to implement `pyre servers` *)
      version: string;
      pid: int;
      socket: string;
      global_root: string;
      relative_local_root: string option;
    }
  | Superclasses of { superclasses: Request.ClassExpression.t list }
[@@deriving sexp, compare, yojson { strict = false }]

let to_string response = to_yojson response |> Yojson.Safe.to_string
