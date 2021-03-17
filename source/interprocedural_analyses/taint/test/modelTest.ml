(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Pyre
open Core
open OUnit2
open Test
open TestHelper
module Callable = Interprocedural.Callable
open Taint
open Model.ModelQuery

let set_up_environment ?source ?rules ~context ~model_source () =
  let source =
    match source with
    | None -> model_source
    | Some source -> source
  in
  let { ScratchProject.BuiltGlobalEnvironment.global_environment; _ } =
    ScratchProject.setup ~context ["test.py", source] |> ScratchProject.build_global_environment
  in
  let configuration =
    let rules =
      match rules with
      | Some rules -> rules
      | None -> []
    in
    let named name = { AnnotationParser.name; kind = Named } in
    Taint.TaintConfiguration.
      {
        empty with
        sources =
          [
            named "TestTest";
            named "UserControlled";
            named "Test";
            named "Demo";
            { AnnotationParser.name = "WithSubkind"; kind = Parametric };
          ];
        sinks =
          [
            named "TestSink";
            named "OtherSink";
            named "Test";
            named "Demo";
            named "XSS";
            { AnnotationParser.name = "TestSinkWithSubkind"; kind = Parametric };
          ];
        features = ["special"];
        partial_sink_labels = String.Map.Tree.of_alist_exn ["Test", ["a"; "b"]];
        rules;
      }
  in
  let source = Test.trim_extra_indentation model_source in
  let resolution =
    let global_resolution =
      Analysis.AnnotatedGlobalEnvironment.read_only global_environment
      |> Analysis.GlobalResolution.create
    in
    TypeCheck.resolution global_resolution (module TypeCheck.DummyContext)
  in

  let rule_filter =
    match rules with
    | Some rules -> Some (List.map rules ~f:(fun { Taint.TaintConfiguration.Rule.code; _ } -> code))
    | None -> None
  in
  let ({ Taint.Model.errors; skip_overrides; _ } as parse_result) =
    Taint.Model.parse ~resolution ?rule_filter ~source ~configuration Callable.Map.empty
  in
  assert_bool
    (Format.sprintf
       "Models have parsing errors: %s"
       (List.to_string errors ~f:Taint.Model.display_verification_error))
    (List.is_empty errors);

  let environment =
    Analysis.TypeEnvironment.create global_environment |> Analysis.TypeEnvironment.read_only
  in
  parse_result, environment, skip_overrides


let assert_model ?source ?rules ?expected_skipped_overrides ~context ~model_source ~expect () =
  let { Taint.Model.models; _ }, environment, skip_overrides =
    set_up_environment ?source ?rules ~context ~model_source ()
  in
  begin
    match expected_skipped_overrides with
    | Some expected ->
        let expected_set = List.map expected ~f:Ast.Reference.create |> Ast.Reference.Set.of_list in
        assert_equal ~cmp:Ast.Reference.Set.equal expected_set skip_overrides
    | None -> ()
  end;
  let get_model callable =
    let message = Format.asprintf "Model %a missing" Interprocedural.Callable.pp callable in
    Callable.Map.find models callable |> Option.value_exn ?here:None ?error:None ~message, false
    (* obscure *)
  in
  List.iter ~f:(check_expectation ~environment ~get_model) expect


let assert_no_model ?source ?rules ~context ~model_source callable =
  let { Taint.Model.models; _ }, _, _ =
    set_up_environment ?source ?rules ~context ~model_source ()
  in
  assert_false (Callable.Map.mem models callable)


let assert_queries ?source ?rules ~context ~model_source ~expect () =
  let { Taint.Model.queries; _ }, _, _ =
    set_up_environment ?source ?rules ~context ~model_source ()
  in
  assert_equal
    ~cmp:(List.equal (fun left right -> compare_rule left right = 0))
    ~printer:(List.to_string ~f:show_rule)
    queries
    expect


let test_source_models context =
  let assert_model = assert_model ~context in
  assert_model
    ~model_source:"def test.taint() -> TaintSource[TestTest]: ..."
    ~expect:[outcome ~kind:`Function ~returns:[Sources.NamedSource "TestTest"] "test.taint"]
    ();
  assert_model
    ~model_source:"os.environ: TaintSource[TestTest] = ..."
    ~expect:[outcome ~kind:`Object ~returns:[Sources.NamedSource "TestTest"] "os.environ"]
    ();
  assert_model
    ~model_source:"django.http.Request.GET: TaintSource[TestTest] = ..."
    ~expect:
      [outcome ~kind:`Object ~returns:[Sources.NamedSource "TestTest"] "django.http.Request.GET"]
    ();
  assert_model
    ~model_source:"def test.taint() -> TaintSource[Test, UserControlled]: ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~returns:[Sources.NamedSource "Test"; Sources.NamedSource "UserControlled"]
          "test.taint";
      ]
    ();
  assert_model
    ~model_source:"os.environ: TaintSink[Test] = ..."
    ~expect:
      [
        outcome
          ~kind:`Object
          ~sink_parameters:[{ name = "$global"; sinks = [Sinks.NamedSink "Test"] }]
          "os.environ";
      ]
    ();
  assert_model
    ~source:"def f(x: int): ..."
    ~model_source:"def test.f(x) -> TaintSource[Test, ViaValueOf[x]]: ..."
    ~expect:[outcome ~kind:`Function ~returns:[Sources.NamedSource "Test"] "test.f"]
    ();
  assert_model
    ~source:"def f(x: int): ..."
    ~model_source:"def test.f() -> TaintSource[Test, ViaValueOf[x]]: ..."
    ~expect:[outcome ~kind:`Function ~returns:[Sources.NamedSource "Test"] "test.f"]
    ();
  assert_model
    ~source:
      {|
    class C:
      @property
      def foo(self) -> int:
        return self.x
      @foo.setter
      def foo(self, value) -> None:
        self.x = value
    |}
    ~model_source:{|
      @property
      def test.C.foo(self) -> TaintSource[Test]: ...
    |}
    ~expect:[outcome ~kind:`Method ~returns:[Sources.NamedSource "Test"] "test.C.foo"]
    ();
  assert_model
    ~source:
      {|
    class C:
      @property
      def foo(self) -> int:
        return self.x
      @foo.setter
      def foo(self, value) -> None:
        self.x = value
    |}
    ~model_source:
      {|
      @foo.setter
      def test.C.foo(self, value) -> TaintSource[Test]: ...
    |}
    ~expect:[outcome ~kind:`PropertySetter ~returns:[Sources.NamedSource "Test"] "test.C.foo"]
    ();
  assert_model
    ~source:"def f(x: int): ..."
    ~model_source:"def test.f(x) -> AppliesTo[0, TaintSource[Test]]: ..."
    ~expect:[outcome ~kind:`Function ~returns:[Sources.NamedSource "Test"] "test.f"]
    ();
  assert_model
    ~source:
      {|
        import abc
        class C:
          @abc.abstractproperty
          def foo(self) -> int:
            return self.x
          @foo.setter
          def foo(self, value) -> None:
            self.x = value
        |}
    ~model_source:{|
        @property
        def test.C.foo(self) -> TaintSource[Test]: ...
    |}
    ~expect:[outcome ~kind:`Method ~returns:[Sources.NamedSource "Test"] "test.C.foo"]
    ();
  assert_model
    ~source:"def f(x: int): ..."
    ~model_source:"def test.f(x) -> TaintSource[WithSubkind[Subkind]]: ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~returns:[Sources.ParametricSource { source_name = "WithSubkind"; subkind = "Subkind" }]
          "test.f";
      ]
    ();
  ();
  assert_model
    ~source:{|
      def foo(x, y): ...
    |}
    ~model_source:"def test.foo(y: TaintSource[Test]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~source_parameters:[{ name = "y"; sources = [Sources.NamedSource "Test"] }]
          "test.foo";
      ]
    ()


