# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import tempfile
import textwrap
from pathlib import Path
from typing import Dict, List, Optional, Sequence

import libcst as cst

import testslide
from libcst.metadata import CodePosition, CodeRange, MetadataWrapper

from ..coverage_data import (
    AnnotationCollector,
    AnnotationCountCollector,
    find_module_paths,
    FixmeCountCollector,
    FunctionAnnotationInfo,
    FunctionAnnotationKind,
    get_paths_to_collect,
    IgnoreCountCollector,
    module_from_code,
    module_from_path,
    ModuleMode,
    ParameterAnnotationInfo,
    ReturnAnnotationInfo,
    StrictCountCollector,
)
from ..tests import setup


def parse_code(code: str) -> MetadataWrapper:
    module = module_from_code(textwrap.dedent(code.rstrip()))
    if module is None:
        raise RuntimeError(f"Failed to parse code {code}")
    return module


class ParsingHelpersTest(testslide.TestCase):
    def test_module_from_path(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root)
            source_path = root_path / "source.py"
            source_path.write_text("reveal_type(42)")

            self.assertIsNotNone(module_from_path(source_path))
            self.assertIsNone(module_from_path(root_path / "nonexistent.py"))

    def test_module_from_code(self) -> None:
        self.assertIsNotNone(
            module_from_code(
                textwrap.dedent(
                    """
                    def foo() -> int:
                        pass
                    """
                )
            )
        )
        self.assertIsNone(
            module_from_code(
                textwrap.dedent(
                    """
                    def foo() ->
                    """
                )
            )
        )


