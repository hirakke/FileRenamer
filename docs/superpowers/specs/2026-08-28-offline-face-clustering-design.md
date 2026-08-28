# Offline Face Clustering — Experimental Design

## Goal

Add an opt-in, fully offline experiment that finds faces in imported photographs,
groups faces that may depict the same person, and lets the user name a confirmed
person group for matching in later sessions. The feature must remain separate from
renaming, duplicate detection, trash, Undo, and image conversion.

This work lives only on `experiment/offline-face-clustering` until its accuracy,
performance, privacy behaviour, and model licensing are reviewed.

## Reference implementations

### UnlikeOtherAI/Faces (MIT)

- Repository: <https://github.com/UnlikeOtherAI/Faces>
- Reviewed revision: `8bd922e2c71b40833b247425abf8aa9566723925`
- Useful design:
  - Vision face detection
  - padded face crop rendered to 112 × 112
  - embedding backend separated from detection
  - L2-normalised embeddings
  - cosine similarity
- Important limitation: the repository does not ship a trained model. Its optional
  InsightFace download path identifies the weights as non-commercial research use.
  FileRenamer must not copy or redistribute those weights.

### mattt/DBSCAN (MIT)

- Repository: <https://github.com/mattt/DBSCAN>
- Reviewed revision: `9e0bac44de48b981fb1afcea1f2d29320e306c1a`
- Useful design:
  - density-based clustering with configurable epsilon and minimum points
  - explicit outliers
  - no need to choose the number of people in advance

The FileRenamer implementation will be written for this codebase rather than adding
a package dependency. The algorithm and terminology are attributed in third-party
notices when implementation begins.

### Qualcomm MobileFaceNet (Apache-2.0 model)

- Model card: <https://huggingface.co/qualcomm/MobileFaceNet>
- Source recipe: <https://github.com/qualcomm/ai-hub-models/tree/v0.61.0/src/qai_hub_models/models/mobile_facenet>
- Reviewed release: `v0.61.0`
- Input: 112 × 112 face image
- Output: 128-dimensional embedding
- Model card license: Apache-2.0

This is the experimental face-specific embedding model. The 128-dimensional output
differs from the proposed 512-dimensional diagram, but embedding size is a model
contract rather than a product requirement. FileRenamer stores the model identifier,
version, and dimension with every confirmed person profile so incompatible model
versions can never be compared silently.

### Additional comparison

- `daduz11/ios-facenet-id` demonstrates Core ML FaceNet embeddings and a classifier,
  but the age of the sample and unclear trained-weight redistribution make it a
  reference only.
- InsightFace `buffalo_*` recognition weights are not approved for redistribution in
  FileRenamer. Converted Core ML files remain derived from those weights.

## Product behaviour

- Setting: “人物候補を分類” in macOS Settings, off by default.
- Processing stays on the Mac. No network request, upload, analytics event, or cloud
  API is introduced.
- Results are described as candidates, never as a guaranteed identity.
- A user can name a candidate group after reviewing it.
- Confirmed names and representative embeddings are available in later sessions.
- It never deletes, excludes, renames, or reorders a file automatically.
- A photograph may belong to more than one person group when it contains multiple
  faces.
- Faces that cannot be grouped remain unlabelled; single-face clusters are not shown.
- Unconfirmed groups and per-photo results remain in memory and are discarded when
  the imported list is cleared or the app exits.
- Only a confirmed person name, a normalised representative embedding, sample count,
  model identity, and timestamps are persisted. Source photos and face crops are not.

## Architecture

### Analysis pipeline

1. `AppModel` creates immutable candidates from the current `RenameItem` snapshot.
2. A dedicated `faceClassificationTask` calls `OfflineFaceClassifier`, an actor.
3. The actor opens each image with security-scoped access, downsamples it through
   ImageIO, applies its orientation, and detects all faces with Vision.
4. Vision landmarks provide eye and face geometry. Face capture quality supplies a
   0...1 quality score. Very small or very low-quality faces remain visible as
   unclassified faces but do not become identity exemplars.
5. `FaceAligner` rotates and scales the eye line into a stable 112 × 112 crop. It
   falls back to a padded crop when landmarks are incomplete.
6. The Qualcomm MobileFaceNet Core ML model produces a 128-dimensional descriptor.
7. The descriptor is L2-normalised defensively and compared with cosine distance.
8. Known-person centroids are matched conservatively first. Remaining descriptors
   are passed to a pure DBSCAN-style `FaceDensityClusterer`.
9. The actor returns stable value types containing group IDs, optional known-person
   IDs, item IDs, face indexes, quality, and normalised bounding boxes.
10. `AppModel` publishes only results belonging to the latest revision.

### Replaceable embedding backend

`FaceEmbeddingBackend` isolates three operations:

- required input size
- descriptor creation from a face crop
- distance between two descriptors

