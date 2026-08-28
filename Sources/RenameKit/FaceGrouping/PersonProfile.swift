import Foundation
import SwiftData

@Model
public final class PersonProfile {
    @Attribute(.unique) public var id: UUID
    public var displayName: String
    public var embeddingData: Data
    public var embeddingModelIdentifier: String
    public var embeddingModelVersion: String
    public var embeddingDimension: Int
    public var sampleCount: Int
    public var createdAt: Date
    public var updatedAt: Date

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
        self.sampleCount = sampleCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func snapshot() throws -> PersonProfileSnapshot {
        let model = FaceEmbeddingModel(
            identifier: embeddingModelIdentifier,
            version: embeddingModelVersion,
            dimension: embeddingDimension
        )
        let embedding = try FaceEmbedding(
            model: model,
            values: try FaceEmbeddingBinaryCodec.decode(
                embeddingData,
                expectedCount: embeddingDimension
            )
        )
        return PersonProfileSnapshot(
            id: id,
            displayName: displayName,
            embedding: embedding,
            sampleCount: sampleCount,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public struct PersonProfileSnapshot: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let displayName: String
    public let embedding: FaceEmbedding
    public let sampleCount: Int
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        displayName: String,
        embedding: FaceEmbedding,
        sampleCount: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.embedding = embedding
        self.sampleCount = sampleCount
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
