import Foundation
import RenameKit
import SwiftData

@MainActor
func runFaceGroupingTests() async {
    let runner = TestRunner.shared
    let model = FaceEmbeddingModel(
        identifier: "qualcomm.mobilefacenet",
        version: "0.61.0",
        dimension: 2
    )
    let contract = FacePipelineContract(
        embeddingModel: model,
        preprocessingVersion: 1,
        alignmentVersion: 2,
        distanceMetricVersion: 1
    )

    runner.suite("FaceEmbedding — 正規化と距離")

    await runner.test("埋め込みをL2正規化する") {
        let embedding = try FaceEmbedding(contract: contract, values: [3, 4])
        try expectEqual(embedding.values.count, 2)
        try expect(abs(embedding.values[0] - 0.6) < 0.000_01)
        try expect(abs(embedding.values[1] - 0.8) < 0.000_01)
    }

    await runner.test("ゼロベクトルと非有限値を拒否する") {
        try await expectThrows {
            _ = try FaceEmbedding(contract: contract, values: [0, 0])
        }
        try await expectThrows {
            _ = try FaceEmbedding(contract: contract, values: [.nan, 1])
        }
    }

    await runner.test("モデルの次元と異なる入力を拒否する") {
        try await expectThrows {
            _ = try FaceEmbedding(contract: contract, values: [1, 0, 0])
        }
    }

    await runner.test("cosine距離を0から2で計算する") {
        let x = try FaceEmbedding(contract: contract, values: [1, 0])
        let same = try FaceEmbedding(contract: contract, values: [2, 0])
        let orthogonal = try FaceEmbedding(contract: contract, values: [0, 1])
        let opposite = try FaceEmbedding(contract: contract, values: [-1, 0])

        try expect(abs(try x.cosineDistance(to: same) - 0) < 0.000_01)
        try expect(abs(try x.cosineDistance(to: orthogonal) - 1) < 0.000_01)
        try expect(abs(try x.cosineDistance(to: opposite) - 2) < 0.000_01)
    }

    await runner.test("モデルID・版・次元が異なる埋め込みを比較しない") {
        let reference = try FaceEmbedding(contract: contract, values: [1, 0])
        let anotherVersion = try FaceEmbedding(
            contract: FacePipelineContract(
                embeddingModel: FaceEmbeddingModel(
                    identifier: model.identifier,
                    version: "0.62.0",
                    dimension: 2
                ),
                preprocessingVersion: contract.preprocessingVersion,
                alignmentVersion: contract.alignmentVersion,
                distanceMetricVersion: contract.distanceMetricVersion
            ),
            values: [1, 0]
        )
        try await expectThrows {
            _ = try reference.cosineDistance(to: anotherVersion)
        }
    }

    await runner.test("同じモデルでも整列版が異なる埋め込みを比較しない") {
        let current = FacePipelineContract(
            embeddingModel: model,
            preprocessingVersion: 1,
            alignmentVersion: 2,
            distanceMetricVersion: 1
        )
        let oldAlignment = FacePipelineContract(
            embeddingModel: model,
            preprocessingVersion: 1,
            alignmentVersion: 1,
            distanceMetricVersion: 1
        )
        let lhs = try FaceEmbedding(contract: current, values: [1, 0])
        let rhs = try FaceEmbedding(contract: oldAlignment, values: [1, 0])

        try await expectThrows {
            _ = try lhs.cosineDistance(to: rhs)
        }
    }

    await runner.test("同じモデルでも前処理版が異なる埋め込みを比較しない") {
        let current = FacePipelineContract(
            embeddingModel: model,
            preprocessingVersion: 1,
            alignmentVersion: 2,
            distanceMetricVersion: 1
        )
        let oldPreprocessing = FacePipelineContract(
            embeddingModel: model,
            preprocessingVersion: 0,
            alignmentVersion: 2,
            distanceMetricVersion: 1
        )
        let lhs = try FaceEmbedding(contract: current, values: [1, 0])
        let rhs = try FaceEmbedding(contract: oldPreprocessing, values: [1, 0])

        try await expectThrows {
            _ = try lhs.cosineDistance(to: rhs)
        }
    }

    runner.suite("FaceGeometry — Vision座標と顔整列")

    await runner.test("Visionの左下原点矩形を表示向き画像の左上原点へ直す") {
        let rect = FaceGeometry.imageRect(
            normalizedVisionRect: CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.40),
            imageSize: CGSize(width: 1_000, height: 500)
        )
        try expect(abs(rect.minX - 100) < 0.001)
        try expect(abs(rect.minY - 200) < 0.001)
        try expect(abs(rect.width - 300) < 0.001)
        try expect(abs(rect.height - 200) < 0.001)
    }

    await runner.test("顔の予備切り抜きを正方形にして画像範囲へ収める") {
        let crop = FaceGeometry.fallbackCrop(
            faceRect: CGRect(x: 5, y: 10, width: 40, height: 50),
            imageBounds: CGRect(x: 0, y: 0, width: 100, height: 80),
            scale: 1.6
        )
        try expectEqual(crop, CGRect(x: 0, y: 0, width: 80, height: 80))
    }

    await runner.test("小さすぎる顔は埋め込み対象にしない") {
        try expect(!FaceGeometry.isLargeEnough(
            faceRect: CGRect(x: 0, y: 0, width: 39, height: 80),
            minimumSide: 40
        ))
        try expect(FaceGeometry.isLargeEnough(
            faceRect: CGRect(x: 0, y: 0, width: 40, height: 40),
            minimumSide: 40
        ))
    }

    await runner.test("両目の中点・傾き・距離から112px整列を決める") {
        let plan = try FaceGeometry.eyeAlignment(
            leftEye: CGPoint(x: 30, y: 45),
            rightEye: CGPoint(x: 70, y: 55),
            targetSize: 112
        )
        try expect(abs(plan.sourceEyeMidpoint.x - 50) < 0.001)
        try expect(abs(plan.sourceEyeMidpoint.y - 50) < 0.001)
        try expect(abs(plan.rotationRadians + atan2(10.0, 40.0)) < 0.000_001)
        try expect(abs(plan.scale - (33.6 / hypot(40.0, 10.0))) < 0.000_001)
        try expectEqual(plan.targetEyeMidpoint, CGPoint(x: 56, y: 42.56))
    }

    await runner.test("重なった目や不正な対象サイズでは整列しない") {
        try await expectThrows {
            _ = try FaceGeometry.eyeAlignment(
                leftEye: CGPoint(x: 10, y: 10),
                rightEye: CGPoint(x: 10, y: 10),
                targetSize: 112
            )
        }
        try await expectThrows {
            _ = try FaceGeometry.eyeAlignment(
                leftEye: CGPoint(x: 10, y: 10),
                rightEye: CGPoint(x: 20, y: 10),
                targetSize: 0
            )
        }
    }

    await runner.test("MobileFaceNetの112px基準5点を返す") {
        let reference = try FaceGeometry.mobileFaceNetReferenceLandmarks(targetSize: 112)
        try expect(hypot(reference.leftEye.x - 44.1964, reference.leftEye.y - 53.1309) < 0.001)
        try expect(hypot(reference.rightEye.x - 67.6879, reference.rightEye.y - 53.0009) < 0.001)
        try expect(hypot(reference.nose.x - 56.0168, reference.nose.y - 66.4911) < 0.001)
        try expect(hypot(reference.leftMouth.x - 46.3662, reference.leftMouth.y - 80.2437) < 0.001)
        try expect(hypot(reference.rightMouth.x - 65.8199, reference.rightMouth.y - 80.1361) < 0.001)
    }

    await runner.test("5点から拡大と平行移動を1px以内で補正する") {
        let target = try FaceGeometry.mobileFaceNetReferenceLandmarks(targetSize: 112)
        let source = FaceFivePointLandmarks(
            leftEye: CGPoint(x: target.leftEye.x * 2 + 20, y: target.leftEye.y * 2 + 30),
            rightEye: CGPoint(x: target.rightEye.x * 2 + 20, y: target.rightEye.y * 2 + 30),
            nose: CGPoint(x: target.nose.x * 2 + 20, y: target.nose.y * 2 + 30),
            leftMouth: CGPoint(x: target.leftMouth.x * 2 + 20, y: target.leftMouth.y * 2 + 30),
            rightMouth: CGPoint(x: target.rightMouth.x * 2 + 20, y: target.rightMouth.y * 2 + 30)
        )
        let transform = try FaceGeometry.similarityTransform(from: source, to: target)

        for (actual, expected) in zip(source.points, target.points) {
            let mapped = actual.applying(transform.affineTransform)
            try expect(hypot(mapped.x - expected.x, mapped.y - expected.y) < 1)
        }
    }

    await runner.test("不正・重複・左右反転した5点を拒否する") {
        let target = try FaceGeometry.mobileFaceNetReferenceLandmarks(targetSize: 112)
        let coincident = FaceFivePointLandmarks(
            leftEye: .zero,
            rightEye: .zero,
            nose: .zero,
            leftMouth: .zero,
            rightMouth: .zero
        )
        let nonfinite = FaceFivePointLandmarks(
            leftEye: CGPoint(x: CGFloat.nan, y: 1),
            rightEye: CGPoint(x: 2, y: 1),
            nose: CGPoint(x: 1.5, y: 2),
            leftMouth: CGPoint(x: 1, y: 3),
            rightMouth: CGPoint(x: 2, y: 3)
        )
        let inverted = FaceFivePointLandmarks(
            leftEye: target.rightEye,
            rightEye: target.leftEye,
            nose: target.nose,
            leftMouth: target.rightMouth,
            rightMouth: target.leftMouth
        )

        try await expectThrows { _ = try FaceGeometry.similarityTransform(from: coincident, to: target) }
        try await expectThrows { _ = try FaceGeometry.similarityTransform(from: nonfinite, to: target) }
        try await expectThrows { _ = try FaceGeometry.similarityTransform(from: inverted, to: target) }
    }

    runner.suite("FaceGroupingPreferences — 安全な初期値")

    await runner.test("人物候補の分類は初回OFF") {
        try expect(!FaceGroupingDefaults.classifiesPeople)
        try expectEqual(FaceGroupingDefaults.sensitivity, .standard)
    }

    await runner.test("感度ごとの閾値は厳密から広めへ単調に広がる") {
        let strict = FaceGroupingSensitivity.strict.policy
        let standard = FaceGroupingSensitivity.standard.policy
        let broad = FaceGroupingSensitivity.broad.policy

        try expect(strict.knownPersonMaximumDistance < standard.knownPersonMaximumDistance)
        try expect(standard.knownPersonMaximumDistance < broad.knownPersonMaximumDistance)
        try expect(strict.clusterEpsilon < standard.clusterEpsilon)
        try expect(standard.clusterEpsilon < broad.clusterEpsilon)
        try expect(strict.minimumCaptureQuality > standard.minimumCaptureQuality)
        try expect(standard.minimumCaptureQuality > broad.minimumCaptureQuality)
        try expectEqual(strict.knownPersonAmbiguityMargin, 0.10)
        try expectEqual(standard.knownPersonAmbiguityMargin, 0.08)
        try expectEqual(broad.knownPersonAmbiguityMargin, 0.06)
        try expectEqual(strict.rejectionMaximumDistance, 0.24)
        try expectEqual(standard.rejectionMaximumDistance, 0.24)
        try expectEqual(broad.rejectionMaximumDistance, 0.24)
        try expectEqual(strict.clusterMinimumPoints, 2)
        try expectEqual(standard.clusterMinimumPoints, 2)
        try expectEqual(broad.clusterMinimumPoints, 2)
    }

    await runner.test("顔サイズ・品質・5点整列で利用範囲を安全に制限する") {
        let policy = FaceEligibilityPolicy(sensitivity: .standard)
        let cases: [(CGFloat, Float?, Bool, FaceEligibilityTier)] = [
            (120, 0.70, true, .prototypeEligible),
            (50, 0.25, true, .classificationEligible),
            (39, 0.90, true, .displayOnly),
            (120, 0.90, false, .displayOnly),
            (120, 0.10, true, .displayOnly)
        ]

        for (side, quality, hasFivePoints, expected) in cases {
            try expectEqual(
                policy.tier(
                    faceSide: side,
                    quality: quality,
                    hasFivePointAlignment: hasFivePoints
                ),
                expected
            )
        }
    }

    runner.suite("PeopleMatcher — 保守的な既知人物判定")

    await runner.test("近い正例2件の平均と候補差から人物を確定する") {
        let query = try FaceEmbedding(contract: contract, values: [1, 0])
        let best = try makePersonSnapshot(
            idSuffix: 1,
            name: "Best",
            positiveValues: [[0.995, 0.1], [0.98, -0.2]],
            contract: contract
        )
        let runnerUp = try makePersonSnapshot(
            idSuffix: 2,
            name: "Runner-up",
            positiveValues: [[0.7, 0.7]],
            contract: contract
        )
        let nearest = try best.positives.map {
            try query.cosineDistance(to: $0.embedding)
        }.sorted().prefix(2)
        let expectedScore = nearest.reduce(0, +) / Float(nearest.count)

        let decision = try PeopleMatcher(policy: .standard).decide(
            embedding: query,
            people: [runnerUp, best],
            blockedPersonIDs: []
        )

        try expectEqual(decision, .accepted(personID: best.id, score: expectedScore))
    }

    await runner.test("次点との差が0.08未満なら人物名を確定しない") {
        let query = try FaceEmbedding(contract: contract, values: [1, 0])
        let best = try makePersonSnapshot(
            idSuffix: 1,
            name: "Best",
            positiveValues: [[1, 0]],
            contract: contract
        )
        let runnerUp = try makePersonSnapshot(
            idSuffix: 2,
            name: "Runner-up",
            positiveValues: [[0.95, 0.3122499]],
            contract: contract
        )

        let decision = try PeopleMatcher(policy: .standard).decide(
            embedding: query,
            people: [runnerUp, best],
            blockedPersonIDs: []
        )

        if case let .ambiguous(candidates) = decision {
            try expectEqual(candidates.map(\.personID), [best.id, runnerUp.id])
        } else {
            try expect(false, "曖昧候補として返されませんでした")
        }
    }

    await runner.test("拒否例に近い顔・互換性のない顔・割当済み人物は未確定にする") {
        let query = try FaceEmbedding(contract: contract, values: [1, 0])
        let rejected = try makePersonSnapshot(
            idSuffix: 1,
            name: "Rejected",
            positiveValues: [[1, 0]],
            rejectionValues: [[0.999, 0.001]],
            contract: contract
        )
        let blockable = try makePersonSnapshot(
            idSuffix: 3,
            name: "Already assigned in this photo",
            positiveValues: [[1, 0]],
            contract: contract
        )
        let incompatibleContract = FacePipelineContract(
            embeddingModel: FaceEmbeddingModel(
                identifier: model.identifier,
                version: "future",
                dimension: model.dimension
            ),
            preprocessingVersion: contract.preprocessingVersion,
            alignmentVersion: contract.alignmentVersion,
            distanceMetricVersion: contract.distanceMetricVersion
        )
        let incompatible = try makePersonSnapshot(
            idSuffix: 2,
            name: "Incompatible",
            positiveValues: [[1, 0]],
            contract: incompatibleContract
        )

        try expectEqual(
            try PeopleMatcher(policy: .standard).decide(
                embedding: query,
                people: [rejected],
                blockedPersonIDs: []
            ),
            .unconfirmed
        )
        try expectEqual(
            try PeopleMatcher(policy: .standard).decide(
                embedding: query,
                people: [incompatible],
                blockedPersonIDs: []
            ),
            .unconfirmed
        )
        try expectEqual(
            try PeopleMatcher(policy: .standard).decide(
                embedding: query,
                people: [blockable],
                blockedPersonIDs: [blockable.id]
            ),
            .unconfirmed
        )
    }

    runner.suite("FaceDensityClusterer — 人物候補")

    await runner.test("密度到達可能な顔を同じクラスタにまとめる") {
        let ids = makeFaceDescriptorIDs(count: 4)
        let distances: [FaceDescriptorPair: Float] = [
            FaceDescriptorPair(ids[0], ids[1]): 0.10,
            FaceDescriptorPair(ids[1], ids[2]): 0.10,
            FaceDescriptorPair(ids[0], ids[2]): 0.40
        ]
        let result = FaceDensityClusterer().cluster(
            ids: ids,
            epsilon: 0.20,
            minimumPoints: 2,
            distances: distances
        )

        try expectEqual(result.clusters, [[ids[0], ids[1], ids[2]]])
        try expectEqual(result.outliers, [ids[3]])
    }

    await runner.test("入力順にかかわらず結果内の表示順を維持する") {
        let ids = makeFaceDescriptorIDs(count: 5)
        let distances: [FaceDescriptorPair: Float] = [
            FaceDescriptorPair(ids[0], ids[2]): 0.05,
            FaceDescriptorPair(ids[1], ids[4]): 0.05
        ]
        let result = FaceDensityClusterer().cluster(
            ids: ids,
            epsilon: 0.10,
            minimumPoints: 2,
            distances: distances
        )

        try expectEqual(result.clusters, [[ids[0], ids[2]], [ids[1], ids[4]]])
        try expectEqual(result.outliers, [ids[3]])
    }

    await runner.test("欠損・非有限・境界値の距離を近傍にしない") {
        let ids = makeFaceDescriptorIDs(count: 4)
        let distances: [FaceDescriptorPair: Float] = [
            FaceDescriptorPair(ids[0], ids[1]): .nan,
            FaceDescriptorPair(ids[1], ids[2]): .infinity,
            FaceDescriptorPair(ids[2], ids[3]): 0.20
        ]
        let result = FaceDensityClusterer().cluster(
            ids: ids,
            epsilon: 0.20,
            minimumPoints: 2,
            distances: distances
        )

        try expect(result.clusters.isEmpty)
        try expectEqual(result.outliers, ids)
    }

    await runner.test("最小点数が2未満なら安全な値へ補正する") {
        let ids = makeFaceDescriptorIDs(count: 2)
        let result = FaceDensityClusterer().cluster(
            ids: ids,
            epsilon: 0.20,
            minimumPoints: 0,
            distances: [:]
        )

        try expect(result.clusters.isEmpty)
        try expectEqual(result.outliers, ids)
    }

    await runner.test("同じ写真の別の顔を同一クラスタへ入れない") {
        let sharedItemID = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
        let ids = [
            FaceDescriptorID(itemID: sharedItemID, faceIndex: 0),
            FaceDescriptorID(itemID: sharedItemID, faceIndex: 1),
            FaceDescriptorID(
                itemID: UUID(uuidString: "00000000-0000-0000-0000-000000000200")!,
                faceIndex: 0
            )
        ]
        let distances = Dictionary(uniqueKeysWithValues: [
            (FaceDescriptorPair(ids[0], ids[1]), Float(0.05)),
            (FaceDescriptorPair(ids[0], ids[2]), Float(0.06)),
            (FaceDescriptorPair(ids[1], ids[2]), Float(0.07))
        ])

        let result = FaceDensityClusterer().cluster(
            ids: ids,
            epsilon: 0.42,
            minimumPoints: 2,
            distances: distances,
            cannotLink: [FaceDescriptorPair(ids[0], ids[1])]
        )

        try expect(!result.clusters.contains {
            Set($0).isSuperset(of: [ids[0], ids[1]])
        })
    }

    runner.suite("FacePrototypeSelector — 代表顔の選択")

    await runner.test("正例12件・拒否例24件へ決定的に間引く") {
        let candidates = try (0..<30).map { index in
            try makePersonEmbeddingSample(
                index: index,
                count: 30,
                contract: contract
            )
        }

        let positives = try FacePrototypeSelector.select(
            existing: Array(candidates.prefix(4)),
            adding: Array(candidates.dropFirst(4)),
            limit: 12,
            nearDuplicateDistance: 0.02
        )
        let rejections = try FacePrototypeSelector.select(
            existing: [],
            adding: candidates,
            limit: 24,
            nearDuplicateDistance: 0.02
        )

        try expectEqual(positives.count, 12)
        try expectEqual(rejections.count, 24)
        try expectEqual(
            positives.map(\.id),
            positives.sorted(by: FacePrototypeSelector.stableOrder).map(\.id)
        )
        try expectEqual(
            rejections.map(\.id),
            rejections.sorted(by: FacePrototypeSelector.stableOrder).map(\.id)
        )
    }

    await runner.test("距離0.02未満のほぼ同じ代表顔を重複保存しない") {
        let first = PersonEmbeddingSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            embedding: try FaceEmbedding(contract: contract, values: [1, 0]),
            captureQuality: 0.8,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let duplicate = PersonEmbeddingSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            embedding: try FaceEmbedding(contract: contract, values: [0.999, 0.001]),
            captureQuality: 0.9,
            createdAt: Date(timeIntervalSince1970: 2)
        )

        let selected = try FacePrototypeSelector.select(
            existing: [first],
            adding: [duplicate],
            limit: 12,
            nearDuplicateDistance: 0.02
        )

        try expectEqual(selected.map(\.id), [first.id])
    }

    runner.suite("PersonStore — 確認した人物")

    await runner.test("複数の顔から正規化した代表埋め込みを作る") {
        let first = try FaceEmbedding(contract: contract, values: [1, 0])
        let second = try FaceEmbedding(contract: contract, values: [0, 1])
        let centroid = try FaceEmbedding.centroid(of: [first, second])
        let expected = Float(1 / Double(2).squareRoot())

        try expect(abs(centroid.values[0] - expected) < 0.000_01)
        try expect(abs(centroid.values[1] - expected) < 0.000_01)
    }

    await runner.test("異なるモデルの顔を一つの人物へ登録しない") {
        let first = try FaceEmbedding(contract: contract, values: [1, 0])
        let otherModel = FaceEmbeddingModel(
            identifier: "another.model",
            version: model.version,
            dimension: model.dimension
        )
        let second = try FaceEmbedding(
            contract: FacePipelineContract(
                embeddingModel: otherModel,
                preprocessingVersion: contract.preprocessingVersion,
                alignmentVersion: contract.alignmentVersion,
                distanceMetricVersion: contract.distanceMetricVersion
            ),
            values: [1, 0]
        )
        try await expectThrows {
            _ = try FaceEmbedding.centroid(of: [first, second])
        }
    }

    await runner.test("正例と拒否例を保存領域を開き直しても保持する") {
        let container = try makeInMemoryPersonContainer()
        let firstStore = PersonStore(container: container)
        let positive = PersonEmbeddingSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            embedding: try FaceEmbedding(contract: contract, values: [1, 0]),
            captureQuality: 0.8,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let rejection = PersonEmbeddingSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            embedding: try FaceEmbedding(contract: contract, values: [0, 1]),
            captureQuality: 0.7,
            createdAt: Date(timeIntervalSince1970: 110)
        )
        let saved = try firstStore.createPerson(
            displayName: "  Keiju  ",
            prototype: positive,
            now: Date(timeIntervalSince1970: 100)
        )
        _ = try firstStore.addRejection(
            personID: saved.id,
            sample: rejection,
            now: Date(timeIntervalSince1970: 120)
        )

        let reopened = PersonStore(container: container)
        let loaded = try reopened.people().first
        try expectEqual(loaded?.displayName, "Keiju")
        try expectEqual(loaded?.positives.map(\.id), [positive.id])
        try expectEqual(loaded?.rejections.map(\.id), [rejection.id])
        try expectEqual(loaded?.isLegacyOnly, false)
        try expectEqual(
            try reopened.statistics(),
            PersonStoreStatistics(
                savedPersonCount: 1,
                legacyProfileCount: 0,
                positivePrototypeCount: 1,
                rejectionPrototypeCount: 1
            )
        )

        let renamed = try reopened.renamePerson(
            id: saved.id,
            displayName: "慶樹",
            now: Date(timeIntervalSince1970: 200)
        )
        try expectEqual(renamed.displayName, "慶樹")
        try expectEqual(renamed.updatedAt, Date(timeIntervalSince1970: 200))

        try reopened.deletePerson(id: saved.id)
        try expect(try reopened.people().isEmpty)
    }

    await runner.test("旧代表値だけの人物は名前を残して再確認対象にする") {
        let container = try makeInMemoryPersonContainer()
        let context = ModelContext(container)
        let legacy = PersonProfile(
            displayName: "以前の人物名",
            embedding: try FaceEmbedding(contract: contract, values: [1, 0]),
            sampleCount: 3,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        context.insert(legacy)
        try context.save()

        let people = try PersonStore(container: container).people()
        try expectEqual(people.count, 1)
        try expectEqual(people[0].displayName, "以前の人物名")
        try expect(people[0].positives.isEmpty)
        try expect(people[0].rejections.isEmpty)
        try expect(people[0].isLegacyOnly)
    }

    await runner.test("人物の統合をスナップショットから元に戻せる") {
        let store = try makeInMemoryPersonStore()
        let first = try store.createPerson(
            displayName: "One",
            prototype: makePersonEmbeddingSample(index: 0, count: 8, contract: contract)
        )
        let second = try store.createPerson(
            displayName: "Two",
            prototype: makePersonEmbeddingSample(index: 2, count: 8, contract: contract)
        )
        let before = try store.snapshot()

        let merged = try store.mergePeople(
            sourceIDs: [second.id],
            destinationID: first.id
        )
        try expectEqual(try store.people().map(\.id), [merged.id])

        try store.restore(before)
        try expectEqual(try store.snapshot(), before)
        try expectEqual(Set(try store.people().map(\.id)), [first.id, second.id])
    }

    await runner.test("人物編集を正確なスナップショットへ復元できる") {
        let store = try makeInMemoryPersonStore()
        let created = try store.createPerson(
            displayName: "Before",
            prototype: makePersonEmbeddingSample(index: 0, count: 8, contract: contract),
            now: Date(timeIntervalSince1970: 10)
        )
        let before = try store.snapshot()

        _ = try store.renamePerson(
            id: created.id,
            displayName: "After",
            now: Date(timeIntervalSince1970: 20)
        )
        _ = try store.addPositivePrototype(
            makePersonEmbeddingSample(index: 2, count: 8, contract: contract),
            to: created.id,
            now: Date(timeIntervalSince1970: 30)
        )
        _ = try store.addRejectionPrototype(
            makePersonEmbeddingSample(index: 4, count: 8, contract: contract),
            to: created.id,
            now: Date(timeIntervalSince1970: 40)
        )
        try store.restore(before)

        try expectEqual(try store.snapshot(), before)
    }

    await runner.test("互換性のない人物統合は保存内容を変更しない") {
        let store = try makeInMemoryPersonStore()
        let destination = try store.createPerson(
            displayName: "Current",
            prototype: makePersonEmbeddingSample(index: 0, count: 8, contract: contract)
        )
        let incompatibleContract = FacePipelineContract(
            embeddingModel: FaceEmbeddingModel(
                identifier: contract.embeddingModel.identifier,
                version: "future",
                dimension: contract.embeddingModel.dimension
            ),
            preprocessingVersion: contract.preprocessingVersion,
            alignmentVersion: contract.alignmentVersion,
            distanceMetricVersion: contract.distanceMetricVersion
        )
        let source = try store.createPerson(
            displayName: "Future",
            prototype: makePersonEmbeddingSample(
                index: 1,
                count: 8,
                contract: incompatibleContract
            )
        )
        let before = try store.snapshot()

        try await expectThrows {
            _ = try store.mergePeople(
                sourceIDs: [source.id],
                destinationID: destination.id
            )
        }

        try expectEqual(try store.snapshot(), before)
    }

    await runner.test("空の名前・顔なし・壊れた埋め込みを保存しない") {
        let store = try makeInMemoryPersonStore()
        let embedding = try FaceEmbedding(contract: contract, values: [1, 0])
        try await expectThrows {
            _ = try store.savePerson(displayName: "   ", embeddings: [embedding])
        }
        try await expectThrows {
            _ = try store.savePerson(displayName: "Keiju", embeddings: [])
        }
        try expect(try store.people().isEmpty)
    }

    await runner.test("互換モデルだけを既知人物候補として照合する") {
        let store = try makeInMemoryPersonStore()
        let saved = try store.savePerson(
            displayName: "Keiju",
            embeddings: [try FaceEmbedding(contract: contract, values: [1, 0])]
        )
        _ = try store.savePerson(
            displayName: "Someone",
            embeddings: [try FaceEmbedding(contract: contract, values: [0, 1])]
        )

        let match = try store.bestMatch(
            for: FaceEmbedding(contract: contract, values: [0.99, 0.01]),
            maximumDistance: 0.10
        )
        try expectEqual(match?.person.id, saved.id)
        try expect((match?.distance ?? 1) < 0.01)

        let incompatible = try FaceEmbedding(
            contract: FacePipelineContract(
                embeddingModel: FaceEmbeddingModel(
                    identifier: model.identifier,
                    version: "next",
                    dimension: 2
                ),
                preprocessingVersion: contract.preprocessingVersion,
                alignmentVersion: contract.alignmentVersion,
                distanceMetricVersion: contract.distanceMetricVersion
            ),
            values: [1, 0]
        )
        try expect(try store.bestMatch(for: incompatible, maximumDistance: 0.10) == nil)
    }

    await runner.test("人物データをまとめて削除できる") {
        let store = try makeInMemoryPersonStore()
        _ = try store.savePerson(
            displayName: "One",
            embeddings: [try FaceEmbedding(contract: contract, values: [1, 0])]
        )
        _ = try store.savePerson(
            displayName: "Two",
            embeddings: [try FaceEmbedding(contract: contract, values: [0, 1])]
        )

        try store.deleteAllPeople()
        try expect(try store.people().isEmpty)
    }

    runner.suite("PeopleWorkspaceProjection — 現在のリスト表示")

    await runner.test("人物・候補・未確認を漏れなく読み込み順へ投影する") {
        let itemIDs = makeFaceDescriptorIDs(count: 3).map(\.itemID)
        let firstPersonFace = FaceDescriptorID(itemID: itemIDs[0], faceIndex: 0)
        let secondPersonFace = FaceDescriptorID(itemID: itemIDs[0], faceIndex: 1)
        let candidateFaces = [
            FaceDescriptorID(itemID: itemIDs[1], faceIndex: 0),
            FaceDescriptorID(itemID: itemIDs[2], faceIndex: 0)
        ]
        let ambiguousFace = FaceDescriptorID(itemID: itemIDs[1], faceIndex: 1)
        let displayOnlyFace = FaceDescriptorID(itemID: itemIDs[2], faceIndex: 1)
        let singletonFace = FaceDescriptorID(itemID: itemIDs[0], faceIndex: 2)
        let firstPerson = try makePersonSnapshot(
            idSuffix: 31,
            name: "Keiju",
            positiveValues: [[1, 0]],
            contract: contract
        )
        let secondPerson = try makePersonSnapshot(
            idSuffix: 32,
            name: "Friend",
            positiveValues: [[0, 1]],
            contract: contract
        )
        let cluster = PeopleCandidateCluster(members: candidateFaces)
        let result = PeopleClassificationResult(
            faceIDsByItemID: [
                itemIDs[0]: [firstPersonFace, secondPersonFace, singletonFace],
                itemIDs[1]: [candidateFaces[0], ambiguousFace],
                itemIDs[2]: [candidateFaces[1], displayOnlyFace]
            ],
            namedAssignments: [
                firstPerson.id: [firstPersonFace],
                secondPerson.id: [secondPersonFace]
            ],
            unnamedClusters: [cluster],
            unconfirmedFaceIDs: [ambiguousFace, displayOnlyFace]
        )

        let projection = PeopleWorkspaceProjection.make(
            orderedItemIDs: itemIDs,
            result: result,
            people: [secondPerson, firstPerson]
        )

        try expectEqual(
            projection.groups.map(\.id),
            [
                .person(firstPerson.id),
                .person(secondPerson.id),
                .candidate(cluster.id)
            ]
        )
        try expectEqual(projection.groups[0].itemIDs, [itemIDs[0]])
        try expectEqual(projection.groups[1].itemIDs, [itemIDs[0]])
        try expectEqual(projection.groups[2].itemIDs, [itemIDs[1], itemIDs[2]])
        try expectEqual(
            Set(projection.unconfirmed.map(\.faceID)),
            [ambiguousFace, displayOnlyFace, singletonFace]
        )

        let reordered = PeopleWorkspaceProjection.make(
            orderedItemIDs: Array(itemIDs.reversed()),
            result: result,
            people: [firstPerson, secondPerson]
        )
        try expect(projection.groups.map(\.id) != reordered.groups.map(\.id))
        try expectEqual(
            Dictionary(uniqueKeysWithValues: projection.groups.map { ($0.id, Set($0.faceIDs)) }),
            Dictionary(uniqueKeysWithValues: reordered.groups.map { ($0.id, Set($0.faceIDs)) })
        )
    }
}

