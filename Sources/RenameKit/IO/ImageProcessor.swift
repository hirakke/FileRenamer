import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageEditConfiguration: Hashable, Sendable, Codable {
    public let outputFormat: ImageOutputFormat
    public let maxLongEdge: Int?
    public let preventsUpscaling: Bool
    public let jpegCompressionQuality: Double

    public init(
        outputFormat: ImageOutputFormat,
        maxLongEdge: Int?,
        preventsUpscaling: Bool = true,
        jpegCompressionQuality: Double = 0.95
    ) {
        self.outputFormat = outputFormat
        self.maxLongEdge = maxLongEdge
        self.preventsUpscaling = preventsUpscaling
        self.jpegCompressionQuality = max(0.5, min(jpegCompressionQuality, 1.0))
    }

    private enum CodingKeys: String, CodingKey {
        case outputFormat, maxLongEdge, preventsUpscaling, jpegCompressionQuality
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outputFormat = try values.decode(ImageOutputFormat.self, forKey: .outputFormat)
        maxLongEdge = try values.decodeIfPresent(Int.self, forKey: .maxLongEdge)
        preventsUpscaling = try values.decodeIfPresent(Bool.self, forKey: .preventsUpscaling) ?? true
        jpegCompressionQuality = max(
            0.5,
            min(try values.decodeIfPresent(Double.self, forKey: .jpegCompressionQuality) ?? 0.95, 1.0)
        )
    }
}

public struct ImageEditRequest: Hashable, Sendable {
    public let url: URL
    public let configuration: ImageEditConfiguration
    public let originalCopyDirectory: URL?
    public let originalFileName: String

    public init(
        url: URL,
        configuration: ImageEditConfiguration,
        originalCopyDirectory: URL? = nil,
        originalFileName: String? = nil
    ) {
        self.url = url
        self.configuration = configuration
        self.originalCopyDirectory = originalCopyDirectory
        self.originalFileName = originalFileName ?? url.lastPathComponent
    }
}

public struct ImageEditRecord: Hashable, Sendable, Codable {
    public let fileURL: URL
    public let backupURL: URL
    public let configuration: ImageEditConfiguration

    public init(fileURL: URL, backupURL: URL, configuration: ImageEditConfiguration) {
        self.fileURL = fileURL
        self.backupURL = backupURL
        self.configuration = configuration
    }
}

public struct ImageProcessingJournalEntry: Hashable, Sendable, Codable {
    public let fileURL: URL
    public let backupURL: URL
    public let originalCopyURL: URL?
    public var backupIsReady: Bool

    public init(
        fileURL: URL,
        backupURL: URL,
        originalCopyURL: URL? = nil,
        backupIsReady: Bool = false
    ) {
        self.fileURL = fileURL
        self.backupURL = backupURL
        self.originalCopyURL = originalCopyURL
        self.backupIsReady = backupIsReady
    }
}

public struct ImageProcessingJournal: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let createdAt: Date
    public var entries: [ImageProcessingJournalEntry]
    public var createdOriginalDirectories: [URL]
    public let renameMoves: [RenameOperation]
    public let accessBookmarks: [Data]
    public var isCommitted: Bool

    public init(
        id: UUID,
        createdAt: Date = Date(),
        entries: [ImageProcessingJournalEntry],
        createdOriginalDirectories: [URL],
        renameMoves: [RenameOperation],
        accessBookmarks: [Data],
        isCommitted: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.entries = entries
        self.createdOriginalDirectories = createdOriginalDirectories
        self.renameMoves = renameMoves
        self.accessBookmarks = accessBookmarks
        self.isCommitted = isCommitted
    }
}

public struct ImageProcessingJournalStore: @unchecked Sendable {
    public let directoryURL: URL
    private let fileManager: FileManager

    public init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL()
        self.fileManager = fileManager
    }

    public static func defaultDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("FileRenamer/ImageProcessingJournals", isDirectory: true)
    }

    public func save(_ journal: ImageProcessingJournal) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: fileURL(for: journal.id), options: .atomic)
    }

    public func remove(id: UUID) throws {
        let url = fileURL(for: id)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    public func loadAll() -> [ImageProcessingJournal] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls.compactMap { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(ImageProcessingJournal.self, from: data)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }
}

public struct ImageRecoveryReport: Sendable {
    public var recoveredBatchCount = 0
    public var recoveredFileCount = 0
    public var messages: [String] = []
    public var hasUnresolvedWork = false
    public var hasWork: Bool { recoveredBatchCount > 0 || hasUnresolvedWork }
}