class AnnotationCollectorTest(testslide.TestCase):
    maxDiff = 2000

    def _build_and_visit_annotation_collector(self, source: str) -> AnnotationCollector:
        source_module = parse_code(source)
        collector = AnnotationCollector()
        source_module.visit(collector)
        return collector

    def test_return_code_range(self) -> None:
        collector = self._build_and_visit_annotation_collector(
            """
            def foobar():
                pass
            """
        )
        returns = list(collector.returns())
        self.assertEqual(len(returns), 1)
        self.assertEqual(
            returns[0].code_range,
            CodeRange(CodePosition(2, 4), CodePosition(2, 10)),
        )

    def test_line_count(self) -> None:
        source_module = MetadataWrapper(cst.parse_module("# No trailing newline"))
        collector = AnnotationCollector()
        source_module.visit(collector)
        self.assertEqual(collector.line_count, 1)
        source_module = MetadataWrapper(cst.parse_module("# With trailing newline\n"))
        collector = AnnotationCollector()
        source_module.visit(collector)
        self.assertEqual(collector.line_count, 2)

    def _assert_function_annotations(
        self,
        code: str,
        expected: Sequence[FunctionAnnotationInfo],
    ) -> None:
        module = parse_code(code)
        collector = AnnotationCollector()
        module.visit(collector)
        actual = collector.functions
        self.assertEqual(
            actual,
            expected,
        )

    def test_function_annotations__standalone_no_annotations(self) -> None:
        self._assert_function_annotations(
            """
            def f(x):
                pass
            """,
            [
                FunctionAnnotationInfo(
                    code_range=CodeRange(
                        start=CodePosition(line=2, column=0),
                        end=CodePosition(line=3, column=8),
                    ),
                    annotation_kind=FunctionAnnotationKind.NOT_ANNOTATED,
                    returns=ReturnAnnotationInfo(
                        function_name="f",
                        is_annotated=False,
                        code_range=CodeRange(
                            start=CodePosition(line=2, column=4),
                            end=CodePosition(line=2, column=5),
                        ),
                    ),
                    parameters=[
                        ParameterAnnotationInfo(
                            function_name="f",
                            name="x",
                            is_annotated=False,
                            code_range=CodeRange(
                                start=CodePosition(line=2, column=6),
                                end=CodePosition(line=2, column=7),
                            ),
                        )
                    ],
                    is_method_or_classmethod=False,
                )
            ],
        )

    def test_function_annotations__standalone_partially_annotated(self) -> None:
        self._assert_function_annotations(
            """
            def f(x) -> None:
                pass

            def g(x: int):
                pass
            """,
            [
                FunctionAnnotationInfo(
                    code_range=CodeRange(
                        start=CodePosition(line=2, column=0),
                        end=CodePosition(line=3, column=8),
                    ),
                    annotation_kind=FunctionAnnotationKind.PARTIALLY_ANNOTATED,
                    returns=ReturnAnnotationInfo(
                        function_name="f",
                        is_annotated=True,
                        code_range=CodeRange(
                            start=CodePosition(line=2, column=4),
                            end=CodePosition(line=2, column=5),
                        ),
                    ),
                    parameters=[
                        ParameterAnnotationInfo(
                            function_name="f",
                            name="x",
                            is_annotated=False,
                            code_range=CodeRange(
                                start=CodePosition(line=2, column=6),
                                end=CodePosition(line=2, column=7),
                            ),
                        )
                    ],
                    is_method_or_classmethod=False,
                ),
                FunctionAnnotationInfo(
                    code_range=CodeRange(
                        start=CodePosition(line=5, column=0),
                        end=CodePosition(line=6, column=8),
                    ),
                    annotation_kind=FunctionAnnotationKind.PARTIALLY_ANNOTATED,
                    returns=ReturnAnnotationInfo(
                        function_name="g",
                        is_annotated=False,
                        code_range=CodeRange(
                            start=CodePosition(line=5, column=4),
                            end=CodePosition(line=5, column=5),
                        ),
                    ),
                    parameters=[
                        ParameterAnnotationInfo(
                            function_name="g",
                            name="x",
                            is_annotated=True,
                            code_range=CodeRange(
                                start=CodePosition(line=5, column=6),
                                end=CodePosition(line=5, column=7),
                            ),
                        )
                    ],
                    is_method_or_classmethod=False,
                ),
            ],
        )

    def test_function_annotations__standalone_fully_annotated(self) -> None:
        self._assert_function_annotations(
            """
            def f(x: int) -> None:
                pass
            """,
            [
                FunctionAnnotationInfo(
                    code_range=CodeRange(
                        start=CodePosition(line=2, column=0),
                        end=CodePosition(line=3, column=8),
                    ),
                    annotation_kind=FunctionAnnotationKind.FULLY_ANNOTATED,
                    returns=ReturnAnnotationInfo(
                        function_name="f",
                        is_annotated=True,
                        code_range=CodeRange(
                            start=CodePosition(line=2, column=4),
                            end=CodePosition(line=2, column=5),
                        ),
                    ),
                    parameters=[
                        ParameterAnnotationInfo(
                            function_name="f",
                            name="x",
                            is_annotated=True,
                            code_range=CodeRange(
                                start=CodePosition(line=2, column=6),
                                end=CodePosition(line=2, column=7),
                            ),
                        )
                    ],
                    is_method_or_classmethod=False,
                )
            ],
        )

    def test_function_annotations__annotated_method(self) -> None:
        self._assert_function_annotations(
            """
            class A:
                def f(self, x: int) -> None:
                    pass
            """,
            [
                FunctionAnnotationInfo(
                    code_range=CodeRange(
                        start=CodePosition(line=3, column=4),
                        end=CodePosition(line=4, column=12),
                    ),
                    annotation_kind=FunctionAnnotationKind.FULLY_ANNOTATED,
                    returns=ReturnAnnotationInfo(
                        function_name="A.f",
                        is_annotated=True,
                        code_range=CodeRange(
                            start=CodePosition(line=3, column=8),
                            end=CodePosition(line=3, column=9),
                        ),
                    ),
                    parameters=[
                        ParameterAnnotationInfo(
                            function_name="A.f",
                            name="self",
                            is_annotated=False,
                            code_range=CodeRange(
                                start=CodePosition(line=3, column=10),
                                end=CodePosition(line=3, column=14),
                            ),
                        ),
                        ParameterAnnotationInfo(
                            function_name="A.f",
                            name="x",
                            is_annotated=True,
                            code_range=CodeRange(
                                start=CodePosition(line=3, column=16),
                                end=CodePosition(line=3, column=17),
                            ),
                        ),
                    ],
                    is_method_or_classmethod=True,
                )
            ],
        )

    def test_function_annotations__partially_annotated_static_method(self) -> None:
        self._assert_function_annotations(
            """
            class A:

                @staticmethod
                def f(self, x: int) -> None:
                    pass
            """,
            [
                FunctionAnnotationInfo(
                    code_range=CodeRange(
                        start=CodePosition(line=5, column=4),
                        end=CodePosition(line=6, column=12),
                    ),
                    annotation_kind=FunctionAnnotationKind.PARTIALLY_ANNOTATED,
                    returns=ReturnAnnotationInfo(
                        function_name="A.f",
                        is_annotated=True,
                        code_range=CodeRange(
                            start=CodePosition(line=5, column=8),
                            end=CodePosition(line=5, column=9),
                        ),
                    ),
                    parameters=[
                        ParameterAnnotationInfo(
                            function_name="A.f",
                            name="self",
                            is_annotated=False,
                            code_range=CodeRange(
                                start=CodePosition(line=5, column=10),
                                end=CodePosition(line=5, column=14),
                            ),
                        ),
                        ParameterAnnotationInfo(
                            function_name="A.f",
                            name="x",
                            is_annotated=True,
                            code_range=CodeRange(
                                start=CodePosition(line=5, column=16),
                                end=CodePosition(line=5, column=17),
                            ),
                        ),
                    ],
                    is_method_or_classmethod=False,
                )
            ],
        )


