# FileRenamer Offline Face Clustering Implementation Plan

> **Execution note:** Implement every task test-first in this experimental worktree.

**Goal:** Importした写真をMac内だけで顔解析し、同一人物候補をまとめ、確認した人物名と代表埋め込みをローカルへ保存して次回の写真でも候補表示できるようにする。

**Architecture:** Visionで顔矩形・ランドマーク・撮影品質を求め、目の位置を基準に112×112へ整列する。Apache-2.0のQualcomm MobileFaceNetをCore MLへ変換して128次元埋め込みを生成し、L2正規化・cosine距離・DBSCANで分類する。確定した人物プロファイルだけをSwiftDataへ保存し、写真パス・顔切り抜き・未確定グループは保存しない。既存の類似画像解析とはactor、Task、revision、状態を完全に分離する。

**Tech Stack:** Swift 5 mode、SwiftUI、Vision、Core ML、ImageIO、SwiftData、既存RenameKitTests、Xcode 26。

**Spec:** `docs/superpowers/specs/2026-08-28-offline-face-clustering-design.md`

**Reference implementations:**

- `UnlikeOtherAI/Faces` revision `8bd922e2c71b40833b247425abf8aa9566723925` (MIT)
- `mattt/DBSCAN` revision `9e0bac44de48b981fb1afcea1f2d29320e306c1a` (MIT)
- Qualcomm MobileFaceNet release `v0.61.0` (Apache-2.0 model card)

## Global constraints

- Work only in `.worktrees/offline-face-clustering` on `experiment/offline-face-clustering`.
- Do not alter or stash the uncommitted `main` localization catalog.
- The feature is off by default and performs no network operation at runtime.
- Never bundle InsightFace `buffalo_*` or weights without explicit redistribution rights.
- Never mutate imported files, rename rules, ordering, selection, Undo history, or trash state.
- Use “人物候補” / “同じ人物の可能性” wording, not an identity guarantee.
- Every production behaviour begins with a failing test.

---

### Task 1: Embedding math and deterministic DBSCAN

**Files:**

- Create: `Sources/RenameKit/FaceGrouping/FaceEmbedding.swift`
- Create: `Sources/RenameKit/FaceGrouping/FaceDensityClusterer.swift`
- Create: `Sources/RenameKitTests/FaceGroupingTests.swift`
- Modify: `Sources/RenameKitTests/main.swift`

- [ ] Add failing tests for L2 normalisation, zero vectors, cosine distance, dimension mismatch, model mismatch, clusters, chained density reachability, outliers, missing/non-finite distances, and stable order.
- [ ] Run `RenameKitTests` and confirm compilation or expectations fail for the missing production types.
- [ ] Implement immutable `FaceEmbedding`, `FaceDescriptorID`, `FaceDistanceMatrix`, `FaceClusterResult`, and deterministic DBSCAN-style `FaceDensityClusterer`.
- [ ] Run the new suite and the complete existing suite.
- [ ] Commit as `Add face embedding and density clustering logic`.

### Task 2: Confirmed-person profile and SwiftData store

**Files:**

- Create: `Sources/RenameKit/FaceGrouping/PersonProfile.swift`
- Create: `Sources/RenameKit/FaceGrouping/PersonStore.swift`
- Modify: `Sources/RenameKitTests/FaceGroupingTests.swift`

- [ ] Add failing tests for centroid creation, normalisation, invalid/mixed embeddings, model-version rejection, in-memory SwiftData insert/fetch/rename/delete, and delete-all.
- [ ] Implement `@Model PersonProfile` without source paths or face crops.
- [ ] Implement local-only `PersonStore` with an injectable in-memory `ModelContainer` for tests.
- [ ] Add known-profile matching that checks model ID, version, and dimension before cosine comparison.
- [ ] Run tests and commit as `Persist confirmed people locally`.

### Task 3: Obtain and reproducibly convert the licensed model

**Files:**

- Create: `scripts/convert-mobilefacenet-to-coreml.py`
- Create: `Sources/FileRenamer/Resources/Models/MobileFaceNet.mlpackage/**`
- Create: `Sources/FileRenamer/Resources/Models/MobileFaceNet-LICENSE.txt`
- Create: `Sources/FileRenamer/Resources/Models/MobileFaceNet-METADATA.json`
- Create or modify: `THIRD_PARTY_NOTICES.md`

- [ ] Download Qualcomm `v0.61.0` float ONNX release into `/private/tmp`, record SHA-256, and inspect input/output names and shapes.
- [ ] Add a conversion script that renames the Core ML contract to `input` and `embedding`, uses 112×112 RGB NCHW float input, and preserves 128-dimensional output.
- [ ] Convert and verify output shape, finiteness, and approximately unit L2 norm using a deterministic input.
- [ ] Record source URL, upstream release, source checksum, generated artifact checksum, model dimension, preprocessing contract, and license.
- [ ] Confirm no InsightFace artifact or accidental training data is present with `rg` and file inventory checks.
- [ ] Commit as `Bundle licensed MobileFaceNet Core ML model`.