public enum ImageProcessingError: Error, LocalizedError {
    case sourceUnreadable(URL)
    case unsupportedFormat(URL)
    case destinationCreationFailed(URL)
    case encodingFailed(URL)
    case replacementFailed(URL, Error)
    case backupMissing(URL)
    case originalCopyDirectoryExists(URL)
    case originalCopyExists(URL)
    case originalCopyFailed(URL, Error)

    public var errorDescription: String? {
        switch self {
        case .sourceUnreadable(let url):
            return "画像を読み込めません: \(url.lastPathComponent)"
        case .unsupportedFormat(let url):
            return "対応していない画像形式です: \(url.lastPathComponent)"
        case .destinationCreationFailed(let url):
            return "画像の書き出し先を作成できません: \(url.lastPathComponent)"
        case .encodingFailed(let url):
            return "画像を書き出せません: \(url.lastPathComponent)"
        case .replacementFailed(let url, let error):
            return "画像を置き換えられません: \(url.lastPathComponent)（\(error.localizedDescription)）"
        case .backupMissing(let url):
            return "元画像のバックアップが見つかりません: \(url.lastPathComponent)"
        case .originalCopyDirectoryExists(let url):
            return "元画像の保存フォルダが既に存在します: \(url.lastPathComponent)"
        case .originalCopyExists(let url):
            return "元画像の保存先に同名ファイルがあります: \(url.lastPathComponent)"
        case .originalCopyFailed(let url, let error):
            return "元画像を保存できません: \(url.lastPathComponent)（\(error.localizedDescription)）"
        }
    }
}

public extension RenameRule {
    func imageEditConfiguration(
        for url: URL,
        jpegQuality: JPEGQualitySetting = JPEGQualitySetting(),
        preservesJPEGAtMaximumQuality: Bool = true
    ) -> ImageEditConfiguration? {
        guard FileKinds.isEditableImage(url) else { return nil }

        let source = url.pathExtension.lowercased()
        let requiresExplicitEncoding: Bool
        if imageOutputFormat == .jpeg {
            // JPEG → JPEG at 100% with no resize is safest when left byte-for-byte
            // untouched. Any lower quality or resize remains an explicit re-encode.
            let preservesJPEGBytes = FileKinds.jpegExtensions.contains(source)
                && !imageResize.isEnabled
                && jpegQuality.compressionQuality >= 1.0
                && preservesJPEGAtMaximumQuality
            requiresExplicitEncoding = !preservesJPEGBytes
        } else if let target = imageOutputFormat.fileExtension {
            if FileKinds.jpegExtensions.contains(source), target == "jpg" {
                requiresExplicitEncoding = false
            } else {
                requiresExplicitEncoding = source != target
            }
        } else {
            requiresExplicitEncoding = false
        }

        // HEIC/HEIF are accepted as conversion inputs, but this app intentionally
        // only writes JPEG and PNG. Preserve+resize must not silently change format.
        if FileKinds.isHEIF(url), imageOutputFormat == .preserve { return nil }

        let maxLongEdge = imageResize.isEnabled ? imageResize.normalizedLongEdge : nil

        guard maxLongEdge != nil || requiresExplicitEncoding else { return nil }
        return ImageEditConfiguration(
            outputFormat: imageOutputFormat,
            maxLongEdge: maxLongEdge,
            preventsUpscaling: imageResize.preventsUpscaling,
            jpegCompressionQuality: jpegQuality.compressionQuality
        )
    }

    func showsJPEGQuality(for urls: [URL]) -> Bool {
        if imageOutputFormat == .jpeg { return true }
        return imageOutputFormat == .preserve
            && imageResize.isEnabled
            && urls.contains(where: FileKinds.isJPEG)
    }
}

