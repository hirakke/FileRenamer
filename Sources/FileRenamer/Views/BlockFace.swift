import SwiftUI
import RenameKit

/// Editing operations on a rule, expressed on a binding so the same block UI can
/// drive the live rule in the toolbar or a draft rule inside a preset editor.
extension Binding where Value == RenameRule {
    func append(_ token: RenameToken) {
        wrappedValue.tokens.append(token)
    }

    func remove(tokenID: UUID) {
        wrappedValue.tokens.removeAll { $0.id == tokenID }
    }

    func update(_ token: RenameToken) {
        guard let index = wrappedValue.tokens.firstIndex(where: { $0.id == token.id }) else { return }
        wrappedValue.tokens[index] = token
    }

    func move(tokenID: UUID, toIndex index: Int) {
        var tokens = wrappedValue.tokens
        guard let current = tokens.firstIndex(where: { $0.id == tokenID }), current != index else { return }
        let token = tokens.remove(at: current)
        // Qualified: `Binding` is @dynamicMemberLookup, so a bare `min`/`max` here
        // resolves against RenameRule instead of the stdlib.
        let target = Swift.min(Swift.max(index > current ? index - 1 : index, 0), tokens.count)
        tokens.insert(token, at: target)
        wrappedValue.tokens = tokens
    }
}

/// A block as it appears inside the rule text.
///
/// The field is a line of text, so a block has to read as a word in that line rather
/// than as a tile dropped on top of it: same monospaced face, same size, sitting on
/// the same baseline. What separates it from the literal characters around it is a
/// soft tinted ground and coloured text — not weight or hard edges.
///
/// The face is the *format* (`YYYYMMDD`, `001`), so the field reads as the shape of
/// the name rather than as one file's particular result.
struct BlockFace: View {
    let token: RenameToken
    var isSelected: Bool = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        // Deliberately not `glassEffect`: tinted glass is designed to carry white
        // content, and coloured text on a strongly tinted ground disappears. The
        // block keeps the rounded shape but draws its own light wash, so the
        // contrast between text and ground is known rather than inherited.
        Text(BlockLabel.text(for: token))
            .font(.system(.body, design: .monospaced).weight(.semibold))
            .foregroundStyle(token.tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(token.tint.opacity(isSelected ? 0.26 : 0.15), in: shape)
            .overlay {
                if isSelected {
                    shape.strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1)
                }
            }
    }
}

/// What a block shows on its face.
///
/// A format rather than a value: `YYYYMMDD`, `001`. Showing one file's actual date
/// would read as a literal string that happens to be there, when the point is that
/// this part of the name is derived per file.
enum BlockLabel {
    static func text(for token: RenameToken) -> String {
        switch token {
        case .counter(let config):
            return config.formatted(at: 0)
        case .date(let config):
            return displayPattern(config.pattern)
        case .originalName(let config):
            return config.transform == .none ? "元のファイル名" : "元のファイル名(\(config.transform.displayName))"
        case .metadata(let config):
            return config.field.displayName
        case .text(let config):
            return config.value
        case .separator(let config):
            return config.value
        }
    }

    /// `yyyyMMdd` → `YYYYMMDD`. Upper case reads as a placeholder rather than as
    /// text that will appear verbatim; the exact case of the pattern only matters
    /// inside `DateFormatter`.
    static func displayPattern(_ pattern: String) -> String {
        pattern.uppercased()
    }
}

extension RenameToken {
    /// Variables produce different text per file; literals are the same every time.
    var isVariable: Bool {
        switch self {
        case .counter, .date, .originalName, .metadata: return true
        case .text, .separator: return false
        }
    }

    var tint: Color {
        switch self {
        case .counter: return Palette.tomatoRed
        case .date: return Palette.carrotOrange
        case .originalName: return Palette.reefEncounter
        case .metadata: return Palette.livid
        case .text, .separator: return Palette.azraqBlue
        }
    }
}
