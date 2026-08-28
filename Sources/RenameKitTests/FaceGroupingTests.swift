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

    runner.suite("PersonStore — 確認した人物")

    await runner.test("複数の顔から正規化した代表埋め込みを作る") {
        let first = try FaceEmbedding(model: model, values: [1, 0])
        let second = try FaceEmbedding(model: model, values: [0, 1])
        let centroid = try FaceEmbedding.centroid(of: [first, second])
        let expected = Float(1 / Double(2).squareRoot())

        try expect(abs(centroid.values[0] - expected) < 0.000_01)
        try expect(abs(centroid.values[1] - expected) < 0.000_01)
    }

    await runner.test("異なるモデルの顔を一つの人物へ登録しない") {
        let first = try FaceEmbedding(model: model, values: [1, 0])
        let otherModel = FaceEmbeddingModel(
            identifier: "another.model",
            version: model.version,
            dimension: model.dimension
        )
        let second = try FaceEmbedding(model: otherModel, values: [1, 0])
        try await expectThrows {
            _ = try FaceEmbedding.centroid(of: [first, second])
        }
    }

    await runner.test("人物を保存して再取得・改名・削除できる") {
        let store = try makeInMemoryPersonStore()
        let embeddings = [
            try FaceEmbedding(model: model, values: [1, 0]),
            try FaceEmbedding(model: model, values: [0.8, 0.2])
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
        let embedding = try FaceEmbedding(model: model, values: [1, 0])
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
            embeddings: [try FaceEmbedding(model: model, values: [1, 0])]
        )
        _ = try store.savePerson(
            displayName: "Someone",
            embeddings: [try FaceEmbedding(model: model, values: [0, 1])]
        )

        let match = try store.bestMatch(
            for: FaceEmbedding(model: model, values: [0.99, 0.01]),
            maximumDistance: 0.10
        )
        try expectEqual(match?.person.id, saved.id)
        try expect((match?.distance ?? 1) < 0.01)

        let incompatible = try FaceEmbedding(
            model: FaceEmbeddingModel(identifier: model.identifier, version: "next", dimension: 2),
            values: [1, 0]
        )
        try expect(try store.bestMatch(for: incompatible, maximumDistance: 0.10) == nil)
    }

    await runner.test("人物データをまとめて削除できる") {
        let store = try makeInMemoryPersonStore()
        _ = try store.savePerson(
            displayName: "One",
            embeddings: [try FaceEmbedding(model: model, values: [1, 0])]
        )
        _ = try store.savePerson(
            displayName: "Two",
            embeddings: [try FaceEmbedding(model: model, values: [0, 1])]
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
