import SwiftUI
import RenameKit

/// The "Name" step. The rule is typed like a file name; blocks are dropped in where
/// a part of it has to vary per file.
struct NamingRuleBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @State private var editingContext = RuleEditingContext()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(L10n.string("ruleBar.namingRule", defaultValue: "Naming Rule", language: preferences.resolvedLanguage))
                    .font(.headline)
                PresetMenu()
                BlockInsertMenu(insert: insertBlock)
                    .tutorialTip(InsertBlocksTip(language: preferences.resolvedLanguage), step: 2, arrowEdge: .top)
                ImageOptionsControl()
                Spacer()
                samplePreview
            }

            RuleTextField(
                rule: $model.rule,
                context: editingContext,
                editorPresentation: .popover,
                onEditingChanged: { model.isRuleTextEditing = $0 }
            )
            .tutorialTip(TypeNameTip(language: preferences.resolvedLanguage), step: 1, arrowEdge: .top)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .raisedWorkSurface(opacity: 0.97)
        .zIndex(1)
        .onDisappear {
            model.isRuleTextEditing = false
        }
    }

    private func insertBlock(_ token: RenameToken) {
        model.insertBlock(token, atRun: editingContext.focusedRunID, caret: editingContext.caretLocation)
    }

    /// Live example built from the first item, so the rule is legible before the
    /// user scrolls the list.
    private var samplePreview: some View {
        Group {
            if let first = model.previews.first {
                HStack(spacing: 6) {
                    Text(L10n.string("ruleBar.example", defaultValue: "Example:", language: preferences.resolvedLanguage)).font(.caption).foregroundStyle(.secondary)
                    Text(first.proposedName)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(first.validation.isError ? Palette.error : Color.primary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct ImageOptionsControl: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @State private var isPresented = false
    @State private var isResizeExpanded = false
    @State private var longEdgeText = ""
    @FocusState private var isLongEdgeFocused: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(L10n.string("ruleBar.imageSettings", defaultValue: "Image Settings", language: preferences.resolvedLanguage))
                CustomChevron()
                    .stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                    .frame(width: 6, height: 10)
                    .rotationEffect(.degrees(isPresented ? -90 : 90))
                    .animation(.easeInOut(duration: 0.16), value: isPresented)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(L10n.string("ruleBar.setImageFormatAndDimensions", defaultValue: "Set image format and dimensions", language: preferences.resolvedLanguage))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            optionsPopover
        }
    }

    private var optionsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("ruleBar.imageSettings", defaultValue: "Image Settings", language: preferences.resolvedLanguage))
                .font(.headline)

            optionPicker(
                title: L10n.string("ruleBar.imageFormat", defaultValue: "Image Format", language: preferences.resolvedLanguage),
                selection: $model.rule.imageOutputFormat,
                options: ImageOutputFormat.allCases
            ) { $0.localizedDisplayName(in: preferences.resolvedLanguage) }

            if model.showsJPEGQualitySetting {
                jpegQualityControl
            }

            Divider()

            resizeDisclosure

            Text(L10n.string("ruleBar.imageConversionAndResizingSupport", defaultValue: "Image conversion and resizing support JPEG and PNG. Transparent areas become white in JPEG.", language: preferences.resolvedLanguage))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        // Keep the popover's geometry stable. Resizing an AppKit popover while its
        // SwiftUI content is transitioning can lock the layout pass on macOS.
        .frame(width: 360, height: 472, alignment: .top)
        .onAppear {
            longEdgeText = String(model.rule.imageResize.normalizedLongEdge)
            isResizeExpanded = model.rule.imageResize.isEnabled
        }
    }

    private var jpegQualityControl: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.string("ruleBar.jpegQuality", defaultValue: "JPEG Quality", language: preferences.resolvedLanguage))
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(L10n.string("ruleBar.jpegQuality", defaultValue: "JPEG Quality", language: preferences.resolvedLanguage), selection: $model.jpegQualitySetting.preset) {
                ForEach(JPEGQualityPreset.allCases, id: \.self) { preset in
                    Text(preset.localizedDisplayName(in: preferences.resolvedLanguage)).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if model.jpegQualitySetting.preset == .custom {
                HStack(spacing: 10) {
                    Slider(value: customQualityValue, in: 50...100, step: 1)
                        .accessibilityLabel(L10n.string("ruleBar.customJpegQuality", defaultValue: "Custom JPEG Quality", language: preferences.resolvedLanguage))
                    Text("\(model.jpegQualitySetting.normalizedCustomPercent)%")
                        .font(.system(.callout, design: .monospaced))
                        .frame(width: 42, alignment: .trailing)
                }
            }

            Text(preferences.preservesJPEGAtMaximumQuality
                 ? L10n.string("ruleBar.jpegFilesAreNotRecompressed", defaultValue: "JPEG files are not recompressed at 100% when format and size are unchanged.", language: preferences.resolvedLanguage)
                 : L10n.string("ruleBar.jpegFilesAreRecompressedWhen", defaultValue: "JPEG files are recompressed when saved.", language: preferences.resolvedLanguage))
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(preferences.preservesJPEGAtMaximumQuality
                      ? L10n.string("ruleBar.jpegFilesAreReEncoded", defaultValue: "JPEG files are re-encoded when resized or saved below 100% quality.", language: preferences.resolvedLanguage)
                      : L10n.string("ruleBar.jpegFilesAreReEncoded2", defaultValue: "JPEG files are re-encoded, including at 100% quality.", language: preferences.resolvedLanguage))
        }
    }

    private var customQualityValue: Binding<Double> {
        Binding(
            get: { Double(model.jpegQualitySetting.normalizedCustomPercent) },
            set: { model.jpegQualitySetting.customPercent = Int($0.rounded()) }
        )
    }

    private func optionPicker<Option: Hashable>(
        title: String,
        selection: Binding<Option>,
        options: [Option],
        label: @escaping (Option) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var resizeDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                // This is intentionally a plain state change. The containing
                // popover has fixed geometry, so disclosure never starts a nested
                // AppKit/SwiftUI resize animation.
                isResizeExpanded.toggle()
            } label: {
                HStack(spacing: 9) {
                    CustomChevron()
                        .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 7, height: 12)
                        .rotationEffect(.degrees(isResizeExpanded ? 90 : 0))

                    Text(L10n.string("ruleBar.resizeImages", defaultValue: "Resize Images", language: preferences.resolvedLanguage))
                        .fontWeight(.medium)

                    Spacer()

                    Text(resizeSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isResizeExpanded ? L10n.string("ruleBar.closeResizeSettings", defaultValue: "Close resize settings", language: preferences.resolvedLanguage) : L10n.string("ruleBar.openResizeSettings", defaultValue: "Open resize settings", language: preferences.resolvedLanguage))

            if isResizeExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(L10n.string("ruleBar.enableResizing", defaultValue: "Enable Resizing", language: preferences.resolvedLanguage), isOn: $model.rule.imageResize.isEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: model.rule.imageResize.isEnabled) { wasEnabled, isEnabled in
                            if isEnabled && !wasEnabled {
                                model.rule.imageResize.preventsUpscaling = preferences.preventsUpscalingByDefault
                            }
                        }

                    HStack(spacing: 8) {
                        Text(L10n.string("ruleBar.maximumLongEdge", defaultValue: "Maximum Long Edge", language: preferences.resolvedLanguage))

                        Spacer()

                        TextField("2048", text: $longEdgeText)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 88)
                            .focused($isLongEdgeFocused)
                            .onSubmit(commitLongEdge)
                            .onChange(of: longEdgeText) { _, newValue in sanitizeLongEdgeText(newValue) }

                        Text("px")
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!model.rule.imageResize.isEnabled)

                    Text(L10n.string("ruleBar.6420000PxResizes", defaultValue: "64–20,000 px. Resizes while preserving the aspect ratio.", language: preferences.resolvedLanguage))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle(
                        L10n.string("ruleBar.doNotUpscaleSmallerImages", defaultValue: "Do Not Upscale Smaller Images", language: preferences.resolvedLanguage),
                        isOn: $model.rule.imageResize.preventsUpscaling
                    )
                    .disabled(!model.rule.imageResize.isEnabled)
                }
                .padding(.leading, 16)
            }
        }
        .onChange(of: isLongEdgeFocused) { _, focused in
            if !focused {
                commitLongEdge()
            }
        }
        .onChange(of: model.rule.imageResize.maxLongEdge) { _, newValue in
            if !isLongEdgeFocused {
                longEdgeText = String(newValue)
            }
        }
    }

    private var resizeSummary: String {
        model.rule.imageResize.isEnabled
            ? "\(model.rule.imageResize.normalizedLongEdge) px"
            : L10n.string("imageResize.off", defaultValue: "Off", language: preferences.resolvedLanguage)
    }

    private func sanitizeLongEdgeText(_ text: String) {
        let filtered = text.filter { "0123456789".contains($0) }
        if filtered != text {
            longEdgeText = filtered
        }
    }

    private func commitLongEdge() {
        guard let pixels = Int(longEdgeText), !longEdgeText.isEmpty else {
            longEdgeText = String(model.rule.imageResize.normalizedLongEdge)
            return
        }
        let normalized = max(64, min(pixels, 20_000))
        model.rule.imageResize.maxLongEdge = normalized
        longEdgeText = String(normalized)
    }
}

