import Foundation
import RenameKit

private extension RenameToken {
    var isVariableToken: Bool { !isTextRun }
}

private let folder = URL(fileURLWithPath: "/tmp/photos", isDirectory: true)

private func makeItem(_ name: String, creation: Date? = nil, capture: Date? = nil, size: Int64? = nil, locked: Bool = false) -> RenameItem {
    var metadata = FileMetadata()
    metadata.creationDate = creation
    metadata.captureDate = capture
    metadata.fileSize = size
    return RenameItem(originalURL: folder.appendingPathComponent(name), isLocked: locked, metadata: metadata)
}

private func makeDate(_ string: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.date(from: string) ?? Date(timeIntervalSince1970: 0)
}

@MainActor
func runEngineTests() async {
    let runner = TestRunner.shared
    runner.suite("RenameEngine — 並び順が番号を決める")

    // The core promise of the app.
    await runner.test("リスト順がそのまま連番になる") {
        let items = [makeItem("IMG_3051.jpg"), makeItem("IMG_3048.jpg"), makeItem("IMG_3060.jpg")]
        let rule = RenameRule(tokens: [
            .text(TextConfiguration(value: "Event")),
            .separator(SeparatorConfiguration(value: "_")),
            .counter(CounterConfiguration(start: 1, digits: 3))
        ])
        let previews = RenameEngine().makePreviews(items: items, rule: rule)
        try expectEqual(previews.map(\.proposedName), ["Event_001.jpg", "Event_002.jpg", "Event_003.jpg"])
        try expectEqual(previews.compactMap(\.counterValue), [1, 2, 3])
    }

    await runner.test("並べ替えると番号が即座に付け替わる") {
        var items = [makeItem("A.jpg"), makeItem("B.jpg"), makeItem("C.jpg"), makeItem("D.jpg")]
        items = ItemSorter.move(items, fromOffsets: IndexSet(integer: 3), toOffset: 1)
        try expectEqual(items.map(\.baseName), ["A", "D", "B", "C"])
        try expectEqual(items.map(\.order), [0, 1, 2, 3])

        let rule = RenameRule(tokens: [.counter(CounterConfiguration(start: 1, digits: 3))])
        let previews = RenameEngine().makePreviews(items: items, rule: rule)
        try expectEqual(previews.map(\.proposedName), ["001.jpg", "002.jpg", "003.jpg", "004.jpg"])
        try expectEqual(previews[1].sourceURL.lastPathComponent, "D.jpg")
    }

    await runner.test("開始番号と桁数が反映される") {
        let rule = RenameRule(tokens: [.counter(CounterConfiguration(start: 100, digits: 4))])
        let previews = RenameEngine().makePreviews(items: [makeItem("a.jpg"), makeItem("b.jpg")], rule: rule)
        try expectEqual(previews.map(\.proposedName), ["0100.jpg", "0101.jpg"])
    }

    await runner.test("桁数を超える番号は切り捨てない") {
        try expectEqual(CounterConfiguration(start: 12345, digits: 3).formatted(at: 0), "12345")
    }

    await runner.test("拡張子は大文字小文字ごと保持される") {
        let rule = RenameRule(tokens: [.text(TextConfiguration(value: "Event"))])
        let previews = RenameEngine().makePreviews(items: [makeItem("DSCF2041.RAF")], rule: rule)
        try expectEqual(previews[0].proposedName, "Event.RAF")
    }

    await runner.test("拡張子を小文字・大文字へ切り替えられる") {
        let lower = RenameRule(
            tokens: [.text(TextConfiguration(value: "Event"))],
            extensionTransform: .lowercase
        )
        let upper = RenameRule(
            tokens: [.text(TextConfiguration(value: "Event"))],
            extensionTransform: .uppercase
        )
        try expectEqual(
            RenameEngine().makePreviews(items: [makeItem("photo.JpG")], rule: lower)[0].proposedName,
            "Event.jpg"
        )
        try expectEqual(
            RenameEngine().makePreviews(items: [makeItem("photo.jpg")], rule: upper)[0].proposedName,
            "Event.JPG"
        )
    }

    await runner.test("JPEG・PNGへ画像形式を変更できる") {
        for (format, expected) in [(ImageOutputFormat.jpeg, "Event.jpg"), (.png, "Event.png")] {
            let rule = RenameRule(
                tokens: [.text(TextConfiguration(value: "Event"))],
                imageOutputFormat: format
            )
            let preview = RenameEngine().makePreviews(items: [makeItem("photo.png")], rule: rule)[0]
            try expectEqual(preview.proposedName, expected)
            try expectEqual(preview.requiresContentProcessing, format != .png)
        }
    }

    await runner.test("JPEG品質の値と表示条件が一箇所で決まる") {
        let expected: [(JPEGQualityPreset, Int, Double)] = [
            (.compact, 80, 0.80),
            (.standard, 90, 0.90),
            (.high, 95, 0.95),
            (.maximum, 100, 1.00)
        ]
        for (preset, percent, quality) in expected {
            let setting = JPEGQualitySetting(preset: preset)
            try expectEqual(setting.percent, percent)
            try expectEqual(setting.compressionQuality, quality)
        }
        try expectEqual(
            JPEGQualitySetting(preset: .custom, customPercent: 73).compressionQuality,
            0.73
        )
        try expectEqual(JPEGQualitySetting(preset: .custom, customPercent: 20).percent, 50)
        try expectEqual(JPEGQualitySetting(preset: .custom, customPercent: 120).percent, 100)

        let jpeg = folder.appendingPathComponent("photo.jpg")
        let png = folder.appendingPathComponent("photo.png")
        let explicitJPEG = RenameRule(imageOutputFormat: .jpeg)
        try expect(explicitJPEG.showsJPEGQuality(for: [png]))
        try expect(explicitJPEG.imageEditConfiguration(for: jpeg) != nil)
        try expect(explicitJPEG.imageEditConfiguration(
            for: jpeg,
            jpegQuality: JPEGQualitySetting(preset: .maximum)
        ) == nil)
        try expect(explicitJPEG.imageEditConfiguration(
            for: jpeg,
            jpegQuality: JPEGQualitySetting(preset: .maximum),
            preservesJPEGAtMaximumQuality: false
        ) != nil)
        try expect(!RenameEngine().makePreviews(
            items: [makeItem("photo.jpg")],
            rule: explicitJPEG,
            jpegQuality: JPEGQualitySetting(preset: .maximum)
        )[0].requiresContentProcessing)
        try expect(RenameEngine().makePreviews(
            items: [makeItem("photo.jpg")],
            rule: explicitJPEG,
            jpegQuality: JPEGQualitySetting(preset: .maximum),
            preservesJPEGAtMaximumQuality: false
        )[0].requiresContentProcessing)

        let maximumWithResize = RenameRule(
            imageOutputFormat: .jpeg,
            imageResize: ImageResizeConfiguration(isEnabled: true, maxLongEdge: 128)
        )
        try expect(maximumWithResize.imageEditConfiguration(
            for: jpeg,
            jpegQuality: JPEGQualitySetting(preset: .maximum)
        ) != nil)

        let preserveResize = RenameRule(
            imageResize: ImageResizeConfiguration(isEnabled: true, maxLongEdge: 1200)
        )
        try expect(preserveResize.showsJPEGQuality(for: [jpeg]))
        try expect(!preserveResize.showsJPEGQuality(for: [png]))
        let customConfiguration = preserveResize.imageEditConfiguration(
            for: jpeg,
            jpegQuality: JPEGQualitySetting(preset: .custom, customPercent: 73)
        )
        try expectEqual(customConfiguration?.jpegCompressionQuality, 0.73)

        let pngOutput = RenameRule(
            imageOutputFormat: .png,
            imageResize: ImageResizeConfiguration(isEnabled: true, maxLongEdge: 1200)
        )
        try expect(!pngOutput.showsJPEGQuality(for: [jpeg, png]))
    }

    await runner.test("通常リネームだけでは画像を再エンコードしない") {
        let rule = RenameRule(tokens: [.text(TextConfiguration(value: "Renamed"))])
        let preview = RenameEngine().makePreviews(items: [makeItem("photo.jpg")], rule: rule)[0]
        try expect(!preview.requiresContentProcessing)
        try expect(rule.imageEditConfiguration(for: preview.sourceURL) == nil)
    }

    await runner.test("RAWは画像形式変換の対象外") {
        let rule = RenameRule(
            tokens: [.text(TextConfiguration(value: "Event"))],
            imageOutputFormat: .jpeg,
            imageResize: ImageResizeConfiguration(isEnabled: true, maxLongEdge: 1280)
        )
        let preview = RenameEngine().makePreviews(items: [makeItem("photo.RAF")], rule: rule)[0]
        try expectEqual(preview.proposedName, "Event.RAF")
        try expect(!preview.requiresContentProcessing)
    }

    await runner.test("撮影日がなければ作成日にフォールバックする") {
        let items = [
            makeItem("shot.jpg", creation: makeDate("2020-01-01 00:00:00"), capture: makeDate("2026-08-08 14:30:05")),
            makeItem("report.pdf", creation: makeDate("2026-01-02 09:00:00"))
        ]
        let rule = RenameRule(tokens: [
            .date(DateConfiguration(source: .capture, preset: .compact)),
            .separator(SeparatorConfiguration(value: "_")),
            .counter(CounterConfiguration(start: 1, digits: 2))
        ])
        let previews = RenameEngine().makePreviews(items: items, rule: rule)
        try expectEqual(previews.map(\.proposedName), ["20260808_01.jpg", "20260102_02.pdf"])
    }

    await runner.test("RAW+JPEG は同じベース名になる") {
        let item = RenameItem(
            originalURL: folder.appendingPathComponent("DSCF0001.RAF"),
            companionURLs: [folder.appendingPathComponent("DSCF0001.JPG")]
        )
        let rule = RenameRule(tokens: [
            .text(TextConfiguration(value: "Event")),
            .separator(SeparatorConfiguration(value: "_")),
            .counter(CounterConfiguration(start: 1, digits: 3))
        ])
        let previews = RenameEngine().makePreviews(items: [item], rule: rule)
        try expectEqual(previews[0].operations.map(\.destination.lastPathComponent), ["Event_001.RAF", "Event_001.JPG"])
    }

    await runner.test("使用できない文字は置換される") {
        let rule = RenameRule(tokens: [.text(TextConfiguration(value: "Trip 8/9"))])
        let previews = RenameEngine().makePreviews(items: [makeItem("a.jpg")], rule: rule)
        try expectEqual(previews[0].proposedName, "Trip 8-9.jpg")
    }

    await runner.test("元の名前トークン") {
        let rule = RenameRule(tokens: [.originalName(OriginalNameConfiguration(transform: .lowercase))])
        let previews = RenameEngine().makePreviews(items: [makeItem("DSCF2041.RAF")], rule: rule)
        try expectEqual(previews[0].proposedName, "dscf2041.RAF")
    }

    await runner.test("写真メタデータをファイル名に使える") {
        var metadata = FileMetadata()
        metadata.cameraModel = "X-T5"
        metadata.iso = 800
        metadata.pixelWidth = 6240
        metadata.pixelHeight = 4160
        let item = RenameItem(originalURL: folder.appendingPathComponent("shot.RAF"), metadata: metadata)
        let rule = RenameRule(tokens: [
            .metadata(MetadataConfiguration(field: .cameraModel)),
            .separator(SeparatorConfiguration(value: "_")),
            .metadata(MetadataConfiguration(field: .iso)),
            .separator(SeparatorConfiguration(value: "_")),
            .metadata(MetadataConfiguration(field: .dimensions))
        ])
        let preview = RenameEngine().makePreviews(items: [item], rule: rule)[0]
        try expectEqual(preview.proposedName, "X-T5_ISO800_6240x4160.RAF")
    }

    await runner.test("元の名前を正規表現で検索・置換できる") {
        let rule = RenameRule(tokens: [.originalName(OriginalNameConfiguration(
            find: "^IMG_0*",
            replacement: "Shot-",
            usesRegularExpression: true
        ))])
        let preview = RenameEngine().makePreviews(items: [makeItem("IMG_0032.JPG")], rule: rule)[0]
        try expectEqual(preview.proposedName, "Shot-32.JPG")
    }

    await runner.test("連番をフォルダごとにリセットできる") {
        let a = folder.appendingPathComponent("A", isDirectory: true)
        let b = folder.appendingPathComponent("B", isDirectory: true)
        let items = [
            RenameItem(originalURL: a.appendingPathComponent("1.jpg")),
            RenameItem(originalURL: a.appendingPathComponent("2.jpg")),
            RenameItem(originalURL: b.appendingPathComponent("3.jpg"))
        ]
        let rule = RenameRule(tokens: [.counter(CounterConfiguration(
            start: 1,
            digits: 2,
            resetMode: .folder
        ))])
        let previews = RenameEngine().makePreviews(items: items, rule: rule)
        try expectEqual(previews.map(\.proposedName), ["01.jpg", "02.jpg", "01.jpg"])
    }

    await runner.test("旧形式の連番・元名設定を後方互換で読める") {
        let counterData = Data("{\"start\":5,\"digits\":2,\"step\":1}".utf8)
        let counter = try JSONDecoder().decode(CounterConfiguration.self, from: counterData)
        try expectEqual(counter.resetMode, .never)

        let originalData = Data("{\"transform\":\"lowercase\"}".utf8)
        let original = try JSONDecoder().decode(OriginalNameConfiguration.self, from: originalData)
        try expectEqual(original.find, "")
        try expectEqual(original.transform, .lowercase)

        let ruleData = Data("{\"tokens\":[],\"extensionTransform\":\"none\"}".utf8)
        let legacyRule = try JSONDecoder().decode(RenameRule.self, from: ruleData)
        try expectEqual(legacyRule.imageOutputFormat, .preserve)
        try expect(!legacyRule.imageResize.isEnabled)
        try expect(legacyRule.imageResize.preventsUpscaling)

        let legacyImageConfiguration = Data("{\"outputFormat\":\"jpeg\",\"maxLongEdge\":128}".utf8)
        let decodedImageConfiguration = try JSONDecoder().decode(
            ImageEditConfiguration.self,
            from: legacyImageConfiguration
        )
        try expectEqual(decodedImageConfiguration.jpegCompressionQuality, 0.95)
        try expect(decodedImageConfiguration.preventsUpscaling)
    }
}

