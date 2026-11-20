import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ScreenshotCompositionWindowController: NSObject, NSWindowDelegate {
    static let shared = ScreenshotCompositionWindowController()
    static let announcement = ScreenshotCompositionWindowController(isAnnouncement: true)
    private static var additionalPosts: [UUID: ScreenshotCompositionWindowController] = [:]
    private static var openingPosts: Set<URL> = []
    private static var writingPosts: Set<URL> = []
    private static var postWindows: [ScreenshotCompositionWindowController] { [announcement] + Array(additionalPosts.values) }
    private let id = UUID()
    private let isAnnouncement: Bool
    private var postCloseGuard: EditorCloseGuard?
    private var window: NSWindow?
    private var model: ScreenshotCompositionModel?
    private var exportBeforeClosing: (() -> Void)?
    private var captureTask: Task<Void, Never>?
    private var saveTask: Task<Bool, Never>?
    private var untitledPostName = FeatureAnnouncement.title

    private init(isAnnouncement: Bool = false) {
        self.isAnnouncement = isAnnouncement
        super.init()
    }

    func open(on screen: NSScreen? = nil, images: [URL] = []) {
        if isAnnouncement && !images.isEmpty && (model?.hasPostContent == true || model?.postURL != nil) {
            let draft = Self.newPostWindow()
            draft.open(on: screen, images: images)
            return
        }
        if let window {
            if !images.isEmpty { model?.importImages(images) }
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let model = ScreenshotCompositionModel(isAnnouncement: isAnnouncement)
        if !images.isEmpty { model.importImages(images) }
        show(model, on: screen)
    }

    private func show(_ model: ScreenshotCompositionModel, on screen: NSScreen?) {
        self.model = model
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = isAnnouncement ? untitledPostName : "Compose Screenshots"
        window.minSize = CGSize(width: 980, height: 680)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ScreenshotCompositionWindow(model: model,
            onCaptureWindow: { [weak self] in self?.captureWindow() },
            onExportAvailable: { [weak self] action in self?.exportBeforeClosing = action },
            onSavePost: { [weak self] in self?.savePost() },
            onDuplicatePost: { [weak self] in self?.duplicatePost() },
            onPostStateChanged: { [weak self] in self?.refreshPostWindow() }))
        self.window = window
        if isAnnouncement {
            let postCloseGuard = EditorCloseGuard()
            self.postCloseGuard = postCloseGuard
            postCloseGuard.hasUnsavedChanges = { [weak model] in model?.hasUnsavedPostChanges == true }
            postCloseGuard.projectName = { [weak self] in self?.window?.title ?? FeatureAnnouncement.title }
            postCloseGuard.isFinishingSave = { [weak self] in self?.saveTask != nil }
            postCloseGuard.finishSave = { [weak self] in await self?.saveTask?.value == true }
            postCloseGuard.onDecision = { [weak self] decision, done in
                if case .save = decision { self?.savePost(onSuccess: done) }
                else { done() }
            }
            postCloseGuard.attach(to: window)
            refreshPostWindow()
        }
        if let screen { window.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - 590, y: screen.visibleFrame.midY - 390)) }
        else { window.center() }
        AppActivationPolicy.enter(hidePreview: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func newPostWindow() -> ScreenshotCompositionWindowController {
        let controller = ScreenshotCompositionWindowController(isAnnouncement: true)
        additionalPosts[controller.id] = controller
        return controller
    }

    static func createPost(on screen: NSScreen?) {
        newPostWindow().open(on: screen)
    }

    static func choosePost() {
        let screen = NSApp.keyWindow?.screen
        let panel = NSOpenPanel()
        panel.title = "Open Post"
        panel.allowedContentTypes = [FeatureAnnouncementProject.contentType]
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK, let url = panel.url { openPost(url, on: screen) }
        }
    }

    static func openPost(_ url: URL, on screen: NSScreen? = nil) {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        if let existing = postWindows.first(where: { $0.model?.postURL == url }) {
            existing.open()
            return
        }
        guard !writingPosts.contains(url), openingPosts.insert(url).inserted else { return }
        Task { @MainActor in
            defer { openingPosts.remove(url) }
            do {
                let post = try await Task.detached(priority: .userInitiated) {
                    try FeatureAnnouncementProject.read(from: url)
                }.value
                let model = ScreenshotCompositionModel(isAnnouncement: true)
                model.loadPost(post.makeDocument(), from: url)
                newPostWindow().show(model, on: screen)
            } catch {
                let alert = NSAlert(error: error)
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.keyWindow, window.attachedSheet == nil { alert.beginSheetModal(for: window, completionHandler: nil) }
                else { alert.runModal() }
            }
        }
    }

    private func duplicatePost() {
        guard let model, model.hasPostContent else { return }
        var document = model.document
        if let draft = model.calloutDraft { document.announcement?.callout = draft }
        let copy = ScreenshotCompositionModel(isAnnouncement: true)
        copy.loadPost(document, from: nil)
        let controller = Self.newPostWindow()
        controller.untitledPostName = (window?.title ?? FeatureAnnouncement.title) + " Copy"
        controller.show(copy, on: window?.screen)
    }

    private func refreshPostWindow() {
        guard let model, let window, isAnnouncement else { return }
        window.representedURL = model.postURL
        window.title = model.postURL?.deletingPathExtension().lastPathComponent ?? untitledPostName
        postCloseGuard?.refreshDocumentEdited()
    }

    private func savePost(onSuccess: (() -> Void)? = nil) {
        guard let model, let window, saveTask == nil,
              model.hasPostContent || model.postURL != nil else { return }
        if let url = model.postURL {
            writePost(to: url, onSuccess: onSuccess)
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Post"
        panel.allowedContentTypes = [FeatureAnnouncementProject.contentType]
        panel.nameFieldStringValue = "\(untitledPostName).\(FeatureAnnouncementProject.pathExtension)"
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.writePost(to: url, onSuccess: onSuccess) }
        }
    }

    private func writePost(to url: URL, onSuccess: (() -> Void)?) {
        guard let model, saveTask == nil else { return }
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        guard !Self.postWindows.contains(where: { $0 !== self && $0.model?.postURL == url }),
              !Self.openingPosts.contains(url), Self.writingPosts.insert(url).inserted else {
            model.errorMessage = "That post is open or being saved. Choose a different file."
            return
        }
        model.applyCalloutDraft()
        let snapshot = model.document
        model.isSavingPost = true
        model.errorMessage = nil
        saveTask = Task { @MainActor in
            defer {
                Self.writingPosts.remove(url)
                model.isSavingPost = false
                saveTask = nil
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FeatureAnnouncementProject.write(snapshot, to: url)
                }.value
                model.markPostSaved(to: url, revision: snapshot.revision)
                refreshPostWindow()
                if !model.hasUnsavedPostChanges { onSuccess?() }
                return true
            } catch {
                model.errorMessage = error.localizedDescription
                return false
            }
        }
    }

    static func reviewUnsavedPostBeforeQuitting() -> Bool {
        guard let controller = postWindows.first(where: { $0.model?.hasUnsavedPostChanges == true || $0.saveTask != nil }),
              let window = controller.window else { return false }
        window.makeKeyAndOrderFront(nil)
        window.performClose(nil)
        return true
    }

    func captureWindow() {
        guard let window, let model, captureTask == nil else { return }
        guard !ScreenCapture.shared.isCapturing else {
            model.errorMessage = "Another capture is in progress. Finish it, then try again."
            return
        }
        guard ScreenCapturePermission.isReadyToCapture() else { return }
        window.orderOut(nil)
        captureTask = Task { @MainActor [weak self] in
            defer {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self?.captureTask = nil
            }
            do {
                // Native window selection, without a baked-in shadow: each
                // screenshot's editable shadow is drawn by the composer.
                if let url = try await ScreenCapture.shared.captureWindow(includeShadow: false) {
                    defer { try? FileManager.default.removeItem(at: url) }
                    model.importImages([url])
                }
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, model.hasUnexportedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Export this composition before closing?"
        alert.informativeText = "The canvas is kept only in this window. Export a PNG to keep the combined image; individual layers cannot be reopened from it."
        alert.addButton(withTitle: "Export PNG…")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: sender) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.exportBeforeClosing?() }
            else if response == .alertSecondButtonReturn { sender.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        postCloseGuard?.detach()
        postCloseGuard = nil
        exportBeforeClosing = nil
        window = nil; model = nil
        Self.additionalPosts.removeValue(forKey: id)
        AppActivationPolicy.leave(restorePreview: true)
    }
}

