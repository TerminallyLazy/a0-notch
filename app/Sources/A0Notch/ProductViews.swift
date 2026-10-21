import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NotchCore

struct InteractiveZero: View {
    @Bindable var store: IslandStore
    var size: CGFloat = 88
    @State private var dragging = false
    var body: some View {
        ZeroView(tint: store.tint, gaze: store.gaze, animated: store.mode != .hidden,
                 happy: store.characterState == .finished, state: store.characterState,
                 emote: store.interaction.emote, outfit: store.wardrobe.resolved(),
                 paused: store.suspended || store.mode == .hidden, waving: store.interaction.waving)
            .frame(width: size, height: size)
            .opacity(store.desktopVisible ? 0.18 : 1)
            .contentShape(Rectangle())
            .onHover { store.interaction.hover($0) }
            .onTapGesture {
                if store.mode == .expanded { store.interaction.slap() }
                else { store.open() }
            }
            .gesture(DragGesture(minimumDistance: 7).onChanged { _ in
                if !dragging { dragging = true; store.avatarDragging = true; store.interaction.play(.surprised) }
            }.onEnded { _ in
                dragging = false; store.avatarDragging = false; store.desktop?.show(at: NSEvent.mouseLocation)
            })
            .contextMenu {
                Button("Wardrobe…") { store.wardrobePresented = true }
                Button(store.desktopVisible ? "Return to notch" : "Move Zero to desktop") { store.toggleDesktop() }
                Button(store.soundMuted ? "Unmute" : "Mute") { store.toggleSound() }
            }
            .popover(isPresented: $store.wardrobePresented) {
                WardrobeView(wardrobe: store.wardrobe) { _ in store.interact() }.padding(16)
            }
            .accessibilityLabel("Zero, \(store.characterState.rawValue)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { store.open() }
    }
}

struct ExpandedContent: View {
    @Bindable var store: IslandStore
    @FocusState private var composerFocused: Bool
    @FocusState private var uploadFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch store.expanded.content {
            case .attention(let entry): alert(entry)
            case .finished(let event):
                HStack {
                    InteractiveZero(store: store, size: 92)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Response delivered").font(A0Brand.ui(20, weight: .medium))
                        if event.context == store.focusedIdentity {
                            Text(store.lastResponse.isEmpty ? "Open this chat to see the response." : store.lastResponse).lineLimit(3)
                        } else { Text("A chat finished. Its content has not been loaded.").foregroundStyle(A0Theme.muted) }
                        Button("View chat") { store.focus(event.context); store.navigate(.result) }
                    }
                }
            case .view(let view, _):
                switch view {
                case .prompt: composer
                case .upload, .uploading, .choose: upload
                case .result: result
                case .note:
                    Text(store.mutationMessage).lineLimit(3)
                    Button("Overview") { store.navigate(.overview) }
                case .working: overview(working: true)
                default: overview(working: false)
                }
            }
        }
        .font(A0Brand.ui(12)).padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { composerFocused = store.islandEditing && store.transfer.phase != .staged }
        .onChange(of: store.composerRequested) { _, _ in composerFocused = true }
        .onChange(of: composerFocused) { _, value in store.islandComposerEditing = value; store.islandEditing = value || uploadFocused }
        .onChange(of: uploadFocused) { _, value in store.islandEditing = value || composerFocused }
    }
    private func alert(_ entry: AttentionQueue.Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: entry.kind == .error ? "exclamationmark.triangle" : "bubble.left")
                    .foregroundStyle(A0Theme.accent)
                Text(entry.kind == .error ? "An error needs your attention" : "Agent Zero is waiting for input")
                    .font(A0Brand.ui(17, weight: .medium))
                Spacer()
                Text("\(store.expanded.attention.entries.count) queued").font(A0Brand.mono(10))
            }
            if entry.id.context != store.focusedIdentity {
                Text("Chat \(entry.id.context.contextID). Select View to load its recent activity. Your selected chat has not changed.")
                    .foregroundStyle(A0Theme.muted).lineLimit(3)
                Button("View this chat") { store.viewAlert(entry) }.buttonStyle(IslandButtonStyle(primary: true))
            } else {
                if entry.kind == .error {
                    Text(store.chatSnapshot?.logs.last(where: { $0.type == "error" })?.content ?? store.activityLine)
                        .foregroundStyle(A0Theme.error).lineLimit(2)
                    HStack {
                        Button("Draft retry request") { store.draft = "Please investigate the error and retry if safe."; store.showChats() }
                        Button("Open in WebUI", action: store.openWebUI)
                    }
                } else {
                    Text(store.activityLine).lineLimit(1)
                    composer
                }
            }
            Button("Dismiss this notification") { store.dismissAlert(entry.id) }
                .foregroundStyle(A0Theme.accent)
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let row = store.focused {
                let captured = store.target
                Text("MESSAGE TO \(store.name(row))").font(A0Brand.mono(10)).foregroundStyle(A0Theme.accent)
                TextField("Ask or reply to Agent Zero…", text: Binding(
                    get: { store.target == captured ? store.draft : "" },
                    set: { if store.target == captured { store.draft = $0 } }))
                    .id(store.selection).focused($composerFocused).textFieldStyle(.roundedBorder)
                    .disabled(store.mutationBusy).accessibilityIdentifier("notch-composer")
                HStack {
                    Button("Send") { store.perform(.send, target: captured) }
                        .buttonStyle(IslandButtonStyle(primary: true))
                        .disabled(!store.canMutate || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Menu("Nudge draft") {
                        ForEach(["Continue", "Explain your approach", "Stop and explain the current state"], id: \.self) { text in
                            Button(text) { if store.target == captured { store.draft = text } }
                        }
                    }
                    DictationControls(store: store, surface: .island)
                    ModelInformationControl(store: store)
                    Button("Full chat", action: store.showChats)
                }
                if !store.mutationMessage.isEmpty { Text(store.mutationMessage).font(A0Brand.ui(10)).lineLimit(2) }
            } else {
                Text("Select a chat before composing.")
                Button("All chats…", action: store.showChats)
            }
        }
    }
    private func overview(working: Bool) -> some View {
        HStack(spacing: 14) {
            InteractiveZero(store: store, size: store.presentation == .slim ? 68 : 96)
            VStack(alignment: .leading, spacing: 7) {
                if let row = store.focused {
                    Text(store.name(row)).font(A0Brand.ui(17, weight: .medium)).lineLimit(1)
                    Text(working && row.running ? "Agent Zero is on it…" : store.activityLine).lineLimit(2)
                    ForEach(Array(store.recentEvents.filter { $0.context_id == row.id && $0.incarnation == row.incarnation }.suffix(2)), id: \.sequence) { event in
                        HStack(spacing: 5) {
                            Text(event.kind.replacingOccurrences(of: "_", with: " "))
                            Text(event.tool).lineLimit(1)
                            if let diff = event.diff {
                                Button("\(diff.path) +\(diff.added) −\(diff.removed)") { store.showDiff.toggle() }
                                    .lineLimit(1)
                            }
                        }.font(A0Brand.mono(10)).foregroundStyle(A0Theme.muted)
                    }
                    HStack(spacing: 6) {
                        Button("Ask") { store.navigate(.prompt) }
                        Button("Result") { store.navigate(.result) }
                        Button("Files…", action: store.pickFiles).disabled(!store.canMutate)
                    }
                } else {
                    Text(store.contexts.isEmpty ? "Agent Zero is idle." : "Choose your conversation.").font(A0Brand.ui(20, weight: .medium))
                    Text("\(store.contexts.count) chats discovered. Content loads only when you select one.").foregroundStyle(A0Theme.muted)
                    Button("Open chats", action: store.showChats)
                }
                if store.interaction.dizzy { Text("Too many slaps at once.").foregroundStyle(A0Theme.accent) }
                if store.showDiff {
                    Text("Diff metadata only — counts reflect the observed tool change, not a full diff.").font(A0Brand.ui(10))
                }
            }
        }
    }
    private var result: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last response").font(A0Brand.ui(20, weight: .medium))
            ScrollView { Text(store.lastResponse.isEmpty ? "No response in the recent window." : store.lastResponse).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Button("Open full chat", action: store.showChats)
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.lastResponse, forType: .string) }
                Button("Ask again") { store.navigate(.prompt) }
            }
        }
    }
    private var upload: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Files for \(store.focused.map(store.name) ?? "selected chat")").font(A0Brand.ui(17, weight: .medium))
            switch store.transfer.phase {
            case .staged:
                Text(store.transfer.files.map { $0.url.lastPathComponent }.joined(separator: ", ")).lineLimit(2)
                TextField("Optional message sent with files", text: $store.uploadPrompt).focused($uploadFocused).textFieldStyle(.roundedBorder)
                    .onAppear { uploadFocused = true }
                Text("Files are delivered as normal chat attachments. Nothing is sent until you confirm.").font(A0Brand.ui(10))
                HStack {
                    Button("Send files", action: store.uploadFiles).buttonStyle(IslandButtonStyle(primary: true)).disabled(!store.canMutate)
                    Button("Cancel", action: store.cancelUpload)
                }
            case .uploading:
                ProgressView("Delivering attachments…")
                Text("Waiting for a server receipt. Byte progress is unavailable.").font(A0Brand.ui(10))
                Button("Cancel locally", action: store.cancelUpload)
            case .result:
                Text("Files delivered to the selected chat.")
                HStack {
                    Button("Ask about files") { store.chooseFiles(.askAboutFiles) }
                    Button("Open in chat") { store.chooseFiles(.openInChat) }
                }
            case .ambiguous(let message), .failed(let message):
                Text(message).foregroundStyle(A0Theme.accent)
                Button("Open WebUI", action: store.openWebUI)
            case .cancelled(let outcome):
                Text(outcome == .remoteOutcomeUnknown ? "Cancelled locally. Remote delivery may have occurred." : "Files were not sent.")
            default:
                Button("Choose files…", action: store.pickFiles).disabled(!store.canMutate)
                Text("Or drop regular files onto the island after selecting a chat.")
            }
        }
    }
}

struct IslandFileDrop: DropDelegate {
    let store: IslandStore
    func validateDrop(info: DropInfo) -> Bool { store.canMutate && store.supportsUploads && info.hasItemsConforming(to: [.fileURL]) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard store.canMutate, (1...8).contains(providers.count) else { return false }
        let captured = store.target
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let data: Data? = await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in continuation.resume(returning: data) }
                }
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return }
                urls.append(url)
            }
            store.stageFiles(urls, target: captured)
        }
        return true
    }
}
