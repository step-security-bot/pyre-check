# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from builtins import _test_source, _test_sink
from typing import Any, MutableMapping
from typing_extensions import Self
from pyre_extensions import ReadOnly


class A:
    def __init__(self) -> None:
        self.B: str = ""
        self.mapping: MutableMapping[str, Any] = {}

    def self_readonly_str(
        self: ReadOnly[Self]
    ) -> None:
        _test_sink(self.B)

    def self_untyped_str(
        self
    ) -> None:
        _test_sink(self.B)

    def self_readonly_map(
        self: ReadOnly[Self]
    ) -> None:
        # pyre-ignore[3005]: Ignore ReadOnly Violation
        _test_sink(self.mapping.get(""))

    def self_untyped_map(
        self
    ) -> None:
        _test_sink(self.mapping.get(""))

    def readonly_tito(self, x: ReadOnly[str]):
        return x


def readonly_tito():
    a = A()
    x = a.readonly_tito(_test_source())
    _test_sink(x)


class Foo:
    tainted: str = ""
    not_tainted: str = ""


def readonly_foo_tainted(foo: ReadOnly[Foo]) -> None:
    # TODO(T162446777): ReadOnly False Negative
    _test_sink(foo.tainted)


def readonly_foo_not_tainted(foo: ReadOnly[Foo]) -> None:
    _test_sink(foo.not_tainted)


def regular_foo_tainted(foo: Foo) -> None:
    _test_sink(foo.tainted)


def regular_foo_not_tainted(foo: Foo) -> None:
    _test_sink(foo.not_tainted)