let test_sanitize context =
  let open Taint.Result in
  let assert_model = assert_model ~context in
  assert_model
    ~model_source:{|
      @Sanitize
      def test.taint(x): ...
    |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~analysis_mode:
            (Mode.Sanitize
               {
                 Mode.sources = Some Mode.AllSources;
                 sinks = Some Mode.AllSinks;
                 tito = Some AllTito;
               })
          "test.taint";
      ]
    ();
  assert_model
    ~model_source:{|
      @Sanitize(TaintSource)
      def test.taint(x): ...
    |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~analysis_mode:
            (Mode.Sanitize { Mode.sources = Some Mode.AllSources; sinks = None; tito = None })
          "test.taint";
      ]
    ();
  assert_model
    ~model_source:{|
      @Sanitize(TaintSink)
      def test.taint(x): ...
    |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~analysis_mode:
            (Mode.Sanitize { Mode.sources = None; sinks = Some Mode.AllSinks; tito = None })
          "test.taint";
      ]
    ();
  assert_model
    ~model_source:{|
      @Sanitize(TaintInTaintOut)
      def test.taint(x): ...
    |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~analysis_mode:(Mode.Sanitize { Mode.sources = None; sinks = None; tito = Some AllTito })
          "test.taint";
      ]
    ();
  assert_model
    ~model_source:
      {|
      @Sanitize(TaintSource)
      @Sanitize(TaintInTaintOut)
      def test.taint(x): ...
    |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~analysis_mode:
            (Mode.Sanitize
               { Mode.sources = Some Mode.AllSources; sinks = None; tito = Some AllTito })
          "test.taint";
      ]
    ();
  assert_model
    ~model_source:
      {|
      @Sanitize(TaintSource, TaintInTaintOut)
      def test.taint(x): ...
    |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~analysis_mode:
            (Mode.Sanitize
               { Mode.sources = Some Mode.AllSources; sinks = None; tito = Some AllTito })
          "test.taint";
      ]
    ();
  assert_model
    ~model_source:{|
      @Sanitize(TaintSource[Test])
      def test.taint(x): ...
    |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~analysis_mode:
            (Mode.Sanitize
               {
                 Mode.sources = Some (Mode.SpecificSources [Sources.NamedSource "Test"]);
                 sinks = None;
                 tito = None;
               })
          "test.taint";
      ]
    ();
  assert_model
    ~model_source:
      {|
      @Sanitize(TaintSource[Test, UserControlled])
      def test.taint(x): ...
    |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~analysis_mode:
            (Mode.Sanitize
               {
                 Mode.sources =
                   Some
                     (Mode.SpecificSources
                        [Sources.NamedSource "UserControlled"; Sources.NamedSource "Test"]);
                 sinks = None;
                 tito = None;
               })
          "test.taint";
      ]
    ();
  assert_model
    ~model_source:
      {|
      @Sanitize(TaintInTaintOut[TaintSource[Test]])
      def test.taint(x): ...
    |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~analysis_mode:
            (Mode.Sanitize
               {
                 Mode.sources = None;
                 sinks = None;
                 tito =
                   Some
                     (Mode.SpecificTito
                        {
                          sanitized_tito_sources = [Sources.NamedSource "Test"];
                          sanitized_tito_sinks = [];
                        });
               })
          "test.taint";
      ]
    ();
  assert_model
    ~model_source:
      {|
      @Sanitize(TaintInTaintOut[TaintSink[Test]])
      def test.taint(x): ...
    |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~analysis_mode:
            (Mode.Sanitize
               {
                 Mode.sources = None;
                 sinks = None;
                 tito =
                   Some
                     (Mode.SpecificTito
                        {
                          sanitized_tito_sources = [];
                          sanitized_tito_sinks = [Sinks.NamedSink "Test"];
                        });
               })
          "test.taint";
      ]
    ();
  assert_model
    ~model_source:
      {|
      @Sanitize(TaintSource[Test], TaintInTaintOut[TaintSink[Test]])
      def test.taint(x): ...
    |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~analysis_mode:
            (Mode.Sanitize
               {
                 Mode.sources = Some (Mode.SpecificSources [Sources.NamedSource "Test"]);
                 sinks = None;
                 tito =
                   Some
                     (Mode.SpecificTito
                        {
                          sanitized_tito_sources = [];
                          sanitized_tito_sinks = [Sinks.NamedSink "Test"];
                        });
               })
          "test.taint";
      ]
    ();
  assert_model
    ~model_source:
      {|
      @Sanitize(TaintInTaintOut[TaintSource[Test], TaintSink[Test]])
      def test.taint(x): ...
    |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~analysis_mode:
            (Mode.Sanitize
               {
                 Mode.sources = None;
                 sinks = None;
                 tito =
                   Some
                     (Mode.SpecificTito
                        {
                          sanitized_tito_sources = [Sources.NamedSource "Test"];
                          sanitized_tito_sinks = [Sinks.NamedSink "Test"];
                        });
               })
          "test.taint";
      ]
    ();
  assert_model
    ~model_source:"django.http.Request.GET: Sanitize = ..."
    ~expect:
      [
        outcome
          ~kind:`Object
          ~analysis_mode:
            (Mode.Sanitize
               {
                 Mode.sources = Some Mode.AllSources;
                 Mode.sinks = Some Mode.AllSinks;
                 Mode.tito = Some Mode.AllTito;
               })
          "django.http.Request.GET";
      ]
    ();
  assert_model
    ~model_source:"django.http.Request.GET: Sanitize[TaintSource] = ..."
    ~expect:
      [
        outcome
          ~kind:`Object
          ~analysis_mode:
            (Mode.Sanitize { Mode.sources = Some Mode.AllSources; sinks = None; tito = None })
          "django.http.Request.GET";
      ]
    ();
  assert_model
    ~model_source:"django.http.Request.GET: Sanitize[TaintSink] = ..."
    ~expect:
      [
        outcome
          ~kind:`Object
          ~analysis_mode:
            (Mode.Sanitize { sources = None; Mode.sinks = Some Mode.AllSinks; tito = None })
          "django.http.Request.GET";
      ]
    ();
  assert_model
    ~model_source:"django.http.Request.GET: Sanitize[TaintSource[Test]] = ..."
    ~expect:
      [
        outcome
          ~kind:`Object
          ~analysis_mode:
            (Mode.Sanitize
               {
                 Mode.sources = Some (Mode.SpecificSources [Sources.NamedSource "Test"]);
                 sinks = None;
                 tito = None;
               })
          "django.http.Request.GET";
      ]
    ();
  assert_model
    ~model_source:"django.http.Request.GET: Sanitize[TaintSink[Test]] = ..."
    ~expect:
      [
        outcome
          ~kind:`Object
          ~analysis_mode:
            (Mode.Sanitize
               {
                 sources = None;
                 Mode.sinks = Some (Mode.SpecificSinks [Sinks.NamedSink "Test"]);
                 tito = None;
               })
          "django.http.Request.GET";
      ]
    ();
  assert_model
    ~model_source:"django.http.Request.GET: Sanitize[TaintSource[Test, TestTest]] = ..."
    ~expect:
      [
        outcome
          ~kind:`Object
          ~analysis_mode:
            (Mode.Sanitize
               {
                 Mode.sources =
                   Some
                     (Mode.SpecificSources
                        [Sources.NamedSource "TestTest"; Sources.NamedSource "Test"]);
                 sinks = None;
                 tito = None;
               })
          "django.http.Request.GET";
      ]
    ();
  assert_model
    ~model_source:"django.http.Request.GET: Sanitize[TaintSink[Test, TestSink]] = ..."
    ~expect:
      [
        outcome
          ~kind:`Object
          ~analysis_mode:
            (Mode.Sanitize
               {
                 sources = None;
                 Mode.sinks =
                   Some (Mode.SpecificSinks [Sinks.NamedSink "TestSink"; Sinks.NamedSink "Test"]);
                 tito = None;
               })
          "django.http.Request.GET";
      ]
    ()


let test_sink_models context =
  let assert_model = assert_model ~context in
  assert_model
    ~model_source:{|
        def test.sink(parameter: TaintSink[TestSink]):
          ...
      |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.NamedSink "TestSink"] }]
          "test.sink";
      ]
    ();
  assert_model
    ~model_source:"def test.sink(parameter0, parameter1: TaintSink[Test]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:[{ name = "parameter1"; sinks = [Sinks.NamedSink "Test"] }]
          "test.sink";
      ]
    ();
  assert_model
    ~model_source:"def test.sink(parameter0: TaintSink[Test], parameter1: TaintSink[Test]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:
            [
              { name = "parameter0"; sinks = [Sinks.NamedSink "Test"] };
              { name = "parameter1"; sinks = [Sinks.NamedSink "Test"] };
            ]
          "test.sink";
      ]
    ();
  assert_model
    ~model_source:"def test.sink(parameter0: TaintSink[Test], parameter1: TaintSink[Test]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:
            [
              { name = "parameter0"; sinks = [Sinks.NamedSink "Test"] };
              { name = "parameter1"; sinks = [Sinks.NamedSink "Test"] };
            ]
          "test.sink";
      ]
    ();
  assert_model
    ~model_source:"def test.both(parameter0: TaintSink[Demo]) -> TaintSource[Demo]: ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~returns:[Sources.NamedSource "Demo"]
          ~sink_parameters:[{ name = "parameter0"; sinks = [Sinks.NamedSink "Demo"] }]
          "test.both";
      ]
    ();
  assert_model
    ~model_source:
      "def test.sink(parameter0: TaintSink[Test], parameter1: TaintSink[Test, \
       ViaValueOf[parameter0]]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:
            [
              { name = "parameter0"; sinks = [Sinks.NamedSink "Test"] };
              { name = "parameter1"; sinks = [Sinks.NamedSink "Test"] };
            ]
          "test.sink";
      ]
    ();
  assert_model
    ~model_source:"def test.xss(parameter: TaintSink[XSS]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.NamedSink "XSS"] }]
          "test.xss";
      ]
    ();
  assert_model
    ~model_source:"def test.multiple(parameter: TaintSink[XSS, Demo]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:
            [{ name = "parameter"; sinks = [Sinks.NamedSink "Demo"; Sinks.NamedSink "XSS"] }]
          "test.multiple";
      ]
    ();
  assert_model
    ~model_source:"def test.multiple(parameter: AppliesTo[1, TaintSink[XSS, Demo]]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:
            [{ name = "parameter"; sinks = [Sinks.NamedSink "Demo"; Sinks.NamedSink "XSS"] }]
          "test.multiple";
      ]
    ();
  assert_model
    ~model_source:
      {|
        def test.sink(parameter: TaintSink[TestSinkWithSubkind[Subkind]]):
          ...
      |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:
            [
              {
                name = "parameter";
                sinks =
                  [Sinks.ParametricSink { sink_name = "TestSinkWithSubkind"; subkind = "Subkind" }];
              };
            ]
          "test.sink";
      ]
    ();

  ()


let test_cross_repository_models context =
  let assert_model = assert_model ~context in
  assert_model
    ~source:{|
      def cross_repository_source(source_parameter): ...
    |}
    ~model_source:
      {|
      def test.cross_repository_source(
        source_parameter: CrossRepositoryTaint[
          TaintSource[UserControlled],
          'crossRepositorySource',
          'formal(0)',
          0
        ]): ...
    |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~source_parameters:
            [{ name = "source_parameter"; sources = [Sources.NamedSource "UserControlled"] }]
          "test.cross_repository_source";
      ]
    ();
  assert_model
    ~source:{|
      def cross_repository_source(source_parameter): ...
    |}
    ~model_source:
      {|
      def test.cross_repository_source(
        source_parameter: CrossRepositoryTaintAnchor[
          TaintSource[UserControlled],
          'crossRepositorySource',
          'formal(0)',
        ]): ...
    |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~source_parameters:
            [{ name = "source_parameter"; sources = [Sources.NamedSource "UserControlled"] }]
          "test.cross_repository_source";
      ]
    ();
  assert_model
    ~source:{|
      def cross_repository_sink(x): ...
    |}
    ~model_source:
      {|
      def test.cross_repository_sink(
        x: CrossRepositoryTaintAnchor[
          TaintSink[Test],
          'crossRepositorySink',
          'formal(0)',
        ]): ...
    |}
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:[{ name = "x"; sinks = [Sinks.NamedSink "Test"] }]
          "test.cross_repository_sink";
      ]
    ()


let test_class_models context =
  let assert_model = assert_model ~context in
  assert_model
    ~source:
      {|
        class Sink:
          def Sink.method(parameter): ...
          def Sink.method_with_multiple_parameters(first, second): ...
      |}
    ~model_source:"class test.Sink(TaintSink[TestSink]): ..."
    ~expect:
      [
        outcome
          ~kind:`Method
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.NamedSink "TestSink"] }]
          "test.Sink.method";
        outcome
          ~kind:`Method
          ~sink_parameters:
            [
              { name = "first"; sinks = [Sinks.NamedSink "TestSink"] };
              { name = "second"; sinks = [Sinks.NamedSink "TestSink"] };
            ]
          "test.Sink.method_with_multiple_parameters";
      ]
    ();
  assert_model
    ~source:
      {|
        class Sink:
          def Sink.method(parameter): ...
          def Sink.method_with_multiple_parameters(first, second): ...
      |}
    ~model_source:"class test.Sink(TaintSink[TestSink], TaintSink[OtherSink]): ..."
    ~expect:
      [
        outcome
          ~kind:`Method
          ~sink_parameters:
            [
              {
                name = "parameter";
                sinks = [Sinks.NamedSink "OtherSink"; Sinks.NamedSink "TestSink"];
              };
            ]
          "test.Sink.method";
        outcome
          ~kind:`Method
          ~sink_parameters:
            [
              { name = "first"; sinks = [Sinks.NamedSink "OtherSink"; Sinks.NamedSink "TestSink"] };
              { name = "second"; sinks = [Sinks.NamedSink "OtherSink"; Sinks.NamedSink "TestSink"] };
            ]
          "test.Sink.method_with_multiple_parameters";
      ]
    ();
  assert_model
    ~source:
      {|
        class SinkAndSource:
          def SinkAndSource.method(parameter): ...
      |}
    ~model_source:"class test.SinkAndSource(TaintSink[TestSink], TaintSource[TestTest]): ..."
    ~expect:
      [
        outcome
          ~kind:`Method
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.NamedSink "TestSink"] }]
          ~returns:[Sources.NamedSource "TestTest"]
          "test.SinkAndSource.method";
      ]
    ();

  assert_model
    ~source:
      {|
        class Source:
          def Source.method(parameter): ...
          def Source.method_with_multiple_parameters(first, second): ...
          Source.attribute = ...
      |}
    ~model_source:{|
        class test.Source(TaintSource[UserControlled]): ...
      |}
    ~expect:
      [
        outcome ~kind:`Method ~returns:[Sources.NamedSource "UserControlled"] "test.Source.method";
        outcome
          ~kind:`Method
          ~returns:[Sources.NamedSource "UserControlled"]
          "test.Source.method_with_multiple_parameters";
      ]
    ();
  assert_model
    ~source:
      {|
        class AnnotatedSink:
          def AnnotatedSink.method(parameter: int) -> None: ...
      |}
    ~model_source:"class test.AnnotatedSink(TaintSink[TestSink]): ..."
    ~expect:
      [
        outcome
          ~kind:`Method
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.NamedSink "TestSink"] }]
          "test.AnnotatedSink.method";
      ]
    ();
  assert_model
    ~source:
      {|
         class AnnotatedSource:
          def AnnotatedSource.method(parameter: int) -> None: ...
      |}
    ~model_source:"class test.AnnotatedSource(TaintSource[UserControlled]): ..."
    ~expect:
      [
        outcome
          ~kind:`Method
          ~returns:[Sources.NamedSource "UserControlled"]
          "test.AnnotatedSource.method";
      ]
    ();
  assert_model
    ~source:
      {|
         class SourceWithDefault:
          def SourceWithDefault.method(parameter: int = 1) -> None: ...
      |}
    ~model_source:"class test.SourceWithDefault(TaintSink[Test]): ..."
    ~expect:
      [
        outcome
          ~kind:`Method
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.NamedSink "Test"] }]
          "test.SourceWithDefault.method";
      ]
    ();
  assert_model
    ~source:
      {|
         class Source:
           @classmethod
           def Source.method(cls, parameter: int) -> None: ...
      |}
    ~model_source:"class test.Source(TaintSource[UserControlled]): ..."
    ~expect:
      [outcome ~kind:`Method ~returns:[Sources.NamedSource "UserControlled"] "test.Source.method"]
    ();
  assert_model
    ~source:
      {|
         class Source:
           @property
           def Source.prop(self) -> int: ...
      |}
    ~model_source:"class test.Source(TaintSource[UserControlled]): ..."
    ~expect:
      [outcome ~kind:`Method ~returns:[Sources.NamedSource "UserControlled"] "test.Source.prop"]
    ();
  assert_model
    ~source:
      {|
        class SkipMe:
          def SkipMe.method(parameter): ...
          def SkipMe.method_with_multiple_parameters(first, second): ...
      |}
    ~model_source:"class test.SkipMe(SkipAnalysis): ..."
    ~expect:
      [
        outcome ~kind:`Method ~analysis_mode:Taint.Result.Mode.SkipAnalysis "test.SkipMe.method";
        outcome
          ~kind:`Method
          ~analysis_mode:Taint.Result.Mode.SkipAnalysis
          "test.SkipMe.method_with_multiple_parameters";
      ]
    ();
  (* Skip overrides do not generate methods. *)
  assert_model
    ~source:
      {|
        class SkipMe:
          def SkipMe.method(parameter): ...
          def SkipMe.method_with_multiple_parameters(first, second): ...
      |}
    ~model_source:"class test.SkipMe(SkipOverrides): ..."
    ~expected_skipped_overrides:
      ["test.SkipMe.method"; "test.SkipMe.method_with_multiple_parameters"]
    ~expect:[]
    ()


let test_taint_in_taint_out_models context =
  assert_model
    ~context
    ~model_source:"def test.tito(parameter: TaintInTaintOut): ..."
    ~expect:[outcome ~kind:`Function ~tito_parameters:["parameter"] "test.tito"]
    ();
  assert_model
    ~context
    ~model_source:"def test.tito(parameter: AppliesTo[1, TaintInTaintOut]): ..."
    ~expect:[outcome ~kind:`Function ~tito_parameters:["parameter"] "test.tito"]
    ()


let test_taint_in_taint_out_models_alternate context =
  assert_model
    ~context
    ~model_source:"def test.tito(parameter: TaintInTaintOut[LocalReturn]): ..."
    ~expect:[outcome ~kind:`Function ~tito_parameters:["parameter"] "test.tito"]
    ()


