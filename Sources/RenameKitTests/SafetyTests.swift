import Foundation
import RenameKit

private struct StubExistenceChecker: FileExistenceChecking {
    let existing: Set<String>
    func fileExists(at url: URL) -> Bool { existing.contains(url.standardizedFileURL.path) }
}

private struct StubBatchExistenceChecker: BatchFileExistenceChecking {
    let existing: Set<URL>
    func fileExists(at url: URL) -> Bool { false }
    func existingFiles(at urls: [URL]) -> Set<URL> { existing.intersection(urls) }
}

private let folder = URL(fileURLWithPath: "/tmp/photos", isDirectory: true)

private func makePreview(source: String, destination: String, in directory: URL = folder) -> RenamePreview {
    RenamePreview(
        itemID: UUID(),
        counterValue: nil,
        proposedBaseName: URL(fileURLWithPath: destination).deletingPathExtension().lastPathComponent,
        operations: [RenameOperation(
            source: directory.appendingPathComponent(source),
            destination: directory.appendingPathComponent(destination)
        )]
    )
}

@MainActor
func runValidatorTests() async {
    let runner = TestRunner.shared
    runner.suite("RenameValidator — 安全性")

    await runner.test("変更後の名前が重複したらエラー") {
        let previews = [
            makePreview(source: "a.jpg", destination: "Event_001.jpg"),
            makePreview(source: "b.jpg", destination: "Event_001.jpg")
        ]
        let validated = RenameValidator(existenceChecker: StubExistenceChecker(existing: [])).validate(previews)
        try expectEqual(validated.errorCount, 2)
    }

    await runner.test("大文字小文字だけの違いも重複として扱う") {
        let previews = [
            makePreview(source: "a.jpg", destination: "Event_001.jpg"),
            makePreview(source: "b.jpg", destination: "EVENT_001.jpg")
        ]
        let validated = RenameValidator(existenceChecker: StubExistenceChecker(existing: [])).validate(previews)
        try expect(validated.hasErrors)
    }

    await runner.test("Unicodeの合成・分解表現も同じ名前として扱う") {
        let composed = "Caf\u{00E9}.jpg"
        let decomposed = "Cafe\u{0301}.jpg"
        let previews = [
            makePreview(source: "a.jpg", destination: composed),
            makePreview(source: "b.jpg", destination: decomposed)
        ]
        let validated = RenameValidator(existenceChecker: StubExistenceChecker(existing: [])).validate(previews)
        try expect(validated.hasErrors)
    }

    await runner.test("既存ファイルとの衝突はエラー") {
        let checker = StubExistenceChecker(existing: ["/tmp/photos/Taken.jpg"])
        let validated = RenameValidator(existenceChecker: checker).validate([makePreview(source: "a.jpg", destination: "Taken.jpg")])
        try expect(validated[0].validation.isError)
    }

    await runner.test("保存先の一括確認経路で既存衝突を検出する") {
        let destination = folder.appendingPathComponent("Taken.jpg")
        let checker = StubBatchExistenceChecker(existing: [destination])
        let validated = RenameValidator(existenceChecker: checker)
            .validate([makePreview(source: "a.jpg", destination: "Taken.jpg")])
        try expect(validated[0].validation.isError)
    }

    // A↔B swap: both destinations exist, but both sources are vacating.
    await runner.test("バッチ内での名前の入れ替えは許可される") {
        let previews = [
            makePreview(source: "A.jpg", destination: "B.jpg"),
            makePreview(source: "B.jpg", destination: "A.jpg")
        ]
        let checker = StubExistenceChecker(existing: ["/tmp/photos/A.jpg", "/tmp/photos/B.jpg"])
        let validated = RenameValidator(existenceChecker: checker).validate(previews)
        try expect(!validated.hasErrors)
    }

    // Rule whose tokens all render to nothing -> ".jpg", which is a hidden file, not a name.
    await runner.test("空のファイル名はエラー") {
        let item = RenameItem(originalURL: folder.appendingPathComponent("a.jpg"))
        let rule = RenameRule(tokens: [.text(TextConfiguration(value: ""))])
        let previews = RenameEngine().makePreviews(items: [item], rule: rule)
        try expectEqual(previews[0].proposedBaseName, "")
        let validated = RenameValidator(existenceChecker: StubExistenceChecker(existing: [])).validate(previews)
        try expect(validated[0].validation.isError)
    }

    await runner.test("名前が変わらない場合は警告どまり") {
        let checker = StubExistenceChecker(existing: ["/tmp/photos/a.jpg"])
        let validated = RenameValidator(existenceChecker: checker).validate([makePreview(source: "a.jpg", destination: "a.jpg")])
        try expect(validated[0].validation.isWarning)
        try expect(!validated.hasErrors)
    }

    await runner.test("255バイトを超える名前はエラー") {
        let long = String(repeating: "あ", count: 200) // 600 bytes
        let validated = RenameValidator(existenceChecker: StubExistenceChecker(existing: []))
            .validate([makePreview(source: "a.jpg", destination: "\(long).jpg")])
        try expect(validated[0].validation.isError)
    }
}

