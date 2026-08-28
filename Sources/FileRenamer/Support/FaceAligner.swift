import CoreGraphics
import Foundation
import RenameKit
import Vision

enum FaceAlignmentMethod: String, Hashable, Sendable {
    case eyes
    case paddedCrop
}

struct AlignedFaceImage {
    let image: CGImage
    let method: FaceAlignmentMethod
}

enum FaceAligner {
    static let targetSize = 112

    static func align(
        image: CGImage,
        observation: VNFaceObservation
    ) -> AlignedFaceImage? {
        if let eyes = eyeCenters(observation: observation, image: image),
           let plan = try? FaceGeometry.eyeAlignment(
               leftEye: eyes.left,
               rightEye: eyes.right,
               targetSize: CGFloat(targetSize)
           ),
           let aligned = render(image: image, alignment: plan) {
            return AlignedFaceImage(image: aligned, method: .eyes)
        }

        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let faceRect = FaceGeometry.imageRect(
            normalizedVisionRect: observation.boundingBox,
            imageSize: imageBounds.size
        )
        let crop = FaceGeometry.fallbackCrop(
            faceRect: faceRect,
            imageBounds: imageBounds,
            scale: 1.6
        )
        guard !crop.isNull,
              let cropped = image.cropping(to: crop),
              let resized = resize(cropped, width: targetSize, height: targetSize)
        else { return nil }
        return AlignedFaceImage(image: resized, method: .paddedCrop)
    }

    private static func eyeCenters(
        observation: VNFaceObservation,
        image: CGImage
    ) -> (left: CGPoint, right: CGPoint)? {
        guard let leftRegion = observation.landmarks?.leftEye,
              let rightRegion = observation.landmarks?.rightEye,
              leftRegion.pointCount > 0,
              rightRegion.pointCount > 0
        else { return nil }

        let faceRect = FaceGeometry.imageRect(
            normalizedVisionRect: observation.boundingBox,
            imageSize: CGSize(width: image.width, height: image.height)
        )
        let first = center(of: leftRegion, in: faceRect)
        let second = center(of: rightRegion, in: faceRect)
        guard first.x != second.x || first.y != second.y else { return nil }
        return first.x <= second.x ? (first, second) : (second, first)
    }

    private static func center(
        of region: VNFaceLandmarkRegion2D,
        in faceRect: CGRect
    ) -> CGPoint {
        let points = region.normalizedPoints
        var sum = CGPoint.zero
        for index in 0..<region.pointCount {
            sum.x += faceRect.minX + points[index].x * faceRect.width
            sum.y += faceRect.maxY - points[index].y * faceRect.height
        }
        return CGPoint(
            x: sum.x / CGFloat(region.pointCount),
            y: sum.y / CGFloat(region.pointCount)
        )
    }

    private static func render(
        image: CGImage,
        alignment: FaceEyeAlignment
    ) -> CGImage? {
        guard let context = makeContext(width: targetSize, height: targetSize) else {
            return nil
        }
        prepareTopLeftCoordinates(context, height: targetSize)

        let cosine = cos(alignment.rotationRadians) * alignment.scale
        let sine = sin(alignment.rotationRadians) * alignment.scale
        let transform = CGAffineTransform(
            a: cosine,
            b: sine,
            c: -sine,
            d: cosine,
            tx: alignment.targetEyeMidpoint.x
                - cosine * alignment.sourceEyeMidpoint.x
                + sine * alignment.sourceEyeMidpoint.y,
            ty: alignment.targetEyeMidpoint.y
                - sine * alignment.sourceEyeMidpoint.x
                - cosine * alignment.sourceEyeMidpoint.y
        )
        context.concatenate(transform)
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return context.makeImage()
    }

    private static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = makeContext(width: width, height: height) else { return nil }
        prepareTopLeftCoordinates(context, height: height)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func prepareTopLeftCoordinates(_ context: CGContext, height: Int) {
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
    }
}