class AnnotationCountCollectorTest(testslide.TestCase):
    def assert_counts(self, source: str, expected: Dict[str, int]) -> None:
        source_module = parse_code(source)
        result = AnnotationCountCollector().collect(source_module)
        self.assertDictEqual(
            expected,
            result.to_count_dict(),
        )

    def test_count_annotations(self) -> None:
        self.assert_counts(
            """
            def foo(x) -> int:
                pass
            """,
            {
                "annotated_return_count": 1,
                "annotated_globals_count": 0,
                "annotated_parameter_count": 0,
                "return_count": 1,
                "globals_count": 0,
                "parameter_count": 1,
                "attribute_count": 0,
                "annotated_attribute_count": 0,
                "function_count": 1,
                "partially_annotated_function_count": 1,
                "fully_annotated_function_count": 0,
                "line_count": 3,
            },
        )

        self.assert_counts(
            """
            def bar(x: int, y):
                pass
            """,
            {
                "annotated_return_count": 0,
                "annotated_globals_count": 0,
                "annotated_parameter_count": 1,
                "return_count": 1,
                "globals_count": 0,
                "parameter_count": 2,
                "attribute_count": 0,
                "annotated_attribute_count": 0,
                "function_count": 1,
                "partially_annotated_function_count": 1,
                "fully_annotated_function_count": 0,
                "line_count": 3,
            },
        )

        self.assert_counts(
            """
            a = foo()
            b: int = bar()
            """,
            {
                "annotated_return_count": 0,
                "annotated_globals_count": 2,
                "annotated_parameter_count": 0,
                "return_count": 0,
                "globals_count": 2,
                "parameter_count": 0,
                "attribute_count": 0,
                "annotated_attribute_count": 0,
                "function_count": 0,
                "partially_annotated_function_count": 0,
                "fully_annotated_function_count": 0,
                "line_count": 3,
            },
        )

        self.assert_counts(
            """
            class A:
                a: int = 100
                b = ""
            """,
            {
                "annotated_return_count": 0,
                "annotated_globals_count": 0,
                "annotated_parameter_count": 0,
                "return_count": 0,
                "globals_count": 0,
                "parameter_count": 0,
                "attribute_count": 2,
                "annotated_attribute_count": 2,
                "function_count": 0,
                "partially_annotated_function_count": 0,
                "fully_annotated_function_count": 0,
                "line_count": 4,
            },
        )

        # For now, don't count annotations inside of functions
        self.assert_counts(
            """
            def foo():
                a: int = 100
            """,
            {
                "annotated_return_count": 0,
                "annotated_globals_count": 0,
                "annotated_parameter_count": 0,
                "return_count": 1,
                "globals_count": 0,
                "parameter_count": 0,
                "attribute_count": 0,
                "annotated_attribute_count": 0,
                "function_count": 1,
                "partially_annotated_function_count": 0,
                "fully_annotated_function_count": 0,
                "line_count": 3,
            },
        )

        self.assert_counts(
            """
            def foo():
                def bar(x: int) -> int:
                    pass
            """,
            {
                "annotated_return_count": 1,
                "annotated_globals_count": 0,
                "annotated_parameter_count": 1,
                "return_count": 2,
                "globals_count": 0,
                "parameter_count": 1,
                "attribute_count": 0,
                "annotated_attribute_count": 0,
                "function_count": 2,
                "partially_annotated_function_count": 0,
                "fully_annotated_function_count": 1,
                "line_count": 4,
            },
        )

        self.assert_counts(
            """
            class A:
                def bar(self, x: int):
                    pass
            """,
            {
                "annotated_return_count": 0,
                "annotated_globals_count": 0,
                "annotated_parameter_count": 1,
                "return_count": 1,
                "globals_count": 0,
                "parameter_count": 1,
                "attribute_count": 0,
                "annotated_attribute_count": 0,
                "function_count": 1,
                "partially_annotated_function_count": 1,
                "fully_annotated_function_count": 0,
                "line_count": 4,
            },
        )

        self.assert_counts(
            """
            class A:
                def bar(this, x: int) -> None:
                    pass
            """,
            {
                "annotated_return_count": 1,
                "annotated_globals_count": 0,
                "annotated_parameter_count": 1,
                "return_count": 1,
                "globals_count": 0,
                "parameter_count": 1,
                "attribute_count": 0,
                "annotated_attribute_count": 0,
                "function_count": 1,
                "partially_annotated_function_count": 0,
                "fully_annotated_function_count": 1,
                "line_count": 4,
            },
        )

        self.assert_counts(
            """
            class A:
                @classmethod
                def bar(cls, x: int):
                    pass
            """,
            {
                "annotated_return_count": 0,
                "annotated_globals_count": 0,
                "annotated_parameter_count": 1,
                "return_count": 1,
                "globals_count": 0,
                "parameter_count": 1,
                "attribute_count": 0,
                "annotated_attribute_count": 0,
                "function_count": 1,
                "partially_annotated_function_count": 1,
                "fully_annotated_function_count": 0,
                "line_count": 5,
            },
        )

        self.assert_counts(
            """
            def bar(self, x: int):
                pass
            """,
            {
                "annotated_return_count": 0,
                "annotated_globals_count": 0,
                "annotated_parameter_count": 1,
                "return_count": 1,
                "globals_count": 0,
                "parameter_count": 2,
                "attribute_count": 0,
                "annotated_attribute_count": 0,
                "function_count": 1,
                "partially_annotated_function_count": 1,
                "fully_annotated_function_count": 0,
                "line_count": 3,
            },
        )

        self.assert_counts(
            """
            class A:
                @staticmethod
                def bar(self, x: int) -> None:
                    pass
            """,
            {
                "annotated_return_count": 1,
                "annotated_globals_count": 0,
                "annotated_parameter_count": 1,
                "return_count": 1,
                "globals_count": 0,
                "parameter_count": 2,
                "attribute_count": 0,
                "annotated_attribute_count": 0,
                "function_count": 1,
                "partially_annotated_function_count": 1,
                "fully_annotated_function_count": 0,
                "line_count": 5,
            },
        )

        self.assert_counts(
            """
            def foo(x: str) -> str:
                return x
            """,
            {
                "return_count": 1,
                "annotated_return_count": 1,
                "globals_count": 0,
                "annotated_globals_count": 0,
                "parameter_count": 1,
                "annotated_parameter_count": 1,
                "attribute_count": 0,
                "annotated_attribute_count": 0,
                "function_count": 1,
                "partially_annotated_function_count": 0,
                "fully_annotated_function_count": 1,
                "line_count": 3,
            },
        )
        self.assert_counts(
            """
            class Test:
                def foo(self, input: str) -> None:
                    class Foo:
                        pass

                    pass

                def bar(self, input: str) -> None:
                    pass
            """,
            {
                "return_count": 2,
                "annotated_return_count": 2,
                "globals_count": 0,
                "annotated_globals_count": 0,
                "parameter_count": 2,
                "annotated_parameter_count": 2,
                "attribute_count": 0,
                "annotated_attribute_count": 0,
                "function_count": 2,
                "partially_annotated_function_count": 0,
                "fully_annotated_function_count": 2,
                "line_count": 10,
            },
        )
        # Ensure globals and attributes with literal values are considered annotated.
        self.assert_counts(
            """
            x: int = 1
            y = 2
            z = foo

            class Foo:
                x = 1
                y = foo
            """,
            {
                "return_count": 0,
                "annotated_return_count": 0,
                "globals_count": 3,
                "annotated_globals_count": 3,
                "parameter_count": 0,
                "annotated_parameter_count": 0,
                "attribute_count": 2,
                "annotated_attribute_count": 2,
                "function_count": 0,
                "partially_annotated_function_count": 0,
                "fully_annotated_function_count": 0,
                "line_count": 8,
            },
        )

    def test_count_annotations__partially_annotated_methods(self) -> None:
        self.assert_counts(
            """
            class A:
                def bar(self): ...
            """,
            {
                "return_count": 1,
                "annotated_return_count": 0,
                "globals_count": 0,
                "annotated_globals_count": 0,
                "parameter_count": 0,
                "annotated_parameter_count": 0,
                "attribute_count": 0,
                "annotated_attribute_count": 0,
                "function_count": 1,
                "partially_annotated_function_count": 0,
                "fully_annotated_function_count": 0,
                "line_count": 3,
            },
        )
        self.assert_counts(
            """
            class A:
                def bar(self) -> None: ...
            """,
            {
                "return_count": 1,
                "annotated_return_count": 1,
                "globals_count": 0,
                "annotated_globals_count": 0,
                "parameter_count": 0,
                "annotated_parameter_count": 0,
                "attribute_count": 0,
                "annotated_attribute_count": 0,
                "function_count": 1,
                "partially_annotated_function_count": 0,
                "fully_annotated_function_count": 1,
                "line_count": 3,
            },
        )
        self.assert_counts(
            """
            class A:
                def baz(self, x): ...
            """,
            {
                "return_count": 1,
                "annotated_return_count": 0,
                "globals_count": 0,
                "annotated_globals_count": 0,
                "parameter_count": 1,
                "annotated_parameter_count": 0,
                "attribute_count": 0,
                "annotated_attribute_count": 0,
                "function_count": 1,
                "partially_annotated_function_count": 0,
                "fully_annotated_function_count": 0,
                "line_count": 3,
            },
        )
        self.assert_counts(
            """
            class A:
                def baz(self, x) -> None: ...
            """,
            {
                "return_count": 1,
                "annotated_return_count": 1,
                "globals_count": 0,
                "annotated_globals_count": 0,
                "parameter_count": 1,
                "annotated_parameter_count": 0,
                "attribute_count": 0,
                "annotated_attribute_count": 0,
                "function_count": 1,
                "partially_annotated_function_count": 1,
                "fully_annotated_function_count": 0,
                "line_count": 3,
            },
        )
        self.assert_counts(
            """
            class A:
                def baz(self: Foo): ...
            """,
            {
                "return_count": 1,
                "annotated_return_count": 0,
                "globals_count": 0,
                "annotated_globals_count": 0,
                "parameter_count": 0,
                "annotated_parameter_count": 0,
                "attribute_count": 0,
                "annotated_attribute_count": 0,
                "function_count": 1,
                "partially_annotated_function_count": 1,
                "fully_annotated_function_count": 0,
                "line_count": 3,
            },
        )