struct ScreenshotCompositionWindow: View {
    @Bindable var model: ScreenshotCompositionModel
    @Environment(\.displayScale) private var displayScale
    var onCaptureWindow: () -> Void = {}
    var onExportAvailable: (@escaping () -> Void) -> Void = { _ in }
    var onSavePost: () -> Void = {}
    var onDuplicatePost: () -> Void = {}
    var onPostStateChanged: () -> Void = {}
    @State private var layout: ScreenshotCompositionLayout = .row
    @State private var exportScale: CGFloat = 0
    @State private var transferStatus: TransferStatus?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var dropTarget = false
    @State private var confirmRemove = false
    @State private var gestureFrame: CGRect?
    @State private var announcementFormat: FeatureAnnouncement.Format = .square
    @State private var phonePreview = false
    private var detailDraft: CGRect? {
        get { model.calloutDraft }
        nonmutating set { model.calloutDraft = newValue }
    }

    private var isAnnouncement: Bool { model.document.announcement != nil }
    private var canExport: Bool {
        isAnnouncement ? model.canExportAnnouncement : !model.document.screenshots.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                Group {
                    if isAnnouncement { announcementInspector } else { inspector }
                }.frame(width: 290)
                Divider()
                canvas
            }
            Divider()
            footer
        }
        .frame(minWidth: 960, minHeight: 640)
        .tint(EditorChrome.accent)
        .background(EditorChrome.workspace)
        .background(TransferToast(status: transferStatus, onRetry: export,
            onDismiss: { transferStatus = nil }))
        .background(EditorShortcutHandler(scope: .image, perform: { action in
            switch action {
            case .imageUndo: model.undo()
            case .imageRedo: model.redo()
            case .imageSave: if isAnnouncement { onSavePost() } else { export() }
            case .imageExport: export()
            case .imageDelete:
                if model.selection != nil { confirmRemove = true }
            default: return false
            }
            return true
        }))
        .onAppear { onExportAvailable(export) }
        .onChange(of: model.hasUnsavedPostChanges) { onPostStateChanged() }
        .onChange(of: model.postURL) { onPostStateChanged() }
        .onChange(of: model.document.screenshots.first?.id) { detailDraft = nil }
        .onExitCommand { detailDraft = nil }
        .alert("Remove this screenshot?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.removeSelection() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The source file is kept. You can undo this change.") }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget, perform: importDrop)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: importImages) {
                Label(isAnnouncement ? (model.selection == nil ? "Add Screenshot…" : "Replace Screenshot…") : "Add Images…",
                      systemImage: "photo.on.rectangle")
            }
                .disabled(isImporting)
            Button(action: onCaptureWindow) {
                Label("Capture Window", systemImage: "macwindow")
            }
            Menu {
                if isAnnouncement {
                    Button("Save Post", systemImage: "square.and.arrow.down", action: onSavePost)
                        .disabled(model.isSavingPost || (!model.hasPostContent && model.postURL == nil))
                    Button("Duplicate Post", systemImage: "plus.square.on.square", action: onDuplicatePost)
                        .disabled(!model.hasPostContent)
                } else {
                    Button("New Social Post", systemImage: "rectangle.and.text.magnifyingglass") {
                        ScreenshotCompositionWindowController.createPost(on: NSApp.keyWindow?.screen)
                    }
                }
                Button("Open Post…", systemImage: "folder", action: ScreenshotCompositionWindowController.choosePost)
            } label: {
                Label("Post", systemImage: "doc")
            }
            Divider().frame(height: 22)
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly) }
                .disabled(!model.canUndo).help("Undo")
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward").labelStyle(.iconOnly) }
                .disabled(!model.canRedo).help("Redo")
            Spacer()
            Button(action: export) {
                Label(isAnnouncement ? "Export Both Sizes…" : "Export PNG…", systemImage: "arrow.down.circle")
            }
                .buttonStyle(.borderedProminent)
                .disabled(!canExport || isExporting)
        }
        .buttonStyle(EditorButtonStyle())
        .padding(.horizontal, 16).frame(height: 48).studioGlass(cornerRadius: 0)
    }

    private var announcementInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("Post") {
                    Picker("Layout", selection: Binding(
                        get: { model.document.announcement?.arrangement ?? .headlineAbove },
                        set: { arrangement in model.change { $0.announcement?.arrangement = arrangement } }
                    )) {
                        ForEach(FeatureAnnouncement.Arrangement.allCases) { Text($0.title).tag($0) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Headline").font(.callout)
                        TextField("Headline", text: announcementText(\.headline, maximum: FeatureAnnouncement.headlineLimit), axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(2...3)
                            .help("Press Option-Return to insert a line break.")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Caption (optional)").font(.callout)
                        TextField("Caption", text: announcementText(\.caption, maximum: FeatureAnnouncement.captionLimit), axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(2...4)
                    }
                }
                if !model.document.screenshots.isEmpty {
                    section("Magnified Callout") { calloutControls }
                }
                section("Logo") {
                    if let logo = model.document.announcement?.logo {
                        Image(decorative: logo, scale: 1).resizable().scaledToFit().frame(height: 36)
                    }
                    HStack {
                        Button(model.document.announcement?.logo == nil ? "Add Logo…" : "Replace Logo…", action: importLogo)
                        if model.document.announcement?.logo != nil {
                            Button("Remove") { model.change { $0.announcement?.logo = nil } }
                        }
                    }
                }
                errorControls
            }.padding(16)
        }
        .scrollIndicators(.hidden)
        .background(EditorChrome.panel)
    }

    @ViewBuilder
    private var calloutControls: some View {
        if let draft = detailDraft {
            Text("Drag over the detail to magnify.").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Adjust Selection") {
                VStack(spacing: 6) {
                    detailSlider("Left", \.origin.x, range: 0...(1 - draft.width))
                    detailSlider("Top", \.origin.y, range: 0...(1 - draft.height))
                    detailSlider("Width", \.size.width, range: detailSizeRange(at: draft.minX))
                    detailSlider("Height", \.size.height, range: detailSizeRange(at: draft.minY))
                }.padding(.top, 7)
            }
            HStack {
                Button("Apply Callout", action: applyCallout).buttonStyle(.borderedProminent)
                Button("Cancel") { detailDraft = nil }
            }
        } else if let callout = model.document.announcement?.callout {
            HStack {
                Button("Edit Callout") { detailDraft = callout }
                Button("Remove") { model.change { $0.announcement?.callout = nil } }
                    .accessibilityLabel("Remove Callout")
            }
        } else {
            Button("Add Callout", systemImage: "plus.magnifyingglass") {
                detailDraft = FeatureAnnouncement.defaultCallout
            }
        }
    }

    private func applyCallout() {
        model.applyCalloutDraft()
    }

    private func detailSizeRange(at origin: CGFloat) -> ClosedRange<CGFloat> {
        let minimum = FeatureAnnouncement.minimumDetail
        return minimum...max(minimum, min(FeatureAnnouncement.maximumDetail, 1 - origin))
    }

    private func detailSlider(_ title: String, _ key: WritableKeyPath<CGRect, CGFloat>,
                              range: ClosedRange<CGFloat>) -> some View {
        InspectorSlider(title, value: Binding(get: { detailDraft?[keyPath: key] ?? range.lowerBound },
            set: { detailDraft?[keyPath: key] = $0 }), range: range, format: .percent())
    }

    private func announcementText(_ key: WritableKeyPath<FeatureAnnouncement, String>, maximum: Int) -> Binding<String> {
        Binding(get: { model.document.announcement?[keyPath: key] ?? "" }, set: { value in
            let limited = String(value.prefix(maximum))
            guard limited != model.document.announcement?[keyPath: key] else { return }
            model.change { $0.announcement?[keyPath: key] = limited }
        })
    }

    @ViewBuilder
    private var errorControls: some View {
        if let error = model.errorMessage {
            Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            Button("Dismiss") { model.errorMessage = nil }
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("Canvas") {
                    Menu("Aspect Ratio") {
                        ForEach(CanvasAspectRatio.allCases.filter { $0 != .auto }, id: \.self) { aspect in
                            Button(aspect.rawValue) { model.setCanvasAspect(aspect) }
                        }
                    }
                    valueSlider("Width", value: Binding(get: { model.document.size.width }, set: {
                        model.resizeCanvas(CGSize(width: $0, height: model.document.size.height))
                    }), range: 400...6000)
                    valueSlider("Height", value: Binding(get: { model.document.size.height }, set: {
                        model.resizeCanvas(CGSize(width: model.document.size.width, height: $0))
                    }), range: 400...6000)
                    backgroundControls
                }
                section("Layout") {
                    HStack {
                        Picker("Layout", selection: $layout) {
                            ForEach(ScreenshotCompositionLayout.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden()
                        Button("Arrange") { model.change { $0.arrange(layout) } }
                            .disabled(model.document.screenshots.isEmpty)
                    }
                    valueSlider("Padding", value: documentValue(\.padding),
                        range: 0...min(model.document.size.width, model.document.size.height) / 4)
                    valueSlider("Spacing", value: documentValue(\.spacing), range: 0...300)
                    Text("Padding keeps images inside the canvas. Spacing applies when you choose Arrange.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                section("Screenshots · \(model.document.screenshots.count)") {
                    if model.document.screenshots.isEmpty {
                        Text("Add images or capture a window to begin.").foregroundStyle(.secondary).font(.callout)
                    }
                    Text("Front to back").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.document.screenshots.reversed()) { item in
                        Button { model.selectedID = item.id } label: {
                            HStack(spacing: 8) {
                                Image(decorative: item.image, scale: 1).resizable().scaledToFit().frame(width: 42, height: 30)
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(EditorButtonStyle(selected: model.selectedID == item.id))
                        .accessibilityLabel("Select \(item.name)")
                        .accessibilityAddTraits(model.selectedID == item.id ? .isSelected : [])
                    }
                }
                if let selected = model.selection {
                    section("Selected Screenshot") {
                        Text(selected.name).font(.caption).lineLimit(2)
                        valueSlider("X", value: frameValue(\.origin.x), range: model.document.padding...max(model.document.padding, model.document.size.width - model.document.padding - selected.frame.width))
                        valueSlider("Y", value: frameValue(\.origin.y), range: model.document.padding...max(model.document.padding, model.document.size.height - model.document.padding - selected.frame.height))
                        valueSlider("Width", value: Binding(get: { model.selection?.frame.width ?? 1 }, set: { width in
                            guard let item = model.selection else { return }
                            var frame = item.frame
                            frame.size = CGSize(width: width, height: width * CGFloat(item.image.height) / CGFloat(item.image.width))
                            let fitted = model.document.fittedFrame(frame)
                            model.updateSelected { $0.frame = fitted }
                        }), range: 20...max(20, model.document.contentRect.width))
                        valueSlider("Corners", value: selectedValue(\.cornerRadius), range: 0...0.25, format: .percent())
                        valueSlider("Shadow", value: selectedValue(\.shadow), range: 0...1, format: .percent())
                        Picker("Shadow Style", selection: Binding(get: { model.selection?.shadowStyle ?? .soft }, set: { style in
                            model.updateSelected { $0.shadowStyle = style }
                        })) {
                            ForEach(AnnotationShadowStyle.allCases) { Text($0.title).tag($0) }
                        }
                        HStack {
                            Button("Backward", systemImage: "square.2.layers.3d.bottom.filled") { model.moveSelection(by: -1) }
                                .disabled(model.document.screenshots.first?.id == selected.id)
                            Button("Forward", systemImage: "square.2.layers.3d.top.filled") { model.moveSelection(by: 1) }
                                .disabled(model.document.screenshots.last?.id == selected.id)
                        }.controlSize(.small)
                        Button("Remove", systemImage: "trash", role: .destructive) { confirmRemove = true }
                    }
                }
                errorControls
            }.padding(16)
        }
        .scrollIndicators(.hidden)
        .background(EditorChrome.panel)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private var backgroundControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Background", selection: Binding(get: { backgroundKind }, set: { kind in
                model.change {
                    $0.background = kind == 0 ? .none : kind == 1 ? .solid(.graphite) : .gradient(AnnotationBackgroundGradient.presets[0])
                }
            })) {
                Text("Transparent").tag(0)
                Text("Color").tag(1)
                Text("Gradient").tag(2)
                if backgroundKind == 3 { Text("Default Wallpaper").tag(3) }
            }
            if case .solid(let color) = model.document.background {
                ColorPicker("Color", selection: Binding(get: { color.color }, set: { color in
                    model.change { $0.background = .solid(.custom(from: color)) }
                }), supportsOpacity: false)
            }
            if case .gradient(let current) = model.document.background {
                Picker("Gradient", selection: Binding(get: { current.id }, set: { id in
                    if let preset = AnnotationBackgroundGradient.presets.first(where: { $0.id == id }) {
                        model.change { $0.background = .gradient(preset) }
                    }
                })) {
                    ForEach(AnnotationBackgroundGradient.presets) { Text($0.title).tag($0.id) }
                }
            }
        }
    }

    private var backgroundKind: Int {
        switch model.document.background {
        case .none: 0
        case .solid: 1
        case .gradient: 2
        case .customWallpaper: 3
        }
    }

    private func valueSlider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>,
                             format: InspectorValueFormat = .pixels) -> some View {
        InspectorSlider(title, value: value, range: range, format: format, onEditingChanged: {
            if $0 { model.beginEditing() } else { model.endEditing() }
        })
    }

    private func documentValue(_ key: WritableKeyPath<ScreenshotComposition, CGFloat>) -> Binding<CGFloat> {
        Binding(get: { model.document[keyPath: key] }, set: { value in
            model.change { doc in
                doc[keyPath: key] = value
                for index in doc.screenshots.indices { doc.screenshots[index].frame = doc.fittedFrame(doc.screenshots[index].frame) }
            }
        })
    }

    private func selectedValue(_ key: WritableKeyPath<CompositionScreenshot, CGFloat>) -> Binding<CGFloat> {
        Binding(get: { model.selection?[keyPath: key] ?? 0 }, set: { value in model.updateSelected { $0[keyPath: key] = value } })
    }

    private func frameValue(_ key: WritableKeyPath<CGRect, CGFloat>) -> Binding<CGFloat> {
        Binding(get: { model.selection?.frame[keyPath: key] ?? 0 }, set: { value in
            guard var frame = model.selection?.frame else { return }
            frame[keyPath: key] = value
            let fitted = model.document.fittedFrame(frame)
            model.updateSelected { $0.frame = fitted }
        })
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let size = isAnnouncement ? announcementFormat.size : model.document.size
            let previewWidth = isAnnouncement && phonePreview ? min(390, proxy.size.width - 64) : proxy.size.width - 64
            let scale = max(0.01, min(previewWidth / size.width, (proxy.size.height - 64) / size.height))
            let renderScale = isAnnouncement ? min(1, scale * displayScale) : scale
            ZStack {
                EditorChrome.workspace
                ZStack(alignment: .topLeading) {
                    TransparencyGrid()
                    // The same renderer drives preview and export, so gradients,
                    // alpha, rounding and shadows cannot diverge between them.
                    if let image = try? ScreenshotCompositionRenderer.render(
                        model.document, scale: renderScale, format: announcementFormat, showsCalloutOutline: detailDraft == nil
                    ) {
                        Image(decorative: image, scale: 1).resizable()
                    }
                    if let draft = detailDraft, let announcement = model.document.announcement,
                       let media = announcement.layout(for: announcementFormat,
                           screenshot: model.document.screenshots.first?.image).media {
                        detailSelection(draft, screenshot: media.screenshotRect, canvasHeight: size.height, scale: scale)
                    } else if !isAnnouncement {
                        ForEach(model.document.screenshots) { item in
                            itemControls(item, scale: scale)
                        }
                    }
                    if model.document.screenshots.isEmpty && !isAnnouncement {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle").font(.largeTitle)
                            Text("Drop screenshots here").font(.title3.weight(.semibold))
                            Text("Or use Add Images and Capture Window above.").font(.callout)
                        }.foregroundStyle(.secondary).frame(width: size.width * scale, height: size.height * scale)
                    }
                }
                .frame(width: size.width * scale, height: size.height * scale)
                .clipped()
                .coordinateSpace(name: "compositionCanvas")
                .overlay(Rectangle().stroke(dropTarget ? EditorChrome.accent : EditorChrome.border, lineWidth: dropTarget ? 3 : 1))
            }
        }
    }

    private func detailSelection(_ draft: CGRect, screenshot: CGRect, canvasHeight: CGFloat, scale: CGFloat) -> some View {
        let width = screenshot.width * scale
        let height = screenshot.height * scale
        return Rectangle().fill(.clear)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.black.opacity(0.7), lineWidth: 3)
                    .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.white, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                    .frame(width: draft.width * width, height: draft.height * height)
                    .offset(x: draft.minX * width, y: draft.minY * height)
                    .allowsHitTesting(false)
            }
            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                let start = CGPoint(x: value.startLocation.x / width, y: value.startLocation.y / height)
                let end = CGPoint(x: value.location.x / width, y: value.location.y / height)
                if let detail = FeatureAnnouncement.detailSelection(from: start, to: end) {
                    detailDraft = detail
                }
            })
            .offset(x: screenshot.minX * scale, y: (canvasHeight - screenshot.maxY) * scale)
            .accessibilityHidden(true)
    }

    private func itemControls(_ item: CompositionScreenshot, scale: CGFloat) -> some View {
        let selected = model.selectedID == item.id
        return Rectangle().fill(.clear)
            .contentShape(Rectangle())
            .overlay { if selected { Rectangle().stroke(EditorChrome.accent, lineWidth: 2) } }
            .frame(width: item.frame.width * scale, height: item.frame.height * scale)
            .onTapGesture { model.selectedID = item.id }
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("compositionCanvas")).onChanged { value in
                if gestureFrame == nil { model.selectedID = item.id; gestureFrame = item.frame; model.beginEditing() }
                guard let start = gestureFrame else { return }
                let frame = model.document.fittedFrame(start.offsetBy(dx: value.translation.width / scale, dy: value.translation.height / scale))
                model.updateSelected { $0.frame = frame }
            }.onEnded { _ in gestureFrame = nil; model.endEditing() })
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(EditorChrome.accent, in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel("Resize screenshot; use Width in the inspector for keyboard input")
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("compositionCanvas")).onChanged { value in
                            if gestureFrame == nil { gestureFrame = item.frame; model.beginEditing() }
                            guard var frame = gestureFrame else { return }
                            let ratio = CGFloat(item.image.height) / CGFloat(item.image.width)
                            let delta = (value.translation.width + value.translation.height * ratio) / (1 + ratio * ratio) / scale
                            frame.size.width = max(20, frame.width + delta)
                            frame.size.height = frame.width * ratio
                            let fitted = model.document.fittedFrame(frame)
                            model.updateSelected { $0.frame = fitted }
                        }.onEnded { _ in gestureFrame = nil; model.endEditing() })
                }
            }
            .offset(x: item.frame.minX * scale, y: item.frame.minY * scale)
    }

    private var resolvedExportScale: CGFloat {
        exportScale == 0 ? model.document.sourceResolutionScale : exportScale
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if isAnnouncement {
                Picker("Preview", selection: $announcementFormat) {
                    ForEach(FeatureAnnouncement.Format.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 174)
                Toggle("Phone Size", isOn: $phonePreview).toggleStyle(.checkbox)
                    .help("Preview the post at up to 390 points wide.")
                Spacer()
                let size = announcementFormat.size
                Text("\(Int(size.width)) × \(Int(size.height)) px")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text("Drag to move · Drag the blue corner to resize").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Export Scale", selection: $exportScale) {
                    Text("Auto").tag(CGFloat(0))
                    Text("1×").tag(CGFloat(1)); Text("2×").tag(CGFloat(2)); Text("3×").tag(CGFloat(3))
                }.frame(width: 170)
                    .help("Auto keeps screenshots at least at their original pixel dimensions. Choose 1×, 2×, or 3× for a fixed output size.")
                Text("\(Int((model.document.size.width * resolvedExportScale).rounded())) × \(Int((model.document.size.height * resolvedExportScale).rounded())) px")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 16).frame(height: 44).studioGlass(cornerRadius: 0)
    }

    private func importImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = !isAnnouncement
        panel.canChooseDirectories = false
        panel.prompt = isAnnouncement ? "Choose Screenshot" : "Add Images"
        isImporting = true
        panel.begin { response in
            isImporting = false
            if response == .OK { model.importImages(panel.urls) }
        }
    }

    private func importLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose Logo"
        panel.begin { response in
            if response == .OK, let url = panel.url { model.importAnnouncementLogo(url) }
        }
    }

    private func importDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isImporting else { return false }
        isImporting = true
        Task { @MainActor in
            var urls: [URL] = []
            // Await in provider order so asynchronous decoding cannot reorder layers.
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        continuation.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                    }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            model.importImages(urls)
            if urls.isEmpty { model.errorMessage = "Drop image files from Finder, or use Add Images." }
            isImporting = false
        }
        return true
    }

    private func export() {
        guard !isExporting, canExport else { return }
        if isAnnouncement {
            let panel = NSOpenPanel()
            panel.title = "Export Both Sizes"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export Both Sizes"
            panel.begin { response in
                guard response == .OK, let directory = panel.url else { return }
                applyCallout()
                beginExport { snapshot in
                    try ScreenshotCompositionRenderer.exportAnnouncement(snapshot, to: directory)
                }
            }
            return
        }
        do { _ = try ScreenshotCompositionRenderer.outputSize(model.document, scale: resolvedExportScale) }
        catch { model.errorMessage = error.localizedDescription; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ScreenshotFileNaming.fileName(template: ScreenshotFileNaming.template(), extension: "png")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let scale = resolvedExportScale
            beginExport { snapshot in
                try ScreenshotCompositionRenderer.export(snapshot, scale: scale, to: url)
                return url
            }
        }
    }

    private func beginExport(_ write: @escaping @Sendable (ScreenshotComposition) throws -> URL) {
        guard !isExporting, canExport else { return }
        let snapshot = model.document
        isExporting = true
        transferStatus = .working(stage: .exporting, progress: nil)
        Task { @MainActor in
            do {
                let url = try await Task.detached(priority: .userInitiated) { try write(snapshot) }.value
                model.markExported(snapshot.revision)
                transferStatus = .exported(url: url)
            } catch {
                transferStatus = .failed(headline: "Export failed", message: error.localizedDescription, canRetry: true)
            }
            isExporting = false
        }
    }
}
