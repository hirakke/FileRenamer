import CryptoKit
import Foundation
import ImageIO
import RenameKit
import Vision

enum SimilarImageSensitivity: String, CaseIterable, Identifiable, Sendable {
    case strict
    case standard
    case broad

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .strict: return "厳密"
        case .standard: return "標準"
        case .broad: return "広め"
        }
    }

    /// Vision documents distance ordering (smaller is more similar), but deliberately
    /// does not prescribe product thresholds. These conservative app-level values are
    /// paired with a perceptual-hash prefilter to avoid obvious false positives.
    var featureDistanceThreshold: Float {
        switch self {
        case .strict: return 0.18
        case .standard: return 0.32
        case .broad: return 0.48
        }
    }

    var perceptualHashDistance: Int {
        switch self {
        case .strict: return 6
        case .standard: return 12
        case .broad: return 20
        }
    }
}

struct SimilarImageScanConfiguration: Sendable {
    let exactMatchesOnly: Bool
    let sensitivity: SimilarImageSensitivity
    let excludesRAWJPEGCompanions: Bool
}

enum SimilarImageMatchKind: String, Hashable, Sendable {
    case exact
    case similar
}

struct SimilarImageMatch: Identifiable, Hashable, Sendable {
    let otherItemID: UUID
    let kind: SimilarImageMatchKind
    let featureDistance: Float?

    var id: String { "\(otherItemID.uuidString)|\(kind.rawValue)" }
}

struct SimilarImageCandidate: Sendable {
    let itemID: UUID
    let analysisURL: URL
    let allURLs: [URL]
}