/// A small hand-drawn chevron keeps disclosure behavior independent from the
/// system Menu indicator and makes its open/closed state unambiguous.
private struct CustomChevron: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.12))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.72, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY - rect.height * 0.12))
        return path
    }
}

/// The same catalogue as the preset editor's insert panel, folded into a menu for
/// the toolbar where there is no room for three rows of popups.
struct BlockInsertMenu: View {
    @EnvironmentObject private var preferences: AppPreferences
    let insert: (RenameToken) -> Void
    @State private var isCustomDateSheetPresented = false

    var body: some View {
        Menu {
            Menu(L10n.string("ruleBar.counterAndDate", defaultValue: "Counter and Date", language: preferences.resolvedLanguage)) {
                ForEach(TokenInsertPanel.counterAndDateOptions.indices, id: \.self) { index in
                    let option = TokenInsertPanel.counterAndDateOptions[index]
                    Button(option.title(in: preferences.resolvedLanguage)) { insert(option.make()) }
                }
                Divider()
                Button(L10n.string(
                    "blockInsert.customDate.menu",
                    defaultValue: "Date (Custom Format)…",
                    language: preferences.resolvedLanguage
                )) { isCustomDateSheetPresented = true }
            }
            Menu(L10n.string("ruleBar.originalName", defaultValue: "Original Name", language: preferences.resolvedLanguage)) {
                ForEach(TokenInsertPanel.originalNameOptions.indices, id: \.self) { index in
                    let option = TokenInsertPanel.originalNameOptions[index]
                    Button(option.title(in: preferences.resolvedLanguage)) { insert(option.make()) }
                }
            }
        } label: {
            Label(L10n.string("ruleBar.insertBlock", defaultValue: "Insert Block", language: preferences.resolvedLanguage), systemImage: "plus.square")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .sheet(isPresented: $isCustomDateSheetPresented) {
            CustomDateBlockSheet { insert(.date($0)) }
        }
    }
}

/// Lets a custom date pattern be typed straight from the insert menu instead of
/// inserting a preset and then opening the block's editor.
private struct CustomDateBlockSheet: View {
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var pattern = "YYYYMMDD"
    @State private var source: DateSource = .creation
    let onInsert: (DateConfiguration) -> Void

