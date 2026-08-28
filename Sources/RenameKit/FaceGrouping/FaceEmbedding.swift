import Foundation

public struct FaceEmbeddingModel: Hashable, Codable, Sendable {
    public let identifier: String
    public let version: String
    public let dimension: Int

    public init(identifier: String, version: String, dimension: Int) {
        self.identifier = identifier
        self.version = version
        self.dimension = dimension
    }
}

public enum FaceEmbeddingError: Error, Equatable, Sendable {
    case emptyCollection
    case invalidModelDimension(Int)
    case dimensionMismatch(expected: Int, actual: Int)
    case nonFiniteValue
    case zeroMagnitude
    case incompatibleModels(FaceEmbeddingModel, FaceEmbeddingModel)
}

/// An immutable, L2-normalised face descriptor tied to one exact model contract.
///
/// Model identity is part of the value so descriptors from different model releases
/// can never be compared accidentally after a future model update.
public struct FaceEmbedding: Hashable, Sendable {
    public let model: FaceEmbeddingModel
    public let values: [Float]

    public init(model: FaceEmbeddingModel, values: [Float]) throws {
        guard model.dimension > 0 else {
            throw FaceEmbeddingError.invalidModelDimension(model.dimension)
        }
        guard values.count == model.dimension else {
            throw FaceEmbeddingError.dimensionMismatch(
                expected: model.dimension,
                actual: values.count
            )
        }
        guard values.allSatisfy(\.isFinite) else {
            throw FaceEmbeddingError.nonFiniteValue
        }

        let squaredMagnitude = values.reduce(into: Double.zero) { partial, value in
            partial += Double(value) * Double(value)
        }
        guard squaredMagnitude.isFinite, squaredMagnitude > Double.ulpOfOne else {
            throw FaceEmbeddingError.zeroMagnitude
        }

        let magnitude = squaredMagnitude.squareRoot()
        self.model = model
        self.values = values.map { Float(Double($0) / magnitude) }
    }

    /// Cosine distance for unit vectors: 0 is identical, 1 orthogonal, 2 opposite.
    public func cosineDistance(to other: FaceEmbedding) throws -> Float {
        guard model == other.model else {
            throw FaceEmbeddingError.incompatibleModels(model, other.model)
        }

        let dot = zip(values, other.values).reduce(into: Double.zero) { partial, pair in
            partial += Double(pair.0) * Double(pair.1)
        }
        guard dot.isFinite else { throw FaceEmbeddingError.nonFiniteValue }
        return Float(1 - min(1, max(-1, dot)))
    }

    public static func centroid(of embeddings: [FaceEmbedding]) throws -> FaceEmbedding {
        guard let first = embeddings.first else {
            throw FaceEmbeddingError.emptyCollection
        }
        guard embeddings.allSatisfy({ $0.model == first.model }) else {
            let incompatible = embeddings.first(where: { $0.model != first.model })!
            throw FaceEmbeddingError.incompatibleModels(first.model, incompatible.model)
        }

        var sums = [Double](repeating: 0, count: first.model.dimension)
        for embedding in embeddings {
            for index in sums.indices {
                sums[index] += Double(embedding.values[index])
            }
        }
        let divisor = Double(embeddings.count)
        return try FaceEmbedding(
            model: first.model,
            values: sums.map { Float($0 / divisor) }
        )
    }
}

public struct FaceDescriptorID: Hashable, Codable, Sendable {
    public let itemID: UUID
    public let faceIndex: Int

    public init(itemID: UUID, faceIndex: Int) {
        self.itemID = itemID
        self.faceIndex = faceIndex
    }
}

/// Canonical unordered pair used by the precomputed pair-distance table.
public struct FaceDescriptorPair: Hashable, Sendable {
    public let first: FaceDescriptorID
    public let second: FaceDescriptorID

    public init(_ lhs: FaceDescriptorID, _ rhs: FaceDescriptorID) {
        if Self.precedes(lhs, rhs) {
            first = lhs
            second = rhs
        } else {
            first = rhs
            second = lhs
        }
    }

    private static func precedes(_ lhs: FaceDescriptorID, _ rhs: FaceDescriptorID) -> Bool {
        let leftUUID = lhs.itemID.uuidString
        let rightUUID = rhs.itemID.uuidString
        return leftUUID == rightUUID ? lhs.faceIndex <= rhs.faceIndex : leftUUID < rightUUID
    }
}
