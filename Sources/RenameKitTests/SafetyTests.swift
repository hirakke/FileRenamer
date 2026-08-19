import Foundation
import ImageIO
import UniformTypeIdentifiers
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

    runner.suite("ImageProcessor — 画像変換と復元")

    await runner.test("PNGを長辺128pxのJPEGへ変換し、UndoとRedoが成立する") {
        try await withSandbox { sandbox in
            let source = sandbox.appendingPathComponent("source.png")
            let backupRoot = sandbox.appendingPathComponent("backups", isDirectory: true)
            let originalData = try makeTestPNG(width: 320, height: 160)
            try originalData.write(to: source)

            let processor = ImageProcessor(backupRootURL: backupRoot)
            let configuration = ImageEditConfiguration(outputFormat: .jpeg, maxLongEdge: 128)
            let records = try await processor.apply(
                requests: [ImageEditRequest(url: source, configuration: configuration)],
                transactionID: UUID()
            )

            let converted = try imageProperties(source)
            try expectEqual(converted.width, 128)
            try expectEqual(converted.height, 64)
            try expectEqual(converted.type, UTType.jpeg.identifier)

            try await processor.restore(records)
            try expectEqual(try Data(contentsOf: source), originalData)
            let restored = try imageProperties(source)
            try expectEqual(restored.width, 320)
            try expectEqual(restored.height, 160)
            try expectEqual(restored.type, UTType.png.identifier)

            try await processor.reapply(records)
            let redone = try imageProperties(source)
            try expectEqual(redone.width, 128)
            try expectEqual(redone.height, 64)
            try expectEqual(redone.type, UTType.jpeg.identifier)
        }
    }

    await runner.test("JPEGを形式維持でリサイズし選択品質で再保存する") {
        try await withSandbox { sandbox in
            let source = sandbox.appendingPathComponent("source.jpg")
            try makeTestImage(width: 320, height: 160, type: .jpeg, detailed: true).write(to: source)
            let processor = ImageProcessor(
                backupRootURL: sandbox.appendingPathComponent("jpeg-resize-backups", isDirectory: true)
            )
            _ = try await processor.apply(
                requests: [ImageEditRequest(
                    url: source,
                    configuration: ImageEditConfiguration(
                        outputFormat: .preserve,
                        maxLongEdge: 128,
                        jpegCompressionQuality: 0.80
                    )
                )],
                transactionID: UUID()
            )
            let converted = try imageProperties(source)
            try expectEqual(converted.width, 128)
            try expectEqual(converted.height, 64)
            try expectEqual(converted.type, UTType.jpeg.identifier)
        }
    }

    await runner.test("小さい画像は既定で拡大せず、明示時だけ拡大する") {
        try await withSandbox { sandbox in
            let source = sandbox.appendingPathComponent("small.png")
            let backupRoot = sandbox.appendingPathComponent("upscale-backups", isDirectory: true)
            try makeTestPNG(width: 32, height: 16).write(to: source)

            let processor = ImageProcessor(backupRootURL: backupRoot)
            _ = try await processor.apply(
                requests: [ImageEditRequest(
                    url: source,
                    configuration: ImageEditConfiguration(outputFormat: .preserve, maxLongEdge: 128)
                )],
                transactionID: UUID()
            )

            var resized = try imageProperties(source)
            try expectEqual(resized.width, 32)
            try expectEqual(resized.height, 16)

            _ = try await processor.apply(
                requests: [ImageEditRequest(
                    url: source,
                    configuration: ImageEditConfiguration(
                        outputFormat: .preserve,
                        maxLongEdge: 128,
                        preventsUpscaling: false
                    )
                )],
                transactionID: UUID()
            )

            resized = try imageProperties(source)
            try expectEqual(resized.width, 128)
            try expectEqual(resized.height, 64)
            try expectEqual(resized.type, UTType.png.identifier)
        }
    }

    await runner.test("JPEG品質80・90・95・100とカスタム値を実エンコードへ渡す") {
        try await withSandbox { sandbox in
            let sourceData = try makeTestPNG(width: 640, height: 480, detailed: true)
            let processor = ImageProcessor(
                backupRootURL: sandbox.appendingPathComponent("quality-backups", isDirectory: true)
            )
            let qualities = [0.80, 0.90, 0.95, 1.00, 0.73]
            var sizes: [Double: Int] = [:]
            for quality in qualities {
                let url = sandbox.appendingPathComponent("quality-\(Int(quality * 100)).jpg")
                try sourceData.write(to: url)
                _ = try await processor.apply(
                    requests: [ImageEditRequest(
                        url: url,
                        configuration: ImageEditConfiguration(
                            outputFormat: .jpeg,
                            maxLongEdge: nil,
                            jpegCompressionQuality: quality
                        )
                    )],
                    transactionID: UUID()
                )
                try expectEqual(try imageProperties(url).type, UTType.jpeg.identifier)
                sizes[quality] = try Data(contentsOf: url).count
            }
            try expect((sizes[0.80] ?? 0) < (sizes[0.90] ?? 0))
            try expect((sizes[0.90] ?? 0) < (sizes[0.95] ?? 0))
            try expect((sizes[0.95] ?? 0) < (sizes[1.00] ?? 0))
            try expect((sizes[0.73] ?? 0) < (sizes[0.80] ?? 0))
        }
    }

    await runner.test("HEICをJPEGへ変換できる") {
        try await withSandbox { sandbox in
            let source = sandbox.appendingPathComponent("input.heic")
            try makeTestImage(width: 128, height: 64, type: .heic, detailed: true).write(to: source)
            let processor = ImageProcessor(
                backupRootURL: sandbox.appendingPathComponent("heic-backups", isDirectory: true)
            )
            _ = try await processor.apply(
                requests: [ImageEditRequest(
                    url: source,
                    configuration: ImageEditConfiguration(
                        outputFormat: .jpeg,
                        maxLongEdge: nil,
                        jpegCompressionQuality: 0.95
                    )
                )],
                transactionID: UUID()
            )
            try expectEqual(try imageProperties(source).type, UTType.jpeg.identifier)
        }
    }

    await runner.test("JPEGリサイズ後も撮影日時・GPS・カメラ情報を保持する") {
        try await withSandbox { sandbox in
            let source = sandbox.appendingPathComponent("metadata.jpg")
            let metadata: [CFString: Any] = [
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: "2026:08:12 20:30:40",
                    kCGImagePropertyExifLensModel: "Test Lens"
                ],
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 35.6812,
                    kCGImagePropertyGPSLatitudeRef: "N",
                    kCGImagePropertyGPSLongitude: 139.7671,
                    kCGImagePropertyGPSLongitudeRef: "E"
                ],
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFMake: "Test Camera Co.",
                    kCGImagePropertyTIFFModel: "Test Camera",
                    kCGImagePropertyTIFFOrientation: 1
                ]
            ]
            try makeTestImage(
                width: 320,
                height: 160,
                type: .jpeg,
                detailed: true,
                properties: metadata
            ).write(to: source)

            _ = try await ImageProcessor(
                backupRootURL: sandbox.appendingPathComponent("metadata-backups", isDirectory: true)
            ).apply(
                requests: [ImageEditRequest(
                    url: source,
                    configuration: ImageEditConfiguration(
                        outputFormat: .jpeg,
                        maxLongEdge: 128,
                        jpegCompressionQuality: 0.95
                    )
                )],
                transactionID: UUID()
            )

            let properties = try imageMetadata(source)
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            try expectEqual(exif?[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:08:12 20:30:40")
            try expectEqual(tiff?[kCGImagePropertyTIFFMake] as? String, "Test Camera Co.")
            try expect(gps?[kCGImagePropertyGPSLatitude] != nil)
            try expectEqual(properties[kCGImagePropertyPixelWidth] as? Int, 128)
            try expectEqual(exif?[kCGImagePropertyExifPixelXDimension] as? Int, 128)
        }
    }

    await runner.test("PNGへ書き出せる") {
        try await withSandbox { sandbox in
            let originalData = try makeTestPNG(width: 96, height: 48)
            let backupRoot = sandbox.appendingPathComponent("format-backups", isDirectory: true)
            let processor = ImageProcessor(backupRootURL: backupRoot)

            for (format, type, name) in [
                (ImageOutputFormat.png, UTType.png.identifier, "output.png")
            ] {
                let url = sandbox.appendingPathComponent(name)
                try originalData.write(to: url)
                _ = try await processor.apply(
                    requests: [ImageEditRequest(
                        url: url,
                        configuration: ImageEditConfiguration(outputFormat: format, maxLongEdge: nil)
                    )],
                    transactionID: UUID()
                )
                try expectEqual(try imageProperties(url).type, type)
            }
        }
    }

    await runner.test("PNGの透明度を保持し、JPEGでは透明部分を白にする") {
        try await withSandbox { sandbox in
            let transparentData = try makeTestImage(
                width: 40,
                height: 20,
                type: .png,
                alpha: 64
            )
            let processor = ImageProcessor(
                backupRootURL: sandbox.appendingPathComponent("alpha-backups", isDirectory: true)
            )

            let png = sandbox.appendingPathComponent("alpha.png")
            try transparentData.write(to: png)
            _ = try await processor.apply(
                requests: [ImageEditRequest(
                    url: png,
                    configuration: ImageEditConfiguration(outputFormat: .png, maxLongEdge: 20)
                )],
                transactionID: UUID()
            )
            try expectEqual(try imageHasAlpha(png), true)

            let jpeg = sandbox.appendingPathComponent("alpha.jpg")
            try transparentData.write(to: jpeg)
            _ = try await processor.apply(
                requests: [ImageEditRequest(
                    url: jpeg,
                    configuration: ImageEditConfiguration(outputFormat: .jpeg, maxLongEdge: nil)
                )],
                transactionID: UUID()
            )
            try expectEqual(try imageHasAlpha(jpeg), false)
        }
    }

    await runner.test("指定した新規フォルダへリサイズ前の元画像を保存する") {
        try await withSandbox { sandbox in
            let source = sandbox.appendingPathComponent("photo.png")
            let originals = sandbox.appendingPathComponent("任意の元画像", isDirectory: true)
            let backupRoot = sandbox.appendingPathComponent("original-copy-backups", isDirectory: true)
            let originalData = try makeTestPNG(width: 320, height: 160)
            try originalData.write(to: source)

            let processor = ImageProcessor(backupRootURL: backupRoot)
            _ = try await processor.apply(
                requests: [ImageEditRequest(
                    url: source,
                    configuration: ImageEditConfiguration(outputFormat: .preserve, maxLongEdge: 128),
                    originalCopyDirectory: originals,
                    originalFileName: "photo.png"
                )],
                transactionID: UUID()
            )

            try expectEqual(
                try Data(contentsOf: originals.appendingPathComponent("photo.png")),
                originalData
            )
            try expectEqual(try imageProperties(source).width, 128)
        }
    }

    await runner.test("形式変換のみでも変更前の元画像を保存する") {
        try await withSandbox { sandbox in
            let source = sandbox.appendingPathComponent("convert.jpg")
            let originals = sandbox.appendingPathComponent("形式変換の元画像", isDirectory: true)
            let originalData = try makeTestPNG(width: 96, height: 48, detailed: true)
            try originalData.write(to: source)

            _ = try await ImageProcessor(
                backupRootURL: sandbox.appendingPathComponent("convert-backups", isDirectory: true)
            ).apply(
                requests: [ImageEditRequest(
                    url: source,
                    configuration: ImageEditConfiguration(
                        outputFormat: .jpeg,
                        maxLongEdge: nil,
                        jpegCompressionQuality: 0.95
                    ),
                    originalCopyDirectory: originals,
                    originalFileName: "convert.png"
                )],
                transactionID: UUID()
            )

            try expectEqual(
                try Data(contentsOf: originals.appendingPathComponent("convert.png")),
                originalData
            )
            try expectEqual(try imageProperties(source).type, UTType.jpeg.identifier)
        }
    }

    await runner.test("同名の元画像保存フォルダがある場合は変更せず停止する") {
        try await withSandbox { sandbox in
            let source = sandbox.appendingPathComponent("photo.png")
            let originals = sandbox.appendingPathComponent("元画像", isDirectory: true)
            let backupRoot = sandbox.appendingPathComponent("collision-backups", isDirectory: true)
            let originalData = try makeTestPNG(width: 320, height: 160)
            try originalData.write(to: source)
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: false)

            let processor = ImageProcessor(backupRootURL: backupRoot)
            try await expectThrows {
                _ = try await processor.apply(
                    requests: [ImageEditRequest(
                        url: source,
                        configuration: ImageEditConfiguration(outputFormat: .preserve, maxLongEdge: 128),
                        originalCopyDirectory: originals,
                        originalFileName: "photo.png"
                    )],
                    transactionID: UUID()
                )
            }
            try expectEqual(try Data(contentsOf: source), originalData)
        }
    }

    await runner.test("57件目で失敗しても変更画像と原本コピーをすべて戻す") {
        try await withSandbox { sandbox in
            let originals = sandbox.appendingPathComponent("元画像一括", isDirectory: true)
            let backupRoot = sandbox.appendingPathComponent("batch-backups", isDirectory: true)
            let originalData = try makeTestPNG(width: 16, height: 8, detailed: true)
            var requests: [ImageEditRequest] = []
            var existingURLs: [URL] = []
            for index in 0..<100 {
                let url = sandbox.appendingPathComponent(String(format: "photo-%03d.png", index))
                if index != 56 {
                    try originalData.write(to: url)
                    existingURLs.append(url)
                }
                requests.append(ImageEditRequest(
                    url: url,
                    configuration: ImageEditConfiguration(
                        outputFormat: .jpeg,
                        maxLongEdge: nil,
                        jpegCompressionQuality: 0.95
                    ),
                    originalCopyDirectory: originals,
                    originalFileName: url.lastPathComponent
                ))
            }

            try await expectThrows {
                _ = try await ImageProcessor(backupRootURL: backupRoot).apply(
                    requests: requests,
                    transactionID: UUID()
                )
            }
            for url in existingURLs {
                try expectEqual(try Data(contentsOf: url), originalData)
            }
            try expect(!FileManager.default.fileExists(atPath: originals.path))
        }
    }

    await runner.test("キャンセル時は変更と原本保存フォルダを残さない") {
        try await withSandbox { sandbox in
            let source = sandbox.appendingPathComponent("cancel.png")
            let originals = sandbox.appendingPathComponent("キャンセル原本", isDirectory: true)
            let originalData = try makeTestPNG(width: 320, height: 160, detailed: true)
            try originalData.write(to: source)
            let task = Task {
                try await ImageProcessor(
                    backupRootURL: sandbox.appendingPathComponent("cancel-backups", isDirectory: true)
                ).apply(
                    requests: [ImageEditRequest(
                        url: source,
                        configuration: ImageEditConfiguration(outputFormat: .jpeg, maxLongEdge: 128),
                        originalCopyDirectory: originals,
                        originalFileName: "cancel.png"
                    )],
                    transactionID: UUID()
                )
            }
            task.cancel()
            try await expectThrows { _ = try await task.value }
            try expectEqual(try Data(contentsOf: source), originalData)
            try expect(!FileManager.default.fileExists(atPath: originals.path))
        }
    }

    await runner.test("画像処理中に終了しても次回起動時に元画像へ復旧する") {
        try await withSandbox { sandbox in
            let source = sandbox.appendingPathComponent("interrupted.png")
            let backupRoot = sandbox.appendingPathComponent("recovery-backups", isDirectory: true)
            let journalDirectory = sandbox.appendingPathComponent("image-journals", isDirectory: true)
            let originals = sandbox.appendingPathComponent("中断時の元画像", isDirectory: true)
            let originalCopy = originals.appendingPathComponent("interrupted.png")
            let backup = backupRoot.appendingPathComponent("batch/backup.png")
            let originalData = try makeTestPNG(width: 80, height: 40, detailed: true)
            let changedData = try makeTestPNG(width: 24, height: 12)

            try FileManager.default.createDirectory(
                at: backup.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: false)
            try originalData.write(to: backup)
            try originalData.write(to: originalCopy)
            try changedData.write(to: source)

            let store = ImageProcessingJournalStore(directoryURL: journalDirectory)
            let journal = ImageProcessingJournal(
                id: UUID(),
                entries: [ImageProcessingJournalEntry(
                    fileURL: source,
                    backupURL: backup,
                    originalCopyURL: originalCopy,
                    backupIsReady: true
                )],
                createdOriginalDirectories: [originals],
                renameMoves: [],
                accessBookmarks: []
            )
            try store.save(journal)

            let report = await ImageProcessor(
                backupRootURL: backupRoot,
                journalStore: store
            ).recoverPendingTransactions()

            try expectEqual(report.recoveredBatchCount, 1)
            try expectEqual(report.recoveredFileCount, 1)
            try expectEqual(try Data(contentsOf: source), originalData)
            try expect(!FileManager.default.fileExists(atPath: originals.path))
            try expect(store.loadAll().isEmpty)
        }
    }

    runner.suite("ImageSettingsStore — JPEG品質の保持")

    await runner.test("初回は95%で、最後の選択を再起動相当で読み戻す") {
        let suiteName = "FileRenamerTests.ImageSettings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ExpectationFailure(message: "UserDefaultsスイートを作成できません", file: #fileID, line: #line)
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ImageSettingsStore(userDefaults: defaults, keyPrefix: "test")
        try expectEqual(store.loadJPEGQuality(), JPEGQualitySetting(preset: .high, customPercent: 95))

        store.saveJPEGQuality(JPEGQualitySetting(preset: .custom, customPercent: 73))
        let relaunchedStore = ImageSettingsStore(userDefaults: defaults, keyPrefix: "test")
        try expectEqual(
            relaunchedStore.loadJPEGQuality(),
            JPEGQualitySetting(preset: .custom, customPercent: 73)
        )
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

private func makeTestPNG(width: Int, height: Int, detailed: Bool = false) throws -> Data {
    try makeTestImage(width: width, height: height, type: .png, detailed: detailed)
}

private func makeTestImage(
    width: Int,
    height: Int,
    type: UTType,
    detailed: Bool = false,
    properties: [CFString: Any] = [:],
    alpha: UInt8 = 255
) throws -> Data {
    let bytesPerRow = width * 4
    var pixels = Data(count: bytesPerRow * height)
    pixels.withUnsafeMutableBytes { raw in
        guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        for index in 0..<(width * height) {
            let x = index % width
            let y = index / width
            bytes[index * 4] = detailed ? UInt8((x * 17 + y * 3) % 256) : 40
            bytes[index * 4 + 1] = detailed ? UInt8((x * 5 + y * 19) % 256) : 120
            bytes[index * 4 + 2] = detailed ? UInt8((x * 11 + y * 7) % 256) : 220
            bytes[index * 4 + 3] = alpha
        }
    }
    guard let provider = CGDataProvider(data: pixels as CFData),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let image = CGImage(
              width: width,
              height: height,
              bitsPerComponent: 8,
              bitsPerPixel: 32,
              bytesPerRow: bytesPerRow,
              space: colorSpace,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
              provider: provider,
              decode: nil,
              shouldInterpolate: false,
              intent: .defaultIntent
          )
    else { throw ExpectationFailure(message: "テスト画像を作成できません", file: #fileID, line: #line) }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        type.identifier as CFString,
        1,
        nil
    ) else { throw ExpectationFailure(message: "テスト画像の出力先を作成できません", file: #fileID, line: #line) }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw ExpectationFailure(message: "テスト画像を確定できません", file: #fileID, line: #line)
    }
    return data as Data
}

private func imageMetadata(_ url: URL) throws -> [CFString: Any] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { throw ExpectationFailure(message: "画像メタデータを取得できません", file: #fileID, line: #line) }
    return properties
}

private func imageHasAlpha(_ url: URL) throws -> Bool {
    let properties = try imageMetadata(url)
    return properties[kCGImagePropertyHasAlpha] as? Bool ?? false
}

private func imageProperties(_ url: URL) throws -> (width: Int, height: Int, type: String) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          let type = CGImageSourceGetType(source) as String?
    else { throw ExpectationFailure(message: "画像情報を取得できません", file: #fileID, line: #line) }
    return (width, height, type)
}
