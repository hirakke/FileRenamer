import CoreGraphics
import CoreImage
import Foundation
import RenameKit
import Vision

enum FaceAlignmentMethod: String, Hashable, Sendable {
    case fivePoint
    case eyes
    case paddedCrop
}

struct AlignedFaceImage {
    let image: CGImage
    let method: FaceAlignmentMethod
}

enum FaceAligner {
    static let targetSize = 112
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func align(
        image: CGImage,
        observation: VNFaceObservation
    ) -> AlignedFaceImage? {
        if let landmarks = fivePointLandmarks(observation: observation, image: image),
           let reference = try? FaceGeometry.mobileFaceNetReferenceLandmarks(
               targetSize: CGFloat(targetSize)
           ),
           let transform = try? FaceGeometry.similarityTransform(
               from: landmarks,
               to: reference
           ),
           let aligned = render(image: image, similarity: transform) {
            return AlignedFaceImage(image: aligned, method: .fivePoint)
        }

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

    private static func fivePointLandmarks(
        observation: VNFaceObservation,
        image: CGImage
    ) -> FaceFivePointLandmarks? {
        guard let faceLandmarks = observation.landmarks,
              let leftEyeRegion = faceLandmarks.leftEye,
              let rightEyeRegion = faceLandmarks.rightEye,
              let noseRegion = faceLandmarks.nose,
              let outerLipsRegion = faceLandmarks.outerLips,
              leftEyeRegion.pointCount > 0,
              rightEyeRegion.pointCount > 0,
              noseRegion.pointCount > 0,
              outerLipsRegion.pointCount >= 2
        else { return nil }

        let faceRect = FaceGeometry.imageRect(
            normalizedVisionRect: observation.boundingBox,
            imageSize: CGSize(width: image.width, height: image.height)
        )
        let eyes = [
            center(of: leftEyeRegion, in: faceRect),
            center(of: rightEyeRegion, in: faceRect)
        ].sorted { $0.x < $1.x }
        let nose = medianCenter(of: noseRegion, in: faceRect)
        let lipPoints = points(of: outerLipsRegion, in: faceRect).sorted { $0.x < $1.x }
        guard let leftMouth = lipPoints.first,
              let rightMouth = lipPoints.last
        else { return nil }

        return FaceFivePointLandmarks(
            leftEye: eyes[0],
            rightEye: eyes[1],
            nose: nose,
            leftMouth: leftMouth,
            rightMouth: rightMouth
        )
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
        let mappedPoints = points(of: region, in: faceRect)
        var sum = CGPoint.zero
        for point in mappedPoints {
            sum.x += point.x
            sum.y += point.y
        }
        return CGPoint(
            x: sum.x / CGFloat(mappedPoints.count),
            y: sum.y / CGFloat(mappedPoints.count)
        )
    }

    private static func medianCenter(
        of region: VNFaceLandmarkRegion2D,
        in faceRect: CGRect
    ) -> CGPoint {
        let mappedPoints = points(of: region, in: faceRect)
        let sortedX = mappedPoints.map(\.x).sorted()
        let sortedY = mappedPoints.map(\.y).sorted()
        let middle = mappedPoints.count / 2
        if mappedPoints.count.isMultiple(of: 2) {
            return CGPoint(
                x: (sortedX[middle - 1] + sortedX[middle]) / 2,
                y: (sortedY[middle - 1] + sortedY[middle]) / 2
            )
        }
        return CGPoint(x: sortedX[middle], y: sortedY[middle])
    }

    private static func points(
        of region: VNFaceLandmarkRegion2D,
        in faceRect: CGRect
    ) -> [CGPoint] {
        let normalized = region.normalizedPoints
        return (0..<region.pointCount).map { index in
            CGPoint(
                x: faceRect.minX + normalized[index].x * faceRect.width,
                y: faceRect.maxY - normalized[index].y * faceRect.height
            )
        }
    }

    private static func render(
        image: CGImage,
        similarity: FaceSimilarityTransform
    ) -> CGImage? {
        let upper = similarity.affineTransform
        let sourceHeight = CGFloat(image.height)
        let outputHeight = CGFloat(targetSize)
        let coreImageTransform = CGAffineTransform(
            a: upper.a,
            b: -upper.b,
            c: -upper.c,
            d: upper.d,
            tx: upper.tx + upper.c * sourceHeight,
            ty: outputHeight - upper.d * sourceHeight - upper.ty
        )
        let transformed = CIImage(cgImage: image).transformed(by: coreImageTransform)
        return ciContext.createCGImage(
            transformed,
            from: CGRect(x: 0, y: 0, width: targetSize, height: targetSize),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
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
        return ciContext.createCGImage(
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
