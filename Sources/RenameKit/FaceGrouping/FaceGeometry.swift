import Foundation

public enum FaceGeometryError: Error, Equatable, Sendable {
    case invalidImageSize
    case invalidTargetSize
    case coincidentEyes
}

public struct FaceEyeAlignment: Equatable, Sendable {
    public let sourceEyeMidpoint: CGPoint
    public let targetEyeMidpoint: CGPoint
    public let rotationRadians: CGFloat
    public let scale: CGFloat

    public init(
        sourceEyeMidpoint: CGPoint,
        targetEyeMidpoint: CGPoint,
        rotationRadians: CGFloat,
        scale: CGFloat
    ) {
        self.sourceEyeMidpoint = sourceEyeMidpoint
        self.targetEyeMidpoint = targetEyeMidpoint
        self.rotationRadians = rotationRadians
        self.scale = scale
    }
}

/// Pure geometry shared by Vision-facing code and the dependency-free safety suite.
///
/// The input image is expected to have already had its EXIF orientation applied.
/// Vision's normalized lower-left coordinates are converted to the image's
/// upper-left pixel coordinates exactly once at this boundary.
public enum FaceGeometry {
    public static func imageRect(
        normalizedVisionRect: CGRect,
        imageSize: CGSize
    ) -> CGRect {
        CGRect(
            x: normalizedVisionRect.minX * imageSize.width,
            y: (1 - normalizedVisionRect.maxY) * imageSize.height,
            width: normalizedVisionRect.width * imageSize.width,
            height: normalizedVisionRect.height * imageSize.height
        )
    }

    public static func isLargeEnough(
        faceRect: CGRect,
        minimumSide: CGFloat
    ) -> Bool {
        minimumSide > 0
            && faceRect.width.isFinite
            && faceRect.height.isFinite
            && min(faceRect.width, faceRect.height) >= minimumSide
    }

    /// Returns the largest requested square that can fit inside the image and
    /// shifts it at the edges instead of shrinking one side independently.
    public static func fallbackCrop(
        faceRect: CGRect,
        imageBounds: CGRect,
        scale: CGFloat
    ) -> CGRect {
        guard !faceRect.isNull,
              !faceRect.isInfinite,
              !imageBounds.isNull,
              !imageBounds.isInfinite,
              imageBounds.width > 0,
              imageBounds.height > 0
        else { return .null }

        let requestedSide = max(faceRect.width, faceRect.height) * max(1, scale)
        let side = min(requestedSide, imageBounds.width, imageBounds.height)
        let center = CGPoint(x: faceRect.midX, y: faceRect.midY)
        let minimumX = imageBounds.minX
        let maximumX = imageBounds.maxX - side
        let minimumY = imageBounds.minY
        let maximumY = imageBounds.maxY - side
        let originX = min(max(center.x - side / 2, minimumX), maximumX)
        let originY = min(max(center.y - side / 2, minimumY), maximumY)
        return CGRect(x: originX, y: originY, width: side, height: side).integral
    }

    /// Produces the transform parameters that place eyes at 35% and 65% of the
    /// target width and 38% of its height. Rotation is the angle to apply to the
    /// upper-left-coordinate source image, hence the negative source eye angle.
    public static func eyeAlignment(
        leftEye: CGPoint,
        rightEye: CGPoint,
        targetSize: CGFloat
    ) throws -> FaceEyeAlignment {
        guard targetSize.isFinite, targetSize > 0 else {
            throw FaceGeometryError.invalidTargetSize
        }
        let deltaX = rightEye.x - leftEye.x
        let deltaY = rightEye.y - leftEye.y
        let distance = hypot(deltaX, deltaY)
        guard distance.isFinite, distance > CGFloat.ulpOfOne else {
            throw FaceGeometryError.coincidentEyes
        }

        return FaceEyeAlignment(
            sourceEyeMidpoint: CGPoint(
                x: (leftEye.x + rightEye.x) / 2,
                y: (leftEye.y + rightEye.y) / 2
            ),
            targetEyeMidpoint: CGPoint(x: targetSize * 0.5, y: targetSize * 0.38),
            rotationRadians: -atan2(deltaY, deltaX),
            scale: targetSize * 0.30 / distance
        )
    }
}
