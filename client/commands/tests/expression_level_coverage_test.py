# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import tempfile
from pathlib import Path
from typing import Iterable, List

import testslide

from ... import command_arguments, configuration
from ...tests import setup

from .. import expression_level_coverage, frontend_configuration

from ..query import Response


class ExpressionLevelTest(testslide.TestCase):
    def test_get_expression_level_coverage_response(self) -> None:
        self.assertEqual(
            expression_level_coverage._get_expression_level_coverage_response(
                Response(
                    {
                        "response": [
                            {
                                "path": "test.py",
                                "total_expressions": 7,
                                "coverage_gaps": [
                                    {
                                        "location": {
                                            "start": {"line": 11, "column": 16},
                                            "stop": {"line": 11, "column": 17},
                                        },
                                        "type_": "typing.Any",
                                        "reason": ["TypeIsAny"],
                                    },
                                ],
                            }
                        ]
                    }
                ).payload,
            ),
            [
                expression_level_coverage.ExpressionLevelCoverage(
                    path="test.py",
                    total_expressions=7,
                    coverage_gaps=[
                        expression_level_coverage.CoverageGap(
                            location=expression_level_coverage.Location(
                                start=expression_level_coverage.Pair(
                                    line=11, column=16
                                ),
                                stop=expression_level_coverage.Pair(line=11, column=17),
                            ),
                            type_="typing.Any",
                            reason=["TypeIsAny"],
                        )
                    ],
                )
            ],
        )
        with self.assertRaises(expression_level_coverage.ErrorParsingFailure):
            expression_level_coverage._get_expression_level_coverage_response(
                "garbage input"
            )
        with self.assertRaises(expression_level_coverage.ErrorParsingFailure):
            expression_level_coverage._get_expression_level_coverage_response(
                {
                    "response": [
                        {
                            "paths": "path_not_paths.py",
                            "total_expressions": 0,
                            "coverage_gaps": [],
                        }
                    ]
                }
            )

    def test_calculate_percent_covered(self) -> None:
        self.assertEqual(
            expression_level_coverage._calculate_percent_covered(0, 0), 100.0
        )
        self.assertEqual(
            expression_level_coverage._calculate_percent_covered(3, 7), 57.14
        )

    def test_get_total_and_uncovered_expressions(self) -> None:
        coverage = expression_level_coverage.ExpressionLevelCoverage(
            path="test.py",
            total_expressions=7,
            coverage_gaps=[
                expression_level_coverage.CoverageGap(
                    location=expression_level_coverage.Location(
                        start=expression_level_coverage.Pair(line=11, column=16),
                        stop=expression_level_coverage.Pair(line=11, column=17),
                    ),
                    type_="typing.Any",
                    reason=["TypeIsAny"],
                )
            ],
        )
        self.assertEqual(
            expression_level_coverage._get_total_and_uncovered_expressions(coverage),
            (7, 1),
        )

    def test_summary_expression_level_coverage(self) -> None:
        def assert_summary_expression_level_coverage(
            response: object, expected: str
        ) -> None:
            self.assertEqual(
                expression_level_coverage.summary_expression_level(response),
                expected,
            )

        assert_summary_expression_level_coverage(
            Response({"response": []}).payload,
            "Overall: 100.0% expressions are covered",
        )
        assert_summary_expression_level_coverage(
            Response(
                {
                    "response": [
                        {
                            "path": "test.py",
                            "total_expressions": 0,
                            "coverage_gaps": [],
                        }
                    ]
                }
            ).payload,
            "test.py: 100.0% expressions are covered\nOverall: 100.0% expressions are covered",
        )
        assert_summary_expression_level_coverage(
            Response(
                {
                    "response": [
                        {
                            "path": "test.py",
                            "total_expressions": 7,
                            "coverage_gaps": [
                                {
                                    "location": {
                                        "start": {"line": 11, "column": 16},
                                        "stop": {"line": 11, "column": 17},
                                    },
                                    "type_": "typing.Any",
                                    "reason": ["TypeIsAny"],
                                },
                                {
                                    "location": {
                                        "start": {"line": 12, "column": 11},
                                        "stop": {"line": 12, "column": 12},
                                    },
                                    "type_": "typing.Any",
                                    "reason": ["TypeIsAny"],
                                },
                            ],
                        }
                    ]
                }
            ).payload,
            "test.py: 71.43% expressions are covered\nOverall: 71.43% expressions are covered",
        )
        assert_summary_expression_level_coverage(
            Response(
                {
                    "response": [
                        {
                            "path": "library.py",
                            "total_expressions": 4,
                            "coverage_gaps": [],
                        },
                        {
                            "path": "test.py",
                            "total_expressions": 7,
                            "coverage_gaps": [
                                {
                                    "location": {
                                        "start": {"line": 11, "column": 16},
                                        "stop": {"line": 11, "column": 17},
                                    },
                                    "type_": "typing.Any",
                                    "reason": ["TypeIsAny"],
                                },
                                {
                                    "location": {
                                        "start": {"line": 12, "column": 11},
                                        "stop": {"line": 12, "column": 12},
                                    },
                                    "type_": "typing.Any",
                                    "reason": ["TypeIsAny"],
                                },
                            ],
                        },
                    ]
                }
            ).payload,
            "library.py: 100.0% expressions are covered\ntest.py: 71.43% expressions are covered\nOverall: 81.82% expressions are covered",
        )

    def test_get_path_list(self) -> None:
        def assert_get_path_list(response: Iterable[str], expected: List[str]) -> None:
            with tempfile.TemporaryDirectory() as root:
                root_path = Path(root).resolve()
                setup.ensure_directories_exists(
                    root_path, [".pyre", "allows", "blocks", "search", "local/src"]
                )
                setup.write_configuration_file(
                    root_path,
                    {
                        "do_not_ignore_errors_in": ["allows", "nonexistent"],
                        "ignore_all_errors": ["blocks", "nonexistent"],
                        "exclude": ["exclude"],
                        "extensions": [".ext", "invalid_extension"],
                        "workers": 42,
                        "search_path": ["search", "nonexistent"],
                        "strict": True,
                    },
                )
                setup.write_configuration_file(
                    root_path, {"source_directories": ["src"]}, relative="local"
                )

                temp_configuration = configuration.create_configuration(
                    command_arguments.CommandArguments(
                        local_configuration="local",
                        dot_pyre_directory=root_path / ".pyre",
                    ),
                    root_path,
                )

                self.assertEqual(
                    expression_level_coverage.get_path_list(
                        frontend_configuration.OpenSource(temp_configuration),
                        "/fake/path",
                        response,
                    ),
                    expected,
                )

        assert_get_path_list([], [])
        assert_get_path_list(["test.py"], ["/fake/path/test.py"])
        assert_get_path_list(["@arguments.txt"], ["@/fake/path/arguments.txt"])
        assert_get_path_list(
            ["test.py", "@arguments.txt"],
            ["/fake/path/test.py", "@/fake/path/arguments.txt"],
        )
        assert_get_path_list(["../other_path/test.py"], ["/fake/other_path/test.py"])
        assert_get_path_list(
            ["@../other_path/arguments.txt"],
            ["@/fake/path/../other_path/arguments.txt"],
        )
        assert_get_path_list(
            ["../other_path/test.py", "@../other_path/arguments.txt"],
            [
                "/fake/other_path/test.py",
                "@/fake/path/../other_path/arguments.txt",
            ],
        )
