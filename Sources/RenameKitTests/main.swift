import Foundation

await runEngineTests()
await runSorterTests()
await runPerformanceTests()
await runLocalizationTests()
await runValidatorTests()
await runExecutorTests()
exit(TestRunner.shared.finish())
