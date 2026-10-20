# Contributing

Thank you for helping with androcall. This document explains how to build the project,
what the conventions are, and what a good pull request looks like.

## Getting set up

You need a Mac (macOS 12 or later) with the Command Line Tools, a JDK 21, and the
Android SDK (platform 35).

```bash
git clone https://github.com/JivinSardine/androcall.git
cd androcall

# Build the macOS app
python3 scripts/build_macos.py --dmg

# Run the macOS tests
python3 scripts/run_tests_macos.py

# Build and test the Android companion
cd android
ANDROCALL_REPO_ROOT="$(cd .. && pwd)" ./gradlew testDebugUnitTest assembleRelease
```

### Why there is no Xcode project

androcall is built with `swiftc` directly and the `.app` bundle is assembled by
`scripts/build_macos.py`. This keeps the build working on any Mac with the Command Line
Tools, on both architectures, and in CI without a macOS runner licence or a huge
Xcode download. It also means the **macOS 12 deployment target is enforced by the
compiler**: `-target x86_64-apple-macos12.0` turns an accidental use of a newer API into
a build error.

If you add a file, add it to `SWIFT_SOURCES_APP` in `scripts/build_macos.py` (and to
`SWIFT_SOURCES_CORE` for the protocol core). The build script fails loudly when a
listed file is missing, so the lists cannot silently drift.

## The layout

```
macos/AndroCallCore/    the protocol core: crypto, framing, canonical JSON, session
macos/AndroCall/        the SwiftUI application
macos/AndroCallTests/   the test suite (a self-contained runner, not XCTest)
android/app/src/main/   the Kotlin companion
protocol/               the protocol specification and the conformance vectors
tools/reference/        the independent Python reference implementation
```

## Changing the protocol

The protocol is specified in [`protocol/PROTOCOL.md`](protocol/PROTOCOL.md) and
implemented three times. If you change it:

1. Update `protocol/PROTOCOL.md`.
2. Update `tools/reference/androcall_ref.py` and regenerate the vectors:
   ```bash
   python3 tools/reference/generate_vectors.py
   ```
3. Update the Swift implementation in `macos/AndroCallCore/`.
4. Update the Kotlin implementation in `android/app/src/main/java/dev/androcall/android/protocol/`.
5. Run **both** test suites. Both must pass, because both check the same vectors.

Never change the published vectors to make a test pass. The vectors are the contract;
if an implementation disagrees with them, the implementation is wrong.

## Style

- **Swift:** follow the existing files. Four-space indentation, `public` on types that
  cross a module boundary, documentation comments on public API.
- **Kotlin:** four-space indentation, `private` by default, explicit types where the
  inference is unclear.
- **Comments** explain *why*, not *what*. The code already says what it does.
- Keep lines under 100 characters where practical.

## Testing expectations

A pull request should:

- build for **both** macOS architectures;
- pass the macOS test suite and the Android test suite;
- pass `python3 tools/reference/generate_vectors.py --check`;
- not reduce the coverage described in [`docs/TESTING.md`](docs/TESTING.md).

If your change cannot be tested automatically, say so in the pull request and describe
exactly what you tested by hand.

## Reporting bugs

Open an issue at <https://github.com/JivinSardine/androcall/issues>. Please include your
macOS version, your phone's Android version, and the diagnostic log from both devices
(**Diagnostics › Copy log**). The log never contains contact data or keys.

## Security problems

Do not open a public issue. See [`docs/SECURITY.md`](docs/SECURITY.md).

## Commit messages

Use a short imperative summary, and explain the reasoning in the body when it is not
obvious:

```
Fix the frame header's byte order

The header fields were written big-endian while the specification and the
reference implementation use little-endian. The conformance vectors now pin
the little-endian encoding on both platforms.
```

## Licence

androcall is MIT-licensed. By contributing you agree that your contribution is licensed
under the same terms.
