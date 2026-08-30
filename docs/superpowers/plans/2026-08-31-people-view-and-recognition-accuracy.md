# People View and Recognition Accuracy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Photos-style People display mode and replace the current fragile face grouping with versioned five-point alignment, conservative multi-prototype matching, correctable local learning, and a measurable accuracy gate.

**Architecture:** Keep image decoding, Vision, and Core ML in a background `FaceAnalyzer`; move matching, prototype selection, clustering constraints, and workspace projection into dependency-free RenameKit types; keep SwiftData behind `PersonStore`; expose current-tab results through a focused `PeopleWorkspaceModel`. The People UI shows only currently imported files, while confirmed names and versioned positive/rejection embeddings persist locally without paths or crops.

**Tech Stack:** Swift 5 language mode, SwiftUI, AppKit, Vision, Core ML, SwiftData, Swift Package Manager executable safety harness, Xcode 26/macOS 14 deployment target.

**Spec:** `docs/superpowers/specs/2026-08-31-people-view-and-recognition-accuracy-design.md`

## Global Constraints

- Work only on `experiment/offline-face-clustering` in the existing isolated worktree.
- Preserve the pre-existing uncommitted changes in `Sources/FileRenamer/Resources/Localizable.xcstrings`; inspect and merge new keys instead of replacing that file.
- People classification remains off by default and fully local.
- Never persist source URLs, bookmarks, `RenameItem` IDs, crops, thumbnails, or current-workspace assignments in the People database.
- Never compare embeddings whose complete pipeline contracts differ.
- Automatic results never become training prototypes; only explicit user corrections may write People data.
- People operations never rename, move, delete, reorder, or modify a source file and never enter rename history.
- Existing Rename, filesystem Undo/Redo, order Undo/Redo, image conversion, duplicate review, Sandbox, rollback, and crash-recovery behaviour must remain unchanged.
- Keep Qualcomm MobileFaceNet v0.61.0 and its existing notices as the bundled provider; do not add InsightFace `buffalo_*` or other unapproved weights.
- New Swift files under synchronized Xcode source groups do not require manual `project.pbxproj` file references.
- Run commands from `/Users/keiju/Documents/AICDS-Claude/FileRenamer/.worktrees/offline-face-clustering`.
- Logic test command: `swift run RenameKitTests` and require the final line to report `0 failed`.
- App build command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FileRenamer.xcodeproj -scheme FileRenamer -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath .derivedData CODE_SIGNING_ALLOWED=NO build`.

---

## File structure

### New RenameKit files

- `Sources/RenameKit/FaceGrouping/FacePipelineContract.swift` — complete identity of an embedding pipeline.
- `Sources/RenameKit/FaceGrouping/FacePrototypeSelector.swift` — bounded, deterministic positive/rejection sample selection.
- `Sources/RenameKit/FaceGrouping/PeopleMatcher.swift` — multi-prototype score, ambiguity margin, rejection, and same-photo blocking.
- `Sources/RenameKit/FaceGrouping/PeopleWorkspaceProjection.swift` — pure conversion from face decisions to overview/detail/unconfirmed groups.
- `Sources/RenameKit/FaceGrouping/PeopleAccuracyMetrics.swift` — dependency-free diagnostic confusion counts, precision, recall, and threshold reports.

### New app files

- `Sources/FileRenamer/Support/FaceAnalyzer.swift` — actor for decoding, Vision, five-point alignment, and embeddings.
- `Sources/FileRenamer/Support/PeopleWorkspaceModel.swift` — current-tab lifecycle, revision gating, commands, and Undo registration.
- `Sources/FileRenamer/Support/PeopleAccuracyDiagnostic.swift` — debug-only labelled-folder evaluation using the production pipeline.
- `Sources/FileRenamer/Views/PeopleView.swift` — route between overview, detail, and unconfirmed views.
- `Sources/FileRenamer/Views/PeopleOverviewView.swift` — approved Photos-style circular people grid.
- `Sources/FileRenamer/Views/PersonDetailView.swift` — full-photo gallery and classification actions.
- `Sources/FileRenamer/Views/DiscreteGridColumnControl.swift` — shared 2...8 stepped column control.
- `Sources/FileRenamer/Views/PeopleAccuracyDiagnosticView.swift` — debug-only progress and metric report.

### Existing files to modify

- `Sources/RenameKit/FaceGrouping/FaceEmbedding.swift`
- `Sources/RenameKit/FaceGrouping/FaceGeometry.swift`
- `Sources/RenameKit/FaceGrouping/FaceDensityClusterer.swift`
- `Sources/RenameKit/FaceGrouping/FaceGroupingPreferences.swift`
- `Sources/RenameKit/FaceGrouping/PersonProfile.swift`
- `Sources/RenameKit/FaceGrouping/PersonStore.swift`
- `Sources/RenameKitTests/FaceGroupingTests.swift`
- `Sources/RenameKitTests/main.swift`
- `Sources/FileRenamer/Support/FaceAligner.swift`
- `Sources/FileRenamer/Support/MobileFaceNetEmbedder.swift`
- `Sources/FileRenamer/Support/OfflineFaceClassifier.swift`
- `Sources/FileRenamer/AppModel.swift`
- `Sources/FileRenamer/FileRenamerApp.swift`
- `Sources/FileRenamer/Support/Localization.swift`
- `Sources/FileRenamer/Views/ContentView.swift`
- `Sources/FileRenamer/Views/FileGridView.swift`
- `Sources/FileRenamer/Views/FileListView.swift`
- `Sources/FileRenamer/Views/StatusBar.swift`
- `Sources/FileRenamer/Resources/Localizable.xcstrings`
- `PRIVACY.md`
- `README.md`
- `README.en.md`

### File to delete after replacement

- `Sources/FileRenamer/Views/PeopleReviewView.swift`

---

### Task 1: Version the complete embedding pipeline

**Files:**
- Create: `Sources/RenameKit/FaceGrouping/FacePipelineContract.swift`
- Modify: `Sources/RenameKit/FaceGrouping/FaceEmbedding.swift`
- Modify: `Sources/FileRenamer/Support/MobileFaceNetEmbedder.swift`
- Test: `Sources/RenameKitTests/FaceGroupingTests.swift`

**Interfaces:**
- Produces: `FacePipelineContract`, `FaceEmbedding.contract`, `FaceEmbeddingProvider`.
- Consumes: existing `FaceEmbeddingModel` and Core ML `CGImage` input.

- [ ] **Step 1: Add failing contract-compatibility tests**

Append tests that build embeddings with the same model but different alignment or preprocessing versions and assert that `cosineDistance` throws:

```swift
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
try await expectThrows { _ = try lhs.cosineDistance(to: rhs) }
```

- [ ] **Step 2: Run the safety harness and verify the new test fails**

Run: `swift run RenameKitTests`

Expected: compilation fails because `FacePipelineContract` and `FaceEmbedding(contract:values:)` do not exist.

- [ ] **Step 3: Add the contract value and update `FaceEmbedding`**

Implement this public contract and make it the compatibility key:

```swift
public struct FacePipelineContract: Hashable, Codable, Sendable {
    public let embeddingModel: FaceEmbeddingModel
    public let preprocessingVersion: Int
    public let alignmentVersion: Int
    public let distanceMetricVersion: Int