@MainActor
func runExecutorTests() async {
    let runner = TestRunner.shared
    runner.suite("RenameExecutor — 実ファイル操作")

    func withSandbox(_ body: (URL) async throws -> Void) async throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileRenamerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try await body(sandbox)
    }

    func write(_ name: String, _ contents: String, in sandbox: URL) throws {
        try contents.write(to: sandbox.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func names(in sandbox: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: sandbox.path).sorted()
    }

    func read(_ name: String, in sandbox: URL) throws -> String {
        try String(contentsOf: sandbox.appendingPathComponent(name), encoding: .utf8)
    }

    await runner.test("リネームしても中身は変わらない") {
        try await withSandbox { sandbox in
            try write("IMG_3051.jpg", "first", in: sandbox)
            try write("IMG_3048.jpg", "second", in: sandbox)
            let transaction = try await RenameExecutor().execute(previews: [
                makePreview(source: "IMG_3051.jpg", destination: "Event_001.jpg", in: sandbox),
                makePreview(source: "IMG_3048.jpg", destination: "Event_002.jpg", in: sandbox)
            ])
            try expectEqual(try names(in: sandbox), ["Event_001.jpg", "Event_002.jpg"])
            try expectEqual(try read("Event_001.jpg", in: sandbox), "first")
            try expectEqual(transaction.fileCount, 2)
        }
    }

    // The case the two-phase rename exists for.
    await runner.test("A→B / B→A の入れ替えが成立する") {
        try await withSandbox { sandbox in
            try write("A.jpg", "a", in: sandbox)
            try write("B.jpg", "b", in: sandbox)
            _ = try await RenameExecutor().execute(previews: [
                makePreview(source: "A.jpg", destination: "B.jpg", in: sandbox),
                makePreview(source: "B.jpg", destination: "A.jpg", in: sandbox)
            ])
            try expectEqual(try names(in: sandbox), ["A.jpg", "B.jpg"])
            try expectEqual(try read("A.jpg", in: sandbox), "b")
            try expectEqual(try read("B.jpg", in: sandbox), "a")
        }
    }

    await runner.test("Undo で元の名前に戻る") {
        try await withSandbox { sandbox in
            try write("one.txt", "1", in: sandbox)
            try write("two.txt", "2", in: sandbox)
            let executor = RenameExecutor()
            let transaction = try await executor.execute(previews: [
                makePreview(source: "one.txt", destination: "Doc_001.txt", in: sandbox),
                makePreview(source: "two.txt", destination: "Doc_002.txt", in: sandbox)
            ])
            try expectEqual(try names(in: sandbox), ["Doc_001.txt", "Doc_002.txt"])
            _ = try await executor.revert(transaction)
            try expectEqual(try names(in: sandbox), ["one.txt", "two.txt"])
        }
    }

    await runner.test("承認済みフォルダのブックマークをUndo履歴へ引き継ぐ") {
        try await withSandbox { sandbox in
            try write("before.txt", "content", in: sandbox)
            let bookmark = Data([7, 11, 13])
            let transaction = try await RenameExecutor().execute(
                previews: [makePreview(source: "before.txt", destination: "after.txt", in: sandbox)],
                accessBookmarks: [bookmark]
            )
            try expectEqual(transaction.accessBookmarks, [bookmark])
        }
    }

    await runner.test("一時ファイルが残らない") {
        try await withSandbox { sandbox in
            try write("a.txt", "a", in: sandbox)
            _ = try await RenameExecutor().execute(previews: [makePreview(source: "a.txt", destination: "b.txt", in: sandbox)])
            let leftovers = try FileManager.default
                .contentsOfDirectory(atPath: sandbox.path)
                .filter { $0.hasPrefix(".filerenamer-tmp") }
            try expect(leftovers.isEmpty)
        }
    }

    await runner.test("中断されたステージングを次回起動時に復旧する") {
        try await withSandbox { sandbox in
            let journalDirectory = sandbox.appendingPathComponent("journals", isDirectory: true)
            let store = RenameJournalStore(directoryURL: journalDirectory)
            let source = sandbox.appendingPathComponent("original.txt")
            let temporary = sandbox.appendingPathComponent(".filerenamer-tmp-test.txt")
            let destination = sandbox.appendingPathComponent("renamed.txt")
            try write("original.txt", "safe", in: sandbox)
            try FileManager.default.moveItem(at: source, to: temporary)
            try store.save(RenameJournal(entries: [
                RenameJournalEntry(
                    source: source,
                    temporary: temporary,
                    destination: destination,
                    state: .staged
                )
            ]))

            let report = await RenameExecutor(journalStore: store).recoverPendingTransactions()
            try expectEqual(report.recoveredBatchCount, 1)
            try expectEqual(report.recoveredFileCount, 1)
            try expectEqual(try read("original.txt", in: sandbox), "safe")
            try expect(store.loadAll().journals.isEmpty)
        }
    }

    await runner.test("最終名まで進んだ未コミット処理も元へ復旧する") {
        try await withSandbox { sandbox in
            let store = RenameJournalStore(directoryURL: sandbox.appendingPathComponent("journals", isDirectory: true))
            let source = sandbox.appendingPathComponent("before.txt")
            let temporary = sandbox.appendingPathComponent(".filerenamer-tmp-test.txt")
            let destination = sandbox.appendingPathComponent("after.txt")
            try write("after.txt", "content", in: sandbox)
            try store.save(RenameJournal(entries: [
                RenameJournalEntry(source: source, temporary: temporary, destination: destination, state: .finalized)
            ]))

            let report = await RenameExecutor(journalStore: store).recoverPendingTransactions()
            try expectEqual(report.recoveredFileCount, 1)
            try expectEqual(try read("before.txt", in: sandbox), "content")
            try expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    await runner.test("エラーがある場合は一切実行しない") {
        try await withSandbox { sandbox in
            var previews = [makePreview(source: "a.txt", destination: "b.txt", in: sandbox)]
            try write("a.txt", "a", in: sandbox)
            previews[0].validation = .error("bad")
            try await expectThrows { _ = try await RenameExecutor().execute(previews: previews) }
            try expectEqual(try names(in: sandbox), ["a.txt"])
        }
    }

    await runner.test("元ファイルが消えていたら何も動かさない") {
        try await withSandbox { sandbox in
            try write("a.txt", "a", in: sandbox)
            try await expectThrows {
                _ = try await RenameExecutor().execute(previews: [
                    makePreview(source: "a.txt", destination: "x.txt", in: sandbox),
                    makePreview(source: "ghost.txt", destination: "y.txt", in: sandbox)
                ])
            }
            try expectEqual(try names(in: sandbox), ["a.txt"])
        }
    }

    await runner.test("RAW と JPEG が一緒にリネームされる") {
        try await withSandbox { sandbox in
            try write("DSCF0001.RAF", "raw", in: sandbox)
            try write("DSCF0001.JPG", "jpeg", in: sandbox)
            let preview = RenamePreview(
                itemID: UUID(),
                counterValue: 1,
                proposedBaseName: "Event_001",
                operations: [
                    RenameOperation(source: sandbox.appendingPathComponent("DSCF0001.RAF"),
                                    destination: sandbox.appendingPathComponent("Event_001.RAF")),
                    RenameOperation(source: sandbox.appendingPathComponent("DSCF0001.JPG"),
                                    destination: sandbox.appendingPathComponent("Event_001.JPG"))
                ]
            )
            _ = try await RenameExecutor().execute(previews: [preview])
            try expectEqual(try names(in: sandbox), ["Event_001.JPG", "Event_001.RAF"])
        }
    }

    runner.suite("RulePresetStore — プリセットの保存")

    await runner.test("保存したプリセットを読み戻せる") {
        try await withSandbox { sandbox in
            let store = RulePresetStore(fileURL: sandbox.appendingPathComponent("presets.json"))
            let preset = RenameRulePreset(name: "旅行", rule: RenameRule(tokens: [
                .text(TextConfiguration(value: "Trip")),
                .separator(SeparatorConfiguration(value: "-")),
                .counter(CounterConfiguration(start: 5, digits: 2))
            ]))
            try store.save([preset])

            let loaded = store.load()
            try expectEqual(loaded.count, 1)
            try expectEqual(loaded[0].name, "旅行")
            try expectEqual(loaded[0].rule, preset.rule)
        }
    }

    // Built-ins are recreated in code, so persisting them would fossilise old versions.
    await runner.test("組み込みプリセットは保存されない") {
        try await withSandbox { sandbox in
            let store = RulePresetStore(fileURL: sandbox.appendingPathComponent("presets.json"))
            try store.save(RenameRulePreset.builtIns)
            try expect(store.load().isEmpty)
        }
    }

    await runner.test("プリセットを書き出して再読込できる") {
        try await withSandbox { sandbox in
            let store = RulePresetStore(fileURL: sandbox.appendingPathComponent("presets.json"))
            let preset = RenameRulePreset(name: "共有", rule: RenameRule(tokens: [
                .originalName(OriginalNameConfiguration(find: "IMG_", replacement: "")),
                .counter(CounterConfiguration(resetMode: .folder))
            ]))
            let data = try store.exportData([preset])
            let imported = try store.decodeImportedPresets(from: data)
            try expectEqual(imported.count, 1)
            try expectEqual(imported[0].rule, preset.rule)
        }
    }

    await runner.test("ファイルが壊れていても空で起動できる") {
        try await withSandbox { sandbox in
            let url = sandbox.appendingPathComponent("presets.json")
            try "not json".write(to: url, atomically: true, encoding: .utf8)
            let result = RulePresetStore(fileURL: url).loadWithDiagnostics()
            try expect(result.presets.isEmpty)
            try expect(result.recoveryMessage != nil)
            let backups = try FileManager.default.contentsOfDirectory(atPath: sandbox.path)
                .filter { $0.hasPrefix("rule-presets-corrupt-") }
            try expectEqual(backups.count, 1)
        }
    }

    runner.suite("RenameHistory — Undo スタック")

    await runner.test("記録した順に Undo / Redo できる") {
        var history = RenameHistory()
        try expect(!history.canUndo)
        let transaction = RenameTransaction(moves: [])
        history.record(transaction)
        try expect(history.canUndo)
        _ = history.beginUndo()
        history.finishUndo()
        try expect(!history.canUndo)
        try expect(history.canRedo)
        _ = history.beginRedo()
        history.finishRedo()
        try expect(history.canUndo)
    }

    await runner.test("Undo履歴を再起動後も読み戻せる") {
        try await withSandbox { sandbox in
            let store = RenameHistoryStore(fileURL: sandbox.appendingPathComponent("history.json"))
            let transaction = RenameTransaction(
                moves: [RenameOperation(
                    source: sandbox.appendingPathComponent("before.txt"),
                    destination: sandbox.appendingPathComponent("after.txt")
                )],
                accessBookmarks: [Data([1, 2, 3])]
            )
            var history = RenameHistory()
            history.record(transaction)
            try store.save(history)

            let loaded = store.load()
            try expectEqual(loaded.lastTransaction?.moves, transaction.moves)
            try expectEqual(loaded.lastTransaction?.accessBookmarks, transaction.accessBookmarks)
        }
    }
}