/// Local-only duplicate and similarity analysis.
///
/// Exact matches use a streaming SHA-256 digest. Near matches first use a tiny dHash
/// as an inexpensive candidate filter, then Vision feature prints as the final test.
/// All caches are keyed by path, size and modification time so replacing a file can
/// never reuse the previous file's result.
actor SimilarImageDetector {
    static let shared = SimilarImageDetector()

    private struct FileKey: Hashable {
        let path: String
        let size: Int64
        let modificationMilliseconds: Int64
    }

    private struct PreparedCandidate {
        let candidate: SimilarImageCandidate
        let key: FileKey
    }

    private struct PairKey: Hashable {
        let first: UUID
        let second: UUID

        init(_ lhs: UUID, _ rhs: UUID) {
            if lhs.uuidString < rhs.uuidString {
                first = lhs
                second = rhs
            } else {
                first = rhs
                second = lhs
            }
        }
    }

    private struct PairResult {
        let kind: SimilarImageMatchKind
        let distance: Float?
    }

    private var exactHashCache: [FileKey: Data] = [:]
    private var perceptualHashCache: [FileKey: UInt64] = [:]
    private var featurePrintCache: [FileKey: VNFeaturePrintObservation] = [:]

    func scan(
        candidates: [SimilarImageCandidate],
        configuration: SimilarImageScanConfiguration
    ) throws -> [UUID: [SimilarImageMatch]] {
        try Task.checkCancellation()
        let prepared = candidates.compactMap(prepare)
        guard prepared.count > 1 else { return [:] }

        var pairs: [PairKey: PairResult] = [:]
        try findExactMatches(in: prepared, configuration: configuration, pairs: &pairs)

        if !configuration.exactMatchesOnly {
            try findNearMatches(in: prepared, configuration: configuration, pairs: &pairs)
        }

        pruneCaches(keeping: Set(prepared.map(\.key)))
        return makeBidirectionalMatches(from: pairs)
    }

    private func prepare(_ candidate: SimilarImageCandidate) -> PreparedCandidate? {
        guard FileKinds.isImage(candidate.analysisURL) else { return nil }
        guard let values = try? candidate.analysisURL.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return nil }

        let key = FileKey(
            path: candidate.analysisURL.standardizedFileURL.path,
            size: Int64(values.fileSize ?? 0),
            modificationMilliseconds: Int64(
                (values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000
            )
        )
        return PreparedCandidate(candidate: candidate, key: key)
    }

    private func findExactMatches(
        in candidates: [PreparedCandidate],
        configuration: SimilarImageScanConfiguration,
        pairs: inout [PairKey: PairResult]
    ) throws {
        let sameSizeGroups = Dictionary(grouping: candidates, by: { $0.key.size })
            .values
            .filter { $0.count > 1 }

        for group in sameSizeGroups {
            try Task.checkCancellation()
            var digestGroups: [Data: [PreparedCandidate]] = [:]
            for candidate in group {
                do {
                    let digest = try exactHash(for: candidate)
                    digestGroups[digest, default: []].append(candidate)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // One unreadable image must not suppress results for the rest.
                    continue
                }
            }

            for duplicateGroup in digestGroups.values where duplicateGroup.count > 1 {
                for leftIndex in 0..<(duplicateGroup.count - 1) {
                    for rightIndex in (leftIndex + 1)..<duplicateGroup.count {
                        let lhs = duplicateGroup[leftIndex].candidate
                        let rhs = duplicateGroup[rightIndex].candidate
                        guard !isExcludedCompanionPair(lhs, rhs, configuration: configuration) else { continue }
                        pairs[PairKey(lhs.itemID, rhs.itemID)] = PairResult(
                            kind: .exact,
                            distance: 0
                        )
                    }
                }
            }
        }
    }

    private func findNearMatches(
        in candidates: [PreparedCandidate],
        configuration: SimilarImageScanConfiguration,
        pairs: inout [PairKey: PairResult]
    ) throws {
        var perceptualHashes: [FileKey: UInt64] = [:]
        for candidate in candidates {
            try Task.checkCancellation()
            if let hash = try? perceptualHash(for: candidate) {
                perceptualHashes[candidate.key] = hash
            }
        }

        for leftIndex in 0..<(candidates.count - 1) {
            if leftIndex.isMultiple(of: 32) { try Task.checkCancellation() }
            let lhs = candidates[leftIndex]
            guard let leftHash = perceptualHashes[lhs.key] else { continue }

            for rightIndex in (leftIndex + 1)..<candidates.count {
                let rhs = candidates[rightIndex]
                let pairKey = PairKey(lhs.candidate.itemID, rhs.candidate.itemID)
                guard pairs[pairKey]?.kind != .exact,
                      !isExcludedCompanionPair(
                        lhs.candidate,
                        rhs.candidate,
                        configuration: configuration
                      ),
                      let rightHash = perceptualHashes[rhs.key],
                      (leftHash ^ rightHash).nonzeroBitCount <= configuration.sensitivity.perceptualHashDistance
                else { continue }

                do {
                    let leftFeature = try featurePrint(for: lhs)
                    let rightFeature = try featurePrint(for: rhs)
                    var distance: Float = 0
                    try leftFeature.computeDistance(&distance, to: rightFeature)
                    if distance <= configuration.sensitivity.featureDistanceThreshold {
                        pairs[pairKey] = PairResult(kind: .similar, distance: distance)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
            }
        }
    }

    private func exactHash(for candidate: PreparedCandidate) throws -> Data {
        if let cached = exactHashCache[candidate.key] { return cached }
        try Task.checkCancellation()

        let url = candidate.candidate.analysisURL
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        let digest = Data(hasher.finalize())
        exactHashCache[candidate.key] = digest
        return digest
    }

    private func perceptualHash(for candidate: PreparedCandidate) throws -> UInt64 {
        if let cached = perceptualHashCache[candidate.key] { return cached }
        try Task.checkCancellation()

        let url = candidate.candidate.analysisURL
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 64
              ] as CFDictionary)
        else { throw SimilarImageDetectionError.cannotDecode(url) }

        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        let result: UInt64? = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: 9,
                height: 8,
                bitsPerComponent: 8,
                bytesPerRow: 9,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }

            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            let values = bytes.bindMemory(to: UInt8.self)
            var hash: UInt64 = 0
            var bit: UInt64 = 1
            for y in 0..<8 {
                for x in 0..<8 {
                    if values[y * 9 + x] > values[y * 9 + x + 1] { hash |= bit }
                    bit <<= 1
                }
            }
            return hash
        }

        guard let result else { throw SimilarImageDetectionError.cannotDecode(url) }
        perceptualHashCache[candidate.key] = result
        return result
    }

    private func featurePrint(for candidate: PreparedCandidate) throws -> VNFeaturePrintObservation {
        if let cached = featurePrintCache[candidate.key] { return cached }
        try Task.checkCancellation()

        let url = candidate.candidate.analysisURL
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(url: url, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first as? VNFeaturePrintObservation else {
            throw SimilarImageDetectionError.cannotCreateFeaturePrint(url)
        }
        featurePrintCache[candidate.key] = result
        return result
    }

    private func isExcludedCompanionPair(
        _ lhs: SimilarImageCandidate,
        _ rhs: SimilarImageCandidate,
        configuration: SimilarImageScanConfiguration
    ) -> Bool {
        guard configuration.excludesRAWJPEGCompanions else { return false }
        for leftURL in lhs.allURLs {
            for rightURL in rhs.allURLs {
                let sameDirectory = leftURL.deletingLastPathComponent().standardizedFileURL
                    == rightURL.deletingLastPathComponent().standardizedFileURL
                let sameBaseName = leftURL.deletingPathExtension().lastPathComponent
                    .precomposedStringWithCanonicalMapping.lowercased()
                    == rightURL.deletingPathExtension().lastPathComponent
                    .precomposedStringWithCanonicalMapping.lowercased()
                let isRAWJPEG = (FileKinds.isRAW(leftURL) && FileKinds.isJPEG(rightURL))
                    || (FileKinds.isJPEG(leftURL) && FileKinds.isRAW(rightURL))
                if sameDirectory && sameBaseName && isRAWJPEG { return true }
            }
        }
        return false
    }

    private func makeBidirectionalMatches(
        from pairs: [PairKey: PairResult]
    ) -> [UUID: [SimilarImageMatch]] {
        var result: [UUID: [SimilarImageMatch]] = [:]
        for (pair, value) in pairs {
            result[pair.first, default: []].append(SimilarImageMatch(
                otherItemID: pair.second,
                kind: value.kind,
                featureDistance: value.distance
            ))
            result[pair.second, default: []].append(SimilarImageMatch(
                otherItemID: pair.first,
                kind: value.kind,
                featureDistance: value.distance
            ))
        }

        for id in result.keys {
            result[id]?.sort {
                if $0.kind != $1.kind { return $0.kind == .exact }
                if $0.featureDistance != $1.featureDistance {
                    return ($0.featureDistance ?? 0) < ($1.featureDistance ?? 0)
                }
                return $0.otherItemID.uuidString < $1.otherItemID.uuidString
            }
        }
        return result
    }

    private func pruneCaches(keeping keys: Set<FileKey>) {
        guard exactHashCache.count > 2_000
                || perceptualHashCache.count > 2_000
                || featurePrintCache.count > 2_000
        else { return }
        exactHashCache = exactHashCache.filter { keys.contains($0.key) }
        perceptualHashCache = perceptualHashCache.filter { keys.contains($0.key) }
        featurePrintCache = featurePrintCache.filter { keys.contains($0.key) }
    }
}

private enum SimilarImageDetectionError: LocalizedError {
    case cannotDecode(URL)
    case cannotCreateFeaturePrint(URL)

    var errorDescription: String? {
        switch self {
        case .cannotDecode(let url):
            return "「\(url.lastPathComponent)」の画像を読み取れませんでした。"
        case .cannotCreateFeaturePrint(let url):
            return "「\(url.lastPathComponent)」の画像特徴を作成できませんでした。"
        }
    }
}
