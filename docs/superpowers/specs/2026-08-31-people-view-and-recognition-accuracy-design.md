# People View and Recognition Accuracy — Design

## Status and scope

This design upgrades the experimental offline face-grouping branch into a usable
People view for the files currently loaded in FileRenamer. It supersedes the UI,
alignment, persistence, clustering, and success-criteria sections of
`2026-08-28-offline-face-clustering-design.md`.

This is an architectural change because it alters the face-analysis pipeline, the
saved-person schema, classification feedback, and the main-window navigation. It
does not turn FileRenamer into a persistent photo-library manager.

## Goal

Provide an experience comparable in structure to the People feature in Apple
Photos:

- open a dedicated People display mode from the main window;
- browse the people found in the currently loaded files;
- open a person and see every currently loaded photo containing that person;
- name, merge, split, and correct people;
- reuse confirmed identities in later folders and app sessions;
- improve real-world recognition accuracy without sending photos or biometric data
  off the Mac.

Apple's private models and training system are not available, so exact parity is
not a release claim. The product target is a similarly understandable workflow and
conservative, correctable on-device classification.

## Explicit boundaries

### In scope

- a third main-window display mode named `人物` / `People`;
- five-landmark face alignment compatible with the bundled MobileFaceNet model;
- multiple representative embeddings per named person;
- conservative matching with ambiguity handling;
- unknown clusters, singletons, and outliers visible for review;
- manual assignment, rejection, split, and merge feedback;
- local persistence of names and biometric embeddings only;
- migration of existing experimental person registrations;
- an embedding-provider boundary for a later licensed model replacement;
- automated safety tests and an opt-in local accuracy diagnostic.

### Out of scope

- indexing photos that are not currently loaded;
- persisting source paths, bookmarks, face crops, thumbnails, or photo assignments;
- searching the user's entire photo library;
- cloud sync, account sync, network inference, or analytics;
- automatic file deletion, movement, renaming, exclusion, or reordering based on a
  face result;
- claiming that a candidate is certainly a specific real-world person;
- bundling InsightFace `buffalo_*` or other weights without confirmed redistribution
  and commercial-use rights.

## Reviewed references

### Qualcomm MobileFaceNet v0.61.0

- Recipe: <https://github.com/qualcomm/ai-hub-models/tree/v0.61.0/src/qai_hub_models/models/mobile_facenet>
- Reviewed recipe revision: `5975a79b55b40f5cbc61f3ac5e52abe47d9d8bd5`
- Upstream model revision: `a6cc9032a659b615f477833e1a70b5e7931bcccc`
- Model input: 112 × 112 RGB in `[0, 1]`
- Model output: 128-dimensional embedding
- Model recipe applies horizontal-flip test-time augmentation.
- Official application alignment uses five points in this order: left eye, right
  eye, nose, left mouth corner, right mouth corner.

The current FileRenamer eye-only transform places the eyes differently from the
official five-point reference crop. This input-distribution mismatch must be fixed
before tuning matching thresholds.

### Immich facial-recognition workflow

- Documentation: <https://github.com/immich-app/immich/blob/main/docs/docs/features/facial-recognition.md>

Useful product and clustering concepts are the People overview, person detail,
manual merge/correction, visible unknowns, density-based core points, and
incremental matching against already assigned people. FileRenamer adopts those
concepts without adopting Immich's server architecture or storing a photo library.

### UnlikeOtherAI/Faces

- Repository: <https://github.com/UnlikeOtherAI/Faces>
- Reviewed revision: `8bd922e2c71b40833b247425abf8aa9566723925`

The repository confirms the value of keeping detection, embedding, matching, and
persistence behind separate interfaces. Its model and product scope are not copied.

## Product behaviour

### Persistence boundary

The People view always reflects only the files in the active FileRenamer tab. When
the list is cleared or another folder is opened, the displayed face assignments are
discarded and rebuilt for the new list.

The app persists confirmed person names, representative embeddings, and correction
embeddings locally. This allows a confirmed person to be recognised in a different
folder later. It does not persist which files contained that person.

### Privacy and opt-in

- People classification remains off by default.
- It is enabled from `FileRenamer > 設定` in the macOS application menu.
- The first operation that saves a person explains that a name and biometric
  feature vectors will be stored on this Mac.
- SwiftData CloudKit integration remains disabled.
- Settings retains a confirmed action to delete all saved People data.
- The privacy policy describes local face analysis, manual classification
  correction, and deletion of saved People data.

## Main-window People experience

### Entry point

The existing List and Gallery display switch gains a third People mode. It is an
alternate projection of the same `RenameItem` collection, not a new window and not
a modal review sheet. The old `PeopleReviewView` sheet is removed after equivalent
actions exist in the People mode.