The first implementation uses the Apache-2.0 Qualcomm MobileFaceNet release through
Core ML and follows the input contract used by `Faces` (112 × 112 RGB normalised to
[-1, 1], L2-normalised output). A Vision feature-print backend remains available only
as a developer fallback and is never mixed with MobileFaceNet profiles.

No InsightFace `buffalo_*` model or other restricted weight is bundled in this branch.
The converted Core ML artifact must retain the Qualcomm release identifier, source
URL, checksum, and Apache-2.0 notice.

### Persistent people store

SwiftData uses an app-local `ModelConfiguration`; CloudKit is not enabled.

`PersonProfile` persists:

- UUID and user-entered display name
- L2-normalised centroid encoded as float data
- embedding model identifier, version, and dimension
- confirmed sample count
- creation and modification timestamps

Naming a group averages its eligible descriptors and normalises the result before a
single SwiftData save. Renaming or deleting a person changes only this people store.
It does not rename, move, modify, or bookmark any source file. A Settings action can
delete all saved people data after confirmation.

### Isolation from existing similarity analysis

- `OfflineFaceClassifier` is separate from `SimilarImageDetector`.
- Face and similar-image tasks have separate cancellation, revisions, progress, and
  caches.
- A file fingerprint uses standardised path, size, and modification time so replaced
  files cannot reuse stale results.
- Ordering changes reuse results because all mappings use `RenameItem.id`.
- Imports, list clearing, content changes, and preference changes cancel or rescan.
- At most one face-classification scan is active per tab.

## Clustering

`FaceDensityClusterer` receives opaque face IDs plus an already computed symmetric
distance matrix. This keeps Vision and Core ML out of the clustering tests.

- Minimum cluster size: 2
- Sensitivity presets adjust epsilon only.
- Self-distance is zero.
- Missing or non-finite distances are not neighbours.
- Deterministic traversal preserves imported item order and face order.
- Outliers are returned but not displayed as people groups.

The thresholds are app-level experimental values. They will be intentionally
conservative and documented as needing calibration against a consented evaluation
set before release.

## State and UI

`AppPreferences` gains:

- `classifiesPeople` (default `false`)
- `faceGroupingSensitivity` (default `strict`)

`AppModel` gains:

- `isClassifyingFaces`
- `faceGroups`
- lookup from item ID to group IDs
- a dedicated review-sheet selection
- access to a local `PersonStore`

UI behaviour:

- Settings explains that analysis is local and results are only candidates.
- Status bar reports analysis without blocking rename controls.
- List and grid show a small textual candidate count only when results exist.
- Selecting the badge opens a review sheet with groups in current file order.
- The sheet shows the source photo and face crop context.
- An unknown group offers “誰ですか？” and a plain text field for a name.
- A known group displays its saved name and permits rename or “登録を解除”.
- Removing a registration deletes only the saved profile; it does not delete photos.
- The sheet does not expose file deletion or automatic file operations.

## Error handling

- An unreadable or unsupported image is skipped without cancelling the batch.
- Cancellation is checked between images, faces, and clustering loops.
- Access is started and stopped symmetrically for every URL.
- A missing Vision result produces no group rather than an alert storm.
- Systemic setup errors clear the current experimental result and leave rename state
  untouched.

## Privacy and safety

- The setting is off by default.
- Confirming a name explicitly persists a biometric embedding and name on this Mac.
- The confirmation explains this before the first save.
- Face crops and source paths are never persisted.
- No data leaves the Mac.
- The UI avoids “recognised”, “identified”, or certainty claims.
- Saved profiles are local-only and can be deleted together from Settings.
- Existing original protection, Sandbox bookmarks, Undo, rollback, duplicate review,
  and trash operations are not reused for face classification.

## Testing

Tests are written before production behaviour.

- density cluster formation, chaining, outliers, and deterministic order
- strict/standard/broad threshold mapping
- one photo contributing multiple faces/groups
- L2 normalisation and cosine-distance behaviour for 128-dimensional descriptors
- model ID/version/dimension mismatch rejection
- confirmed-group centroid creation and normalisation
- SwiftData profile save, rename, delete, and local-only configuration
- known profile match followed by DBSCAN of unknown descriptors
- stale revision result rejection
- preference off by default and cancellation when disabled
- cache invalidation after file size or modification change
- no mutation of rename items, ordering, selection, previews, or history
- cancellation and unreadable-image handling
- existing RenameKit safety suite
- Debug and Release macOS builds

Real-person photographs are not committed as fixtures. Vision integration is checked
with locally generated or explicitly consented test material outside the repository;
pure clustering uses deterministic synthetic distance matrices.

## Success criteria for the experiment

- The feature runs without network access.
- More than one face per photo is handled.
- Candidate groups appear without modifying any file or rename rule.
- A reviewed group can be named and matched after recreating the app model.
- Saved profiles never compare across incompatible model versions or dimensions.
- Disabling the setting cancels work and removes results.
- Existing tests remain green and new clustering/state tests pass.
- No restricted or unlicensed model weight enters Git history or the app bundle.
