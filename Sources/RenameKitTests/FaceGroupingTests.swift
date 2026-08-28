import Foundation
import RenameKit

@MainActor
func runFaceGroupingTests() async {
    let runner = TestRunner.shared
    let model = FaceEmbeddingModel(
        identifier: "qualcomm.mobilefacenet",
        version: "0.61.0",
        dimension: 2
    )

    runner.suite("FaceEmbedding — 正規化と距離")

    await runner.test("埋め込みをL2正規化する") {
        let embedding = try FaceEmbedding(model: model, values: [3, 4])
        try expectEqual(embedding.values.count, 2)
        try expect(abs(embedding.values[0] - 0.6) < 0.000_01)
        try expect(abs(embedding.values[1] - 0.8) < 0.000_01)
    }

    await runner.test("ゼロベクトルと非有限値を拒否する") {
        try await expectThrows {
            _ = try FaceEmbedding(model: model, values: [0, 0])
        }
        try await expectThrows {
            _ = try FaceEmbedding(model: model, values: [.nan, 1])
        }
    }

    await runner.test("モデルの次元と異なる入力を拒否する") {
        try await expectThrows {
            _ = try FaceEmbedding(model: model, values: [1, 0, 0])
        }
    }

    await runner.test("cosine距離を0から2で計算する") {
        let x = try FaceEmbedding(model: model, values: [1, 0])
        let same = try FaceEmbedding(model: model, values: [2, 0])
        let orthogonal = try FaceEmbedding(model: model, values: [0, 1])
        let opposite = try FaceEmbedding(model: model, values: [-1, 0])

        try expect(abs(try x.cosineDistance(to: same) - 0) < 0.000_01)
        try expect(abs(try x.cosineDistance(to: orthogonal) - 1) < 0.000_01)
        try expect(abs(try x.cosineDistance(to: opposite) - 2) < 0.000_01)
    }

    await runner.test("モデルID・版・次元が異なる埋め込みを比較しない") {
        let reference = try FaceEmbedding(model: model, values: [1, 0])
        let anotherVersion = try FaceEmbedding(
            model: FaceEmbeddingModel(
                identifier: model.identifier,
                version: "0.62.0",
                dimension: 2
            ),
            values: [1, 0]
        )
        try await expectThrows {
            _ = try reference.cosineDistance(to: anotherVersion)
        }
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
}

private func makeFaceDescriptorIDs(count: Int) -> [FaceDescriptorID] {
    (0..<count).map { index in
        FaceDescriptorID(
            itemID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
            faceIndex: index
        )
    }
}
