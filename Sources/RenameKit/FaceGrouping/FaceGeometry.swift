import Foundation

public enum FaceGeometryError: Error, Equatable, Sendable {
    case invalidImageSize
    case invalidTargetSize
    case coincidentEyes
    case invalidLandmarks
    case degenerateLandmarks
}

public struct FaceFivePointLandmarks: Equatable, Sendable {
    public let leftEye: CGPoint
    public let rightEye: CGPoint
    public let nose: CGPoint
    public let leftMouth: CGPoint
    public let rightMouth: CGPoint

    public init(
        leftEye: CGPoint,
        rightEye: CGPoint,
        nose: CGPoint,
        leftMouth: CGPoint,
        rightMouth: CGPoint
    ) {
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.nose = nose
        self.leftMouth = leftMouth
        self.rightMouth = rightMouth
    }

    public var points: [CGPoint] {
        [leftEye, rightEye, nose, leftMouth, rightMouth]
    }
}

public struct FaceSimilarityTransform: Equatable, Sendable {
    public let affineTransform: CGAffineTransform

    public init(affineTransform: CGAffineTransform) {
        self.affineTransform = affineTransform
    }
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
    public static func mobileFaceNetReferenceLandmarks(
        targetSize: CGFloat
    ) throws -> FaceFivePointLandmarks {
        guard targetSize.isFinite, targetSize > 0 else {
            throw FaceGeometryError.invalidTargetSize
        }
        let scale = targetSize / 112
        return FaceFivePointLandmarks(
            leftEye: CGPoint(x: 44.1964 * scale, y: 53.1309 * scale),
            rightEye: CGPoint(x: 67.6879 * scale, y: 53.0009 * scale),
            nose: CGPoint(x: 56.0168 * scale, y: 66.4911 * scale),
            leftMouth: CGPoint(x: 46.3662 * scale, y: 80.2437 * scale),
            rightMouth: CGPoint(x: 65.8199 * scale, y: 80.1361 * scale)
        )
    }

    public static func similarityTransform(
        from source: FaceFivePointLandmarks,
        to target: FaceFivePointLandmarks
    ) throws -> FaceSimilarityTransform {
        guard landmarksAreValid(source), landmarksAreValid(target) else {
            throw FaceGeometryError.invalidLandmarks
        }

        let sourceCenter = centroid(of: source.points)
        let targetCenter = centroid(of: target.points)
        let centeredSource = source.points.map {
            CGPoint(x: $0.x - sourceCenter.x, y: $0.y - sourceCenter.y)
        }
        let centeredTarget = target.points.map {
            CGPoint(x: $0.x - targetCenter.x, y: $0.y - targetCenter.y)
        }
        let denominator = centeredSource.reduce(CGFloat.zero) {
            $0 + $1.x * $1.x + $1.y * $1.y
        }
        guard denominator.isFinite, denominator > CGFloat.ulpOfOne else {
            throw FaceGeometryError.degenerateLandmarks
        }

        let a = zip(centeredSource, centeredTarget).reduce(CGFloat.zero) {
            $0 + $1.0.x * $1.1.x + $1.0.y * $1.1.y
        } / denominator
        let b = zip(centeredSource, centeredTarget).reduce(CGFloat.zero) {
            $0 + $1.0.x * $1.1.y - $1.0.y * $1.1.x
        } / denominator
        guard a.isFinite, b.isFinite else {
            throw FaceGeometryError.degenerateLandmarks
        }

        let tx = targetCenter.x - a * sourceCenter.x + b * sourceCenter.y
        let ty = targetCenter.y - b * sourceCenter.x - a * sourceCenter.y
        let transform = CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
        guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
            .allSatisfy(\.isFinite)
        else { throw FaceGeometryError.degenerateLandmarks }
        return FaceSimilarityTransform(affineTransform: transform)
    }

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

    private static func landmarksAreValid(_ landmarks: FaceFivePointLandmarks) -> Bool {
        landmarks.points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
            && landmarks.leftEye.x < landmarks.rightEye.x
            && landmarks.leftMouth.x < landmarks.rightMouth.x
    }

    private static func centroid(of points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(into: CGPoint.zero) { partial, point in
            partial.x += point.x
            partial.y += point.y
        }
        let count = CGFloat(points.count)
        return CGPoint(x: sum.x / count, y: sum.y / count)
    }
}