### People overview

The overview follows the approved Photos-style layout:

- responsive grid of circular representative faces;
- person name or a stable session-local placeholder such as `人物1`;
- count of currently loaded photos containing that person;
- named and unnamed groups in the same visual language;
- an explicit `未確認` tile containing singletons, DBSCAN outliers, ambiguous
  matches, low-quality faces, and faces without eligible alignment.

The representative face is generated on demand from the current file. It is never
saved to the People database.

### Person detail

Selecting a person replaces the overview with a full-photo gallery for that person.
The detail contains:

- back navigation to the People overview;
- person name and current photo count;
- the same discrete grid-column control used by Gallery view, available at all
  times;
- multiple photo selection;
- double-click to open the existing independent preview window;
- context-menu and toolbar actions appropriate to the selected faces.

A photo containing multiple faces can appear under multiple people. Classification
actions target the selected person's face record, not every face in the photo.

### Correction operations

Person detail supports:

- `この人ではない` — remove the selected face from this person;
- `別の人物へ移動` — assign selected faces to an existing person;
- `新しい人物として分離` — create a new person from selected faces;
- naming an unnamed person.

People overview supports selecting multiple person groups and `同じ人物として統合`.
Every action changes People metadata only. It never performs a file operation and
does not add a rename-history transaction. Rename Undo and People-metadata Undo are
separate so neither history can corrupt the other.

While People mode is active, naming, rejection, reassignment, split, and merge
commands register an inverse operation with the window `UndoManager`. Command-Z
therefore reverses the latest People edit. Merge and split also show a confirmation
because they can update several stored prototypes at once.

## Component architecture

### `FaceAnalyzer`

Owns image decoding, orientation, Vision requests, landmark extraction, alignment,
and embedding generation. It returns value types and performs no persistence or UI
mutation.

Inputs:

- immutable item ID and analysis URL;
- `FacePipelineContract`;
- cancellation context.

Outputs per detected face:

- stable face descriptor ID for the current analysis revision;
- normalised bounding box;
- capture-quality and face-size measurements;
- alignment method and eligibility tier;
- optional embedding;
- nonfatal diagnostic reason when embedding is unavailable.

### `PeopleClassifier`

Owns known-person matching, ambiguity handling, same-photo constraints, and
clustering of unknown embeddings. It accepts scalar embeddings and stored profiles;
it does not read images or SwiftUI state.

### `PersonStore`

Owns SwiftData models and local persistence. It exposes snapshots to the classifier
and explicit mutation methods for name, assignment, rejection, merge, migration,
and deletion.

### `PeopleWorkspaceModel`

Owns the current imported-list projection:

- analysis revision and progress;
- current face records and assignments;
- People overview ordering;
- selected person and selected photos;
- commands issued by People views;
- reclassification after a correction or preference change.

`AppModel` creates and observes this component but no longer constructs People
groups in large computed properties. Rename previews, file ordering, history,
duplicate analysis, image conversion, and trash remain outside this component.

### `FaceEmbeddingProvider`

The embedding backend exposes:

- its complete `FacePipelineContract`;
- required input dimensions and pixel contract;
- embedding creation;
- descriptor normalisation and distance.

The bundled MobileFaceNet implementation remains the first provider. A later
512-dimensional provider can be introduced only with a new contract and a reviewed
license. Embeddings with different contracts are never compared.

## Face pipeline contract

`FacePipelineContract` includes:

- embedding model identifier;
- embedding model version;
- embedding dimension;
- preprocessing version;
- alignment version;
- distance metric version.

It participates in every cache key and persisted prototype. Changing any field
invalidates current embeddings and prevents silent matching with legacy data.

## Five-point alignment

### Landmark extraction

Vision landmarks are converted once from normalised face coordinates into the
oriented image's pixel coordinate system. The five source points are:

1. centre of the left-eye landmark region;
2. centre of the right-eye landmark region;
3. robust centre of the available nose landmark region;
4. left corner of the outer-lips region;
5. right corner of the outer-lips region.

Left and right are normalised by x-position after orientation is applied. Invalid,
coincident, nonfinite, or implausibly ordered landmarks do not enter the five-point
solver.

### Canonical transform

The target points are derived from the exact MobileFaceNet reference geometry used
by the reviewed Qualcomm application: square 112 × 112 output, 0.25 inner padding,
no outer padding. A least-squares similarity transform maps all five source points
to those canonical points. Rendering uses a single declared coordinate system and
sRGB output.

### Fallbacks

Eye-only alignment and padded bounding-box crops remain available to show a face in
`未確認`, but their embeddings are not eligible for automatic person assignment,
cluster-core formation, or persistent prototypes. This avoids hiding difficult
faces while preventing weak crops from contaminating identity data.