### Task 4: Vision detection, quality, landmarks, and alignment

**Files:**

- Create: `Sources/FileRenamer/Support/FaceImageLoader.swift`
- Create: `Sources/FileRenamer/Support/FaceAligner.swift`
- Create: `Sources/FileRenamer/Support/MobileFaceNetEmbedder.swift`
- Create: `Sources/FileRenamer/Support/OfflineFaceClassifier.swift`
- Modify: `Sources/RenameKitTests/FaceGroupingTests.swift`

- [ ] Add failing pure-geometry tests for orientation-independent bounding boxes, eye-line transform, crop clipping, minimum face size, and fallback crop.
- [ ] Implement ImageIO downsampling with orientation transform and symmetric security-scoped access.
- [ ] Adapt the MIT `Faces` detect/crop/embed separation to the FileRenamer actor design.
- [ ] Run `VNDetectFaceRectanglesRequest`, feed its observations to landmark and capture-quality requests, and keep all faces per photo.
- [ ] Align eligible faces to 112×112; use padded crop when landmarks are incomplete.
- [ ] Run the Core ML model, defensively normalise embeddings, match known profiles, then cluster unknowns.
- [ ] Add cancellation and cache invalidation keyed by path, size, and modification date.
- [ ] Build FileRenamer and commit as `Add offline face classification pipeline`.

### Task 5: AppModel isolation and settings

**Files:**

- Modify: `Sources/FileRenamer/FileRenamerApp.swift`
- Modify: `Sources/FileRenamer/AppModel.swift`
- Modify: `Sources/FileRenamer/Resources/Localizable.xcstrings`
- Modify: `Sources/RenameKitTests/FaceGroupingTests.swift`

- [ ] Add failing tests for default-off settings and sensitivity threshold mapping in pure RenameKit types.
- [ ] Add `classifiesPeople` and `faceGroupingSensitivity` preferences.
- [ ] Add a separate face task, revision, progress state, result lookup, review selection, cancellation, and rescan triggers to `AppModel`.
- [ ] Ensure reordering reuses ID-keyed results while import, clear, preference changes, and content changes rescan or clear.
- [ ] Add settings copy explaining local analysis and persistent named profiles, plus confirmed “人物データをすべて削除”.
- [ ] Run complete tests, build, and commit as `Integrate face classification state and settings`.

### Task 6: List/grid badges and person review UI

**Files:**

- Modify: `Sources/FileRenamer/Views/FileListView.swift`
- Modify: `Sources/FileRenamer/Views/FileGridView.swift`
- Modify: `Sources/FileRenamer/Views/StatusBar.swift`
- Modify: `Sources/FileRenamer/Views/ContentView.swift`
- Create: `Sources/FileRenamer/Views/PeopleReviewView.swift`
- Create: `Sources/FileRenamer/Views/FaceCropView.swift`
- Modify: `Sources/FileRenamer/Resources/Localizable.xcstrings`

- [ ] Show a small text/count badge only when an item belongs to one or more groups.
- [ ] Open a separate review sheet without changing list selection or deletion state.
- [ ] Display candidate groups in current file order, including photos with multiple faces.
- [ ] Add “誰ですか？” naming flow with first-save biometric-data confirmation.
- [ ] Add rename and registration removal controls that never touch source photos.
- [ ] Show nonblocking face-analysis progress in StatusBar.
- [ ] Verify list/grid reordering and Quick Look still use the correct item IDs.
- [ ] Build and commit as `Add people candidate review UI`.

### Task 7: Privacy, documentation, and attribution

**Files:**

- Modify: `PRIVACY.md`
- Modify: `README.md`
- Modify: `README.en.md`
- Modify: `Sources/FileRenamer/Resources/PrivacyInfo.xcprivacy` if required by the final API inventory
- Modify: `THIRD_PARTY_NOTICES.md`

- [ ] Document local face processing, optional named-profile persistence, deletion controls, no uploads, and no automatic file operations.
- [ ] Document the experimental/off-by-default status and accuracy limitations.
- [ ] Attribute referenced MIT code/algorithm and the Qualcomm model/license without implying endorsement.
- [ ] Audit required-reason APIs and confirm SwiftData/UserDefaults declarations remain accurate.
- [ ] Commit as `Document offline people classification privacy`.

### Task 8: Completion verification

- [ ] Run `RenameKitTests` and record total passed/failed.
- [ ] Run macOS Debug build with signing disabled.
- [ ] Run macOS Release build with signing disabled.
- [ ] Run Xcode Analyze.
- [ ] Inspect the built app for compiled MobileFaceNet, license notice, no ONNX/training data, and no restricted model names.
- [ ] Block network temporarily or inspect runtime calls and demonstrate analysis succeeds without networking.
- [ ] Exercise multiple faces, known person, unknown cluster, disable/cancel, unreadable image, clear list, reorder, and relaunch persistence.
- [ ] Confirm normal rename-only processing produces no embedding task when the preference is off.
- [ ] Run `git diff --check`, inspect branch-only commits, and confirm `main` dirty state remains untouched.
- [ ] Request a final code review and address findings before claiming completion.
