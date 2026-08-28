import CoreGraphics
import CoreML
import Foundation
import RenameKit

enum MobileFaceNetError: LocalizedError {
    case modelNotFound
    case cannotCreatePixels
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "人物候補モデルを読み込めませんでした。"
        case .cannotCreatePixels:
            return "顔画像を人物候補モデルの入力へ変換できませんでした。"
        case .missingOutput:
            return "人物候補モデルから特徴量を取得できませんでした。"
        }
    }
}

final class MobileFaceNetEmbedder {
    static let modelContract = FaceEmbeddingModel(
        identifier: "qualcomm.mobilefacenet",
        version: "0.61.0",
        dimension: 128
    )

    private let model: MLModel

    init() throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(
            contentsOf: try Self.modelURL(),
            configuration: configuration
        )
    }

    func embedding(for image: CGImage) throws -> FaceEmbedding {
        let input = try makeInput(image)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["input": input])
        let prediction = try model.prediction(from: provider)
        guard let output = prediction.featureValue(for: "embedding")?.multiArrayValue,
              output.count == Self.modelContract.dimension
        else { throw MobileFaceNetError.missingOutput }

        let values = (0..<output.count).map { output[$0].floatValue }
        return try FaceEmbedding(model: Self.modelContract, values: values)
    }

    private func makeInput(_ image: CGImage) throws -> MLMultiArray {
        let side = FaceAligner.targetSize
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)
                    ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { throw MobileFaceNetError.cannotCreatePixels }

        let input = try MLMultiArray(
            shape: [1, 3, NSNumber(value: side), NSNumber(value: side)],
            dataType: .float32
        )
        for y in 0..<side {
            for x in 0..<side {
                let pixel = (y * side + x) * 4
                for channel in 0..<3 {
                    input[[0, channel, y, x] as [NSNumber]] = NSNumber(
                        value: Float(pixels[pixel + channel]) / 255
                    )
                }
            }
        }
        return input
    }

    private static func modelURL() throws -> URL {
        var bundles = [Bundle.main]
#if SWIFT_PACKAGE
        bundles.insert(Bundle.module, at: 0)
#endif
        for bundle in bundles {
            if let compiled = bundle.url(
                forResource: "MobileFaceNet",
                withExtension: "mlmodelc"
            ) {
                return compiled
            }
            if let package = bundle.url(
                forResource: "MobileFaceNet",
                withExtension: "mlpackage",
                subdirectory: "Models"
            ) {
                return try MLModel.compileModel(at: package)
            }
        }
        throw MobileFaceNetError.modelNotFound
    }
}
