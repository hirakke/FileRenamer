import CoreGraphics
import CoreImage
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
        // Core Image uses a lower-left origin. `FaceGeometry` deliberately exposes
        // upper-left image coordinates to the rest of the app, so convert both
        // midpoints once here and build the affine transform in Core Image's
        // native coordinate system. Mixing a flipped CGContext with the alignment
        // transform caused the source image to be translated outside the 112 px
        // destination for portrait images.
        let sourceMidpoint = CGPoint(
            x: alignment.sourceEyeMidpoint.x,
            y: CGFloat(image.height) - alignment.sourceEyeMidpoint.y
        )
        let targetMidpoint = CGPoint(
            x: alignment.targetEyeMidpoint.x,
            y: CGFloat(targetSize) - alignment.targetEyeMidpoint.y
        )
        let rotation = -alignment.rotationRadians
        let cosine = cos(rotation) * alignment.scale
        let sine = sin(rotation) * alignment.scale
        let transform = CGAffineTransform(
            a: cosine,
            b: sine,
            c: -sine,
            d: cosine,
            tx: targetMidpoint.x
                - cosine * sourceMidpoint.x
                + sine * sourceMidpoint.y,
            ty: targetMidpoint.y
                - sine * sourceMidpoint.x
                - cosine * sourceMidpoint.y
        )
        let transformed = CIImage(cgImage: image).transformed(by: transform)
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(
            transformed,
            from: CGRect(x: 0, y: 0, width: targetSize, height: targetSize),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
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
