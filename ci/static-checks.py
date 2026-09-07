#!/usr/bin/env python3
"""WP-117 — SR-60 / SR-62 source checks on CODE, not on comments.

The former `grep -rn "delegatecall\\|selfdestruct" src` matched the NatSpec sentence
"no delegatecall, no selfdestruct (SR-60)" in src/handle/HandleRegistry.sol and failed CI on a
sentence that documents the rule. This script strips every `//`, `///`, `/* */` comment and every
string literal from each Solidity file before matching, so a rule may be *named* in a comment while
any real `.delegatecall(`, assembly `delegatecall(...)`, `selfdestruct(...)` still fails.

Checks (contracts/src only; verbatim libs carry their upstream audits):
  SR-60  no `delegatecall` / `selfdestruct` token in code.
  SR-62  the set of files whose CODE contains `whenNotPaused` is exactly the two registration
         controllers plus ArcNSMarket (M3, SR-35: pause blocks only new listings/offers/bids, never
         cancel/settle/withdraw -- the same "pausable surface = new activity only" principle as SR-62).

A built-in self-test runs on every invocation before the scan (a checker that silently stopped
matching would otherwise turn SR-60 into a no-op): the comment / string fixtures must pass and the
real-usage fixtures must fail. Prints exactly one final marker: SR_CHECKS_OK or SR_CHECKS_FAILED.

Usage: python3 ci/static-checks.py [src-dir]      (default: src, relative to contracts/)
"""
from __future__ import annotations

import os
import re
import sys
import tempfile

SR60_TOKENS = re.compile(r"\b(delegatecall|selfdestruct)\b")
SR62_TOKEN = re.compile(r"\bwhenNotPaused\b")
SR62_ALLOWED = ("handle/HandleController.sol", "market/ArcNSMarket.sol", "tld/TldRegistrarController.sol")


def strip_comments_and_strings(text: str) -> str:
    """Return `text` with comment bodies and string-literal bodies blanked, newlines preserved
    (so reported line numbers stay accurate). Handles `//`, `/* */`, `"…"`, `'…'`, backslash
    escapes and the `unicode"…"` / `hex"…"` prefixes (the prefix is code, the body is a string)."""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and nxt == "*":
            i += 2
            while i < n and not (text[i] == "*" and i + 1 < n and text[i + 1] == "/"):
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            i += 2
            continue
        if c in ('"', "'"):
            quote = c
            out.append(" ")
            i += 1
            while i < n and text[i] != quote:
                if text[i] == "\\" and i + 1 < n:
                    i += 1
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def sol_files(root: str) -> list[str]:
    found: list[str] = []
    for d, _, files in os.walk(root):
        for f in files:
            if f.endswith(".sol"):
                found.append(os.path.join(d, f))
    return sorted(found)


def code_hits(path: str, pattern: re.Pattern[str]) -> list[tuple[int, str]]:
    with open(path, encoding="utf-8") as fh:
        code = strip_comments_and_strings(fh.read())
    hits: list[tuple[int, str]] = []
    for ln, line in enumerate(code.splitlines(), 1):
        if pattern.search(line):
            hits.append((ln, line.strip()))
    return hits


def scan(root: str) -> list[str]:
    """Return a list of violation messages (empty = clean)."""
    problems: list[str] = []
    paused_files: list[str] = []
    for path in sol_files(root):
        rel = os.path.relpath(path, root)
        for ln, line in code_hits(path, SR60_TOKENS):
            problems.append(f"SR-60 violated: {rel}:{ln}: {line}")
        if code_hits(path, SR62_TOKEN):
            paused_files.append(rel)
    if tuple(paused_files) != SR62_ALLOWED:
        problems.append(
            f"SR-62: whenNotPaused must appear in code of exactly {list(SR62_ALLOWED)}, found {paused_files}"
        )
    return problems


# ---- self-test ---------------------------------------------------------------------------------