let test_skip_analysis context =
  assert_model
    ~context
    ~model_source:{|
      @SkipAnalysis
      def test.taint(x): ...
    |}
    ~expect:[outcome ~kind:`Function ~analysis_mode:Taint.Result.Mode.SkipAnalysis "test.taint"]
    ()


let test_taint_in_taint_out_update_models context =
  let assert_model = assert_model ~context in
  assert_model
    ~model_source:"def test.update(self, arg1: TaintInTaintOut[Updates[self]]): ..."
    ~expect:[outcome ~kind:`Function ~tito_parameters:["arg1 updates parameter 0"] "test.update"]
    ();
  assert_model
    ~model_source:"def test.update(self, arg1, arg2: TaintInTaintOut[Updates[self, arg1]]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~tito_parameters:["arg2 updates parameter 0"; "arg2 updates parameter 1"]
          "test.update";
      ]
    ();
  assert_model
    ~model_source:"def test.update(self: TaintInTaintOut[LocalReturn, Updates[arg1]], arg1): ..."
    ~expect:
      [outcome ~kind:`Function ~tito_parameters:["self"; "self updates parameter 1"] "test.update"]
    ()


let test_union_models context =
  assert_model
    ~context
    ~model_source:"def test.both(parameter: Union[TaintInTaintOut, TaintSink[XSS]]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.NamedSink "XSS"] }]
          ~tito_parameters:["parameter"]
          "test.both";
      ]
    ()


let test_source_breadcrumbs context =
  assert_model
    ~context
    ~model_source:"def test.source() -> TaintSource[Test, Via[special]]: ..."
    ~expect:[outcome ~kind:`Function ~returns:[Sources.NamedSource "Test"] "test.source"]
    ();
  assert_model
    ~context
    ~model_source:
      "def test.source() -> TaintSource[Test, ViaDynamicFeature[NotSpecifiedInConfig]]: ..."
    ~expect:[outcome ~kind:`Function ~returns:[Sources.NamedSource "Test"] "test.source"]
    ()


let test_sink_breadcrumbs context =
  assert_model
    ~context
    ~model_source:"def test.sink(parameter: TaintSink[Test, Via[special]]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.NamedSink "Test"] }]
          "test.sink";
      ]
    ()


let test_tito_breadcrumbs context =
  assert_model
    ~context
    ~model_source:"def test.tito(parameter: TaintInTaintOut[Via[special]]): ..."
    ~expect:[outcome ~kind:`Function ~tito_parameters:["parameter"] "test.tito"]
    ()


