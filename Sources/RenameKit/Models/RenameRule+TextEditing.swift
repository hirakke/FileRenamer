import Foundation

/// Shaping a rule for an editor where **typing is the primary action** and blocks are
/// dropped into the text.
///
/// In that editor a rule is a line of text with variables embedded in it, so the
/// token list has to strictly alternate: a literal run, a variable, a literal run,
/// and so on, with a run at each end for the caret to live in. Empty runs are real
/// and expected while editing; they are stripped again on save.
public extension RenameRule {
    /// Editing shape: separators folded into text, adjacent runs merged, and an empty
    /// run inserted wherever the caret would otherwise have nowhere to go.
    func normalizedForTextEditing() -> RenameRule {
        // Separators are redundant once text can be typed freely — "_" is just a
        // character. They stay in the model for the compact block bar, but the text
        // editor sees them as ordinary text.
        let flattened = tokens.map { token -> RenameToken in
            guard case .separator(let config) = token else { return token }
            return .text(TextConfiguration(id: config.id, value: config.value))
        }

        var merged: [RenameToken] = []
        for token in flattened {
            if case .text(let config) = token, case .text(let previous)? = merged.last {
                var updated = previous
                updated.value += config.value
                merged[merged.count - 1] = .text(updated)
            } else {
                merged.append(token)
            }
        }

        var result: [RenameToken] = []
        for token in merged {
            if !token.isTextRun, !(result.last?.isTextRun ?? false) {
                result.append(.text(TextConfiguration(value: "")))
            }
            result.append(token)
        }
        if !(result.last?.isTextRun ?? false) {
            result.append(.text(TextConfiguration(value: "")))
        }

        return RenameRule(
            tokens: result,
            extensionTransform: extensionTransform,
            imageOutputFormat: imageOutputFormat,
            imageResize: imageResize
        )
    }

    /// Saving shape: the scaffolding empty runs are dropped again.
    func compactedAfterTextEditing() -> RenameRule {
        var result: [RenameToken] = []
        for token in tokens {
            if case .text(let config) = token {
                if config.value.isEmpty { continue }
                if case .text(let previous)? = result.last {
                    var updated = previous
                    updated.value += config.value
                    result[result.count - 1] = .text(updated)
                    continue
                }
            }
            result.append(token)
        }
        return RenameRule(
            tokens: result,
            extensionTransform: extensionTransform,
            imageOutputFormat: imageOutputFormat,
            imageResize: imageResize
        )
    }

    /// Drops `token` into the middle of a text run, splitting it at the caret — the
    /// same thing typing a character there would do, except the character is a block.
    ///
    /// With no run focused the block goes to the end, which is what an insert button
    /// pressed before typing anything should do.
    func inserting(_ token: RenameToken, atRun runID: UUID?, caret: Int) -> RenameRule {
        var rule = normalizedForTextEditing()

        guard let runID,
              let index = rule.tokens.firstIndex(where: { $0.id == runID }),
              case .text(let config) = rule.tokens[index]
        else {
            rule.tokens.append(token)
            return rule.normalizedForTextEditing()
        }

        let characters = Array(config.value)
        let split = Swift.min(Swift.max(caret, 0), characters.count)
        var head = config
        head.value = String(characters[..<split])
        let tail = TextConfiguration(value: String(characters[split...]))

        rule.tokens.replaceSubrange(index...index, with: [.text(head), token, .text(tail)])
        return rule.normalizedForTextEditing()
    }

    /// Removes a block and closes the gap, merging the text on either side of it.
    func removingToken(id: UUID) -> RenameRule {
        var rule = self
        rule.tokens.removeAll { $0.id == id }
        return rule.normalizedForTextEditing()
    }
}

public extension RenameToken {
    /// Literal text the user types, as opposed to a block that varies per file.
    var isTextRun: Bool {
        if case .text = self { return true }
        return false
    }
}
