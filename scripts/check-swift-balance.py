"""Brace/paren balance check for the Swift sources.

Not a compiler — there is no Swift toolchain on Windows — but it catches the
one class of error that is both easy to introduce when writing Swift blind and
completely invisible until a build runs: an unbalanced brace.

Handles the things a regex cannot: line and block comments, multi-line string
literals, and nested quotes inside string interpolation, which is common here
(for example "\\(count) item\\(count == 1 ? "" : "s")").
"""
from __future__ import annotations

import pathlib
import sys

BACKSLASH = chr(92)
QUOTE = '"'
TRIPLE = QUOTE * 3
INTERP_START = BACKSLASH + "("


def scan(src: str):
    index, length = 0, len(src)
    brace = paren = 0
    line = 1
    context = ["code"]
    # Paren depth at which each interpolation began, so the matching ")"
    # returns to string context instead of being counted as code.
    interpolations: list[int] = []
    issues: list[tuple[int, str]] = []

    while index < length:
        char = src[index]
        if char == "\n":
            line += 1
            index += 1
            continue

        current = context[-1]

        if current == "code":
            if src.startswith("//", index):
                newline = src.find("\n", index)
                index = length if newline < 0 else newline
                continue
            if src.startswith("/*", index):
                close = src.find("*/", index + 2)
                line += src.count("\n", index, close if close > 0 else length)
                index = length if close < 0 else close + 2
                continue
            if src.startswith(TRIPLE, index):
                context.append("multiline")
                index += 3
                continue
            if char == QUOTE:
                context.append("string")
                index += 1
                continue
            if char == "{":
                brace += 1
            elif char == "}":
                brace -= 1
                if brace < 0:
                    issues.append((line, "unmatched }"))
            elif char == "(":
                paren += 1
            elif char == ")":
                if interpolations and paren == interpolations[-1]:
                    interpolations.pop()
                    paren -= 1
                    context.pop()
                    index += 1
                    continue
                paren -= 1
                if paren < 0:
                    issues.append((line, "unmatched )"))
            index += 1
            continue

        # Inside a string of either kind.
        if char == BACKSLASH:
            if src.startswith(INTERP_START, index):
                paren += 1
                interpolations.append(paren)
                context.append("code")
                index += 2
                continue
            index += 2
            continue

        if current == "multiline":
            if src.startswith(TRIPLE, index):
                context.pop()
                index += 3
                continue
            index += 1
            continue

        if char == QUOTE:
            context.pop()
            index += 1
            continue
        index += 1

    return brace, paren, issues, context


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent / "App"
    failures = 0
    files = sorted(root.glob("**/*.swift"))

    for path in files:
        brace, paren, issues, context = scan(path.read_text(encoding="utf-8"))
        healthy = brace == 0 and paren == 0 and not issues and context == ["code"]
        if healthy:
            print(f"  OK   {path.name}")
        else:
            failures += 1
            print(f"  FAIL {path.name}: braces{brace:+d} parens{paren:+d} "
                  f"context={context} {issues[:3]}")

    total_lines = sum(len(p.read_text(encoding="utf-8").splitlines()) for p in files)
    print(f"\n{len(files)} files, {total_lines} lines, {failures} unbalanced")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