## Eligibility and quality tiers

Every detected face is retained in one of three tiers:

- **display-only** — visible in `未確認`, no automatic identity decision;
- **classification-eligible** — may match or join a cluster;
- **prototype-eligible** — may be saved after explicit user confirmation.

Face size, capture quality, landmark completeness, and alignment method determine
the tier. Capture quality is not used as a single destructive filter. Changing the
sensitivity can alter classification eligibility without erasing the face record.

## Known-person matching

### Multiple prototypes

A named person stores up to 12 L2-normalised representative embeddings rather than
one centroid. When a confirmed sample is added:

- near-duplicate embeddings do not consume another slot;
- diverse eligible embeddings are retained using deterministic farthest-point
  selection;
- automatic matches never become prototypes without a user confirmation;
- low-quality or fallback-aligned faces can be manually classified for the current
  workspace but do not become persistent prototypes.

This preserves useful variation in pose, expression, lighting, and age while
bounding storage and comparison work.

### Conservative acceptance

For each eligible face, the classifier calculates a robust score from the nearest
prototype distances for every compatible person. An automatic known-person
assignment requires all of the following:

- best-person score passes the configured acceptance threshold;
- the gap between the best and second-best person passes an ambiguity margin;
- no stored rejection embedding for that person is sufficiently close;
- no same-photo cannot-link constraint is violated.

Otherwise the face is shown in `未確認` with its possible matches. Official model
verification thresholds are not copied directly into clustering; app thresholds
are calibrated against aligned FileRenamer inputs.

## Unknown-person grouping

Classification-eligible faces without a known match are clustered with the existing
deterministic density clusterer.

- sensitivity controls distance and core-point policy;
- a face from the same photo cannot serve as positive evidence for another face in
  that photo;
- clusters with at least two eligible faces appear as unnamed people;
- each singleton and outlier remains accessible in `未確認`;
- cluster results are current-workspace state and are rebuilt when the file list
  changes;
- manual correction can override the same-photo constraint for collages, mirrors,
  or other unusual images.

## Feedback and correction persistence

Explicit user operations are the only source of learning:

- assigning or naming an eligible face adds a positive prototype;
- rejecting a face from a person can add a contract-versioned rejection embedding;
- moving a face rejects the old person and confirms the new person;
- splitting selected faces creates a new profile and rejects them from the source;
- merging people combines their compatible positive and rejection samples, then
  applies deterministic prototype pruning.

Rejection embeddings are capped per person and contain no name beyond the related
person ID, photo path, crop, or file identifier. Uncertain automatic results never
write to SwiftData, preventing feedback loops that amplify an early mistake.

## Persistence schema and migration

### Versioned profile

The revised local schema stores:

- person UUID and display name;
- creation and modification timestamps;
- zero or more versioned positive prototypes;
- zero or more capped versioned rejection embeddings;
- sample counts derived from stored records;
- migration state.

No source URL, bookmark, `RenameItem` ID, photo assignment, thumbnail, or face crop
is stored.

### Existing experimental profiles

The current schema has one centroid without an alignment-version field. Those
embeddings may have been produced from the old eye-only crop and are therefore not
safe automatic references.

Migration preserves the profile UUID, display name, and timestamps but marks the
legacy centroid inactive. The name remains available in assignment UI. The first
new prototype-eligible manual confirmation activates the profile under the new
pipeline contract. Legacy data is not deleted silently and is never compared with
new embeddings.

## Analysis lifecycle and concurrency

- At most one People analysis task runs per FileRenamer tab.
- Heavy Vision, image decoding, Core ML, distance, and clustering work stays off the
  main actor.
- Results carry an imported-list revision; stale revisions are rejected.
- Cancellation is checked between images, faces, matching batches, and clustering
  loops.
- Completed faces may appear progressively, but a cluster snapshot is published
  atomically so the UI never displays a partially mutated group.
- Reordering files reuses face records and changes only presentation order.
- Replacing, resizing, or modifying a source invalidates its fingerprinted cache.
- Clearing or changing the list cancels analysis and clears current workspace
  assignments without deleting confirmed profiles.
- Preference and correction changes reuse compatible embeddings and rerun only
  matching and clustering when possible.

State publication occurs from explicit task-completion and command boundaries, not
from SwiftUI view evaluation, avoiding `Publishing changes from within view updates`
warnings.

## Error handling

- An unreadable or unsupported image produces a per-item diagnostic and does not
  cancel the batch.
- A missing face or incomplete landmark set remains a valid no-result or
  display-only result.
- A missing or incompatible model disables People analysis with one actionable
  message; renaming remains available.
- Security-scoped access starts before image decoding and ends in a symmetric
  `defer` path.
