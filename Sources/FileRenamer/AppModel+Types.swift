import Foundation
import RenameKit

enum ViewMode: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }
    var systemImageName: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

extension AppModel {
    struct AlertMessage: Identifiable {
        enum Action {
            case addWorkingFolder
        }

        let id = UUID()
        var title: String
        var detail: String
        var action: Action?
        var actionTitle: String?
    }

    struct ResultMessage: Identifiable {
        let id = UUID()
        var text: String
        var offersUndo: Bool = false
    }

    struct RenameConfirmation: Identifiable {
        let id = UUID()
        let rows: [RenameConfirmationRow]
        let changedItemCount: Int
        let renamedFileCount: Int
        let processedImageCount: Int
        let warningCount: Int
        let originalImagesDirectory: URL?
        let destinationDirectory: URL?
        let actionTitle: String

        var replacesOriginalImages: Bool {
            processedImageCount > 0 && originalImagesDirectory == nil
        }
    }

    struct RenameConfirmationRow: Identifiable {
        let id = UUID()
        let sourceName: String
        let destinationName: String
        let sourceDirectoryPath: String
        let changesName: Bool
        let imageChange: String?
        let warning: String?
    }

    struct TrashConfirmation: Identifiable {
        let id = UUID()
        let itemIDs: Set<UUID>
    }

    /// Where the files end up after a rename: next to themselves, or gathered
    /// into one folder.
    enum RenameDestination: Equatable {
        case inPlace
        case existingFolder(URL)

        var directory: URL? {
            switch self {
            case .inPlace: return nil
            case .existingFolder(let url): return url
            }
        }
    }

    /// One cluster of pictures that resemble each other.
    ///
    /// Similarity is transitive in practice — if A matches B and B matches C, the
    /// three are one burst, not two separate pairs — so groups are the connected
    /// components of the match graph rather than raw pairs. Reviewing a burst of five
    /// as one group is the difference between one decision and ten.
    struct DuplicateGroup: Identifiable {
        let id: UUID
        let items: [RenameItem]
        let containsExactMatch: Bool

        var count: Int { items.count }

        /// All-exact groups are safe to sweep; mixed ones need looking at.
        var isEntirelyExact: Bool { containsExactMatch }
    }

    struct SimilarityReview: Identifiable {
        let id = UUID()
        let groups: [DuplicateGroup]
        let focusedGroupID: UUID
    }

    struct SimilarityBadge {
        let count: Int
        let containsExactMatch: Bool
    }

    /// One row's validation problem, flattened for the status-bar popover.
    struct Issue: Identifiable, Hashable {
        let id: UUID
        let name: String
        let message: String
        let isError: Bool
    }
}