public struct ImageProcessor: @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (Double) -> Void

    private let fileManager: FileManager
    public let backupRootURL: URL
    private let journalStore: ImageProcessingJournalStore

    public init(
        fileManager: FileManager = .default,
        backupRootURL: URL? = nil,
        journalStore: ImageProcessingJournalStore? = nil
    ) {
        self.fileManager = fileManager
        self.backupRootURL = backupRootURL ?? Self.defaultBackupRootURL()
        self.journalStore = journalStore ?? ImageProcessingJournalStore(fileManager: fileManager)
    }

    public static func defaultBackupRootURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("FileRenamer", isDirectory: true)
            .appendingPathComponent("ImageBackups", isDirectory: true)
    }

    public func apply(
        requests: [ImageEditRequest],
        transactionID: UUID,
        renameMoves: [RenameOperation] = [],
        accessBookmarks: [Data] = [],
        progress: ProgressHandler? = nil
    ) async throws -> [ImageEditRecord] {
        try Task.checkCancellation()
        let fileManager = self.fileManager
        let backupRootURL = self.backupRootURL
        let journalStore = self.journalStore
        let worker = Task.detached(priority: .userInitiated) {
            let directory = backupRootURL.appendingPathComponent(transactionID.uuidString, isDirectory: true)
            let originalDirectories = Set(requests.compactMap(\.originalCopyDirectory))
            var journal = ImageProcessingJournal(
                id: transactionID,
                entries: requests.map { request in
                    let backup = directory.appendingPathComponent(
                        "\(UUID().uuidString).\(request.url.pathExtension)",
                        isDirectory: false
                    )
                    let originalCopy = request.originalCopyDirectory?.appendingPathComponent(
                        request.originalFileName,
                        isDirectory: false
                    )
                    return ImageProcessingJournalEntry(
                        fileURL: request.url,
                        backupURL: backup,
                        originalCopyURL: originalCopy
                    )
                },
                createdOriginalDirectories: [],
                renameMoves: renameMoves,
                accessBookmarks: accessBookmarks
            )
            // Create the journal before touching user-visible files. Later saves
            // advance it only after the corresponding step is durable.
            try journalStore.save(journal)
            var records: [ImageEditRecord] = []
            var createdOriginalDirectories: [URL] = []
            var createdOriginalCopies: [URL] = []
            do {
                for originalDirectory in originalDirectories {
                    guard !fileManager.fileExists(atPath: originalDirectory.path) else {
                        throw ImageProcessingError.originalCopyDirectoryExists(originalDirectory)
                    }
                    do {
                        try fileManager.createDirectory(
                            at: originalDirectory,
                            withIntermediateDirectories: false
                        )
                        createdOriginalDirectories.append(originalDirectory)
                        journal.createdOriginalDirectories.append(originalDirectory)
                        try journalStore.save(journal)
                    } catch {
                        throw ImageProcessingError.originalCopyFailed(originalDirectory, error)
                    }
                }

                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                for (index, request) in requests.enumerated() {
                    try Task.checkCancellation()
                    if let originalDirectory = request.originalCopyDirectory {
                        let originalCopy = originalDirectory.appendingPathComponent(
                            request.originalFileName,
                            isDirectory: false
                        )
                        guard !fileManager.fileExists(atPath: originalCopy.path) else {
                            throw ImageProcessingError.originalCopyExists(originalCopy)
                        }
                        do {
                            try fileManager.copyItem(at: request.url, to: originalCopy)
                            createdOriginalCopies.append(originalCopy)
                        } catch {
                            throw ImageProcessingError.originalCopyFailed(originalCopy, error)
                        }
                    }
                    let backup = journal.entries[index].backupURL
                    try fileManager.copyItem(at: request.url, to: backup)
                    journal.entries[index].backupIsReady = true
                    try journalStore.save(journal)
                    let record = ImageEditRecord(
                        fileURL: request.url,
                        backupURL: backup,
                        configuration: request.configuration
                    )
                    // Include the current file in rollback before replacement starts.
                    // If an I/O error occurs during replacement, restoring the backup
                    // is safe even when the source happened to remain untouched.
                    records.append(record)
                    try Self.encodeAndReplace(record, fileManager: fileManager)
                    progress?(Double(index + 1) / Double(max(requests.count, 1)))
                }
                journal.isCommitted = true
                try journalStore.save(journal)
                try? journalStore.remove(id: journal.id)
                return records
            } catch {
                for record in records.reversed() {
                    try? Self.restore(record, fileManager: fileManager)
                }
                try? fileManager.removeItem(at: directory)
                for originalCopy in createdOriginalCopies.reversed() {
                    try? fileManager.removeItem(at: originalCopy)
                }
                for originalDirectory in createdOriginalDirectories.reversed() {
                    let contents = try? fileManager.contentsOfDirectory(
                        at: originalDirectory,
                        includingPropertiesForKeys: nil
                    )
                    if contents?.isEmpty == true {
                        try? fileManager.removeItem(at: originalDirectory)
                    }
                }
                try? journalStore.remove(id: journal.id)
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public func recoverPendingTransactions() async -> ImageRecoveryReport {
        let fileManager = self.fileManager
        let journalStore = self.journalStore
        return await Task.detached(priority: .userInitiated) {
            var report = ImageRecoveryReport()
            for journal in journalStore.loadAll() {
                if journal.isCommitted {
                    try? journalStore.remove(id: journal.id)
                    continue
                }
                let scopedURLs = Self.resolveSecurityScopedBookmarks(journal.accessBookmarks)
                defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
                do {
                    for entry in journal.entries where entry.backupIsReady {
                        guard fileManager.fileExists(atPath: entry.backupURL.path) else {
                            throw ImageProcessingError.backupMissing(entry.backupURL)
                        }
                        let temporary = Self.temporaryURL(nextTo: entry.fileURL)
                        try fileManager.copyItem(at: entry.backupURL, to: temporary)
                        try Self.replace(entry.fileURL, with: temporary, fileManager: fileManager)
                    }
                    if !journal.renameMoves.isEmpty {
                        let transaction = RenameTransaction(
                            moves: journal.renameMoves,
                            accessBookmarks: journal.accessBookmarks
                        )
                        _ = try await RenameExecutor(fileManager: fileManager).revert(transaction)
                    }
                    for entry in journal.entries {
                        if let copy = entry.originalCopyURL { try? fileManager.removeItem(at: copy) }
                        try? fileManager.removeItem(at: entry.backupURL)
                    }
                    for directory in journal.createdOriginalDirectories {
                        let contents = try? fileManager.contentsOfDirectory(atPath: directory.path)
                        if contents?.isEmpty == true { try? fileManager.removeItem(at: directory) }
                    }
                    try journalStore.remove(id: journal.id)
                    report.recoveredBatchCount += 1
                    report.recoveredFileCount += journal.entries.count
                } catch {
                    report.hasUnresolvedWork = true
                    report.messages.append(error.localizedDescription)
                }
            }
            return report
        }.value
    }

    private static func resolveSecurityScopedBookmarks(_ bookmarks: [Data]) -> [URL] {
        bookmarks.compactMap { bookmark in
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), url.startAccessingSecurityScopedResource() else { return nil }
            return url
        }
    }

    public func restore(
        _ records: [ImageEditRecord],
        progress: ProgressHandler? = nil
    ) async throws {
        let fileManager = self.fileManager
        try await Task.detached(priority: .userInitiated) {
            for record in records where !fileManager.fileExists(atPath: record.backupURL.path) {
                throw ImageProcessingError.backupMissing(record.backupURL)
            }
            var completed: [ImageEditRecord] = []
            do {
                for (index, record) in records.enumerated() {
                    try Self.restore(record, fileManager: fileManager)
                    completed.append(record)
                    progress?(Double(index + 1) / Double(max(records.count, 1)))
                }
            } catch {
                for record in completed.reversed() {
                    try? Self.encodeAndReplace(record, fileManager: fileManager)
                }
                throw error
            }
        }.value
    }

    public func reapply(
        _ records: [ImageEditRecord],
        progress: ProgressHandler? = nil
    ) async throws {
        let fileManager = self.fileManager
        try await Task.detached(priority: .userInitiated) {
            var completed: [ImageEditRecord] = []
            do {
                for (index, record) in records.enumerated() {
                    try Self.encodeAndReplace(record, fileManager: fileManager)
                    completed.append(record)
                    progress?(Double(index + 1) / Double(max(records.count, 1)))
                }
            } catch {
                for record in completed.reversed() {
                    try? Self.restore(record, fileManager: fileManager)
                }
                throw error
            }
        }.value
    }

    public func removeBackups(for transactions: [RenameTransaction]) {
        let directories = Set(transactions.compactMap { transaction in
            transaction.imageEdits.first?.backupURL.deletingLastPathComponent()
        })
        for directory in directories {
            try? fileManager.removeItem(at: directory)
        }
    }

    private static func encodeAndReplace(_ record: ImageEditRecord, fileManager: FileManager) throws {
        let fileDates = try? record.fileURL.resourceValues(forKeys: [
            .creationDateKey,
            .contentModificationDateKey
        ])
        guard let source = CGImageSourceCreateWithURL(record.fileURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else { throw ImageProcessingError.sourceUnreadable(record.fileURL) }

        let image: CGImage?
        if let targetLongEdge = record.configuration.maxLongEdge {
            image = exactLongEdgeImage(
                from: source,
                targetLongEdge: targetLongEdge,
                preventsUpscaling: record.configuration.preventsUpscaling
            )
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { throw ImageProcessingError.sourceUnreadable(record.fileURL) }

        let outputType = try outputType(for: record)
        let encodedImage = outputType == .jpeg ? imageFlattenedOnWhiteIfNeeded(image) : image
        let temporary = temporaryURL(nextTo: record.fileURL)
        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL,
            outputType.identifier as CFString,
            1,
            nil
        ) else { throw ImageProcessingError.destinationCreationFailed(record.fileURL) }

        var properties = updatedMetadata(
            from: source,
            width: encodedImage.width,
            height: encodedImage.height,
            normalizesOrientation: record.configuration.maxLongEdge != nil
        )
        if outputType == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = record.configuration.jpegCompressionQuality
        }
        CGImageDestinationAddImage(destination, encodedImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? fileManager.removeItem(at: temporary)
            throw ImageProcessingError.encodingFailed(record.fileURL)
        }

        do {
            try replace(record.fileURL, with: temporary, fileManager: fileManager)
            var attributes: [FileAttributeKey: Any] = [:]
            if let creationDate = fileDates?.creationDate { attributes[.creationDate] = creationDate }
            if let modificationDate = fileDates?.contentModificationDate {
                attributes[.modificationDate] = modificationDate
            }
            if !attributes.isEmpty {
                try? fileManager.setAttributes(attributes, ofItemAtPath: record.fileURL.path)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw ImageProcessingError.replacementFailed(record.fileURL, error)
        }
    }

    private static func restore(_ record: ImageEditRecord, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: record.backupURL.path) else {
            throw ImageProcessingError.backupMissing(record.backupURL)
        }
        let temporary = temporaryURL(nextTo: record.fileURL)
        try fileManager.copyItem(at: record.backupURL, to: temporary)
        do {
            try replace(record.fileURL, with: temporary, fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw ImageProcessingError.replacementFailed(record.fileURL, error)
        }
    }

    /// ImageIO's thumbnail max size is deliberately an upper bound and therefore
    /// never enlarges a smaller source. Decode an orientation-correct source first,
    /// then draw it into an exact target canvas so every edited image shares the
    /// requested long edge, whether that requires shrinking or enlarging.
    private static func exactLongEdgeImage(
        from source: CGImageSource,
        targetLongEdge: Int,
        preventsUpscaling: Bool
    ) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let sourceWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? targetLongEdge
        let sourceHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? targetLongEdge
        let sourceLongEdge = max(sourceWidth, sourceHeight)
        let effectiveTarget = preventsUpscaling ? min(targetLongEdge, sourceLongEdge) : targetLongEdge
        let decodeLongEdge = max(sourceLongEdge, effectiveTarget)
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeLongEdge,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let orientedImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            decodeOptions as CFDictionary
        ) else { return nil }

        let longEdge = max(orientedImage.width, orientedImage.height)
        guard longEdge > 0 else { return nil }
        let scale = CGFloat(effectiveTarget) / CGFloat(longEdge)
        let targetWidth = max(1, Int((CGFloat(orientedImage.width) * scale).rounded()))
        let targetHeight = max(1, Int((CGFloat(orientedImage.height) * scale).rounded()))

        guard let colorSpace = orientedImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: targetWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.interpolationQuality = .high
        context.draw(orientedImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    private static func updatedMetadata(
        from source: CGImageSource,
        width: Int,
        height: Int,
        normalizesOrientation: Bool
    ) -> [CFString: Any] {
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        properties[kCGImagePropertyPixelWidth] = width
        properties[kCGImagePropertyPixelHeight] = height

        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if normalizesOrientation { tiff[kCGImagePropertyTIFFOrientation] = 1 }
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if normalizesOrientation { properties[kCGImagePropertyOrientation] = 1 }
        return properties
    }

    private static func imageFlattenedOnWhiteIfNeeded(_ image: CGImage) -> CGImage {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast,
              let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: image.width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    private static func replace(_ target: URL, with replacement: URL, fileManager: FileManager) throws {
        let rollback = temporaryURL(nextTo: target, prefix: ".filerenamer-rollback-")
        try fileManager.moveItem(at: target, to: rollback)
        do {
            try fileManager.moveItem(at: replacement, to: target)
            try fileManager.removeItem(at: rollback)
        } catch {
            if fileManager.fileExists(atPath: target.path) { try? fileManager.removeItem(at: target) }
            try? fileManager.moveItem(at: rollback, to: target)
            throw error
        }
    }

    private static func outputType(for record: ImageEditRecord) throws -> UTType {
        switch record.configuration.outputFormat {
        case .jpeg: return .jpeg
        case .png: return .png
        case .preserve:
            let ext = record.fileURL.pathExtension.lowercased()
            if FileKinds.jpegExtensions.contains(ext) { return .jpeg }
            if ext == "png" { return .png }
            throw ImageProcessingError.unsupportedFormat(record.fileURL)
        }
    }

    private static func temporaryURL(nextTo url: URL, prefix: String = ".filerenamer-image-") -> URL {
        let name = "\(prefix)\(UUID().uuidString).\(url.pathExtension)"
        return url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
    }
}
