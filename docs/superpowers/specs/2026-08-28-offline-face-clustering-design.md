# Offline Face Clustering — Experimental Design

## Goal

Add an opt-in, fully offline experiment that finds faces in imported photographs
and groups faces that may depict the same person. The feature must remain separate
from renaming, duplicate detection, trash, Undo, and image conversion.

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
- The feature does not assign names to people in the first experiment.
- It never deletes, excludes, renames, or reorders a file automatically.
- A photograph may belong to more than one person group when it contains multiple
  faces.
- Faces that cannot be grouped remain unlabelled; single-face clusters are not shown.
- Results and face descriptors remain in memory for the first experiment. They are
  discarded when the imported list is cleared or the app exits.

## Architecture

### Analysis pipeline

1. `AppModel` creates immutable candidates from the current `RenameItem` snapshot.
2. A dedicated `faceClassificationTask` calls `OfflineFaceClassifier`, an actor.
3. The actor opens each image with security-scoped access, downsamples it through
   ImageIO, applies its orientation, and detects all faces with Vision.
4. Each bounding box is padded conservatively, clipped to the image, cropped, and
   rendered to the embedding backend’s requested size.
5. The default backend creates a Vision feature print from the face crop. This makes
   the experiment usable without downloading a model.
6. The backend computes pair distances. The classifier does not expose
   `VNFeaturePrintObservation` across actor boundaries.
7. A pure `FaceDensityClusterer` groups descriptors using a DBSCAN-style algorithm.
8. The actor returns stable value types containing group IDs, item IDs, face indexes,
   and normalised bounding boxes.
9. `AppModel` publishes only results belonging to the latest revision.

### Replaceable embedding backend

`FaceEmbeddingBackend` isolates three operations:

- required input size
- descriptor creation from a face crop
- distance between two descriptors

The first implementation uses Vision feature prints. A later Core ML backend can
follow the MobileFaceNet input contract used by `Faces` (112 × 112 RGB normalised to
[-1, 1], L2-normalised output) after a commercially redistributable model is obtained.
No restricted model is bundled in this branch.

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

UI behaviour:

- Settings explains that analysis is local and results are only candidates.
- Status bar reports analysis without blocking rename controls.
- List and grid show a small textual candidate count only when results exist.
- Selecting the badge opens a review sheet with groups in current file order.
- The sheet shows the source photo and face crop context; it does not expose deletion
  or automatic file operations.

## Error handling

- An unreadable or unsupported image is skipped without cancelling the batch.
- Cancellation is checked between images, faces, and clustering loops.
- Access is started and stopped symmetrically for every URL.
- A missing Vision result produces no group rather than an alert storm.
- Systemic setup errors clear the current experimental result and leave rename state
  untouched.

## Privacy and safety

- The setting is off by default.
- No biometric template, crop, person name, or cluster is persisted.
- No data leaves the Mac.
- The UI avoids “recognised”, “identified”, or certainty claims.
- Existing original protection, Sandbox bookmarks, Undo, rollback, duplicate review,
  and trash operations are not reused for face classification.

## Testing

Tests are written before production behaviour.

- density cluster formation, chaining, outliers, and deterministic order
- strict/standard/broad threshold mapping
- one photo contributing multiple faces/groups
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
- Disabling the setting cancels work and removes results.
- Existing tests remain green and new clustering/state tests pass.
- No restricted or unlicensed model weight enters Git history or the app bundle.