class FunctionAnnotationKindTest(testslide.TestCase):

    ANNOTATION = cst.Annotation(cst.Name("Foo"))

    def _parameter(self, name: str, annotated: bool) -> cst.Param:
        return cst.Param(
            name=cst.Name(name),
            annotation=self.ANNOTATION if annotated else None,
        )

    def test_from_function_data(self) -> None:
        self.assertEqual(
            FunctionAnnotationKind.from_function_data(
                is_return_annotated=True,
                is_non_static_method=False,
                parameters=[
                    self._parameter("x0", annotated=True),
                    self._parameter("x1", annotated=True),
                    self._parameter("x2", annotated=True),
                ],
            ),
            FunctionAnnotationKind.FULLY_ANNOTATED,
        )
        self.assertEqual(
            FunctionAnnotationKind.from_function_data(
                is_return_annotated=True,
                is_non_static_method=False,
                parameters=[
                    self._parameter("x0", annotated=False),
                    self._parameter("x1", annotated=False),
                    self._parameter("x2", annotated=False),
                ],
            ),
            FunctionAnnotationKind.PARTIALLY_ANNOTATED,
        )
        self.assertEqual(
            FunctionAnnotationKind.from_function_data(
                is_return_annotated=False,
                is_non_static_method=False,
                parameters=[
                    self._parameter("x0", annotated=False),
                    self._parameter("x1", annotated=False),
                    self._parameter("x2", annotated=False),
                ],
            ),
            FunctionAnnotationKind.NOT_ANNOTATED,
        )
        self.assertEqual(
            FunctionAnnotationKind.from_function_data(
                is_return_annotated=False,
                is_non_static_method=False,
                parameters=[
                    self._parameter("x0", annotated=True),
                    self._parameter("x1", annotated=False),
                    self._parameter("x2", annotated=False),
                ],
            ),
            FunctionAnnotationKind.PARTIALLY_ANNOTATED,
        )
        # An untyped `self` parameter of a method is not required, but it also
        # does not count for partial annotation. As per PEP 484, we need an
        # explicitly annotated parameter or return before we'll typecheck a method.
        #
        # Check several edge cases related to this.
        self.assertEqual(
            FunctionAnnotationKind.from_function_data(
                is_return_annotated=True,
                is_non_static_method=True,
                parameters=[
                    self._parameter("self", annotated=False),
                    self._parameter("x1", annotated=False),
                ],
            ),
            FunctionAnnotationKind.PARTIALLY_ANNOTATED,
        )
        self.assertEqual(
            FunctionAnnotationKind.from_function_data(
                is_return_annotated=True,
                is_non_static_method=True,
                parameters=[
                    self._parameter("self", annotated=True),
                    self._parameter("x1", annotated=False),
                ],
            ),
            FunctionAnnotationKind.PARTIALLY_ANNOTATED,
        )
        self.assertEqual(
            FunctionAnnotationKind.from_function_data(
                is_return_annotated=True,
                is_non_static_method=True,
                parameters=[
                    self._parameter("self", annotated=False),
                ],
            ),
            FunctionAnnotationKind.FULLY_ANNOTATED,
        )
        # An explicitly annotated `self` suffices to make Pyre typecheck the method.
        self.assertEqual(
            FunctionAnnotationKind.from_function_data(
                is_return_annotated=False,
                is_non_static_method=True,
                parameters=[
                    self._parameter("self", annotated=True),
                ],
            ),
            FunctionAnnotationKind.PARTIALLY_ANNOTATED,
        )


