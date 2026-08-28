import Foundation

await runEngineTests()
await runSorterTests()
await runPerformanceTests()
await runLocalizationTests()
await runFaceGroupingTests()
await runValidatorTests()
await runExecutorTests()
exit(TestRunner.shared.finish())
