"""Unit tests that check this app against the Postman collection directly.

These duplicate part of what the Playwright @contract suite does, on purpose:
they need no server, no Prism and no Node, so they run in a plain `pytest`
during the build and fail the image before it is ever pushed. Playwright then
proves the same thing over real HTTP against the running container.

The overlap is the cheap kind -- both read the same collection, so neither can
drift from it independently.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from functools import reduce
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

COLLECTION = Path(__file__).resolve().parents[2] / "postman" / "awuca.postman_collection.json"


def _interpolate(text: str, variables: dict[str, str]) -> str:
    for key, value in variables.items():
        text = text.replace("{{" + key + "}}", value)
    return text


def _load_cases() -> list[dict[str, Any]]:
    """Mirrors playwright-tests/src/collection.ts: one case per saved example,
    driving that example's own originalRequest."""
    collection = json.loads(COLLECTION.read_text(encoding="utf-8"))
    variables = {v["key"]: v.get("value", "") for v in collection.get("variable", [])}

    cases: list[dict[str, Any]] = []

    def walk(items: list[dict[str, Any]], folder: str) -> None:
        for item in items:
            if "item" in item:
                walk(item["item"], item["name"])
                continue
            if "request" not in item:
                continue

            for example in item.get("response", []):
                request = example.get("originalRequest") or item["request"]
                url = request.get("url") or item["request"]["url"]

                path_vars = {
                    v["key"]: _interpolate(v.get("value", ""), variables)
                    for v in url.get("variable", [])
                }
                segments = [
                    path_vars[s[1:]] if s.startswith(":") else _interpolate(s, variables)
                    for s in url.get("path", [])
                ]
                headers = {
                    h["key"]: _interpolate(h.get("value", ""), variables)
                    for h in request.get("header", [])
                    if not h.get("disabled")
                }
                auth_type = (request.get("auth") or item["request"].get("auth") or {}).get("type")

                cases.append(
                    {
                        "id": f"{folder} > {item['name']} > {example['name']}",
                        "method": request.get("method", item["request"]["method"]),
                        "path": "/" + "/".join(segments),
                        "params": {
                            q["key"]: _interpolate(q.get("value", ""), variables)
                            for q in url.get("query", [])
                            if not q.get("disabled")
                        },
                        "headers": headers,
                        "body": (
                            json.loads(_interpolate(request["body"]["raw"], variables))
                            if request.get("body", {}).get("raw")
                            else None
                        ),
                        "no_auth": auth_type == "noauth",
                        "expected_code": example["code"],
                        "expected_body": json.loads(example["body"]) if example.get("body") else None,
                    }
                )

    walk(collection["item"], "")
    return cases


CASES = _load_cases()


def _merge_shapes(values: list[Any]) -> Any:
    """Collapse every element of an example array into one element shape.

    The port of mergeShapes in playwright-tests/src/shape.ts; keep the two in
    step. Comparing each actual element against `expected[0]` alone is wrong
    whenever the example array is heterogeneous, and the collection's payment
    methods are exactly that: pm-0001 has a `billingAddress.line2` string,
    pm-0002 has null there. Under the old rule the example failed against
    ITSELF, so the app was blamed for reproducing its own documentation.
    """

    def merge(merged: Any, value: Any) -> Any:
        # Rule 2 again: a null in any element makes the field a wildcard.
        if merged is None or value is None:
            return None

        if isinstance(merged, list) and isinstance(value, list):
            return merged + value

        if isinstance(merged, dict) and isinstance(value, dict):
            # A key absent from either element is optional, hence None.
            return {
                key: (
                    _merge_shapes([merged[key], value[key]])
                    if key in merged and key in value
                    else None
                )
                for key in {**merged, **value}
            }

        # Primitives, or a type that differs between elements: keep the first.
        return merged

    return reduce(merge, values)


def _shape_mismatches(actual: Any, expected: Any, at: str = "$") -> list[str]:
    """Same four rules as playwright-tests/src/shape.ts: extra keys allowed,
    null is a wildcard, an empty array matches a non-empty example, and EVERY
    element of an example array contributes to the element shape."""
    if expected is None:
        return []

    if isinstance(expected, list):
        if not isinstance(actual, list):
            return [f"{at}: expected array, got {type(actual).__name__}"]
        if not expected or not actual:
            return []
        # Rule 4: the whole example array defines the element shape, not [0].
        element = _merge_shapes(expected)
        return [m for i, e in enumerate(actual) for m in _shape_mismatches(e, element, f"{at}[{i}]")]

    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return [f"{at}: expected object, got {type(actual).__name__}"]
        problems: list[str] = []
        for key, expected_value in expected.items():
            if key not in actual:
                if expected_value is not None:
                    problems.append(f"{at}.{key}: missing")
                continue
            problems.extend(_shape_mismatches(actual[key], expected_value, f"{at}.{key}"))
        return problems

    # bool before int: in Python bool is a subclass of int, so True would
    # otherwise satisfy an example documenting a number.
    for kind in (bool, str):
        if isinstance(expected, kind) != isinstance(actual, kind):
            return [f"{at}: expected {type(expected).__name__}, got {type(actual).__name__}"]
    if isinstance(expected, (int, float)) and not isinstance(actual, (int, float)):
        return [f"{at}: expected number, got {type(actual).__name__}"]

    return []


@pytest.mark.parametrize("case", CASES, ids=[c["id"] for c in CASES])
def test_example_is_satisfied(
    client: TestClient,
    new_customer: Callable[..., dict[str, str]],
    case: dict[str, Any],
) -> None:
    headers = dict(case["headers"])

    if not case["no_auth"]:
        # A fresh customer per case, so the cases that mutate (DELETE pm-0002,
        # PUT pm-0001) cannot poison the ones that follow.
        headers.update(new_customer(int(case["headers"].get("x-account-count", 3))))

    response = client.request(
        case["method"],
        case["path"],
        headers=headers,
        params=case["params"] or None,
        json=case["body"],
    )

    assert response.status_code == case["expected_code"], (
        f"{case['method']} {case['path']} -> {response.status_code}\n{response.text[:500]}"
    )

    if case["expected_body"] is None:
        assert response.text == "", "example documents an empty body"
        return

    mismatches = _shape_mismatches(response.json(), case["expected_body"])
    assert not mismatches, "\n".join(mismatches) + f"\n\nActual: {response.text[:500]}"


def test_every_example_satisfies_its_own_shape() -> None:
    """The comparator's own invariant: no app, no server, no HTTP.

    If a saved example does not match itself then the comparator is wrong, and
    every failure it reports above is an accusation against the backend for
    something the collection itself does. That is precisely what the
    `expected[0]` rule did to Payment Methods > List Payment Methods > 200 OK.

    Cheap to run and it fails first, so a comparator regression is named as one
    instead of being investigated as a backend bug.
    """
    for case in CASES:
        if case["expected_body"] is None:
            continue
        mismatches = _shape_mismatches(case["expected_body"], case["expected_body"])
        assert not mismatches, f"{case['id']} does not satisfy itself: {'; '.join(mismatches)}"


def test_collection_was_actually_loaded() -> None:
    # A parametrize over an empty list is a silent pass, which would make every
    # test above vanish the moment the collection path breaks.
    assert len(CASES) >= 20, f"only {len(CASES)} cases loaded from {COLLECTION}"