    private var configuration: DateConfiguration {
        DateConfiguration(source: source, preset: .custom, customPattern: pattern)
    }

    private var trimmedPatternIsEmpty: Bool {
        pattern.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var exampleText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = configuration.pattern
        return formatter.string(from: Date())
    }

    private func text(_ key: String, _ defaultValue: String) -> String {
        L10n.string(key, defaultValue: defaultValue, language: preferences.resolvedLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("blockInsert.customDate.title", "Custom Date Format"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text(text("blockInsert.customDate.format", "Format"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("YYYYMMDD", text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(commit)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(text("blockInsert.customDate.source", "Date Type"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(text("blockInsert.customDate.source", "Date Type"), selection: $source) {
                    ForEach(DateSource.allCases, id: \.self) { source in
                        Text(source.localizedDisplayName(in: preferences.resolvedLanguage)).tag(source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Text(L10n.format(
                "blockInsert.customDate.preview",
                defaultValue: "Example: %@",
                arguments: [exampleText],
                language: preferences.resolvedLanguage
            ))
            .font(.system(.callout, design: .monospaced))

            Text(text("blockInsert.customDate.help", "YYYY year / MM month / DD day / HH hour / mm minute / ss second"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(text("blockInsert.customDate.cancel", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(text("blockInsert.customDate.insert", "Insert"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedPatternIsEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func commit() {
        guard !trimmedPatternIsEmpty else { return }
        onInsert(configuration)
        dismiss()
    }
}
