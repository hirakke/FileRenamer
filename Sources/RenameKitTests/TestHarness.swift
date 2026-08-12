import Foundation

/// Minimal test harness.
///
/// A dependency-free executable harness, so the safety suite can run with either
/// Xcode or a minimal Swift toolchain: `swift run RenameKitTests`.
struct ExpectationFailure: Error {
    let message: String
    let file: String
    let line: UInt
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "condition was false",
            file: String = #fileID, line: UInt = #line) throws {
    guard condition else { throw ExpectationFailure(message: message(), file: file, line: line) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String = "",
                               file: String = #fileID, line: UInt = #line) throws {
    guard actual == expected else {
        let suffix = message().isEmpty ? "" : " — \(message())"
        throw ExpectationFailure(message: "expected \(expected), got \(actual)\(suffix)", file: file, line: line)
    }
}

func expectThrows(_ body: () async throws -> Void, _ message: @autoclosure () -> String = "expected an error",
                  file: String = #fileID, line: UInt = #line) async throws {
    do {
        try await body()
    } catch {
        return
    }
    throw ExpectationFailure(message: message(), file: file, line: line)
}

@MainActor
final class TestRunner {
    static let shared = TestRunner()

    private var passed = 0
    private var failures: [String] = []
    private var currentSuite = ""

    func suite(_ name: String) {
        currentSuite = name
        print("\n\(name)")
    }

    func test(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            passed += 1
            print("  ✔ \(name)")
        } catch let failure as ExpectationFailure {
            failures.append("\(currentSuite) › \(name): \(failure.message) (\(failure.file):\(failure.line))")
            print("  ✘ \(name): \(failure.message)  [\(failure.file):\(failure.line)]")
        } catch {
            failures.append("\(currentSuite) › \(name): threw \(error)")
            print("  ✘ \(name): threw \(error)")
        }
    }

    func finish() -> Int32 {
        print("\n\(passed) passed, \(failures.count) failed")
        for failure in failures { print("  - \(failure)") }
        return failures.isEmpty ? 0 : 1
    }
}
