import Foundation

/// A very small test harness.
///
/// XCTest ships only with Xcode, and androcall is built with the Command Line
/// Tools alone, so the macOS test suite is a self-contained executable that
/// exits non-zero when a check fails. It runs the same way in CI.
public final class TestRunner {
    public struct Failure: Error {
        public let message: String
    }

    private var passed = 0
    private var failed = 0
    private var currentSuite = ""
    private var failures: [String] = []
    private var skipped = 0

    public init() {}

    public func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
        print("\n▶ \(name)")
        do {
            try body()
        } catch {
            failed += 1
            let message = "\(name): threw \(error)"
            failures.append(message)
            print("  ✗ \(error)")
        }
    }

    public func test(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            print("  ✓ \(name)")
        } catch {
            failed += 1
            let message = "\(currentSuite) › \(name): \(error)"
            failures.append(message)
            print("  ✗ \(name): \(error)")
        }
    }

    public func skip(_ name: String, reason: String) {
        skipped += 1
        print("  – \(name) (skipped: \(reason))")
    }

    public func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition {
            throw Failure(message: message())
        }
    }

    public func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String = ""
    ) throws {
        if actual != expected {
            throw Failure(message: "\(label.isEmpty ? "" : label + ": ")expected \(expected), got \(actual)")
        }
    }

    public func expectEqualBytes(
        _ actual: Data,
        _ expected: Data,
        _ label: String = ""
    ) throws {
        if actual != expected {
            throw Failure(message: "\(label.isEmpty ? "" : label + ": ")expected \(expected.hexString), got \(actual.hexString)")
        }
    }

    /// Assert that `body` throws.
    public func expectThrows(
        _ label: String = "",
        _ body: () throws -> Void
    ) throws {
        do {
            try body()
        } catch {
            return
        }
        throw Failure(message: "\(label): expected an error but none was thrown")
    }

    /// Print the summary and return the process exit code.
    public func finish() -> Int32 {
        print("\n─────────────────────────────")
        print("passed: \(passed)   failed: \(failed)   skipped: \(skipped)")
        if !failures.isEmpty {
            print("\nFailures:")
            for failure in failures {
                print("  • \(failure)")
            }
            return 1
        }
        print("All tests passed.")
        return 0
    }
}

extension Data {
    /// Parse a hex string, throwing when it is malformed.
    public static func requireHex(_ text: String) throws -> Data {
        guard let data = Data(hexString: text) else {
            throw TestRunner.Failure(message: "Invalid hex string in the conformance vectors.")
        }
        return data
    }

    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    public init?(hexString: String) {
        let text = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

/// A reference box used to pass a value out of a concurrent closure.
final class ResultBox: @unchecked Sendable {
    var error: Error?
}