    public init(
        embeddingModel: FaceEmbeddingModel,
        preprocessingVersion: Int,
        alignmentVersion: Int,
        distanceMetricVersion: Int
    ) {
        self.embeddingModel = embeddingModel
        self.preprocessingVersion = preprocessingVersion
        self.alignmentVersion = alignmentVersion
        self.distanceMetricVersion = distanceMetricVersion
    }
}
```

Change `FaceEmbedding` to expose `contract`, retain `model` as a computed compatibility accessor, and compare complete contracts before distance or centroid work:

```swift
public let contract: FacePipelineContract
public var model: FaceEmbeddingModel { contract.embeddingModel }

public init(contract: FacePipelineContract, values: [Float]) throws { /* existing validation */ }
```

Update every existing test call from `FaceEmbedding(model: model, ...)` to a shared test contract. Do not keep a public initializer that silently manufactures a current contract from only a model.

- [ ] **Step 4: Introduce the provider interface and conform MobileFaceNet**

In `MobileFaceNetEmbedder.swift`, define:

```swift
protocol FaceEmbeddingProvider: AnyObject {
    var contract: FacePipelineContract { get }
    var targetSize: Int { get }
    func embedding(for image: CGImage) throws -> FaceEmbedding
}
```

Use this exact bundled contract:

```swift
static let pipelineContract = FacePipelineContract(
    embeddingModel: FaceEmbeddingModel(
        identifier: "qualcomm.mobilefacenet",
        version: "0.61.0",
        dimension: 128
    ),
    preprocessingVersion: 1,
    alignmentVersion: 2,
    distanceMetricVersion: 1
)
```

Return `FaceEmbedding(contract: Self.pipelineContract, values: values)`.

- [ ] **Step 5: Run tests and a Debug build**

Run: `swift run RenameKitTests`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FileRenamer.xcodeproj -scheme FileRenamer -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath .derivedData CODE_SIGNING_ALLOWED=NO build`

Expected: both succeed and the harness ends with `0 failed`.

- [ ] **Step 6: Commit the contract change**

```bash
git add Sources/RenameKit/FaceGrouping/FacePipelineContract.swift Sources/RenameKit/FaceGrouping/FaceEmbedding.swift Sources/RenameKitTests/FaceGroupingTests.swift Sources/FileRenamer/Support/MobileFaceNetEmbedder.swift
git commit -m "Version the face embedding pipeline"
```

---

### Task 2: Replace eye-only alignment with official five-point geometry

**Files:**
- Modify: `Sources/RenameKit/FaceGrouping/FaceGeometry.swift`
- Modify: `Sources/FileRenamer/Support/FaceAligner.swift`
- Test: `Sources/RenameKitTests/FaceGroupingTests.swift`

**Interfaces:**
- Consumes: `FacePipelineContract.alignmentVersion == 2` and Vision landmark points.
- Produces: `FaceFivePointLandmarks`, `FaceSimilarityTransform`, and `FaceAligner.align` results tagged `.fivePoint`, `.eyes`, or `.paddedCrop`.

- [ ] **Step 1: Replace eye-only geometry expectations with five-point reference tests**

Test the exact 112-pixel Qualcomm reference points derived from the reviewed upstream geometry:

```swift
let reference = FaceGeometry.mobileFaceNetReferenceLandmarks(targetSize: 112)
try expect(reference.leftEye.distance(to: CGPoint(x: 44.1964, y: 53.1309)) < 0.001)
try expect(reference.rightEye.distance(to: CGPoint(x: 67.6879, y: 53.0009)) < 0.001)
try expect(reference.nose.distance(to: CGPoint(x: 56.0168, y: 66.4911)) < 0.001)
try expect(reference.leftMouth.distance(to: CGPoint(x: 46.3662, y: 80.2437)) < 0.001)
try expect(reference.rightMouth.distance(to: CGPoint(x: 65.8199, y: 80.1361)) < 0.001)
```

Add a transform test with source points created by scaling the reference by `2` and translating by `(20, 30)`; applying the solved transform must return every target point within one pixel. Add invalid tests for coincident, nonfinite, and left/right-inverted points.

- [ ] **Step 2: Run tests and verify failure**

Run: `swift run RenameKitTests`

Expected: compilation fails because the five-point geometry types and methods do not exist.

- [ ] **Step 3: Implement pure five-point similarity geometry**

Add:

```swift
public struct FaceFivePointLandmarks: Equatable, Sendable {
    public let leftEye: CGPoint
    public let rightEye: CGPoint
    public let nose: CGPoint
    public let leftMouth: CGPoint
    public let rightMouth: CGPoint
    public var points: [CGPoint] { [leftEye, rightEye, nose, leftMouth, rightMouth] }
}

public struct FaceSimilarityTransform: Equatable, Sendable {
    public let affineTransform: CGAffineTransform
}
```

Solve `u = a*x - b*y + tx` and `v = b*x + a*y + ty` using centred source and target points:

```swift
let denominator = centeredSource.reduce(0) { $0 + $1.x * $1.x + $1.y * $1.y }
let a = zip(centeredSource, centeredTarget).reduce(0) {
    $0 + $1.0.x * $1.1.x + $1.0.y * $1.1.y
} / denominator
let b = zip(centeredSource, centeredTarget).reduce(0) {
    $0 + $1.0.x * $1.1.y - $1.0.y * $1.1.x
} / denominator
```

Derive `tx` and `ty` from the centroids and return `CGAffineTransform(a:b:c:d:tx:ty:)` with `c = -b`, `d = a`. Reject invalid geometry before division.

- [ ] **Step 4: Extract all five Vision landmarks and render the canonical crop**

In `FaceAligner`, obtain eye centres, a robust nose centre, and the leftmost/rightmost outer-lip points in oriented-image coordinates. Add:

