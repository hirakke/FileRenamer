import Foundation
import RenameKit

/// Serial workers keep expensive synchronous RenameKit work off the main actor.
/// Separate workers mean a slow destination scan never blocks generation of the
/// newest names while the user keeps typing or arranging files.
actor PreviewGenerationWorker {
    private let engine = RenameEngine()
    private let validator = RenameValidator()

    func generate(
        items: [RenameItem],
        rule: RenameRule,
        jpegQuality: JPEGQualitySetting,
        preservesJPEGAtMaximumQuality: Bool
    ) throws -> [RenamePreview] {
        try Task.checkCancellation()
        let generated = engine.makePreviews(
            items: items,
            rule: rule,
            jpegQuality: jpegQuality,
            preservesJPEGAtMaximumQuality: preservesJPEGAtMaximumQuality
        )
        try Task.checkCancellation()
        return validator.validate(generated, checkExistingFiles: false)
    }
}

actor DestinationValidationWorker {
    private let validator = RenameValidator()

    func validate(_ previews: [RenamePreview]) throws -> [RenamePreview] {
        try Task.checkCancellation()
        let validated = validator.validate(previews)
        try Task.checkCancellation()
        return validated
    }
}