class FixmeCountCollectorTest(testslide.TestCase):
    def assert_counts(
        self,
        source: str,
        expected_codes: Dict[int, List[int]],
        expected_no_codes: List[int],
    ) -> None:
        source_module = parse_code(source.replace("FIXME", "pyre-fixme"))
        result = FixmeCountCollector().collect(source_module)
        self.assertEqual(expected_codes, result.code)
        self.assertEqual(expected_no_codes, result.no_code)

    def test_count_fixmes(self) -> None:
        # no error codes (none in first example, unparseable in second)
        self.assert_counts(
            """
            # FIXME
            # FIXME[8,]
            """,
            {},
            [2, 3],
        )
        self.assert_counts(
            """
            # FIXME[3]: Example Error Message
            # FIXME[3, 4]: Another Message

            # FIXME[34]: Example
            """,
            {3: [2, 3], 4: [3], 34: [5]},
            [],
        )
        self.assert_counts(
            """
            def foo(x: str) -> int:
                return x  # FIXME[7]
            """,
            {7: [3]},
            [],
        )
        self.assert_counts(
            """
            def foo(x: str) -> int:
                # FIXME[7]: comments
                return x
            """,
            {7: [3]},
            [],
        )
        self.assert_counts(
            """
            def foo(x: str) -> int:
                return x  # FIXME
            """,
            {},
            [3],
        )
        self.assert_counts(
            """
            def foo(x: str) -> int:
                return x  # FIXME: comments
            """,
            {},
            [3],
        )
        self.assert_counts(
            """
            def foo(x: str) -> int:
                return x # unrelated # FIXME[7]
            """,
            {7: [3]},
            [],
        )
        self.assert_counts(
            """
            def foo(x: str) -> int:
                return x # unrelated   #  FIXME[7] comments
            """,
            {7: [3]},
            [],
        )
        self.assert_counts(
            """
            def foo(x: str) -> int:
                return x # FIXME[7, 8]
            """,
            {7: [3], 8: [3]},
            [],
        )


