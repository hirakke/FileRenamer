import Foundation
import SwiftData

public enum PersonEmbeddingKind: String, Codable, Hashable, Sendable {
    case positive
    case rejection
}

public struct PersonEmbeddingSample: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let embedding: FaceEmbedding
    public let captureQuality: Float?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        embedding: FaceEmbedding,
        captureQuality: Float?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.embedding = embedding
        self.captureQuality = captureQuality
        self.createdAt = createdAt
    }
}

@Model
public final class PersonEmbeddingRecord {
    @Attribute(.unique) public var id: UUID
    public var kindRawValue: String
    public var embeddingData: Data
    public var embeddingModelIdentifier: String
    public var embeddingModelVersion: String
    public var embeddingDimension: Int
    public var preprocessingVersion: Int
    public var alignmentVersion: Int
    public var distanceMetricVersion: Int
    public var captureQuality: Float?
    public var createdAt: Date

    public init(kind: PersonEmbeddingKind, sample: PersonEmbeddingSample) {
        id = sample.id
        kindRawValue = kind.rawValue
        embeddingData = FaceEmbeddingBinaryCodec.encode(sample.embedding.values)
        embeddingModelIdentifier = sample.embedding.model.identifier
        embeddingModelVersion = sample.embedding.model.version
        embeddingDimension = sample.embedding.model.dimension
        preprocessingVersion = sample.embedding.contract.preprocessingVersion
        alignmentVersion = sample.embedding.contract.alignmentVersion
        distanceMetricVersion = sample.embedding.contract.distanceMetricVersion
        captureQuality = sample.captureQuality
        createdAt = sample.createdAt
    }

    public func sample() throws -> PersonEmbeddingSample {
        let contract = FacePipelineContract(
            embeddingModel: FaceEmbeddingModel(
                identifier: embeddingModelIdentifier,
                version: embeddingModelVersion,
                dimension: embeddingDimension
            ),
            preprocessingVersion: preprocessingVersion,
            alignmentVersion: alignmentVersion,
            distanceMetricVersion: distanceMetricVersion
        )
        return PersonEmbeddingSample(
            id: id,
            embedding: try FaceEmbedding(
                contract: contract,
                values: try FaceEmbeddingBinaryCodec.decode(
                    embeddingData,
                    expectedCount: embeddingDimension
                )
            ),
            captureQuality: captureQuality,
            createdAt: createdAt
        )
    }
}

@Model
public final class PersonProfile {
    @Attribute(.unique) public var id: UUID
    public var displayName: String

    // These required centroid columns remain solely for lightweight migration.
    // V2 matching reads explicit positive records and never reads these columns.
    public var embeddingData: Data
    public var embeddingModelIdentifier: String
    public var embeddingModelVersion: String
    public var embeddingDimension: Int
    public var embeddingPreprocessingVersion: Int = 1
    public var embeddingAlignmentVersion: Int = 1
    public var embeddingDistanceMetricVersion: Int = 1
    public var sampleCount: Int

    public var schemaVersion: Int = 1
    @Relationship(deleteRule: .cascade)
    public var positiveRecords: [PersonEmbeddingRecord] = []
    @Relationship(deleteRule: .cascade)
    public var rejectionRecords: [PersonEmbeddingRecord] = []
    public var createdAt: Date
    public var updatedAt: Date

    /// Creates a legacy-layout row. PersonStore upgrades new profiles to schema 2
    /// and attaches explicit records before its single atomic save.
    public init(
        id: UUID = UUID(),
        displayName: String,
        embedding: FaceEmbedding,
        sampleCount: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        embeddingData = FaceEmbeddingBinaryCodec.encode(embedding.values)
        embeddingModelIdentifier = embedding.model.identifier
        embeddingModelVersion = embedding.model.version
        embeddingDimension = embedding.model.dimension
        embeddingPreprocessingVersion = embedding.contract.preprocessingVersion
        embeddingAlignmentVersion = embedding.contract.alignmentVersion
        embeddingDistanceMetricVersion = embedding.contract.distanceMetricVersion
        self.sampleCount = sampleCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func snapshot() throws -> PersonProfileSnapshot {
        let positives = try positiveRecords
            .map { try $0.sample() }
            .sorted(by: FacePrototypeSelector.stableOrder)
        let rejections = try rejectionRecords
            .map { try $0.sample() }
            .sorted(by: FacePrototypeSelector.stableOrder)
        return PersonProfileSnapshot(
            id: id,
            displayName: displayName,
            positives: positives,
            rejections: rejections,
            isLegacyOnly: positives.isEmpty,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func legacyEmbedding() throws -> FaceEmbedding {
        let contract = FacePipelineContract(
            embeddingModel: FaceEmbeddingModel(
                identifier: embeddingModelIdentifier,
                version: embeddingModelVersion,
                dimension: embeddingDimension
            ),
            preprocessingVersion: embeddingPreprocessingVersion,
            alignmentVersion: embeddingAlignmentVersion,
            distanceMetricVersion: embeddingDistanceMetricVersion
        )
        return try FaceEmbedding(
            contract: contract,
            values: try FaceEmbeddingBinaryCodec.decode(
                embeddingData,
                expectedCount: embeddingDimension
            )
        )
    }

    func copyLegacyColumns(from embedding: FaceEmbedding, sampleCount: Int) {
        embeddingData = FaceEmbeddingBinaryCodec.encode(embedding.values)
        embeddingModelIdentifier = embedding.model.identifier
        embeddingModelVersion = embedding.model.version
        embeddingDimension = embedding.model.dimension
        embeddingPreprocessingVersion = embedding.contract.preprocessingVersion
        embeddingAlignmentVersion = embedding.contract.alignmentVersion
        embeddingDistanceMetricVersion = embedding.contract.distanceMetricVersion
        self.sampleCount = sampleCount
    }
}

public struct PersonProfileSnapshot: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let displayName: String
    public let positives: [PersonEmbeddingSample]
    public let rejections: [PersonEmbeddingSample]
    public let isLegacyOnly: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        displayName: String,
        positives: [PersonEmbeddingSample],
        rejections: [PersonEmbeddingSample],
        isLegacyOnly: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.positives = positives
        self.rejections = rejections
        self.isLegacyOnly = isLegacyOnly
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PersonMatch: Equatable, Sendable {
    public let person: PersonProfileSnapshot
    public let distance: Float

    public init(person: PersonProfileSnapshot, distance: Float) {
        self.person = person
        self.distance = distance
    }
}

enum FaceEmbeddingBinaryCodec {
    static func encode(_ values: [Float]) -> Data {
        var result = Data(capacity: values.count * MemoryLayout<UInt32>.size)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) }
        }
        return result
    }

    static func decode(_ data: Data, expectedCount: Int) throws -> [Float] {
        let stride = MemoryLayout<UInt32>.size
        guard expectedCount > 0, data.count == expectedCount * stride else {
            throw FaceEmbeddingError.dimensionMismatch(
                expected: max(0, expectedCount),
                actual: data.count / stride
            )
        }

        return try data.withUnsafeBytes { rawBuffer -> [Float] in
            guard rawBuffer.count == data.count else {
                throw FaceEmbeddingError.dimensionMismatch(
                    expected: expectedCount,
                    actual: rawBuffer.count / stride
                )
            }
            return (0..<expectedCount).map { index in
                let stored = rawBuffer.loadUnaligned(
                    fromByteOffset: index * stride,
                    as: UInt32.self
                )
                return Float(bitPattern: UInt32(littleEndian: stored))
            }
        }
    }
}
