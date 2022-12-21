# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import json
from pathlib import Path

import testslide

from .. import code_navigation_request, protocol as lsp


class CodeNavigationRequestsTest(testslide.TestCase):
    def test_serialize_request(self) -> None:
        hover_request = code_navigation_request.HoverRequest(
            path=Path("/a/b.py"),
            overlay_id=None,
            position=lsp.PyrePosition(line=1, character=2),
        )
        self.assertEqual(
            hover_request.to_json(),
            [
                "Hover",
                {
                    "module": ["OfPath", "/a/b.py"],
                    "overlay_id": None,
                    "position": {"line": 1, "column": 2},
                },
            ],
        )

        hover_request = code_navigation_request.HoverRequest(
            path=Path("/a/b.py"),
            overlay_id="overlay_key",
            position=lsp.PyrePosition(line=1, character=2),
        )
        self.assertEqual(
            hover_request.to_json(),
            [
                "Hover",
                {
                    "module": ["OfPath", "/a/b.py"],
                    "overlay_id": "overlay_key",
                    "position": {"line": 1, "column": 2},
                },
            ],
        )
        definition_request = code_navigation_request.LocationOfDefinitionRequest(
            path=Path("/a/b.py"),
            overlay_id="overlay_key",
            position=lsp.PyrePosition(line=1, character=2),
        )
        self.assertEqual(
            definition_request.to_json(),
            [
                "LocationOfDefinition",
                {
                    "module": ["OfPath", "/a/b.py"],
                    "overlay_id": "overlay_key",
                    "position": {"line": 1, "column": 2},
                },
            ],
        )

    def test_parse_raw_response(self) -> None:
        raw_response = json.dumps(
            [
                "NotHover",
                {"contents": [{"kind": ["PlainText"], "value": "`int`"}]},
            ]
        )
        self.assertEqual(
            code_navigation_request.parse_raw_response(
                raw_response,
                expected_response_kind="Hover",
                response_type=code_navigation_request.HoverResponse,
            ),
            code_navigation_request.ErrorResponse(
                f"Invalid response {raw_response} to hover request."
            ),
        )

        raw_response = json.dumps(
            [
                "Hover",
                {"contents": [{"kind": ["PlainText"], "value": "`int`"}]},
                "ExtraField",
            ]
        )

        self.assertEqual(
            code_navigation_request.parse_raw_response(
                raw_response,
                expected_response_kind="Hover",
                response_type=code_navigation_request.HoverResponse,
            ),
            code_navigation_request.ErrorResponse(
                f"Invalid response {raw_response} to hover request."
            ),
        )

    def test_hover_response(self) -> None:
        response = {"contents": [{"value": "int", "docstring": "test docstring"}]}
        self.assertEqual(
            code_navigation_request.parse_response(
                response, response_type=code_navigation_request.HoverResponse
            ),
            code_navigation_request.HoverResponse(
                contents=[
                    lsp.PyreHoverResponse(value="int", docstring="test docstring")
                ]
            ),
        )

        # Note that there's a type error here in the TypedDict, but we happily parse it in our json_mixins, even
        # with the cached_schema().
        response = {"contents": [{"value": 32, "docstring": None}]}
        self.assertEqual(
            code_navigation_request.parse_response(
                response, response_type=code_navigation_request.HoverResponse
            ),
            code_navigation_request.HoverResponse(
                contents=[
                    # pyre-ignore[6]: This is documenting a known type error, see comments in test above.
                    lsp.PyreHoverResponse(value=32)
                ]
            ),
        )

    def test_definition_response(self) -> None:
        response = {
            "definitions": [
                {
                    "path": "/a/b.py",
                    "range": {
                        "start": {"line": 1, "column": 2},
                        "stop": {"line": 1, "column": 6},
                    },
                }
            ]
        }
        self.assertEqual(
            code_navigation_request.parse_response(
                response,
                response_type=code_navigation_request.LocationOfDefinitionResponse,
            ),
            code_navigation_request.LocationOfDefinitionResponse(
                definitions=[
                    code_navigation_request.DefinitionResponse(
                        path="/a/b.py",
                        range=code_navigation_request.CodeNavigationRange(
                            code_navigation_request.CodeNavigationPosition(
                                line=1, column=2
                            ),
                            code_navigation_request.CodeNavigationPosition(
                                line=1, column=6
                            ),
                        ),
                    )
                ]
            ),
        )

    def test_local_update_json(self) -> None:
        local_update = code_navigation_request.LocalUpdate(
            path=Path("/a/b.py"),
            content="def foo() -> int: pass\n",
            overlay_id="/a/b.py 1234",
        )
        self.assertEqual(
            local_update.to_json(),
            [
                "LocalUpdate",
                {
                    "module": ["OfPath", "/a/b.py"],
                    "content": "def foo() -> int: pass\n",
                    "overlay_id": "/a/b.py 1234",
                },
            ],
        )

    def test_file_opened_json(self) -> None:
        local_update = code_navigation_request.FileOpened(
            path=Path("/a/b.py"),
            content="def foo() -> int: pass\n",
            overlay_id="/a/b.py 1234",
        )
        self.assertEqual(
            local_update.to_json(),
            [
                "FileOpened",
                {
                    "path": "/a/b.py",
                    "content": "def foo() -> int: pass\n",
                    "overlay_id": "/a/b.py 1234",
                },
            ],
        )

    def test_file_closed_json(self) -> None:
        local_update = code_navigation_request.FileClosed(
            path=Path("/a/b.py"),
            overlay_id="/a/b.py 1234",
        )
        self.assertEqual(
            local_update.to_json(),
            [
                "FileClosed",
                {
                    "path": "/a/b.py",
                    "overlay_id": "/a/b.py 1234",
                },
            ],
        )

    def test_superclasses_request_json(self) -> None:
        superclasses_request = code_navigation_request.SuperclassesRequest(
            class_=code_navigation_request.ClassExpression(
                module=code_navigation_request.ModuleOfName("a"), qualified_name="C"
            ),
            overlay_id=None,
        )
        self.assertEqual(
            superclasses_request.to_json(),
            [
                "Superclasses",
                {
                    "class": {"module": ["OfName", "a"], "qualified_name": "C"},
                    "overlay_id": None,
                },
            ],
        )

    def test_superclasses_response_from_json(self) -> None:
        superclasses_response = (
            code_navigation_request.SuperclassesResponse.cached_schema().load(
                {
                    "superclasses": [
                        {
                            "module": ["OfName", "typing"],
                            "qualified_name": "Sequence",
                        },
                        {
                            "module": ["OfName", "typing"],
                            "qualified_name": "Collection",
                        },
                    ]
                }
            )
        )
        self.assertIsInstance(
            superclasses_response, code_navigation_request.SuperclassesResponse
        )
        superclasses = superclasses_response.superclasses
        self.assertEqual(len(superclasses), 2)
        self.assertEqual(
            superclasses[0],
            code_navigation_request.ClassExpression(
                code_navigation_request.ModuleOfName("typing"), "Sequence"
            ),
        )

        # OfPath.
        superclasses_response = (
            code_navigation_request.SuperclassesResponse.cached_schema().load(
                {
                    "superclasses": [
                        {
                            "module": ["OfPath", "/a/b/typing.py"],
                            "qualified_name": "Sequence",
                        },
                    ]
                }
            )
        )
        self.assertIsInstance(
            superclasses_response, code_navigation_request.SuperclassesResponse
        )
        superclasses = superclasses_response.superclasses
        self.assertEqual(len(superclasses), 1)
        self.assertEqual(
            superclasses[0],
            code_navigation_request.ClassExpression(
                code_navigation_request.ModuleOfPath(Path("/a/b/typing.py")), "Sequence"
            ),
        )

        # Invalid module kind.
        with self.assertRaisesRegex(AssertionError, "JSON must be a list of form"):
            code_navigation_request.SuperclassesResponse.cached_schema().load(
                {
                    "superclasses": [
                        {
                            "module": ["OfInvalid", "/a/b/typing.py"],
                            "qualified_name": "Sequence",
                        },
                    ]
                }
            )