@MainActor
func runSorterTests() async {
    let runner = TestRunner.shared
    runner.suite("ItemSorter — 自動ソートと固定")

    await runner.test("ファイル名は自然順で並ぶ") {
        let items = [makeItem("IMG_10.jpg"), makeItem("IMG_2.jpg"), makeItem("IMG_1.jpg")]
        let sorted = ItemSorter.sorted(items, by: SortDescriptorOption(field: .fileName, ascending: true))
        try expectEqual(sorted.map(\.displayName), ["IMG_1.jpg", "IMG_2.jpg", "IMG_10.jpg"])
        try expectEqual(sorted.map(\.order), [0, 1, 2])
    }

    await runner.test("降順ソート") {
        let items = [makeItem("a.jpg"), makeItem("c.jpg"), makeItem("b.jpg")]
        let sorted = ItemSorter.sorted(items, by: SortDescriptorOption(field: .fileName, ascending: false))
        try expectEqual(sorted.map(\.displayName), ["c.jpg", "b.jpg", "a.jpg"])
    }

    await runner.test("ソートキーを持たないファイルは末尾に沈む") {
        let now = Date()
        let items = [
            makeItem("no-exif.pdf"),
            makeItem("b.jpg", capture: now),
            makeItem("a.jpg", capture: now.addingTimeInterval(-60))
        ]
        let sorted = ItemSorter.sorted(items, by: SortDescriptorOption(field: .captureDate, ascending: true))
        try expectEqual(sorted.map(\.displayName), ["a.jpg", "b.jpg", "no-exif.pdf"])
    }

    await runner.test("固定した行は再ソートしても位置を保つ") {
        let items = [makeItem("GroupPhoto.jpg", locked: true), makeItem("z.jpg"), makeItem("m.jpg"), makeItem("a.jpg")]
        let sorted = ItemSorter.sorted(items, by: SortDescriptorOption(field: .fileName, ascending: true))
        try expectEqual(sorted.map(\.displayName), ["GroupPhoto.jpg", "a.jpg", "m.jpg", "z.jpg"])
    }

    await runner.test("途中で固定した行も動かない") {
        let items = [makeItem("z.jpg"), makeItem("Pinned.jpg", locked: true), makeItem("a.jpg")]
        let sorted = ItemSorter.sorted(items, by: SortDescriptorOption(field: .fileName, ascending: true))
        try expectEqual(sorted.map(\.displayName), ["a.jpg", "Pinned.jpg", "z.jpg"])
    }

    await runner.test("移動後に order が振り直される") {
        let items = [makeItem("A"), makeItem("B"), makeItem("C"), makeItem("D")]
        let moved = ItemSorter.move(items, fromOffsets: IndexSet(integer: 0), toOffset: 4)
        try expectEqual(moved.map(\.displayName), ["B", "C", "D", "A"])
        try expectEqual(moved.map(\.order), [0, 1, 2, 3])
    }

    await runner.test("サイズ順ソート") {
        let items = [makeItem("big", size: 900), makeItem("small", size: 10), makeItem("mid", size: 100)]
        let sorted = ItemSorter.sorted(items, by: SortDescriptorOption(field: .fileSize, ascending: true))
        try expectEqual(sorted.map(\.displayName), ["small", "mid", "big"])
    }

    runner.suite("ItemSorter — ボタンによる 1 つずつの移動")

    await runner.test("1つ後ろへ / 1つ前へ") {
        let items = [makeItem("A"), makeItem("B"), makeItem("C")]
        let ids: Set<UUID> = [items[0].id]
        let down = ItemSorter.shift(items, ids: ids, by: 1)
        try expectEqual(down.map(\.displayName), ["B", "A", "C"])
        try expectEqual(down.map(\.order), [0, 1, 2])
        let backUp = ItemSorter.shift(down, ids: ids, by: -1)
        try expectEqual(backUp.map(\.displayName), ["A", "B", "C"])
    }

    await runner.test("端では動かず、canShift が false になる") {
        let items = [makeItem("A"), makeItem("B")]
        let ids: Set<UUID> = [items[0].id]
        try expect(!ItemSorter.canShift(items, ids: ids, by: -1))
        try expectEqual(ItemSorter.shift(items, ids: ids, by: -1).map(\.displayName), ["A", "B"])
        try expect(ItemSorter.canShift(items, ids: ids, by: 1))
    }

    // A multi-selection should slide as a block, not collapse onto itself.
    await runner.test("複数選択はまとまって 1 つずつ動く") {
        let items = [makeItem("A"), makeItem("B"), makeItem("C"), makeItem("D")]
        let ids: Set<UUID> = [items[1].id, items[2].id]
        let moved = ItemSorter.shift(items, ids: ids, by: 1)
        try expectEqual(moved.map(\.displayName), ["A", "D", "B", "C"])
    }

    await runner.test("先頭 / 末尾へ移動") {
        let items = [makeItem("A"), makeItem("B"), makeItem("C")]
        let toStart = ItemSorter.moveToEdge(items, ids: [items[2].id], toStart: true)
        try expectEqual(toStart.map(\.displayName), ["C", "A", "B"])
        let toEnd = ItemSorter.moveToEdge(items, ids: [items[0].id], toStart: false)
        try expectEqual(toEnd.map(\.displayName), ["B", "C", "A"])
    }

    runner.suite("RenameRule — テキスト編集")

    await runner.test("編集用に正規化するとテキストとブロックが交互になる") {
        let rule = RenameRule(tokens: [
            .counter(CounterConfiguration()),
            .date(DateConfiguration())
        ])
        let normalized = rule.normalizedForTextEditing()
        try expectEqual(normalized.tokens.count, 5)
        try expect(normalized.tokens[0].isTextRun)
        try expect(normalized.tokens[2].isTextRun)
        try expect(normalized.tokens[4].isTextRun)
    }

    await runner.test("区切りはテキストに畳み込まれる") {
        let rule = RenameRule(tokens: [
            .text(TextConfiguration(value: "Day1")),
            .separator(SeparatorConfiguration(value: "_")),
            .counter(CounterConfiguration())
        ])
        let normalized = rule.normalizedForTextEditing()
        guard case .text(let head) = normalized.tokens[0] else {
            try expect(false, "先頭がテキストではない")
            return
        }
        try expectEqual(head.value, "Day1_")
    }

    await runner.test("キャレット位置でテキストが分割されブロックが差し込まれる") {
        var rule = RenameRule(tokens: [.text(TextConfiguration(value: "AB"))]).normalizedForTextEditing()
        guard case .text(let run) = rule.tokens[0] else {
            try expect(false, "テキストランがない")
            return
        }
        rule = rule.inserting(.counter(CounterConfiguration()), atRun: run.id, caret: 1)

        let compacted = rule.compactedAfterTextEditing()
        try expectEqual(compacted.tokens.count, 3)
        guard case .text(let head) = compacted.tokens[0], case .text(let tail) = compacted.tokens[2] else {
            try expect(false, "前後がテキストではない")
            return
        }
        try expectEqual(head.value, "A")
        try expectEqual(tail.value, "B")
    }

    await runner.test("フォーカスがなければ末尾に追加される") {
        let rule = RenameRule(tokens: [.text(TextConfiguration(value: "Day1"))])
            .inserting(.counter(CounterConfiguration()), atRun: nil, caret: 0)
            .compactedAfterTextEditing()
        try expectEqual(rule.tokens.count, 2)
        try expect(rule.tokens[1].isVariableToken)
    }

    await runner.test("保存時に空のテキストランが取り除かれる") {
        let rule = RenameRule(tokens: [.counter(CounterConfiguration())])
            .normalizedForTextEditing()
            .compactedAfterTextEditing()
        try expectEqual(rule.tokens.count, 1)
    }

    await runner.test("ブロックを削除すると前後のテキストが結合する") {
        var rule = RenameRule(tokens: [
            .text(TextConfiguration(value: "A")),
            .counter(CounterConfiguration()),
            .text(TextConfiguration(value: "B"))
        ]).normalizedForTextEditing()
        let counterID = rule.tokens[1].id
        rule = rule.removingToken(id: counterID).compactedAfterTextEditing()
        try expectEqual(rule.tokens.count, 1)
        guard case .text(let merged) = rule.tokens[0] else {
            try expect(false, "テキストに結合されていない")
            return
        }
        try expectEqual(merged.value, "AB")
    }

    // The caret restore after a Backspace delete depends on this: the merged run must
    // keep the earlier run's id, so focus can be put back at the join.
    await runner.test("ブロック削除後の結合ランは前側の id を引き継ぐ") {
        var rule = RenameRule(tokens: [
            .text(TextConfiguration(value: "A")),
            .counter(CounterConfiguration()),
            .text(TextConfiguration(value: "B"))
        ]).normalizedForTextEditing()

        guard case .text(let head) = rule.tokens[0] else {
            try expect(false, "先頭がテキストではない")
            return
        }
        let headID = head.id
        rule = rule.removingToken(id: rule.tokens[1].id)

        guard case .text(let merged) = rule.tokens[0] else {
            try expect(false, "結合されていない")
            return
        }
        try expectEqual(merged.id, headID)
        try expectEqual(merged.value, "AB")
    }

    runner.suite("FileImporter — RAW+JPEG グルーピング")

    await runner.test("RAW を主ファイルとしてペアになる") {
        let urls = [
            folder.appendingPathComponent("DSCF0001.JPG"),
            folder.appendingPathComponent("DSCF0001.RAF"),
            folder.appendingPathComponent("DSCF0002.RAF")
        ]
        let groups = FileImporter.groupCompanions(urls)
        try expectEqual(groups.count, 2)
        try expectEqual(groups[0].map(\.lastPathComponent), ["DSCF0001.RAF", "DSCF0001.JPG"])
    }

    await runner.test("XMP サイドカーも同じグループに入る") {
        let groups = FileImporter.groupCompanions([
            folder.appendingPathComponent("DSCF0001.RAF"),
            folder.appendingPathComponent("DSCF0001.xmp")
        ])
        try expectEqual(groups.count, 1)
        try expectEqual(groups[0].map(\.lastPathComponent), ["DSCF0001.RAF", "DSCF0001.xmp"])
    }

    await runner.test("別フォルダの同名ファイルはグループ化しない") {
        let groups = FileImporter.groupCompanions([
            folder.appendingPathComponent("a/IMG.jpg"),
            folder.appendingPathComponent("b/IMG.jpg")
        ])
        try expectEqual(groups.count, 2)
    }

    await runner.test("同名でも無関係な一般書類はまとめない") {
        let groups = FileImporter.groupCompanions([
            folder.appendingPathComponent("proposal.pdf"),
            folder.appendingPathComponent("proposal.docx")
        ])
        try expectEqual(groups.count, 2)
    }
}