let test_attach_features context =
  let assert_model = assert_model ~context in
  assert_model
    ~model_source:"def test.source() -> AttachToSource[Via[special]]: ..."
    ~expect:[outcome ~kind:`Function ~returns:[Sources.Attach] "test.source"]
    ();
  assert_model
    ~model_source:"def test.sink(arg: AttachToSink[Via[special]]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:[{ name = "arg"; sinks = [Sinks.Attach] }]
          "test.sink";
      ]
    ();
  assert_model
    ~model_source:"def test.tito(arg: AttachToTito[Via[special]]): ..."
    ~expect:[outcome ~kind:`Function ~tito_parameters:["arg"] "test.tito"]
    ()


let test_partial_sinks context =
  let assert_model = assert_model ~context in
  assert_model
    ~model_source:"def test.partial_sink(x: PartialSink[Test[a]], y: PartialSink[Test[b]]): ..."
    ~expect:
      [
        outcome
          ~sink_parameters:
            [
              { name = "x"; sinks = [Sinks.PartialSink { kind = "Test"; label = "a" }] };
              { name = "y"; sinks = [Sinks.PartialSink { kind = "Test"; label = "b" }] };
            ]
          ~kind:`Function
          "test.partial_sink";
      ]
    ()


let test_invalid_models context =
  let assert_invalid_model ?path ?source ~model_source ~expect () =
    let source =
      match source with
      | Some source -> source
      | None ->
          {|
              unannotated_global = source()
              def test.sink(parameter) -> None: pass
              def test.sink_with_optional(parameter, firstOptional=1, secondOptional=2) -> None: pass
              def test.source() -> None: pass
              def test.partial_sink(x, y) -> None: pass
              def function_with_args(normal_arg, __anonymous_arg, *args) -> None: pass
              def function_with_kwargs(normal_arg, **kwargs) -> None: pass
              def anonymous_only(__arg1, __arg2, __arg3) -> None: pass
              def anonymous_with_optional(__arg1, __arg2, __arg3=2) -> None: pass
              class C:
                unannotated_class_variable = source()
            |}
    in
    let resolution =
      ScratchProject.setup ~context ["test.py", source] |> ScratchProject.build_resolution
    in
    let configuration =
      TaintConfiguration.
        {
          empty with
          sources = List.map ~f:(fun name -> { AnnotationParser.name; kind = Named }) ["A"; "B"];
          sinks =
            List.map ~f:(fun name -> { AnnotationParser.name; kind = Named }) ["X"; "Y"; "Test"];
          features = ["featureA"; "featureB"];
          rules = [];
          partial_sink_labels = String.Map.Tree.of_alist_exn ["Test", ["a"; "b"]];
        }
    in
    let error_message =
      let path = path >>| Path.create_absolute ~follow_symbolic_links:false in
      Model.parse
        ~resolution
        ~configuration
        ?path
        ~source:(Test.trim_extra_indentation model_source)
        Callable.Map.empty
      |> fun { Taint.Model.errors; _ } ->
      List.hd errors
      >>| Taint.Model.display_verification_error
      |> Option.value ~default:"no failure"
    in
    assert_equal ~printer:ident expect error_message
  in
  let assert_valid_model ?source ~model_source () =
    assert_invalid_model ?source ~model_source ~expect:"no failure" ()
  in
  assert_invalid_model
    ~model_source:"def test.sink(parameter: TaintSink[X, Unsupported]) -> TaintSource[A]: ..."
    ~expect:
      "`TaintSink[(X, Unsupported)]` is an invalid taint annotation: Unsupported taint sink \
       `Unsupported`"
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: TaintSink[UserControlled]): ..."
    ~expect:
      "`TaintSink[UserControlled]` is an invalid taint annotation: Unsupported taint sink \
       `UserControlled`"
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: SkipAnalysis): ..."
    ~expect:
      "`SkipAnalysis` is an invalid taint annotation: Failed to parse the given taint annotation."
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: TaintSink[X, Y, LocalReturn]): ..."
    ~expect:"Invalid model for `test.sink`: Invalid TaintSink annotation `LocalReturn`"
    ();
  assert_invalid_model
    ~model_source:"def test.source() -> TaintSource[Invalid]: ..."
    ~expect:
      "`TaintSource[Invalid]` is an invalid taint annotation: Unsupported taint source `Invalid`"
    ();
  assert_invalid_model
    ~model_source:"def test.source() -> TaintInTaintOut: ..."
    ~expect:"Invalid model for `test.source`: Invalid return annotation: TaintInTaintOut"
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: TaintInTaintOut[Test]): ..."
    ~expect:"Invalid model for `test.sink`: Invalid TaintInTaintOut annotation `Test`"
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: InvalidTaintDirection[Test]): ..."
    ~expect:
      "`InvalidTaintDirection[Test]` is an invalid taint annotation: Failed to parse the given \
       taint annotation."
    ();
  assert_invalid_model
    ~model_source:"def test.partial_sink(x: PartialSink[Test[first]], y: PartialSink[Test[b]]): ..."
    ~expect:
      "`PartialSink[Test[first]]` is an invalid taint annotation: Unrecognized label `first` for \
       partial sink `Test` (choices: `a, b`)"
    ();
  assert_invalid_model
    ~model_source:
      "def test.partial_sink(x: PartialSink[Test[a]], y: PartialSink[Test[second]]): ..."
    ~expect:
      "`PartialSink[Test[second]]` is an invalid taint annotation: Unrecognized label `second` for \
       partial sink `Test` (choices: `a, b`)"
    ();
  assert_invalid_model
    ~model_source:"def test.partial_sink(x: PartialSink[X[a]], y: PartialSink[X[b]]): ..."
    ~expect:"`PartialSink[X[b]]` is an invalid taint annotation: Unrecognized partial sink `X`."
    ();

  assert_valid_model
    ~model_source:"def test.partial_sink(x: PartialSink[Test[a]], y: PartialSink[Test[b]]): ..."
    ();

  assert_valid_model ~model_source:"def test.sink(): ..." ();
  assert_valid_model ~model_source:"def test.sink_with_optional(): ..." ();
  assert_valid_model ~model_source:"def test.sink_with_optional(parameter): ..." ();
  assert_valid_model ~model_source:"def test.sink_with_optional(parameter, firstOptional): ..." ();
  assert_valid_model
    ~model_source:"def test.sink_with_optional(parameter, firstOptional, secondOptional): ..."
    ();
  assert_invalid_model
    ~model_source:
      "def test.sink_with_optional(parameter, firstOptional, secondOptional, thirdOptional): ..."
    ~expect:
      "Model signature parameters for `test.sink_with_optional` do not match implementation `def \
       sink_with_optional(parameter: unknown, firstOptional: unknown = ..., secondOptional: \
       unknown = ...) -> None: ...`. Reason: unexpected positional parameter: `thirdOptional`."
    ();
  assert_invalid_model
    ~model_source:"def test.sink_with_optional(parameter, firstBad, secondBad): ..."
    ~expect:
      "Model signature parameters for `test.sink_with_optional` do not match implementation `def \
       sink_with_optional(parameter: unknown, firstOptional: unknown = ..., secondOptional: \
       unknown = ...) -> None: ...`. Reason: unexpected positional parameter: `secondBad`."
    ();
  assert_invalid_model
    ~model_source:"def test.sink_with_optional(parameter, *args): ..."
    ~expect:
      "Model signature parameters for `test.sink_with_optional` do not match implementation `def \
       sink_with_optional(parameter: unknown, firstOptional: unknown = ..., secondOptional: \
       unknown = ...) -> None: ...`. Reason: unexpected star parameter."
    ();
  assert_invalid_model
    ~model_source:"def test.sink_with_optional(parameter, **kwargs): ..."
    ~expect:
      "Model signature parameters for `test.sink_with_optional` do not match implementation `def \
       sink_with_optional(parameter: unknown, firstOptional: unknown = ..., secondOptional: \
       unknown = ...) -> None: ...`. Reason: unexpected star star parameter."
    ();
  assert_invalid_model
    ~model_source:"def test.sink_with_optional(__parameter): ..."
    ~expect:
      "Model signature parameters for `test.sink_with_optional` do not match implementation `def \
       sink_with_optional(parameter: unknown, firstOptional: unknown = ..., secondOptional: \
       unknown = ...) -> None: ...`. Reason: unexpected positional only parameter: `__parameter`."
    ();
  assert_invalid_model
    ~model_source:"def test.function_with_args(normal_arg, __random_name, named_arg, *args): ..."
    ~expect:
      "Model signature parameters for `test.function_with_args` do not match implementation `def \
       function_with_args(normal_arg: unknown, unknown, *(unknown)) -> None: ...`. Reason: \
       unexpected positional parameter: `named_arg`."
    ();
  assert_valid_model
    ~model_source:"def test.function_with_args(normal_arg, __random_name, *args): ..."
    ();
  assert_invalid_model
    ~model_source:"def test.function_with_args(normal_arg, __random_name, *, named_arg, *args): ..."
    ~expect:
      "Model signature parameters for `test.function_with_args` do not match implementation `def \
       function_with_args(normal_arg: unknown, unknown, *(unknown)) -> None: ...`. Reason: \
       unexpected named parameter: `named_arg`."
    ();
  assert_valid_model
    ~model_source:
      "def test.function_with_args(normal_arg, __random_name, __random_name_2, *args): ..."
    ();
  assert_valid_model ~model_source:"def test.function_with_kwargs(normal_arg, **kwargs): ..." ();
  assert_invalid_model
    ~model_source:"def test.function_with_kwargs(normal_arg, crazy_arg, **kwargs): ..."
    ~expect:
      "Model signature parameters for `test.function_with_kwargs` do not match implementation `def \
       function_with_kwargs(normal_arg: unknown, **(unknown)) -> None: ...`. Reason: unexpected \
       positional parameter: `crazy_arg`."
    ();
  assert_valid_model
    ~model_source:"def test.function_with_kwargs(normal_arg, *, crazy_arg, **kwargs): ..."
    ();
  assert_valid_model ~model_source:"def test.anonymous_only(__a1, __a2, __a3): ..." ();
  assert_valid_model ~model_source:"def test.anonymous_with_optional(__a1, __a2): ..." ();
  assert_valid_model ~model_source:"def test.anonymous_with_optional(__a1, __a2, __a3=...): ..." ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: Any): ..."
    ~expect:"`Any` is an invalid taint annotation: Failed to parse the given taint annotation."
    ();
  assert_invalid_model
    ~path:"broken_model.pysa"
    ~model_source:"def test.sink(parameter: Any): ..."
    ~expect:
      "broken_model.pysa:1: `Any` is an invalid taint annotation: Failed to parse the given taint \
       annotation."
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: TaintSink[Test, Via[bad_feature]]): ..."
    ~expect:
      "`TaintSink[(Test, Via[bad_feature])]` is an invalid taint annotation: Unrecognized Via \
       annotation `bad_feature`"
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: TaintSink[Updates[self]]): ..."
    ~expect:"`TaintSink[Updates[self]]` is an invalid taint annotation: No such parameter `self`"
    ();
  assert_valid_model ~model_source:"test.unannotated_global: TaintSink[Test]" ();
  assert_invalid_model
    ~model_source:"test.missing_global: TaintSink[Test]"
    ~expect:"`test.missing_global` is not part of the environment!"
    ();
  assert_invalid_model
    ~source:{|
      class C:
        a: int = 1
     |}
    ~model_source:"test.C.b: TaintSink[Test] = ..."
    ~expect:"Class `test.C` has no attribute `b`."
    ();
  assert_valid_model ~model_source:"test.C.unannotated_class_variable: TaintSink[Test]" ();
  assert_invalid_model
    ~model_source:"test.C.missing: TaintSink[Test]"
    ~expect:"Class `test.C` has no attribute `missing`."
    ();
  assert_invalid_model
    ~model_source:
      {|
      class test.ClassSinkWithMethod(TaintSink[TestSink]):
          def method(self): ...
      |}
    ~expect:"Invalid model for `test.ClassSinkWithMethod`: Class model must have a body of `...`."
    ();
  (* Attach syntax. *)
  assert_invalid_model
    ~model_source:"def test.sink(parameter: AttachToSink): ..."
    ~expect:
      "`AttachToSink` is an invalid taint annotation: Failed to parse the given taint annotation."
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: AttachToSink[feature]): ..."
    ~expect:
      "`AttachToSink[feature]` is an invalid taint annotation: All parameters to `AttachToSink` \
       must be of the form `Via[feature]`."
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter: AttachToTito[feature]): ..."
    ~expect:
      "`AttachToTito[feature]` is an invalid taint annotation: All parameters to `AttachToTito` \
       must be of the form `Via[feature]`."
    ();
  assert_invalid_model
    ~model_source:"def test.source() -> AttachToSource[feature]: ..."
    ~expect:
      "`AttachToSource[feature]` is an invalid taint annotation: All parameters to \
       `AttachToSource` must be of the form `Via[feature]`."
    ();

  (* Multiple features. *)
  assert_valid_model
    ~model_source:"def test.sink(parameter: AttachToSink[Via[featureA, featureB]]): ..."
    ();

  (* Default values must be `...`. *)
  assert_invalid_model
    ~model_source:"def test.sink(parameter = TaintSink[Test]): ..."
    ~expect:
      "Default values of `test.sink`'s parameters must be `...`. Did you mean to write `parameter: \
       TaintSink[Test]`?"
    ();
  assert_invalid_model
    ~model_source:"def test.sink(parameter = 1): ..."
    ~expect:
      "Default values of `test.sink`'s parameters must be `...`. Did you mean to write `parameter: \
       1`?"
    ();

  (* ViaValueOf models must specify existing parameters. *)
  assert_invalid_model
    ~model_source:
      "def test.sink(parameter) -> TaintSource[Test, ViaValueOf[nonexistent_parameter]]: ..."
    ~expect:
      "`TaintSource[(Test, ViaValueOf[nonexistent_parameter])]` is an invalid taint annotation: No \
       such parameter `nonexistent_parameter`"
    ();
  assert_invalid_model
    ~source:
      {|
    class C:
      @property
      def foo(self) -> int:
        return self.x
      @foo.setter
      def foo(self, value) -> None:
        self.x = value
    |}
    ~model_source:
      {|
      @property
      def test.C.foo(self, value) -> TaintSource[Test]: ...
    |}
    ~expect:
      "Model signature parameters for `test.C.foo` do not match implementation `(self: C) -> int`. \
       Reason: unexpected positional parameter: `value`."
    ();
  assert_valid_model
    ~source:
      {|
    class C:
      @property
      def foo(self) -> int:
        return self.x
      @foo.setter
      def foo(self, value: int) -> None:
        self.x = value
    |}
    ~model_source:{|
      @foo.setter
      def test.C.foo(self) -> TaintSource[A]: ...
    |}
    ();
  assert_invalid_model
    ~model_source:
      {|
      @decorated
      def accidental_decorator_passed_in() -> TaintSource[Test]: ...
    |}
    ~expect:
      "Unexpected decorators found when parsing model for `accidental_decorator_passed_in`: \
       `decorated`."
    ();
  assert_invalid_model
    ~source:
      {|
      class C:
        @property
        def foo(self) -> int: ...
        @foo.setter
        def foo(self, value) -> None: ...
    |}
    ~model_source:
      {|
      @wrong_name.setter
      def test.C.foo(self, value: TaintSink[Test]): ...
    |}
    ~expect:"Unexpected decorators found when parsing model for `test.C.foo`: `wrong_name.setter`."
    ();
  assert_invalid_model
    ~model_source:
      {|
      @custom_property
      def accidental_decorator_passed_in() -> TaintSource[Test]: ...
    |}
    ~expect:
      "Unexpected decorators found when parsing model for `accidental_decorator_passed_in`: \
       `custom_property`. If you're looking to model a custom property decorator, use the \
       @property decorator."
    ();

  assert_valid_model
    ~source:
      {|
      class C:
        @property
        def foo(self) -> int: ...
        @foo.setter
        def foo(self, value) -> None: ...
    |}
    ~model_source:
      {|
      @foo.setter
      def test.C.foo(self, value: TaintSink[Test]): ...
    |}
    ();
  assert_invalid_model
    ~model_source:
      {|
      def unittest.TestCase.assertIsNotNone(self, x: TaintSink[Test]): ...
    |}
    ~expect:
      "The modelled function `unittest.TestCase.assertIsNotNone` is an imported function, please \
       model `unittest.case.TestCase.assertIsNotNone` directly."
    ();
  assert_invalid_model
    ~model_source:
      {|
        def test.sink(parameter: TaintSink[Test, Via[a-feature]]):
          ...
    |}
    ~expect:
      "`TaintSink[(Test, Via[a.__sub__(feature)])]` is an invalid taint annotation: Invalid \
       expression for breadcrumb: (Expression.Expression.Call\n\
      \   { Expression.Call.callee = a.__sub__;\n\
      \     arguments = [{ Expression.Call.Argument.name = None; value = feature }]\n\
      \     })"
    ();
  assert_invalid_model
    ~source:"def partial_sink(x, y) -> None: ..."
    ~model_source:
      "def test.partial_sink(x: PartialSink[Nonexistent[a]], y: PartialSink[Nonexistent[b]]): ..."
    ~expect:
      "`PartialSink[Nonexistent[b]]` is an invalid taint annotation: Unrecognized partial sink \
       `Nonexistent`."
    ();
  assert_invalid_model
    ~source:"def f(parameter): ..."
    ~model_source:"def test.f(parameter: CrossRepositoryTaint[TaintSource[UserControlled]]): ..."
    ~expect:
      "`CrossRepositoryTaint[TaintSource[UserControlled]]` is an invalid taint annotation: Cross \
       repository taint must be of the form CrossRepositoryTaint[taint, canonical_name, \
       canonical_port, producer_id]."
    ();
  assert_invalid_model
    ~source:"def f(parameter): ..."
    ~model_source:
      "def test.f(parameter: CrossRepositoryTaint[TaintSource[UserControlled], \
       some_canonical_name, 'formal(0)', 0]): ..."
    ~expect:
      "`CrossRepositoryTaint[(TaintSource[UserControlled], some_canonical_name, \"formal(0)\", \
       0)]` is an invalid taint annotation: Cross repository taint must be of the form \
       CrossRepositoryTaint[taint, canonical_name, canonical_port, producer_id]."
    ();
  assert_invalid_model
    ~source:"def f(parameter): ..."
    ~model_source:
      "def test.f(parameter: CrossRepositoryTaint[TaintSource[UserControlled], \
       'some_canonical_name', 0, 0]): ..."
    ~expect:
      "`CrossRepositoryTaint[(TaintSource[UserControlled], \"some_canonical_name\", 0, 0)]` is an \
       invalid taint annotation: Cross repository taint must be of the form \
       CrossRepositoryTaint[taint, canonical_name, canonical_port, producer_id]."
    ();
  (* Ensure that we're verifying models against the undecorated signature. *)
  assert_valid_model
    ~source:
      {|
    from typing import Callable
    def decorate(f: Callable[[int], int]) -> Callable[[], int]:
      def g() -> int:
        return f(42)
      return g
    @decorate
    def foo(parameter: int) -> int:
      return parameter
    |}
    ~model_source:"def test.foo(parameter): ..."
    ();
  assert_valid_model
    ~source:
      {|
    from typing import Callable
    def decorate(f: Callable[[int], int]) -> Callable[[], int]:
      def g() -> int:
        return f(42)
      return g
    @decorate
    def foo(parameter: int) -> int:
      return parameter
    |}
    ~model_source:"def test.foo(): ..."
    ();
  assert_valid_model
    ~source:{|
      def foo(__: int, kwonly: str) -> None: ...
    |}
    ~model_source:"def test.foo(__: TaintSource[A], kwonly): ..."
    ();
  assert_invalid_model
    ~source:{|
      class C:
        @property
        def foo(self) -> int: ...
    |}
    ~model_source:"test.C.foo: TaintSource[A] = ..."
    ~expect:"Class `test.C` has no attribute `foo`."
    ();
  assert_invalid_model
    ~source:{|
      class C:
        foo = 1
      class D(C):
        pass
    |}
    ~model_source:"test.D.foo: TaintSource[A] = ..."
    ~expect:"Class `test.D` has no attribute `foo`."
    ();
  assert_valid_model
    ~source:{|
      class C:
        foo = 1
      class D(C):
        pass
    |}
    ~model_source:"test.C.foo: TaintSource[A] = ..."
    ();
  assert_valid_model
    ~source:
      {|
      class C:
        foo = 1
      class D(C):
        def __init__(self):
          self.foo = 2
    |}
    ~model_source:"test.D.foo: TaintSource[A] = ..."
    ();
  assert_invalid_model
    ~source:{|
      def foo(x):
        ...
    |}
    ~model_source:"def test.foo(x) -> TaintSource[A[Subkind]]: ..."
    ~expect:"`TaintSource[A[Subkind]]` is an invalid taint annotation: Unsupported taint source `A`"
    ();
  assert_invalid_model
    ~source:{|
      def foo(x):
        ...
    |}
    ~model_source:"def test.foo(x: TaintSink[X[Subkind]]): ..."
    ~expect:"`TaintSink[X[Subkind]]` is an invalid taint annotation: Unsupported taint sink `X`"
    ();
  assert_invalid_model
    ~source:{|
      def foo(x):
        ...
    |}
    ~model_source:{|
      @Sanitize(TaintInTaintOut[LocalReturn])
      def test.foo(x): ...
    |}
    ~expect:
      "`LocalReturn` is an invalid taint annotation: Failed to parse the given taint annotation."
    ();

  (* Test source- and sink- specific tito parsing. *)
  assert_valid_model
    ~source:{|
      def foo(x):
        ...
    |}
    ~model_source:
      {|
      @Sanitize(TaintInTaintOut[TaintSource[A]])
      def test.foo(x): ...
    |}
    ();
  assert_valid_model
    ~source:{|
      def foo(x):
        ...
    |}
    ~model_source:
      {|
      @Sanitize(TaintInTaintOut[TaintSink[Test]])
      def test.foo(x): ...
    |}
    ();
  assert_valid_model
    ~source:{|
      def foo(x):
        ...
    |}
    ~model_source:{|
      @Sanitize(TaintSource[A])
      def test.foo(x): ...
    |}
    ();
  assert_invalid_model
    ~source:{|
      def foo(x):
        ...
    |}
    ~model_source:
      {|
      @Sanitize(TaintSource[A, Via[featureA]])
      def test.foo(x): ...
    |}
    ~expect:
      {|Invalid model for `test.foo`: `ModelParser.T.Source {source = (Sources.T.NamedSource "A");
  breadcrumbs = [(SimpleVia "featureA")]; path = ; leaf_names = [];
  leaf_name_provided = false}` is not a supported taint annotation for sanitizers.|}
    ();
  assert_invalid_model
    ~model_source:
      {|
      ModelQuery(
        fnid = "functions",
        where = name.matches("foo"),
        model = Returns(TaintSource[Test])
      )
    |}
    ~expect:
      {|The model query arguments at `{ Expression.Call.Argument.name = (Some fnid); value = "functions" }, { Expression.Call.Argument.name = (Some where); value = name.matches("foo") }, { Expression.Call.Argument.name = (Some model);
  value = Returns(TaintSource[Test]) }` are invalid: expected a find, where and model clause.|}
    ();

  (* We error starting on the first decorator. *)
  assert_invalid_model
    ~path:"a.py"
    ~model_source:{|
      @Sanitize
      def a.not_in_environment(self): ...
    |}
    ~expect:"a.py:2: `a.not_in_environment` is not part of the environment!"
    ();
  assert_invalid_model
    ~path:"a.py"
    ~model_source:
      {|
      @Sanitize(TaintSink)
      @Sanitize(TaintSource)
      def a.not_in_environment(self): ...
    |}
    ~expect:"a.py:2: `a.not_in_environment` is not part of the environment!"
    ();
  assert_invalid_model
    ~source:{|
      class C:
          def __init__(self, x) -> None:
              ...
    |}
    ~model_source:{|
      @Sanitize
      def test.C(): ...
    |}
    ~expect:"The class `test.C` is not a valid define - did you mean to model `test.C.__init__()`?"
    ();
  (* Class models don't error. *)
  assert_valid_model
    ~source:{|
      class C:
          def __init__(self, x) -> None:
              ...
    |}
    ~model_source:{|
      @Sanitize
      class test.C: ...
    |}
    ();

  (* Error on non-existenting callables. *)
  assert_invalid_model
    ~model_source:"def not_in_the_environment(parameter: InvalidTaintDirection[Test]): ..."
    ~expect:"`not_in_the_environment` is not part of the environment!"
    ();
  assert_invalid_model
    ~model_source:"def not_in_the_environment.derp(parameter: InvalidTaintDirection[Test]): ..."
    ~expect:"`not_in_the_environment.derp` is not part of the environment!"
    ();
  assert_invalid_model
    ~source:
      {|
      class Parent:
        def foo(self) -> int: ...
      class Child(Parent):
        pass
    |}
    ~model_source:{|
      def test.Child.foo(self) -> TaintSource[Test]: ...
    |}
    ~expect:
      "The modelled function `test.Child.foo` is an imported function, please model \
       `test.Parent.foo` directly."
    ();
  assert_invalid_model
    ~source:
      {|
      class Parent:
        @property
        def foo(self) -> int: ...
      class Child(Parent):
        pass
    |}
    ~model_source:{|
      @property
      def test.Child.foo(self) -> TaintSource[Test]: ...
    |}
    ~expect:"`test.Child.foo` is not part of the environment!"
    ();
  assert_invalid_model
    ~source:{|
      class C:
        x = ...
      |}
    ~model_source:{|
      test.C.x: Sanitize[TaintInTaintOut[TaintSource[Test]]] = ...
    |}
    ~expect:
      "Invalid model for `test.C.x`: TaintInTaintOut sanitizers cannot be modelled on attributes."
    ();
  assert_invalid_model
    ~source:{|
      class C:
        x = ...
      |}
    ~model_source:{|
      test.C.x: Sanitize[TaintInTaintOut[TaintSink[Test]]] = ...
    |}
    ~expect:
      "Invalid model for `test.C.x`: TaintInTaintOut sanitizers cannot be modelled on attributes."
    ();
  ()


let test_demangle_class_attributes _ =
  let assert_demangle ~expected name =
    assert_equal expected (Model.demangle_class_attribute name)
  in
  assert_demangle ~expected:"a.B" "a.B";
  assert_demangle ~expected:"a.B" "a.__class__.B";

  (* We require `__class__` to directly precede the attribute of the `.`-separated names. *)
  assert_demangle ~expected:"a.B.__class__" "a.B.__class__";
  assert_demangle ~expected:"a.__class__.B.C" "a.__class__.B.C"


let test_filter_by_rules context =
  let assert_model = assert_model ~context in
  assert_model
    ~rules:
      [
        {
          Taint.TaintConfiguration.Rule.sources = [Sources.NamedSource "TestTest"];
          sinks = [Sinks.NamedSink "TestSink"];
          code = 5021;
          message_format = "";
          name = "test rule";
        };
      ]
    ~model_source:"def test.taint() -> TaintSource[TestTest]: ..."
    ~expect:[outcome ~kind:`Function ~returns:[Sources.NamedSource "TestTest"] "test.taint"]
    ();
  assert_no_model
    ~context
    ~rules:
      [
        {
          Taint.TaintConfiguration.Rule.sources = [Sources.NamedSource "Test"];
          sinks = [Sinks.NamedSink "TestSink"];
          code = 5021;
          message_format = "";
          name = "test rule";
        };
      ]
    ~model_source:"def test.taint() -> TaintSource[TestTest]: ..."
    (Callable.create_function (Ast.Reference.create "test.taint"));
  assert_model
    ~rules:
      [
        {
          Taint.TaintConfiguration.Rule.sources = [Sources.NamedSource "TestTest"];
          sinks = [Sinks.NamedSink "TestSink"];
          code = 5021;
          message_format = "";
          name = "test rule";
        };
      ]
    ~model_source:"def test.taint(x: TaintSink[TestSink]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:[{ name = "x"; sinks = [Sinks.NamedSink "TestSink"] }]
          "test.taint";
      ]
    ();
  assert_no_model
    ~context
    ~rules:
      [
        {
          Taint.TaintConfiguration.Rule.sources = [Sources.NamedSource "TestTest"];
          sinks = [Sinks.NamedSink "Test"];
          code = 5021;
          message_format = "";
          name = "test rule";
        };
      ]
    ~model_source:"def test.taint(x: TaintSink[TestSink]): ..."
    (Callable.create_function (Ast.Reference.create "test.taint"));
  assert_model
    ~rules:
      [
        {
          Taint.TaintConfiguration.Rule.sources = [Sources.NamedSource "TestTest"];
          sinks = [Sinks.TriggeredPartialSink { kind = "Test"; label = "a" }];
          code = 4321;
          message_format = "";
          name = "test multiple sources rule";
        };
        {
          Taint.TaintConfiguration.Rule.sources = [Sources.NamedSource "TestTest"];
          sinks = [Sinks.TriggeredPartialSink { kind = "Test"; label = "b" }];
          code = 4321;
          message_format = "";
          name = "test multiple sources rule";
        };
      ]
    ~model_source:"def test.partial_sink(x: PartialSink[Test[a]], y: PartialSink[Test[b]]): ..."
    ~expect:
      [
        outcome
          ~kind:`Function
          ~sink_parameters:
            [
              { name = "x"; sinks = [Sinks.PartialSink { kind = "Test"; label = "a" }] };
              { name = "y"; sinks = [Sinks.PartialSink { kind = "Test"; label = "b" }] };
            ]
          "test.partial_sink";
      ]
    ()


let test_query_parsing context =
  assert_queries
    ~context
    ~model_source:
      {|
    ModelQuery(
     find = "functions",
     where = name.matches("foo"),
     model = Returns(TaintSource[Test])
    )
  |}
    ~expect:
      [
        {
          name = None;
          query = [NameConstraint "foo"];
          rule_kind = FunctionModel;
          productions =
            [
              ReturnTaint
                [
                  TaintAnnotation
                    (Model.Source
                       {
                         source = Sources.NamedSource "Test";
                         breadcrumbs = [];
                         path = [];
                         leaf_names = [];
                         leaf_name_provided = false;
                       });
                ];
            ];
        };
      ]
    ();
  assert_queries
    ~context
    ~model_source:
      {|
    ModelQuery(
     find = "functions",
     where = name.matches("foo"),
     model = [Returns(TaintSource[Test])]
    )
  |}
    ~expect:
      [
        {
          name = None;
          query = [NameConstraint "foo"];
          rule_kind = FunctionModel;
          productions =
            [
              ReturnTaint
                [
                  TaintAnnotation
                    (Model.Source
                       {
                         source = Sources.NamedSource "Test";
                         breadcrumbs = [];
                         path = [];
                         leaf_names = [];
                         leaf_name_provided = false;
                       });
                ];
            ];
        };
      ]
    ();
  assert_queries
    ~context
    ~model_source:
      {|
    ModelQuery(
     find = "functions",
     where = [name.matches("foo"), name.matches("bar")],
     model = Returns(TaintSource[Test])
    )
  |}
    ~expect:
      [
        {
          name = None;
          query = [NameConstraint "foo"; NameConstraint "bar"];
          rule_kind = FunctionModel;
          productions =
            [
              ReturnTaint
                [
                  TaintAnnotation
                    (Model.Source
                       {
                         source = Sources.NamedSource "Test";
                         breadcrumbs = [];
                         path = [];
                         leaf_names = [];
                         leaf_name_provided = false;
                       });
                ];
            ];
        };
      ]
    ();
  assert_queries
    ~context
    ~model_source:
      {|
    ModelQuery(
     find = "functions",
     where = name.matches("foo"),
     model = [Returns([TaintSource[Test], TaintSink[Test]])]
    )
  |}
    ~expect:
      [
        {
          name = None;
          query = [NameConstraint "foo"];
          rule_kind = FunctionModel;
          productions =
            [
              ReturnTaint
                [
                  TaintAnnotation
                    (Model.Source
                       {
                         source = Sources.NamedSource "Test";
                         breadcrumbs = [];
                         path = [];
                         leaf_names = [];
                         leaf_name_provided = false;
                       });
                  TaintAnnotation
                    (Model.Sink
                       {
                         sink = Sinks.NamedSink "Test";
                         breadcrumbs = [];
                         path = [];
                         leaf_names = [];
                         leaf_name_provided = false;
                       });
                ];
            ];
        };
      ]
    ();
  assert_queries
    ~context
    ~model_source:
      {|
    ModelQuery(
     name = "foo_finders",
     find = "functions",
     where = name.matches("foo"),
     model = [Returns([TaintSource[Test], TaintSink[Test]])]
    )
  |}
    ~expect:
      [
        {
          name = Some "foo_finders";
          query = [NameConstraint "foo"];
          rule_kind = FunctionModel;
          productions =
            [
              ReturnTaint
                [
                  TaintAnnotation
                    (Model.Source
                       {
                         source = Sources.NamedSource "Test";
                         breadcrumbs = [];
                         path = [];
                         leaf_names = [];
                         leaf_name_provided = false;
                       });
                  TaintAnnotation
                    (Model.Sink
                       {
                         sink = Sinks.NamedSink "Test";
                         breadcrumbs = [];
                         path = [];
                         leaf_names = [];
                         leaf_name_provided = false;
                       });
                ];
            ];
        };
      ]
    ();
  assert_queries
    ~context
    ~model_source:
      {|
    ModelQuery(
       name = "foo_finders",
       find = "functions",
       where = return_annotation.is_annotated_type(),
       model = [Returns([TaintSource[Test]])]
    )
    |}
    ~expect:
      [
        {
          name = Some "foo_finders";
          query = [ReturnConstraint IsAnnotatedTypeConstraint];
          rule_kind = FunctionModel;
          productions =
            [
              ReturnTaint
                [
                  TaintAnnotation
                    (Model.Source
                       {
                         source = Sources.NamedSource "Test";
                         breadcrumbs = [];
                         path = [];
                         leaf_names = [];
                         leaf_name_provided = false;
                       });
                ];
            ];
        };
      ]
    ();
  assert_queries
    ~context
    ~model_source:
      {|
    ModelQuery(
       name = "foo_finders",
       find = "functions",
       where = any_parameter.annotation.is_annotated_type(),
       model = [Returns([TaintSource[Test]])]
    )
    |}
    ~expect:
      [
        {
          name = Some "foo_finders";
          query = [AnyParameterConstraint (AnnotationConstraint IsAnnotatedTypeConstraint)];
          rule_kind = FunctionModel;
          productions =
            [
              ReturnTaint
                [
                  TaintAnnotation
                    (Model.Source
                       {
                         source = Sources.NamedSource "Test";
                         breadcrumbs = [];
                         path = [];
                         leaf_names = [];
                         leaf_name_provided = false;
                       });
                ];
            ];
        };
      ]
    ();
  assert_queries
    ~context
    ~model_source:
      {|
    ModelQuery(
       name = "foo_finders",
       find = "functions",
       where = AnyOf(
         any_parameter.annotation.is_annotated_type(),
         return_annotation.is_annotated_type(),
       ),
       model = [Returns([TaintSource[Test]])]
    )
    |}
    ~expect:
      [
        {
          name = Some "foo_finders";
          query =
            [
              AnyOf
                [
                  AnyParameterConstraint (AnnotationConstraint IsAnnotatedTypeConstraint);
                  ReturnConstraint IsAnnotatedTypeConstraint;
                ];
            ];
          rule_kind = FunctionModel;
          productions =
            [
              ReturnTaint
                [
                  TaintAnnotation
                    (Model.Source
                       {
                         source = Sources.NamedSource "Test";
                         breadcrumbs = [];
                         path = [];
                         leaf_names = [];
                         leaf_name_provided = false;
                       });
                ];
            ];
        };
      ]
    ();
  (* All parameters. *)
  assert_queries
    ~context
    ~model_source:
      {|
    ModelQuery(
     name = "foo_finders",
     find = "functions",
     where = name.matches("foo"),
     model = [AllParameters(TaintSource[Test])]
    )
  |}
    ~expect:
      [
        {
          name = Some "foo_finders";
          query = [NameConstraint "foo"];
          rule_kind = FunctionModel;
          productions =
            [
              AllParametersTaint
                {
                  excludes = [];
                  taint =
                    [
                      TaintAnnotation
                        (Model.Source
                           {
                             source = Sources.NamedSource "Test";
                             breadcrumbs = [];
                             path = [];
                             leaf_names = [];
                             leaf_name_provided = false;
                           });
                    ];
                };
            ];
        };
      ]
    ();
  assert_queries
    ~context
    ~model_source:
      {|
    ModelQuery(
     name = "foo_finders",
     find = "functions",
     where = name.matches("foo"),
     model = [AllParameters(TaintSource[Test], exclude="self")]
    )
  |}
    ~expect:
      [
        {
          name = Some "foo_finders";
          query = [NameConstraint "foo"];
          rule_kind = FunctionModel;
          productions =
            [
              AllParametersTaint
                {
                  excludes = ["self"];
                  taint =
                    [
                      TaintAnnotation
                        (Model.Source
                           {
                             source = Sources.NamedSource "Test";
                             breadcrumbs = [];
                             path = [];
                             leaf_names = [];
                             leaf_name_provided = false;
                           });
                    ];
                };
            ];
        };
      ]
    ();
  assert_queries
    ~context
    ~model_source:
      {|
    ModelQuery(
     name = "foo_finders",
     find = "functions",
     where = name.matches("foo"),
     model = [AllParameters(TaintSource[Test], exclude=["self", "other"])]
    )
  |}
    ~expect:
      [
        {
          name = Some "foo_finders";
          query = [NameConstraint "foo"];
          rule_kind = FunctionModel;
          productions =
            [
              AllParametersTaint
                {
                  excludes = ["self"; "other"];
                  taint =
                    [
                      TaintAnnotation
                        (Model.Source
                           {
                             source = Sources.NamedSource "Test";
                             breadcrumbs = [];
                             path = [];
                             leaf_names = [];
                             leaf_name_provided = false;
                           });
                    ];
                };
            ];
        };
      ]
    ();
  assert_queries
    ~context
    ~model_source:
      {|
    ModelQuery(
       name = "foo_finders",
       find = "functions",
       where = any_parameter.annotation.is_annotated_type(),
       model = [
         AllParameters(
           ParametricSourceFromAnnotation(pattern=DynamicSource, kind=Dynamic)
         )
       ]
    )
    |}
    ~expect:
      [
        {
          name = Some "foo_finders";
          query = [AnyParameterConstraint (AnnotationConstraint IsAnnotatedTypeConstraint)];
          rule_kind = FunctionModel;
          productions =
            [
              AllParametersTaint
                {
                  excludes = [];
                  taint =
                    [
                      ParametricSourceFromAnnotation
                        { source_pattern = "DynamicSource"; kind = "Dynamic" };
                    ];
                };
            ];
        };
      ]
    ();
  assert_queries
    ~context
    ~model_source:
      {|
    ModelQuery(
       name = "foo_finders",
       find = "functions",
       where = any_parameter.annotation.is_annotated_type(),
       model = [
         AllParameters(
           ParametricSinkFromAnnotation(pattern=DynamicSink, kind=Dynamic)
         )
       ]
    )
    |}
    ~expect:
      [
        {
          name = Some "foo_finders";
          query = [AnyParameterConstraint (AnnotationConstraint IsAnnotatedTypeConstraint)];
          rule_kind = FunctionModel;
          productions =
            [
              AllParametersTaint
                {
                  excludes = [];
                  taint =
                    [
                      ParametricSinkFromAnnotation { sink_pattern = "DynamicSink"; kind = "Dynamic" };
                    ];
                };
            ];
        };
      ]
    ();
  assert_queries
    ~context
    ~model_source:
      {|
    ModelQuery(
     find = "methods",
     where = parent.equals("Foo"),
     model = [Returns([TaintSource[Test], TaintSink[Test]])]
    )
  |}
    ~expect:
      [
        {
          name = None;
          query = [ParentConstraint (Equals "Foo")];
          rule_kind = MethodModel;
          productions =
            [
              ReturnTaint
                [
                  TaintAnnotation
                    (Model.Source
                       {
                         source = Sources.NamedSource "Test";
                         breadcrumbs = [];
                         path = [];
                         leaf_names = [];
                         leaf_name_provided = false;
                       });
                  TaintAnnotation
                    (Model.Sink
                       {
                         sink = Sinks.NamedSink "Test";
                         breadcrumbs = [];
                         path = [];
                         leaf_names = [];
                         leaf_name_provided = false;
                       });
                ];
            ];
        };
      ]
    ();
  assert_queries
    ~context
    ~model_source:
      {|
    ModelQuery(
     find = "methods",
     where = parent.extends("Foo"),
     model = [Returns([TaintSource[Test], TaintSink[Test]])]
    )
  |}
    ~expect:
      [
        {
          name = None;
          query = [ParentConstraint (Extends "Foo")];
          rule_kind = MethodModel;
          productions =
            [
              ReturnTaint
                [
                  TaintAnnotation
                    (Model.Source
                       {
                         source = Sources.NamedSource "Test";
                         breadcrumbs = [];
                         path = [];
                         leaf_names = [];
                         leaf_name_provided = false;
                       });
                  TaintAnnotation
                    (Model.Sink
                       {
                         sink = Sinks.NamedSink "Test";
                         breadcrumbs = [];
                         path = [];
                         leaf_names = [];
                         leaf_name_provided = false;
                       });
                ];
            ];
        };
      ]
    ();
  assert_queries
    ~context
    ~model_source:
      {|
    ModelQuery(
     find = "methods",
     where = parent.matches("Foo.*"),
     model = [Returns([TaintSource[Test], TaintSink[Test]])]
    )
  |}
    ~expect:
      [
        {
          name = None;
          query = [ParentConstraint (Matches (Re2.create_exn "Foo.*"))];
          rule_kind = MethodModel;
          productions =
            [
              ReturnTaint
                [
                  TaintAnnotation
                    (Model.Source
                       {
                         source = Sources.NamedSource "Test";
                         breadcrumbs = [];
                         path = [];
                         leaf_names = [];
                         leaf_name_provided = false;
                       });
                  TaintAnnotation
                    (Model.Sink
                       {
                         sink = Sinks.NamedSink "Test";
                         breadcrumbs = [];
                         path = [];
                         leaf_names = [];
                         leaf_name_provided = false;
                       });
                ];
            ];
        };
      ]
    ();

  assert_queries
    ~context
    ~model_source:
      {|
    ModelQuery(
     find = "methods",
     where = any_decorator.name.matches("foo"),
     model = [Returns([TaintSource[Test]])],
    )
  |}
    ~expect:
      [
        {
          name = None;
          query = [DecoratorNameConstraint "foo"];
          rule_kind = MethodModel;
          productions =
            [
              ReturnTaint
                [
                  TaintAnnotation
                    (Model.Source
                       {
                         source = Sources.NamedSource "Test";
                         breadcrumbs = [];
                         path = [];
                         leaf_names = [];
                         leaf_name_provided = false;
                       });
                ];
            ];
        };
      ]
    ();
  ()


let () =
  "taint_model"
  >::: [
         "attach_features" >:: test_attach_features;
         "class_models" >:: test_class_models;
         "cross_repository_models" >:: test_cross_repository_models;
         "demangle_class_attributes" >:: test_demangle_class_attributes;
         "filter_by_rules" >:: test_filter_by_rules;
         "invalid_models" >:: test_invalid_models;
         "partial_sinks" >:: test_partial_sinks;
         "query_parsing" >:: test_query_parsing;
         "sanitize" >:: test_sanitize;
         "skip_analysis" >:: test_skip_analysis;
         "sink_breadcrumbs" >:: test_sink_breadcrumbs;
         "sink_models" >:: test_sink_models;
         "source_breadcrumbs" >:: test_source_breadcrumbs;
         "source_models" >:: test_source_models;
         "taint_in_taint_out_models" >:: test_taint_in_taint_out_models;
         "taint_in_taint_out_models_alternate" >:: test_taint_in_taint_out_models_alternate;
         "taint_in_taint_out_update_models" >:: test_taint_in_taint_out_update_models;
         "taint_union_models" >:: test_union_models;
         "tito_breadcrumbs" >:: test_tito_breadcrumbs;
       ]
  |> Test.run