- If access is unavailable, the affected item is marked unanalysed without opening a
  folder chooser from background analysis.
- A persistence error rolls back the People metadata operation and leaves files and
  rename state untouched.
- A People metadata command is atomic: its profile, prototype, rejection, and inverse
  Undo information either all succeed or none are published.
- A correction that becomes stale after a folder change is ignored by revision ID.
- The UI reports progress, cancellation, and counts without moving Rename, Undo, or
  bottom-bar controls.

## Settings

The macOS Settings window contains:

- `人物候補を分類` on/off, default off;
- sensitivity: strict, standard, broad;
- local-only explanation;
- saved-person count and legacy-profile count;
- confirmed `人物データをすべて削除` action.

Sensitivity affects automatic decisions, not which detected faces are visible in
`未確認`. Advanced raw threshold fields are not exposed in the normal UI.

## Testing strategy

Tests are written before production changes.

### Geometry and model contract

- Vision-to-image coordinate conversion for all supported orientations;
- exact five-point target coordinates from the upstream MobileFaceNet geometry;
- similarity-transform recovery and target-point error within one output pixel;
- left/right normalisation and invalid-landmark rejection;
- fallback faces classified as display-only;
- Core ML output shape, finiteness, L2 norm, and parity with the converted PyTorch
  wrapper within the existing conversion tolerance;
- cache invalidation for every pipeline-contract component.

### Matching and clustering

- multiple prototypes outperform or equal a single-centroid case on constructed
  pose clusters;
- deterministic prototype selection and storage cap;
- best/second-best ambiguity margin;
- nearby rejection sample blocks automatic assignment;
- same-photo cannot-link behaviour and manual override;
- DBSCAN clusters, singletons, outliers, deterministic order, and all sensitivity
  presets;
- automatic matches never become training prototypes;
- explicit corrections update only the intended profile.

### Persistence and migration

- positive and rejection records save and reload locally;
- incompatible contracts never compare;
- old centroid profiles retain names but become inactive;
- first compatible manual confirmation reactivates a legacy profile;
- merge, split, rename, delete one, and delete all;
- no source URL, bookmark, crop, thumbnail, or item ID in the schema;
- CloudKit remains disabled.

### UI and lifecycle

- People is the third display mode;
- overview, unnamed groups, `未確認`, person detail, and back navigation;
- discrete grid-column control remains available;
- multiple selection and every classification context action;
- Command-Z reverses People naming, rejection, reassignment, split, and merge without
  altering rename history;
- double-click opens the correct independent preview after sorting or reordering;
- folder switching, list clearing, cancellation, stale-result rejection, and
  progressive status;
- no main-thread image inference;
- no mutation of rename rule, previews, order, history, Undo, trash, or image
  processing from a People action.

### Scale and failure cases

- descriptor-only clustering and reclassification at 200 and 1,000 faces;
- unreadable, permission-denied, removed, and concurrently modified files;
- images with no face, one face, many faces, very small faces, incomplete landmarks,
  and repeated appearances in a collage;
- Debug and Release builds, Xcode Analyze, universal architecture, existing safety
  suite, and `git diff --check`.

Real-person photographs are never committed to the repository. An opt-in local
diagnostic accepts a user-labelled test folder, reports same-person recall,
different-person false matches, ambiguous results, and candidate thresholds, then
discards paths and results unless the user explicitly exports the report.

## Accuracy release gate

The feature remains labelled experimental unless all of the following hold:

1. five-point alignment passes geometry and visual crop diagnostics;
2. converted Core ML output remains numerically consistent with the reviewed
   MobileFaceNet wrapper;
3. an explicitly consented, representative local evaluation containing different
   people, poses, lighting, and image ages is completed;
4. automatic assignment precision reaches at least 99% on that evaluation;
5. relaxing sensitivity never bypasses the ambiguity margin or same-photo safety;
6. every uncertain face remains reviewable rather than disappearing;
7. no existing file-operation or Sandbox safety test regresses.

If the 99% precision gate cannot be met at a useful recall after correct alignment
and calibration, automatic naming remains disabled and the next step is evaluating
a commercially redistributable 512-dimensional provider behind
`FaceEmbeddingProvider`. The People UI and manual grouping remain usable.

## Completion criteria

- The People display mode replaces the candidate-review sheet.
- The overview and person-detail flows match the approved Photos-style mockup.
- Every detected face is either assigned or visible in `未確認`.
- Confirmed people can be matched in a later folder without retaining photo paths.
- User corrections improve later decisions without automatic feedback loops.
- Existing legacy names survive migration while unsafe centroids stay inactive.
- All processing and persisted data remain on the Mac.
- The accuracy release gate and automated safety suite pass before the feature is
  presented as non-experimental.