```swift
enum FaceAlignmentMethod: String, Hashable, Sendable {
    case fivePoint
    case eyes
    case paddedCrop
}
```

Attempt five-point alignment first and render directly into 112 × 112 sRGB. Keep eye-only and padded-crop rendering only as fallback display crops. Reuse one `CIContext` rather than creating a context per face.

- [ ] **Step 5: Run tests and visually inspect a local crop sheet**

Run: `swift run RenameKitTests`

Add a debug-only temporary crop-sheet invocation to the existing local diagnostic, inspect upright faces with both eyes, nose, and mouth inside the 112 × 112 result, then remove the invocation before committing. Do not add personal photos or generated crop sheets to Git.

- [ ] **Step 6: Build and commit**

Run the Debug build command from Global Constraints.

```bash
git add Sources/RenameKit/FaceGrouping/FaceGeometry.swift Sources/RenameKitTests/FaceGroupingTests.swift Sources/FileRenamer/Support/FaceAligner.swift
git commit -m "Align faces with five landmarks"
```

---

### Task 3: Retain every detected face with explicit eligibility

**Files:**
- Create: `Sources/FileRenamer/Support/FaceAnalyzer.swift`
- Modify: `Sources/FileRenamer/Support/OfflineFaceClassifier.swift`
- Modify: `Sources/RenameKit/FaceGrouping/FaceGroupingPreferences.swift`
- Test: `Sources/RenameKitTests/FaceGroupingTests.swift`

**Interfaces:**
- Consumes: `FaceEmbeddingProvider`, `FaceAligner`, security-scoped analysis URLs.
- Produces: `AnalyzedFace`, `FaceEligibilityTier`, `FaceIneligibilityReason`, and per-item diagnostics.

- [ ] **Step 1: Add failing eligibility-policy tests**

Define table-driven tests for these decisions:

```swift
try expectEqual(policy.tier(faceSide: 120, quality: 0.70, hasFivePointAlignment: true), .prototypeEligible)
try expectEqual(policy.tier(faceSide: 50, quality: 0.25, hasFivePointAlignment: true), .classificationEligible)
try expectEqual(policy.tier(faceSide: 39, quality: 0.90, hasFivePointAlignment: true), .displayOnly)
try expectEqual(policy.tier(faceSide: 120, quality: 0.90, hasFivePointAlignment: false), .displayOnly)
```

Use `minimumFaceSide = 40`, classification quality from the selected sensitivity, and prototype requirements of five-point alignment, face side at least `80`, and quality at least `0.45`.

- [ ] **Step 2: Run tests and verify failure**

Run: `swift run RenameKitTests`

Expected: compilation fails because the eligibility types do not exist.

- [ ] **Step 3: Add pure eligibility types and policy**

Add to `FaceGroupingPreferences.swift`:

```swift
public enum FaceEligibilityTier: Int, Codable, Sendable {
    case displayOnly
    case classificationEligible
    case prototypeEligible
}

public enum FaceIneligibilityReason: String, Codable, Sendable {
    case tooSmall, lowCaptureQuality, incompleteLandmarks, alignmentFailed, embeddingFailed
}
```

Implement `FaceEligibilityPolicy.tier(faceSide:quality:hasFivePointAlignment:)` with the exact thresholds from Step 1.

- [ ] **Step 4: Split detection/embedding from matching**

Move image loading, Vision requests, landmark-quality pairing, alignment, and embedding into `actor FaceAnalyzer`. Its public input/output is:

```swift
struct FaceAnalysisCandidate: Sendable {
    let itemID: UUID
    let analysisURL: URL
}

struct AnalyzedFace: Identifiable, Sendable {
    let id: FaceDescriptorID
    let normalizedBoundingBox: CGRect
    let captureQuality: Float?
    let alignmentMethod: FaceAlignmentMethod?
    let eligibility: FaceEligibilityTier
    let ineligibilityReason: FaceIneligibilityReason?
    let embedding: FaceEmbedding?
}

struct FaceAnalysisBatch: Sendable {
    let facesByItemID: [UUID: [AnalyzedFace]]
    let unreadableItemIDs: Set<UUID>
}
```

Open each URL with balanced security-scoped access around resource values and image decoding. Keep display-only faces in the batch even when no embedding is produced.

- [ ] **Step 5: Reduce `OfflineFaceClassifier` to orchestration**

Make it accept a `FaceAnalysisBatch` plus stored people and call pure matching/clustering introduced in later tasks. Until Task 5, return every face as unconfirmed and keep the current clusterer behind a small adapter so the branch builds.

- [ ] **Step 6: Run tests, build, and commit**

Run `swift run RenameKitTests`, then the Debug build command.

```bash
git add Sources/RenameKit/FaceGrouping/FaceGroupingPreferences.swift Sources/RenameKitTests/FaceGroupingTests.swift Sources/FileRenamer/Support/FaceAnalyzer.swift Sources/FileRenamer/Support/OfflineFaceClassifier.swift
git commit -m "Retain faces with explicit eligibility"
```

---

### Task 4: Store multiple positive and rejection prototypes safely

**Files:**
- Create: `Sources/RenameKit/FaceGrouping/FacePrototypeSelector.swift`
- Modify: `Sources/RenameKit/FaceGrouping/PersonProfile.swift`
- Modify: `Sources/RenameKit/FaceGrouping/PersonStore.swift`
- Test: `Sources/RenameKitTests/FaceGroupingTests.swift`

**Interfaces:**
- Consumes: `FaceEmbedding` with a complete pipeline contract.
- Produces: `PersonEmbeddingSample`, revised `PersonProfileSnapshot`, atomic `PersonStoreSnapshot`, and store mutation methods.

- [ ] **Step 1: Add failing deterministic sample-selection tests**

Test a maximum of 12 positives, 24 rejections, near-duplicate suppression at cosine distance `0.02`, and deterministic farthest-point retention:

```swift
let selected = try FacePrototypeSelector.select(
    existing: existing,
    adding: candidates,
    limit: 12,
    nearDuplicateDistance: 0.02
)
try expectEqual(selected.count, 12)
try expectEqual(selected.map(\.id), selected.sorted(by: FacePrototypeSelector.stableOrder).map(\.id))
```

Add persistence tests asserting that compatible positives and rejections survive a new in-memory `PersonStore`, while an old profile with no positive relationship reports `isLegacyOnly == true` and retains its display name.

- [ ] **Step 2: Run tests and verify failure**

Run: `swift run RenameKitTests`

Expected: compilation fails for the new sample and store APIs.

- [ ] **Step 3: Add additive SwiftData records without deleting legacy columns**