class IgnoreCountCollectorTest(testslide.TestCase):
    maxDiff = 2000

    def assert_counts(
        self,
        source: str,
        expected_codes: Dict[int, List[int]],
        expected_no_codes: List[int],
    ) -> None:
        source_module = parse_code(source.replace("IGNORE", "pyre-ignore"))
        result = IgnoreCountCollector().collect(source_module)
        self.assertEqual(expected_codes, result.code)
        self.assertEqual(expected_no_codes, result.no_code)

    def test_count_ignores(self) -> None:
        self.assert_counts("# IGNORE[2]: Example Error Message", {2: [1]}, [])
        self.assert_counts(
            """
            # IGNORE[3]: Example Error Message

            # IGNORE[34]: Example
            """,
            {3: [2], 34: [4]},
            [],
        )
        self.assert_counts(
            """
            # IGNORE[2]: Example Error Message

            # IGNORE[2]: message
            """,
            {2: [2, 4]},
            [],
        )


class StrictCountCollectorTest(testslide.TestCase):
    def assert_counts(
        self,
        source: str,
        default_strict: bool,
        mode: ModuleMode,
        explicit_comment_line: Optional[int],
    ) -> None:
        source_module = parse_code(source)
        result = StrictCountCollector(default_strict).collect(source_module)
        self.assertEqual(mode, result.mode)
        self.assertEqual(explicit_comment_line, result.explicit_comment_line)

    def test_strict_files(self) -> None:
        self.assert_counts(
            """
            # pyre-unsafe

            def foo():
                return 1
            """,
            default_strict=True,
            mode=ModuleMode.UNSAFE,
            explicit_comment_line=2,
        )
        self.assert_counts(
            """
            # pyre-strict
            def foo():
                return 1
            """,
            default_strict=False,
            mode=ModuleMode.STRICT,
            explicit_comment_line=2,
        )
        self.assert_counts(
            """
            def foo():
                return 1
            """,
            default_strict=False,
            mode=ModuleMode.UNSAFE,
            explicit_comment_line=None,
        )
        self.assert_counts(
            """
            def foo():
                return 1
            """,
            default_strict=True,
            mode=ModuleMode.STRICT,
            explicit_comment_line=None,
        )
        self.assert_counts(
            """
            # pyre-ignore-all-errors
            def foo():
                return 1
            """,
            default_strict=True,
            mode=ModuleMode.UNSAFE,
            explicit_comment_line=2,
        )
        self.assert_counts(
            """
            def foo(x: str) -> int:
                return x
            """,
            default_strict=False,
            mode=ModuleMode.UNSAFE,
            explicit_comment_line=None,
        )
        self.assert_counts(
            """
            #  pyre-strict
            def foo(x: str) -> int:
                return x
            """,
            default_strict=False,
            mode=ModuleMode.STRICT,
            explicit_comment_line=2,
        )
        self.assert_counts(
            """
            #  pyre-ignore-all-errors[56]
            def foo(x: str) -> int:
                return x
            """,
            default_strict=True,
            mode=ModuleMode.STRICT,
            explicit_comment_line=None,
        )


