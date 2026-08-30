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
        try expectEqual(strict.clusterMinimumPoints, 2)
        try expectEqual(standard.clusterMinimumPoints, 2)
        try expectEqual(broad.clusterMinimumPoints, 2)
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

    await runner.test("人物を保存して再取得・改名・削除できる") {
        let store = try makeInMemoryPersonStore()
        let embeddings = [
            try FaceEmbedding(contract: contract, values: [1, 0]),
            try FaceEmbedding(contract: contract, values: [0.8, 0.2])
        ]
        let saved = try store.savePerson(
            displayName: "  Keiju  ",
            embeddings: embeddings,
            now: Date(timeIntervalSince1970: 100)
        )

        try expectEqual(saved.displayName, "Keiju")
        try expectEqual(saved.sampleCount, 2)
        try expectEqual(saved.embedding.model, model)
        try expectEqual(try store.people().map(\.id), [saved.id])

        let renamed = try store.renamePerson(
            id: saved.id,
            displayName: "慶樹",
            now: Date(timeIntervalSince1970: 200)
        )
        try expectEqual(renamed.displayName, "慶樹")
        try expectEqual(renamed.updatedAt, Date(timeIntervalSince1970: 200))

        try store.deletePerson(id: saved.id)
        try expect(try store.people().isEmpty)
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
}

private func makeFaceDescriptorIDs(count: Int) -> [FaceDescriptorID] {
    (0..<count).map { index in
        FaceDescriptorID(
            itemID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
            faceIndex: index
        )
    }
}

@MainActor
private func makeInMemoryPersonStore() throws -> PersonStore {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
        for: PersonProfile.self,
        configurations: configuration
    )
    return PersonStore(container: container)
}
