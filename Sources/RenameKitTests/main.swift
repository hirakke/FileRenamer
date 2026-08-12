import Foundation

await runEngineTests()
await runSorterTests()
await runPerformanceTests()
await runValidatorTests()
await runExecutorTests()
exit(TestRunner.shared.finish())
