import Darwin
import Foundation

/// Entry point of the macOS test suite.
///
/// Usage: androcall-tests [repo-root]
@main
struct AndroCallTestsMain {
    static func main() {
        // Unbuffered output so a crash still shows how far the suite got.
        setvbuf(stdout, nil, _IONBF, 0)
        if CommandLine.arguments.count > 1 {
            setenv("ANDROCALL_REPO_ROOT", CommandLine.arguments[1], 1)
        }
        let runner = TestRunner()
        print("androcall macOS test suite")
        print("==========================")
        ConformanceTests.run(runner)
        UnitTests.run(runner)
        exit(runner.finish())
    }
}