class ModuleFindingHelpersTest(testslide.TestCase):
    def test_get_paths_to_collect__duplicate_directories(self) -> None:
        self.assertCountEqual(
            get_paths_to_collect(
                [Path("/root/foo.py"), Path("/root/bar.py"), Path("/root/foo.py")],
                root=Path("/root"),
            ),
            [Path("/root/foo.py"), Path("/root/bar.py")],
        )

        self.assertCountEqual(
            get_paths_to_collect(
                [Path("/root/foo"), Path("/root/bar"), Path("/root/foo")],
                root=Path("/root"),
            ),
            [Path("/root/foo"), Path("/root/bar")],
        )

    def test_get_paths_to_collect__expand_directories(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root).resolve()  # resolve is necessary on OSX 11.6
            with setup.switch_working_directory(root_path):
                self.assertCountEqual(
                    get_paths_to_collect(
                        [Path("foo.py"), Path("bar.py")],
                        root=root_path,
                    ),
                    [root_path / "foo.py", root_path / "bar.py"],
                )

    def test_get_paths_to_collect__invalid_given_subdirectory(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root).resolve()  # resolve is necessary on OSX 11.6
            with setup.switch_working_directory(root_path):
                # this is how a valid call behaves: subdirectory lives under project_root
                self.assertCountEqual(
                    get_paths_to_collect(
                        [Path("project_root/subdirectory")],
                        root=root_path / "project_root",
                    ),
                    [root_path / "project_root/subdirectory"],
                )
                # ./subdirectory isn't part of ./project_root
                self.assertRaisesRegex(
                    ValueError,
                    ".* is not nested under the project .*",
                    get_paths_to_collect,
                    [Path("subdirectory")],
                    root=root_path / "project_root",
                )
                # ./subdirectory isn't part of ./local_root
                self.assertRaisesRegex(
                    ValueError,
                    ".* is not nested under the project .*",
                    get_paths_to_collect,
                    [Path("subdirectory")],
                    root=root_path / "local_root",
                )

    def test_get_paths_to_collect__no_explicit_paths(self) -> None:
        self.assertCountEqual(
            get_paths_to_collect(
                None,
                root=Path("/root/local"),
            ),
            [Path("/root/local")],
        )

    def test_find_module_paths__basic(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root)
            setup.ensure_files_exist(
                root_path,
                ["s0.py", "a/s1.py", "b/s2.py", "b/c/s3.py", "b/s4.txt", "b/__s5.py"],
            )
            setup.ensure_directories_exists(root_path, ["b/d"])
            self.assertCountEqual(
                find_module_paths(
                    [
                        root_path / "a/s1.py",
                        root_path / "b/s2.py",
                        root_path / "b/s4.txt",
                    ],
                    excludes=[],
                ),
                [
                    root_path / "a/s1.py",
                    root_path / "b/s2.py",
                ],
            )
            self.assertCountEqual(
                find_module_paths([root_path], excludes=[]),
                [
                    root_path / "s0.py",
                    root_path / "a/s1.py",
                    root_path / "b/s2.py",
                    root_path / "b/c/s3.py",
                ],
            )

    def test_find_module_paths__with_exclude(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root)
            setup.ensure_files_exist(
                root_path,
                ["s0.py", "a/s1.py", "b/s2.py", "b/c/s3.py", "b/s4.txt", "b/__s5.py"],
            )
            setup.ensure_directories_exists(root_path, ["b/d"])
            self.assertCountEqual(
                find_module_paths(
                    [
                        root_path / "a/s1.py",
                        root_path / "b/s2.py",
                        root_path / "b/s4.txt",
                    ],
                    excludes=[r".*2\.py"],
                ),
                [
                    root_path / "a/s1.py",
                ],
            )
            self.assertCountEqual(
                find_module_paths(
                    [root_path],
                    excludes=[r".*2\.py"],
                ),
                [
                    root_path / "s0.py",
                    root_path / "a/s1.py",
                    root_path / "b/c/s3.py",
                ],
            )