Keep all current required `PersonProfile` centroid columns for lightweight migration. Add defaulted relationships and a schema marker:

```swift
@Model public final class PersonEmbeddingRecord {
    @Attribute(.unique) public var id: UUID
    public var kindRawValue: String
    public var embeddingData: Data
    public var embeddingModelIdentifier: String
    public var embeddingModelVersion: String
    public var embeddingDimension: Int
    public var preprocessingVersion: Int
    public var alignmentVersion: Int
    public var distanceMetricVersion: Int
    public var captureQuality: Float?
    public var createdAt: Date
}
```

Add `[PersonEmbeddingRecord]` positive and rejection relationships to `PersonProfile` with cascade deletion, and `schemaVersion` defaulting to `1` for existing rows. Include both model types in the local and test `Schema` values. New profiles copy the first positive into the legacy centroid fields only to satisfy the old nonoptional store layout; v2 matching never reads those columns.

- [ ] **Step 4: Implement bounded selection and immutable snapshots**

Use these public value types:

```swift
public enum PersonEmbeddingKind: String, Codable, Sendable { case positive, rejection }

public struct PersonEmbeddingSample: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let embedding: FaceEmbedding
    public let captureQuality: Float?
    public let createdAt: Date
}

public struct PersonProfileSnapshot: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let displayName: String
    public let positives: [PersonEmbeddingSample]
    public let rejections: [PersonEmbeddingSample]
    public let isLegacyOnly: Bool
    public let createdAt: Date
    public let updatedAt: Date
}
```

Implement farthest-point selection starting with the stable earliest sample, repeatedly adding the candidate whose minimum distance to selected samples is greatest, with UUID as the tie-breaker.

- [ ] **Step 5: Replace centroid APIs with atomic People operations**

Add exact store methods:

```swift
func createPerson(displayName: String, prototype: PersonEmbeddingSample, now: Date = Date()) throws -> PersonProfileSnapshot
func addPrototype(personID: UUID, sample: PersonEmbeddingSample, now: Date = Date()) throws -> PersonProfileSnapshot
func addRejection(personID: UUID, sample: PersonEmbeddingSample, now: Date = Date()) throws -> PersonProfileSnapshot
func renamePerson(id: UUID, displayName: String, now: Date = Date()) throws -> PersonProfileSnapshot
func mergePeople(sourceIDs: Set<UUID>, destinationID: UUID, now: Date = Date()) throws -> PersonProfileSnapshot
func snapshot() throws -> PersonStoreSnapshot
func restore(_ snapshot: PersonStoreSnapshot) throws
```

Every mutation performs one `context.save()` after all validation. On failure call `context.rollback()` and rethrow. `people()` ignores legacy centroid columns for matching and returns `isLegacyOnly` when positives are empty.

- [ ] **Step 6: Run tests twice to verify persistence and determinism**

Run: `swift run RenameKitTests && swift run RenameKitTests`

Expected: both runs end with `0 failed`.

- [ ] **Step 7: Commit the v2 store**

```bash
git add Sources/RenameKit/FaceGrouping/FacePrototypeSelector.swift Sources/RenameKit/FaceGrouping/PersonProfile.swift Sources/RenameKit/FaceGrouping/PersonStore.swift Sources/RenameKitTests/FaceGroupingTests.swift
git commit -m "Store versioned person prototypes"
```

---

### Task 5: Add conservative known-person decisions and cannot-link clustering

**Files:**
- Create: `Sources/RenameKit/FaceGrouping/PeopleMatcher.swift`
- Modify: `Sources/RenameKit/FaceGrouping/FaceDensityClusterer.swift`
- Modify: `Sources/RenameKit/FaceGrouping/FaceGroupingPreferences.swift`
- Modify: `Sources/FileRenamer/Support/OfflineFaceClassifier.swift`
- Test: `Sources/RenameKitTests/FaceGroupingTests.swift`

**Interfaces:**
- Consumes: `PersonProfileSnapshot`, eligible embeddings, sensitivity policy, and blocked person/pair sets.
- Produces: `PeopleMatchDecision`, named assignments, unnamed clusters, and unconfirmed faces.

- [ ] **Step 1: Add failing matching-decision tests**

Cover accepted, ambiguous, rejected, incompatible, and blocked cases. Use the mean of the nearest two positive distances, or the single distance when only one compatible prototype exists:

```swift
let decision = try PeopleMatcher(policy: .standard).decide(
    embedding: query,
    people: [best, runnerUp],
    blockedPersonIDs: []
)
try expectEqual(decision, .accepted(personID: best.id, score: expectedScore))
```

Add a runner-up within the standard ambiguity margin `0.08` and expect `.ambiguous`. Add a close rejection embedding and expect `.unconfirmed`. Add a compatible best person to `blockedPersonIDs` and verify it cannot be accepted.

- [ ] **Step 2: Add failing cannot-link cluster tests**

Create two close faces from the same `itemID`, a third face from another item, and assert the two same-photo faces never share one cluster when passed as a cannot-link pair:

```swift
let result = FaceDensityClusterer().cluster(
    ids: ids,
    epsilon: 0.42,
    minimumPoints: 2,
    distances: distances,
    cannotLink: [FaceDescriptorPair(ids[0], ids[1])]
)
try expect(!result.clusters.contains { Set($0).isSuperset(of: [ids[0], ids[1]]) })
```

- [ ] **Step 3: Run tests and verify failure**

Run: `swift run RenameKitTests`

Expected: compilation fails for `PeopleMatcher` and the `cannotLink` argument.

- [ ] **Step 4: Implement the exact policy and decision rules**

Extend `FaceGroupingPolicy` with `knownPersonAmbiguityMargin` and `rejectionMaximumDistance`. Keep the existing acceptance and cluster distances, and use margins `0.10`, `0.08`, `0.06` for strict, standard, broad. Use rejection distance `0.24` for all presets until the diagnostic provides evidence for a change.

Define:

```swift
public enum PeopleMatchDecision: Equatable, Sendable {
    case accepted(personID: UUID, score: Float)
    case ambiguous(candidates: [PeopleMatchCandidate])
    case unconfirmed
}
```

Sort candidates by score then UUID. Accept only when the best score is within the preset threshold, the second-best gap is at least the ambiguity margin, no compatible rejection is within `0.24`, and the person is not blocked for the source photo.

- [ ] **Step 5: Enforce cannot-link inside deterministic clustering**

Before adding a candidate to a cluster, reject that addition when any existing cluster member forms a pair in `cannotLink`. Keep rejected candidates available for later clusters or the outlier result. Preserve stable input order and existing missing/nonfinite distance behaviour.