@MainActor
func runPerformanceTests() async {
    let runner = TestRunner.shared
    runner.suite("Performance — 大量ファイル")

    await runner.test("10,000件の生成と構造検証を実用時間内に完了する") {
        let items = (0..<10_000).map { index in
            RenameItem(
                originalURL: folder.appendingPathComponent("IMG_\(index).JPG"),
                order: index,
                metadata: FileMetadata(creationDate: Date(timeIntervalSince1970: 1_700_000_000))
            )
        }
        let rule = RenameRule(tokens: [
            .date(DateConfiguration(source: .creation, preset: .compact)),
            .separator(SeparatorConfiguration(value: "_")),
            .counter(CounterConfiguration(start: 1, digits: 5))
        ])

        let clock = ContinuousClock()
        let start = clock.now
        let generated = RenameEngine().makePreviews(items: items, rule: rule)
        let validated = RenameValidator().validate(generated, checkExistingFiles: false)
        let elapsed = start.duration(to: clock.now)

        try expectEqual(validated.count, 10_000)
        try expect(!validated.hasErrors)
        try expect(elapsed < .seconds(5), "10,000件に \(elapsed) かかりました")
    }
}

@MainActor
func runLocalizationTests() async {
    let runner = TestRunner.shared
    runner.suite("Localization — 表示言語")

    await runner.test("システム設定の日本語系ロケールは日本語になる") {
        try expectEqual(AppLanguage.system.resolved(preferredLanguageIdentifier: "ja-JP"), .japanese)
        try expectEqual(AppLanguage.system.resolved(preferredLanguageIdentifier: "ja"), .japanese)
    }

    await runner.test("システム設定の日本語以外は英語になる") {
        try expectEqual(AppLanguage.system.resolved(preferredLanguageIdentifier: "en-US"), .english)
        try expectEqual(AppLanguage.system.resolved(preferredLanguageIdentifier: "fr-FR"), .english)
        try expectEqual(AppLanguage.system.resolved(preferredLanguageIdentifier: "ko-KR"), .english)
    }

    await runner.test("明示した表示言語はシステム設定より優先される") {
        try expectEqual(AppLanguage.japanese.resolved(preferredLanguageIdentifier: "en-US"), .japanese)
        try expectEqual(AppLanguage.english.resolved(preferredLanguageIdentifier: "ja-JP"), .english)
    }
}
