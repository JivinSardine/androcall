#!/usr/bin/env python3
"""Build and run the macOS test suite.

The suite is a self-contained executable (XCTest ships only with Xcode), so it
can run anywhere the app itself can be built.

Usage: python3 scripts/run_tests_macos.py
"""

from __future__ import annotations

import os
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CORE_DIR = os.path.join(REPO, "macos", "AndroCallCore")
TEST_DIR = os.path.join(REPO, "macos", "AndroCallTests")
BUILD_DIR = os.path.join(REPO, "build", "tests")

CORE_SOURCES = [
    "ProtocolConstants.swift",
    "Crypto.swift",
    "SessionKeys.swift",
    "Frame.swift",
    "CanonicalJSON.swift",
    "Message.swift",
    "Models.swift",
    "PhoneNumber.swift",
    "Transport.swift",
    "Session.swift",
]

TEST_SOURCES = [
    "TestHarness.swift",
    "ConformanceTests.swift",
    "UnitTests.swift",
    "AndroCallTestsMain.swift",
]


def run(command: list[str]) -> None:
    print("+ " + " ".join(command[:8]) + (" ..." if len(command) > 8 else ""), flush=True)
    subprocess.run(command, check=True)


def main() -> int:
    sdk = subprocess.run(
        ["xcrun", "--show-sdk-path"], check=True, capture_output=True, text=True
    ).stdout.strip()
    os.makedirs(BUILD_DIR, exist_ok=True)

    core_module = os.path.join(BUILD_DIR, "AndroCallCore.swiftmodule")
    core_library = os.path.join(BUILD_DIR, "libAndroCallCore.a")
    executable = os.path.join(BUILD_DIR, "androcall-tests")

    core_paths = [os.path.join(CORE_DIR, name) for name in CORE_SOURCES]
    test_paths = [os.path.join(TEST_DIR, name) for name in TEST_SOURCES]
    for path in core_paths + test_paths:
        if not os.path.exists(path):
            print(f"missing source file: {path}", file=sys.stderr)
            return 1

    run([
        "swiftc",
        "-sdk", sdk,
        "-target", "x86_64-apple-macos12.0",
        "-swift-version", "5",
        "-emit-module",
        "-emit-module-path", core_module,
        "-emit-library",
        "-static",
        "-o", core_library,
        "-module-name", "AndroCallCore",
        "-O",
        "-whole-module-optimization",
        *core_paths,
    ])

    run([
        "swiftc",
        "-sdk", sdk,
        "-target", "x86_64-apple-macos12.0",
        "-swift-version", "5",
        "-module-name", "AndroCallTests",
        "-I", BUILD_DIR,
        "-L", BUILD_DIR,
        "-lAndroCallCore",
        "-framework", "CryptoKit",
        "-O",
        "-o", executable,
        *test_paths,
    ])

    print("\nRunning the macOS test suite…\n", flush=True)
    result = subprocess.run([executable, REPO])
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