_CLEAN = """// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
/// @notice Non-upgradeable, no proxies, no delegatecall, no selfdestruct (SR-60). Nothing here is
///         pausable (SR-62): whenNotPaused is not used.
/* a block comment
   mentioning selfdestruct and delegatecall
   across lines */
contract Clean {
    string constant NOTE = "delegatecall is banned; selfdestruct too; \\" whenNotPaused";
    string constant U = unicode"selfdestruct";
    bytes constant H = hex"00"; // delegatecall
    function f() external pure returns (uint256) { return 1; } // selfdestruct
}
"""

_BAD_CALL = """// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
contract Bad { function f(address t, bytes calldata d) external { (bool ok,) = t.delegatecall(d); ok; } }
"""

_BAD_ASM = """// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
contract Bad { function f(address t) external { assembly { selfdestruct(t) } } }
"""

_BAD_ASM_DELEGATE = """// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
contract Bad { function f(address t) external { assembly { let r := delegatecall(gas(), t, 0, 0, 0, 0) } } }
"""

_PAUSED_CODE = """// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
contract P { modifier whenNotPaused() { _; } function f() external whenNotPaused {} }
"""


def _write(root: str, rel: str, body: str) -> None:
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)


def self_test() -> list[str]:
    """Return a list of self-test failures (empty = the checker is sound)."""
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        # 1. comments and strings never trigger; the SR62_ALLOWED set are the only whenNotPaused users
        _write(tmp, "handle/Clean.sol", _CLEAN)
        for allowed in SR62_ALLOWED:
            _write(tmp, allowed, _PAUSED_CODE)
        got = scan(tmp)
        if got:
            failures.append(f"clean fixture must pass, got {got}")
        # 2. the real usages each fail with a file:line pointing at the code line (3)
        for name, body in (("call", _BAD_CALL), ("asm-selfdestruct", _BAD_ASM), ("asm-delegatecall", _BAD_ASM_DELEGATE)):
            _write(tmp, f"bad/{name}.sol", body)
            got = scan(tmp)
            if not any(p.startswith("SR-60 violated") and f"bad/{name}.sol:3:" in p for p in got):
                failures.append(f"{name} fixture must fail SR-60 at line 3, got {got}")
            os.remove(os.path.join(tmp, "bad", f"{name}.sol"))
        # 3. whenNotPaused in CODE outside SR62_ALLOWED fails SR-62; in a comment it does not
        _write(tmp, "handle/Extra.sol", _PAUSED_CODE)
        got = scan(tmp)
        if not any(p.startswith("SR-62") for p in got):
            failures.append(f"extra whenNotPaused user must fail SR-62, got {got}")
        os.remove(os.path.join(tmp, "handle", "Extra.sol"))
        # 4. an allowed file that only MENTIONS whenNotPaused in a comment is a missing user (SR-62 set shrinks)
        _write(tmp, SR62_ALLOWED[1], "// whenNotPaused is not used here\ncontract T {}\n")
        got = scan(tmp)
        if not any(p.startswith("SR-62") for p in got):
            failures.append(f"allowed file without whenNotPaused in code must fail SR-62, got {got}")
    return failures


def main(argv: list[str]) -> int:
    root = argv[1] if len(argv) > 1 else "src"
    failures = self_test()
    if failures:
        for f in failures:
            print(f"SELF_TEST_FAILED: {f}")
        print("SR_CHECKS_FAILED")
        return 2
    print("self-test ok (comment/string fixtures pass, delegatecall/selfdestruct/whenNotPaused code fixtures fail)")
    if not os.path.isdir(root):
        print(f"not a directory: {root}")
        print("SR_CHECKS_FAILED")
        return 2
    problems = scan(root)
    files = sol_files(root)
    for p in problems:
        print(p)
    if problems:
        print("SR_CHECKS_FAILED")
        return 1
    print(f"SR-60 ok: no delegatecall/selfdestruct in code across {len(files)} files under {root}")
    print(f"SR-62 ok: whenNotPaused in code only in {list(SR62_ALLOWED)}")
    print("SR_CHECKS_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