- [ ] **Step 6: Wire pure decisions into `OfflineFaceClassifier`**

Process faces in item and face-index order. Track accepted person IDs per item and pass them as `blockedPersonIDs`. Cluster only `.classificationEligible` or `.prototypeEligible` unknown faces. Return:

```swift
struct OfflineFaceClassificationResult: Sendable {
    let facesByItemID: [UUID: [ClassifiedFace]]
    let namedAssignments: [UUID: [FaceDescriptorID]]
    let unknownClusters: [FaceCandidateCluster]
    let unconfirmedFaceIDs: [FaceDescriptorID]
    let unreadableItemIDs: Set<UUID>
}
```

Include display-only, ambiguous, singleton, and outlier IDs in `unconfirmedFaceIDs`.

- [ ] **Step 7: Run tests, build, and commit**

Run the safety harness and Debug build.

```bash
git add Sources/RenameKit/FaceGrouping/PeopleMatcher.swift Sources/RenameKit/FaceGrouping/FaceDensityClusterer.swift Sources/RenameKit/FaceGrouping/FaceGroupingPreferences.swift Sources/RenameKitTests/FaceGroupingTests.swift Sources/FileRenamer/Support/OfflineFaceClassifier.swift
git commit -m "Classify people conservatively"
```

---

### Task 6: Build a current-tab People workspace with stale-result protection

**Files:**
- Create: `Sources/RenameKit/FaceGrouping/PeopleWorkspaceProjection.swift`
- Create: `Sources/FileRenamer/Support/PeopleWorkspaceModel.swift`
- Modify: `Sources/FileRenamer/AppModel.swift`
- Test: `Sources/RenameKitTests/FaceGroupingTests.swift`

**Interfaces:**
- Consumes: current ordered items, `FaceAnalyzer`, `OfflineFaceClassifier`, `PersonStore`, and preferences.
- Produces: observable current-tab state, overview groups, detail item IDs, unconfirmed entries, and progress.

- [ ] **Step 1: Add failing pure projection tests**

Create named, unnamed, ambiguous, display-only, singleton, and outlier records. Assert that named and multi-face unnamed groups appear in overview order and every remaining face appears in `unconfirmed`:

```swift
let projection = PeopleWorkspaceProjection.make(
    orderedItemIDs: itemIDs,
    result: result,
    people: people
)
try expectEqual(projection.groups.map(\.id), expectedGroupIDs)
try expectEqual(Set(projection.unconfirmed.map(\.faceID)), expectedUnconfirmedIDs)
```

Also assert that a photo with two people appears in both groups and that reordering changes presentation only.

- [ ] **Step 2: Run tests and verify failure**

Run: `swift run RenameKitTests`

Expected: compilation fails because `PeopleWorkspaceProjection` does not exist.

- [ ] **Step 3: Implement immutable projection values**

Add:

```swift
public enum PeopleGroupID: Hashable, Codable, Sendable {
    case person(UUID)
    case candidate(String)
}

public struct PeopleGroupProjection: Identifiable, Hashable, Sendable {
    public let id: PeopleGroupID
    public let displayName: String?
    public let faceIDs: [FaceDescriptorID]
    public let itemIDs: [UUID]
    public let representativeFaceID: FaceDescriptorID
}

public struct PeopleWorkspaceProjection: Equatable, Sendable {
    public let groups: [PeopleGroupProjection]
    public let unconfirmed: [UnconfirmedFaceProjection]
}
```

Deduplicate `itemIDs` while preserving imported order.

- [ ] **Step 4: Add `PeopleWorkspaceModel` and one revision-owned task**

Use:

```swift
@MainActor
final class PeopleWorkspaceModel: ObservableObject {
    @Published private(set) var projection = PeopleWorkspaceProjection.empty
    @Published private(set) var isAnalyzing = false
    @Published private(set) var progress = PeopleAnalysisProgress.zero
    @Published private(set) var errorMessage: String?
    @Published var route: PeopleRoute = .overview

    func schedule(items: [RenameItem], sensitivity: FaceGroupingSensitivity, enabled: Bool)
    func reclassifyUsingCachedEmbeddings()
    func clear(cancelTask: Bool = true)
}
```

Increment `revision` on schedule/clear, cancel the previous task, snapshot item IDs and URLs, and publish only when the captured revision still matches. Publish a complete projection atomically; progress may update per completed item. Keep all Vision/Core ML calls inside the analyzer actor.

- [ ] **Step 5: Replace AppModel's scattered People state with the workspace**

Add `let peopleWorkspace: PeopleWorkspaceModel` to `AppModel`, initialized with the shared `PersonStore`. Replace `peopleReview`, `peopleReviewGroups`, direct classification task/revision/result properties, and computed badges with forwarding methods that read the workspace projection. Keep temporary forwarding accessors only until Task 8 removes old views.

Call `schedule` at the existing import/content-change points and call cached reclassification for sensitivity or store changes. File reordering must update projection order without rerunning image analysis.

- [ ] **Step 6: Run tests, build, and commit**

Run the harness and Debug build.

```bash
git add Sources/RenameKit/FaceGrouping/PeopleWorkspaceProjection.swift Sources/RenameKitTests/FaceGroupingTests.swift Sources/FileRenamer/Support/PeopleWorkspaceModel.swift Sources/FileRenamer/AppModel.swift
git commit -m "Add a current-tab People workspace"
```

---

### Task 7: Implement atomic correction commands and People Undo

**Files:**
- Modify: `Sources/RenameKit/FaceGrouping/PersonStore.swift`
- Modify: `Sources/FileRenamer/Support/PeopleWorkspaceModel.swift`
- Modify: `Sources/FileRenamer/AppModel.swift`
- Modify: `Sources/FileRenamer/FileRenamerApp.swift`
- Test: `Sources/RenameKitTests/FaceGroupingTests.swift`

**Interfaces:**
- Consumes: selected face IDs, eligible embeddings, `PersonStoreSnapshot`, and the window `UndoManager`.
- Produces: name, reject, reassign, split, merge commands with inverse state and separate menu availability.

- [ ] **Step 1: Add failing store-operation round-trip tests**

For each operation, capture `before`, perform it, restore `before`, and assert exact equality of names, positive IDs, rejection IDs, and timestamps. Include a forced incompatible-contract failure and verify the context remains equal to `before`.

```swift
let before = try store.snapshot()
_ = try store.mergePeople(sourceIDs: [source.id], destinationID: destination.id)
try store.restore(before)
try expectEqual(try store.snapshot(), before)
```

- [ ] **Step 2: Run tests and verify the new cases fail**