private func makeFaceDescriptorIDs(count: Int) -> [FaceDescriptorID] {
    (0..<count).map { index in
        FaceDescriptorID(
            itemID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
            faceIndex: index
        )
    }
}

private func makePersonEmbeddingSample(
    index: Int,
    count: Int,
    contract: FacePipelineContract
) throws -> PersonEmbeddingSample {
    let angle = (Double(index) / Double(count)) * 2 * Double.pi
    return PersonEmbeddingSample(
        id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", index + 1))!,
        embedding: try FaceEmbedding(
            contract: contract,
            values: [Float(cos(angle)), Float(sin(angle))]
        ),
        captureQuality: Float(0.5 + Double(index % 5) * 0.1),
        createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
    )
}

private func makePersonSnapshot(
    idSuffix: Int,
    name: String,
    positiveValues: [[Float]],
    rejectionValues: [[Float]] = [],
    contract: FacePipelineContract
) throws -> PersonProfileSnapshot {
    let personID = UUID(
        uuidString: String(format: "00000000-0000-0000-0002-%012d", idSuffix)
    )!
    let positives = try positiveValues.enumerated().map { index, values in
        PersonEmbeddingSample(
            id: UUID(
                uuidString: String(
                    format: "00000000-0000-0000-%04d-%012d",
                    idSuffix + 10,
                    index + 1
                )
            )!,
            embedding: try FaceEmbedding(contract: contract, values: values),
            captureQuality: 0.8,
            createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
        )
    }
    let rejections = try rejectionValues.enumerated().map { index, values in
        PersonEmbeddingSample(
            id: UUID(
                uuidString: String(
                    format: "00000000-0000-0000-%04d-%012d",
                    idSuffix + 20,
                    index + 1
                )
            )!,
            embedding: try FaceEmbedding(contract: contract, values: values),
            captureQuality: 0.8,
            createdAt: Date(timeIntervalSince1970: TimeInterval(index + 101))
        )
    }
    return PersonProfileSnapshot(
        id: personID,
        displayName: name,
        positives: positives,
        rejections: rejections,
        isLegacyOnly: positives.isEmpty,
        createdAt: .distantPast,
        updatedAt: .distantPast
    )
}

@MainActor
private func makeInMemoryPersonContainer() throws -> ModelContainer {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: PersonProfile.self,
        PersonEmbeddingRecord.self,
        configurations: configuration
    )
}

@MainActor
private func makeInMemoryPersonStore() throws -> PersonStore {
    try PersonStore(container: makeInMemoryPersonContainer())
}
