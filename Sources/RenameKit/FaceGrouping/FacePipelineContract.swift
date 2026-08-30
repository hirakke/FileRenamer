import Foundation

/// Complete identity of the process that produces a face embedding.
///
/// Two descriptors are comparable only when every field matches. This prevents
/// a model update, preprocessing change, or alignment change from silently
/// reusing incompatible saved data.
public struct FacePipelineContract: Hashable, Codable, Sendable {
    public let embeddingModel: FaceEmbeddingModel
    public let preprocessingVersion: Int
    public let alignmentVersion: Int
    public let distanceMetricVersion: Int

    public init(
        embeddingModel: FaceEmbeddingModel,
        preprocessingVersion: Int,
        alignmentVersion: Int,
        distanceMetricVersion: Int
    ) {
        self.embeddingModel = embeddingModel
        self.preprocessingVersion = preprocessingVersion
        self.alignmentVersion = alignmentVersion
        self.distanceMetricVersion = distanceMetricVersion
    }

    /// Contract used by profiles written before full pipeline versioning.
    public static func legacyEyeAlignment(
        embeddingModel: FaceEmbeddingModel
    ) -> FacePipelineContract {
        FacePipelineContract(
            embeddingModel: embeddingModel,
            preprocessingVersion: 1,
            alignmentVersion: 1,
            distanceMetricVersion: 1
        )
    }
}