Run: `swift run RenameKitTests`

Expected: one or more new operations or exact snapshot restoration are missing.

- [ ] **Step 3: Complete atomic store operations**

Keep workspace-only assignment changes in `PeopleWorkspaceModel`. Add these exact persistent `PersonStore` operations: `renamePerson(id:name:)`, `mergePeople(sourceIDs:destinationID:)`, `addPositivePrototype(_:to:)`, `addRejectionPrototype(_:to:)`, `snapshot()`, and `restore(_:)`. A split or reassignment writes only the explicitly corrected eligible face as a positive prototype for the destination and, when moving away from a previously confirmed person, as a rejection prototype for that source person; it never persists the transient workspace assignment itself. Ensure every persistent command saves once and restores its pre-command snapshot once on failure.

- [ ] **Step 4: Register inverse operations with the attached UndoManager**

`PeopleWorkspaceModel` receives the current window manager from `PeopleView`:

```swift
func attachUndoManager(_ undoManager: UndoManager?)
func perform(_ command: PeopleEditCommand)
func undoPeopleEdit()
func redoPeopleEdit()
var canUndoPeopleEdit: Bool { undoManager?.canUndo == true }
var canRedoPeopleEdit: Bool { undoManager?.canRedo == true }
```

Before a command, capture a `PersonStoreSnapshot` and current assignment override map. Register an inverse closure with `registerUndo(withTarget:)`, restore both snapshots in the closure, rescan cached embeddings, and register the reciprocal redo. Set action names such as `人物を統合` and `人物を分離`.

- [ ] **Step 5: Route Command-Z by active context**

Expose People undo/redo availability through `AppModel` and mirror it in `WorkspaceModel`. In `CommandGroup(replacing: .undoRedo)`, use this priority:

```swift
if workspace.isRuleTextEditing || UndoCommandRouter.hasNativeTextEditorFocus {
    UndoCommandRouter.performNativeUndo()
} else if workspace.activeModel.viewMode == .people,
          workspace.canUndoPeopleEdit {
    workspace.activeModel.peopleWorkspace.undoPeopleEdit()
} else {
    workspace.activeModel.undoOrderChange()
}
```

Apply the matching priority to redo. Keep filesystem Undo on Option-Command-Z.

- [ ] **Step 6: Run tests and build**

Run the harness and Debug build. In a local debug session, perform a People rename, merge, and split; verify Command-Z/Shift-Command-Z affect People data while People mode is active and ordering when List/Grid is active.

- [ ] **Step 7: Commit People correction and Undo**

```bash
git add Sources/RenameKit/FaceGrouping/PersonStore.swift Sources/RenameKitTests/FaceGroupingTests.swift Sources/FileRenamer/Support/PeopleWorkspaceModel.swift Sources/FileRenamer/AppModel.swift Sources/FileRenamer/FileRenamerApp.swift
git commit -m "Make People corrections reversible"
```

---

### Task 8: Replace the review sheet with the Photos-style People mode

**Files:**
- Create: `Sources/FileRenamer/Views/DiscreteGridColumnControl.swift`
- Create: `Sources/FileRenamer/Views/PeopleView.swift`
- Create: `Sources/FileRenamer/Views/PeopleOverviewView.swift`
- Create: `Sources/FileRenamer/Views/PersonDetailView.swift`
- Modify: `Sources/FileRenamer/Views/FileGridView.swift`
- Modify: `Sources/FileRenamer/Views/FileListView.swift`
- Modify: `Sources/FileRenamer/Views/ContentView.swift`
- Modify: `Sources/FileRenamer/Views/StatusBar.swift`
- Modify: `Sources/FileRenamer/AppModel.swift`
- Modify: `Sources/FileRenamer/Support/Localization.swift`
- Delete: `Sources/FileRenamer/Views/PeopleReviewView.swift`

**Interfaces:**
- Consumes: `PeopleWorkspaceModel.projection`, routes, current `AppModel.items`, selection, thumbnails, Quick Look, and edit commands.
- Produces: third view mode, overview/detail/unconfirmed navigation, multiple selection, classification menus, and shared grid-column control.

- [ ] **Step 1: Add `.people` to the display-mode contract and build to expose exhaustive switches**

Change:

```swift
enum ViewMode: String, CaseIterable, Identifiable {
    case list, grid, people
}
```

Use `person.2` as the toolbar symbol and localize `view.people` to `人物` / `People`. Run the Debug build and use every exhaustiveness error as the checklist for adding People behaviour; do not silence switches with `default`.

- [ ] **Step 2: Extract the exact stepped column control**

Move FileGridView's 2...8 slider into `DiscreteGridColumnControl`:

```swift
struct DiscreteGridColumnControl: View {
    @Binding var columnCount: Int
    let range: ClosedRange<Int>
}
```

Keep `Slider(..., step: 1)`, tick labels, accessibility value, and integer clamping. Replace FileGridView's private copy and confirm its existing layout is unchanged.

- [ ] **Step 3: Implement People overview**

Render `projection.groups` as circular `FaceCropView` tiles with name/placeholder and unique item count. Render one explicit `未確認` tile whenever `projection.unconfirmed` is nonempty. Behaviour:

- normal click opens detail;
- Command-click toggles group selection without opening;
- selected two-or-more groups enable `同じ人物として統合…`;
- merge and split show confirmation dialogs;
- no file operation appears in the primary People context menu.

- [ ] **Step 4: Implement person detail and unconfirmed detail**

Use full-photo thumbnails, current import order, shared `AppModel.selection`, and the extracted column control. Add context commands:

```swift
Button("この人ではない") { workspace.reject(selectedFaceIDs, from: groupID) }
Button("別の人物へ移動…") { pendingMove = selectedFaceIDs }
Button("新しい人物として分離…") { pendingSplit = selectedFaceIDs }
```

Double-click and force-click set `model.quickLookURL` from the selected item's original URL. When the same photo has several faces, pass only the face IDs belonging to the open group. Delete-key behaviour remains “remove files from list” only when the user invokes the existing file action explicitly; it is never overloaded as a face rejection.

- [ ] **Step 5: Integrate the route into ContentView and toolbar**

Add `case .people: PeopleView(workspace: model.peopleWorkspace)` to `fileArea`. Remove `.sheet(item: $model.peopleReview)`. Attach the environment `UndoManager` in `PeopleView.onAppear` and detach on disappear. Update toolbar help from `リスト / グリッド` to `リスト / グリッド / 人物`.

- [ ] **Step 6: Simplify list/grid People badges and status**

Badge click switches `model.viewMode = .people` and opens the relevant group instead of opening a sheet. Status count does the same. Show progressive analysis status without shifting Rename/Undo controls: reserve the existing status slot width and replace its contents in place.

- [ ] **Step 7: Remove obsolete review state and file**

Delete `PeopleReview`, `PendingPersonRegistration`, `PeopleReviewGroup`, review-sheet methods, and `PeopleReviewView.swift` only after all equivalent People commands compile. Keep the first-save biometric confirmation and move it to the relevant People naming action.

- [ ] **Step 8: Build and perform the UI acceptance pass**

Run the Debug build. In Xcode, verify:

- List/Grid/People switching at narrow and wide window sizes;
- circular overview, unconfirmed tile, detail/back flow;
- 2...8 columns remain discrete in Gallery and People detail;
- sort/reorder does not swap thumbnails or face groups;
- Command/Shift multiple selection;
- correct independent preview on double-click and force-click;
- clicking elsewhere does not unexpectedly close or reset People route;
- Rename, Undo, and bottom controls do not move during analysis.

- [ ] **Step 9: Commit the People UI**

```bash
git add Sources/FileRenamer/Views/DiscreteGridColumnControl.swift Sources/FileRenamer/Views/PeopleView.swift Sources/FileRenamer/Views/PeopleOverviewView.swift Sources/FileRenamer/Views/PersonDetailView.swift Sources/FileRenamer/Views/FileGridView.swift Sources/FileRenamer/Views/FileListView.swift Sources/FileRenamer/Views/ContentView.swift Sources/FileRenamer/Views/StatusBar.swift Sources/FileRenamer/AppModel.swift Sources/FileRenamer/Support/Localization.swift Sources/FileRenamer/Views/PeopleReviewView.swift
git commit -m "Add the Photos-style People view"
```

---

### Task 9: Finish settings, migration messaging, localization, and privacy copy

**Files:**
- Modify: `Sources/FileRenamer/FileRenamerApp.swift`
- Modify: `Sources/FileRenamer/Support/Localization.swift`
- Modify: `Sources/FileRenamer/Resources/Localizable.xcstrings`
- Modify: `PRIVACY.md`
- Modify: `README.md`
- Modify: `README.en.md`
- Test: `Sources/RenameKitTests/SafetyTests.swift`

**Interfaces:**
- Consumes: store statistics, legacy-only status, feature preferences, and current localized bundle.
- Produces: clear local-only settings, legacy re-registration message, deletion confirmation, and matching public documentation.

- [ ] **Step 1: Inspect and preserve the dirty string catalogue before editing**

Run:

```bash
git diff -- Sources/FileRenamer/Resources/Localizable.xcstrings
```

Record the pre-existing changed keys. Add People keys by editing the current file in place; never regenerate or replace the catalogue wholesale.

- [ ] **Step 2: Add failing localization-key coverage**

Extend the existing localization safety checks with the exact keys used by the new views, including:

```swift
"view.people",
"people.title",
"people.unconfirmed",
"people.notThisPerson",
"people.moveToPerson",
"people.splitPerson",
"people.mergePeople",
"people.legacyNeedsConfirmation",
"people.deleteAll"
```

Require nonempty Japanese and English values.

- [ ] **Step 3: Run tests and verify missing-key failure**

Run: `swift run RenameKitTests`

Expected: localization tests report the new missing keys.

- [ ] **Step 4: Update Settings without raw thresholds**

Keep the default-off toggle and strict/standard/broad segmented picker. Add saved-person and legacy-profile counts from `PersonStore.statistics()`. Show `再確認が必要な人物: N` when legacy-only profiles exist. Keep the confirmed delete-all action and explicitly state that it removes names, positive embeddings, and rejection embeddings but never photos.

- [ ] **Step 5: Update Japanese and English product/privacy copy**

Add concise strings that say:

- processing occurs only on this Mac;
- current imported files are shown in People view;
- confirmed names and biometric feature vectors persist locally;
- paths and face images are not saved;
- manual corrections may save positive and rejection feature vectors;
- disabling analysis does not delete saved People data;
- the Settings delete action removes all saved People data.

Update README wording so it does not claim only a single representative centroid is stored and does not promise Apple Photos accuracy.

- [ ] **Step 6: Run localization tests, diff checks, and commit only intended changes**

Run:

```bash
swift run RenameKitTests
git diff --check
git diff -- Sources/FileRenamer/Resources/Localizable.xcstrings
```

Verify the original dirty localization edits are still present and correct.

```bash
git add Sources/FileRenamer/FileRenamerApp.swift Sources/FileRenamer/Support/Localization.swift Sources/FileRenamer/Resources/Localizable.xcstrings Sources/RenameKitTests/SafetyTests.swift PRIVACY.md README.md README.en.md
git commit -m "Document local People classification"
```

---

### Task 10: Add an opt-in local accuracy diagnostic and release gate

**Files:**
- Create: `Sources/RenameKit/FaceGrouping/PeopleAccuracyMetrics.swift`
- Create: `Sources/FileRenamer/Support/PeopleAccuracyDiagnostic.swift`
- Create: `Sources/FileRenamer/Views/PeopleAccuracyDiagnosticView.swift`
- Modify: `Sources/FileRenamer/FileRenamerApp.swift`
- Modify: `Sources/RenameKitTests/FaceGroupingTests.swift`

**Interfaces:**
- Consumes: a user-selected root whose immediate subfolders are person labels, the production `FaceAnalyzer`, and production `PeopleMatcher` policy.
- Produces: local-only `PeopleAccuracyReport` with precision, recall, false matches, ambiguous count, unreadable count, and threshold table.

- [ ] **Step 1: Add failing metric tests with a fixed score table**

Use labelled pairs and expected confusion counts:

```swift
let report = PeopleAccuracyMetrics.evaluate(
    pairs: [
        .init(expectedSame: true, distance: 0.10),
        .init(expectedSame: true, distance: 0.45),
        .init(expectedSame: false, distance: 0.20),
        .init(expectedSame: false, distance: 0.80)
    ],
    threshold: 0.40
)
try expectEqual(report.truePositive, 1)
try expectEqual(report.falseNegative, 1)
try expectEqual(report.falsePositive, 1)
try expectEqual(report.trueNegative, 1)
```

Test division-by-zero cases and deterministic threshold ordering.

- [ ] **Step 2: Run tests and verify failure**

Run: `swift run RenameKitTests`

Expected: compilation fails because the metric types are missing.

- [ ] **Step 3: Implement pure report metrics in RenameKit**

Create `Sources/RenameKit/FaceGrouping/PeopleAccuracyMetrics.swift`. Define `PeopleAccuracyPair`, `PeopleAccuracyCounts`, `PeopleThresholdReport`, and `PeopleAccuracyMetrics.evaluate(pairs:threshold:)`. Compute precision as `TP / (TP + FP)` and recall as `TP / (TP + FN)`, returning `nil` when the denominator is zero rather than NaN. Sort multi-threshold reports by ascending threshold before returning them.

- [ ] **Step 4: Implement the debug-only labelled-folder runner**

Under `#if DEBUG`, add a Settings button `人物分類のローカル診断…`. The panel selects one root; each immediate subfolder name is a label; supported images below each label are sampled through the production analyzer. Do not persist selected paths or reports. Generate same-person pairs within a folder and deterministic different-person pairs across folders, then evaluate each preset plus a threshold table.

The diagnostic view shows progress, cancellation, counts, precision, recall, false matches, unreadable images, and an optional `レポートを書き出す…` save panel. Exported reports contain labels and aggregate metrics but no source paths or embeddings.

- [ ] **Step 5: Verify the 99% precision gate behaviour**

When the selected evaluation has at least two people and both positive and negative pairs, mark a preset `自動分類の基準を満たす` only if precision is at least `0.99`. A failed gate does not change user preferences automatically and does not remove manual People grouping.

- [ ] **Step 6: Run tests, build, and commit**

Run the harness and Debug build.

```bash
git add Sources/RenameKit/FaceGrouping/PeopleAccuracyMetrics.swift Sources/FileRenamer/Support/PeopleAccuracyDiagnostic.swift Sources/FileRenamer/Views/PeopleAccuracyDiagnosticView.swift Sources/FileRenamer/FileRenamerApp.swift Sources/RenameKitTests/FaceGroupingTests.swift
git commit -m "Add a local People accuracy diagnostic"
```

---

### Task 11: Final integration, scale, and regression verification

**Files:**
- Modify as failures require: files already listed in Tasks 1–10 only.
- Verify: `Sources/FileRenamer/Resources/Models/MobileFaceNet.mlpackage/**`
- Verify: `Sources/FileRenamer/Resources/Models/MobileFaceNet-METADATA.json`
- Verify: `THIRD_PARTY_NOTICES.md`

**Interfaces:**
- Consumes: the complete feature.
- Produces: release evidence and an explicit experimental/non-experimental decision.

- [ ] **Step 1: Run the full safety harness twice**

Run: `swift run RenameKitTests && swift run RenameKitTests`

Expected: both runs end with `0 failed`; no nondeterministic clustering or persistence-order failures.

- [ ] **Step 2: Run Debug and Release builds**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FileRenamer.xcodeproj -scheme FileRenamer -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath .derivedData CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FileRenamer.xcodeproj -scheme FileRenamer -configuration Release -destination 'generic/platform=macOS' -derivedDataPath .derivedData-release CODE_SIGNING_ALLOWED=NO build
```

Expected: `BUILD SUCCEEDED` for both.

- [ ] **Step 3: Run Xcode Analyze and universal-architecture verification**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FileRenamer.xcodeproj -scheme FileRenamer -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath .derivedData-analyze CODE_SIGNING_ALLOWED=NO analyze
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FileRenamer.xcodeproj -scheme FileRenamer -configuration Release -destination 'generic/platform=macOS' -derivedDataPath .derivedData-universal CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
lipo -info .derivedData-universal/Build/Products/Release/FileRenamer.app/Contents/MacOS/FileRenamer
```

Expected: Analyze succeeds and `lipo` lists both `x86_64` and `arm64`.

- [ ] **Step 4: Exercise scale and cancellation**

Use generated descriptor values, not generated face images, to time projection, matching, and clustering at 200 and 1,000 faces. Import a consented local folder with at least 200 photos, switch folders during analysis, and confirm within one image boundary that the old revision stops publishing. Confirm no `Publishing changes from within view updates` warning appears.

- [ ] **Step 5: Perform the manual product regression matrix**

Verify:

- individual-file and folder imports under App Sandbox;
- RAW+JPEG paired items and photos with multiple faces;
- List/Grid selection, reorder, thumbnail identity, and Quick Look;
- People overview/detail/unconfirmed and correction Undo/Redo;
- rename confirmation, rename execution, filesystem Undo/Redo, rollback, and crash recovery;
- image format conversion, long-edge resize, original protection, and JPEG quality;
- similar-image review and trash operations;
- switching tabs while different People analyses run;
- disabling People analysis cancels work but leaves saved names intact;
- delete-all People data removes prototypes/rejections without touching files.

- [ ] **Step 6: Inspect the built app and repository for model/privacy integrity**

Run:

```bash
find .derivedData-release/Build/Products/Release/FileRenamer.app -iname '*MobileFaceNet*' -o -iname '*PrivacyInfo*' -o -iname '*LICENSE*'
git grep -n -i 'buffalo\|insightface' -- ':!docs/superpowers/**'
git diff --check
git status --short
```

Expected: the reviewed MobileFaceNet artifact, privacy manifest, and notices are present; no restricted weight is added; diff check is clean; unrelated pre-existing changes remain identifiable.

- [ ] **Step 7: Run the consented local diagnostic and decide the feature label**

Run the debug diagnostic on the agreed representative folder. If automatic-assignment precision is below `0.99`, keep `人物候補（実験的）` and automatic naming disabled while retaining manual grouping. If it meets the gate and all safety checks pass, update only the label from `実験的` after recording the aggregate report outside Git.

- [ ] **Step 8: Commit only verification-driven fixes**

If Steps 1–7 expose a failure, fix and commit it in the task that owns the affected literal file paths, then rerun that task's focused test and this final verification matrix. Do not use `git add -A`, do not defer unidentified changes into a catch-all commit, and do not create an empty commit when no source fix was required.

---

## Final handoff checklist

- [ ] All task commits are present on `experiment/offline-face-clustering`.
- [ ] The complete safety harness, Debug, Release, Analyze, and universal build pass.
- [ ] The current working tree contains no accidental `.superpowers/`, personal photos, diagnostic reports, signing secrets, DerivedData, or model downloads.
- [ ] The pre-existing localization edits were preserved and intentionally reconciled.
- [ ] Privacy and README copy match the actual persistence schema and UI.
- [ ] A failed accuracy gate leaves the feature visibly experimental and prevents automatic certainty claims.
- [ ] A passed accuracy gate is supported by a local aggregate report, not intuition.
- [ ] No DMG, signing, notarization, release, merge, or push is performed unless the user separately requests it.
