import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NotchCore

struct IslandView: View {
    let store: IslandStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(IslandMotionState.self) private var motion
    @State private var contentVisible = false
    @State private var retainsExpanded = false
    private var overview: Bool {
        if case .view(let view, _) = store.expanded.content { return view == .overview || view == .working || view == .empty }
        return false
    }
    private var hasInlineAvatar: Bool {
        if case .finished = store.expanded.content { return true }
        return overview
    }
    private var slim: Bool { store.presentation == .slim }
    private var contentInset: Double { store.geometry.contentTopInset(hardwareNotchHeight: store.hardwareNotchHeight) }

    var body: some View {
        let geometry = store.geometry
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                Path(geometry.path).fill(store.presentation == .notch ? .black : A0Theme.background)
                if store.mode == .expanded || retainsExpanded {
                    expanded
                        .frame(width: store.presentation.expandedWidth,
                               height: store.presentation.contentHeight(hasContexts: !store.contexts.isEmpty))
                        .padding(.top, contentInset)
                        .opacity(contentVisible ? 1 : 0)
                        .blur(radius: contentVisible || reduceMotion ? 0 : 8)
                        .scaleEffect(contentVisible || reduceMotion ? 1 : 0.97)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: contentVisible)
                } else {
                    compact
                }
                avatarLayer
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .overlay(alignment: .bottom) {
                if store.mode == .expanded && store.countdown < 1 {
                    Capsule().fill(.white.opacity(0.35))
                        .frame(width: 160 * store.countdown, height: 2).padding(.bottom, 3)
                        .accessibilityHidden(true)
                }
            }
            .overlay { Path(geometry.path).stroke(motion.fileHover ? A0Theme.accent : A0Theme.border, lineWidth: motion.fileHover ? 2 : store.presentation == .notch ? 0 : 1) }
            .overlay(alignment: .bottom) {
                if motion.fileHover {
                    Text("Drop to stage files · confirmation required").font(A0Brand.ui(11))
                        .padding(8).background(A0Theme.panel, in: Capsule()).padding(.bottom, 4)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(Path(geometry.path))
            .contentShape(Path(geometry.path))
            .offset(y: geometry.topOffset)
        }
        .frame(width: 720, height: 320, alignment: .top)
        .font(A0Brand.ui(13))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task(id: store.mode) {
            contentVisible = false
            guard store.mode == .expanded else {
                if retainsExpanded && !reduceMotion { try? await Task.sleep(for: .milliseconds(160)) }
                guard !Task.isCancelled else { return }
                retainsExpanded = false
                return
            }
            retainsExpanded = true
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(160)) }
            guard !Task.isCancelled else { return }
            contentVisible = true
        }
        .environment(\.zeroAnimationPaused, store.suspended || store.mode == .hidden)
        // Tiny compact breathing/blinks need fewer redraws than expanded expressions.
        .environment(\.zeroFrameInterval, store.mode == .expanded ? 1.0 / 30 : 1.0 / 20)
        // Geometry is animated once by the native controller, not again by SwiftUI.
        .transaction { $0.animation = nil }
    }

    private var compact: some View {
        HStack {
            Spacer().frame(width: 50)
            if store.mode == .compact && contentInset == 0 {
                Text("\(store.focused?.name ?? "Idle") · \(store.live.mode.rawValue)")
                    .font(A0Brand.mono(slim ? 10 : 11)).foregroundStyle(A0Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 40)
        }.frame(height: store.geometry.size.height)
    }

    // Nodes never move between conditional branches. Native geometry drives their
    // centers and sizes, so interrupted transitions preserve both identity and pose.
    private var avatarLayer: some View {
        let rows = Array(store.orderedContexts.prefix(4))
        let visible = rows + (store.focused.map { focus in rows.contains(where: { $0.id == focus.id }) ? [] : [focus] } ?? [])
        let mainID = store.focused?.id ?? "__zero_home__"
        let minis = visible.filter { $0.id != mainID }
        let progress = IslandAvatarLayout.expansion(height: store.geometry.size.height,
            collapsedHeight: store.presentation == .capsule ? 36 : max(24, store.hardwareNotchHeight),
            expandedHeight: store.presentation.contentHeight(hasContexts: !store.contexts.isEmpty) + contentInset)
        return ZStack(alignment: .topLeading) {
            if store.focused == nil {
                avatar(nil, main: true, index: 0, count: minis.count, progress: progress)
            }
            ForEach(visible, id: \.id) { context in
                avatar(context, main: context.id == mainID,
                       index: minis.firstIndex(where: { $0.id == context.id }) ?? 0,
                       count: minis.count, progress: progress)
                    .id(context.id + ":" + (context.incarnation ?? "legacy"))
            }
        }
        .frame(width: store.geometry.size.width, height: store.geometry.size.height)
        .allowsHitTesting(store.mode != .hidden)
    }

    private func avatar(_ context: LiveContext?, main: Bool, index: Int, count: Int, progress: Double) -> some View {
        let pose = IslandAvatarLayout.pose(main: main, index: index, count: count,
            width: store.geometry.size.width, height: store.geometry.size.height, inset: contentInset,
            expansion: progress, overview: overview, hidden: store.mode == .hidden,
            hasNotch: store.hasNotch && store.presentation == .notch, peek: store.mode == .peek)
        return IslandPersistentAvatar(store: store, context: context, main: main)
            .frame(width: pose.side, height: pose.side)
            .position(pose.center)
            .opacity(pose.opacity)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.72), value: main)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: overview)
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            header
            ExpandedContent(store: store)
                .environment(\.zeroReplacedByIslandLayer, true)
                .padding(.leading, hasInlineAvatar ? 0 : 98)
                .padding(.trailing, overview ? 84 : 38)
            if !store.contexts.isEmpty { contextStrip }

        }
        .padding(.bottom, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            AgentZeroWordmark().frame(width: slim ? 96 : 108, height: 18)
            Text("/ notch").font(A0Brand.ui(10)).foregroundStyle(A0Theme.muted)
            Spacer(minLength: 8)
            Button("Ask") { store.navigate(.prompt) }.buttonStyle(.plain)
            Button("Files") { store.navigate(.upload) }.buttonStyle(.plain)
            Button { store.toggleSound() } label: { Image(systemName: store.soundMuted ? "speaker.slash" : "speaker.wave.2") }
                .buttonStyle(.plain).accessibilityLabel("Toggle sound")
            Text(store.connectionLabel).font(A0Brand.mono(9, weight: .medium)).foregroundStyle(A0Theme.accent)
            Button { store.close() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Collapse island").accessibilityLabel("Collapse island")
        }
        .frame(height: 36)
        .padding(.horizontal, 20)
    }

    private var contextStrip: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(store.orderedContexts) { context in contextButton(context).frame(width: 128) }
                }
            }
            Button("Chats (\(store.contexts.count))…", action: store.showChats)
                .buttonStyle(IslandButtonStyle(primary: true))
        }
        .padding(.top, 7)
        .overlay(alignment: .top) { Rectangle().fill(A0Theme.border).frame(height: 0.5) }
        .padding(.horizontal, 20)
        .frame(height: 42)
    }

    private func contextButton(_ context: LiveContext) -> some View {
        let selected = context.id == store.focused?.id
        return Button { store.focus(context) } label: {
            HStack(spacing: 3) {
                Circle().fill(context.activity.color).frame(width: 5, height: 5)
                Text(store.name(context)).font(A0Brand.ui(slim ? 10 : 11, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(selected ? A0Theme.messageBackground : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) {
                if selected { Capsule().fill(A0Theme.accent).frame(width: 18, height: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Follow \(context.name) · \(context.activity.rawValue)")
        .accessibilityLabel("Focus context \(context.name), \(context.activity.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

}

private extension ContextActivity {
    var stream: String {
        switch self {
        case .idle, .paused: "HDL"
        case .error: "ERR"
        case .thinking: "GEN"
        case .working: "USE"
        case .browsing: "WWW"
        case .delegating: "SUB"
        case .finished: "END"
        }
    }
}

struct IslandButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(A0Brand.ui(12, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(primary ? (configuration.isPressed ? A0Theme.okPressed : A0Theme.ok) : Color.white.opacity(0.09), in: Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
    }
}

/// Intentional keyboard-focus surface; opening it is always a user action.
struct ChatWorkspace: View {
    @Bindable var store: IslandStore
    @State private var search = ""
    @FocusState private var composerFocused: Bool
    @State private var stopTarget: ChatTarget?
    @State private var stopName = ""
    @State private var confirmStop = false
    private var filtered: [LiveContext] {
        search.isEmpty ? store.orderedContexts : store.orderedContexts.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                AgentZeroWordmark().frame(width: 142, height: 26).padding(.vertical, 8)
                TextField("Search all chats", text: $search).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search all chats")
                HStack {
                    Text("\(filtered.count) CHATS").font(A0Brand.mono(10)).foregroundStyle(A0Theme.muted)
                    Spacer()
                    Button { store.createChat() } label: { Image(systemName: "square.and.pencil") }
                        .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!store.canCreate).help("Create new chat").accessibilityLabel("Create new chat")
                }
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filtered) { chat in
                            Button { store.focus(chat) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Circle().fill(chat.activity.color).frame(width: 6, height: 6).padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(store.name(chat)).font(A0Brand.ui(13, weight: .medium)).lineLimit(2)
                                        Text(chat.parent_id == nil ? chat.state.rawValue.capitalized : "Subordinate chat · \(chat.state.rawValue)")
                                            .font(A0Brand.ui(10)).foregroundStyle(A0Theme.muted)
                                        Text(chat.id).font(A0Brand.mono(9)).foregroundStyle(A0Theme.muted).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(chat.id == store.focusedID ? A0Theme.messageBackground : .clear, in: RoundedRectangle(cornerRadius: 9))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityAddTraits(chat.id == store.focusedID ? .isSelected : [])
                        }
                    }
                }
                Text(store.connectionLabel).font(A0Brand.mono(11)).foregroundStyle(A0Theme.accent)
                Button("Connection settings…", action: store.showConnection)
            }.padding(18).frame(minWidth: 210, idealWidth: 240, maxWidth: 300)
            VStack(alignment: .leading, spacing: 0) {
                if let chat = store.focused {
                    chatHeader(chat)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            HStack(alignment: .top) {
                                ZeroView(tint: store.tint, animated: store.animatesActivity, happy: chat.state == .finished)
                                    .frame(width: 72, height: 72)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(store.activityLine).font(A0Brand.ui(18, weight: .medium))
                                    Text(store.chatMessage).font(A0Brand.ui(11)).foregroundStyle(A0Theme.muted)
                                }.padding(.top, 12)
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                Text("LAST RESPONSE").font(A0Brand.mono(10)).foregroundStyle(A0Theme.accent)
                                Text(store.lastResponse.isEmpty ? "No response in the recent activity window. Open the WebUI for full history." : store.lastResponse)
                                    .font(A0Brand.ui(14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(18).background(A0Theme.panel, in: RoundedRectangle(cornerRadius: 18))
                            VStack(alignment: .leading, spacing: 9) {
                                Text("RECENT ACTIVITY").font(A0Brand.mono(10)).foregroundStyle(A0Theme.muted)
                                ForEach(Array((store.chatSnapshot?.logs ?? []).sorted { $0.no > $1.no }.prefix(20))) { row in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(row.heading.isEmpty ? row.type.capitalized : row.heading).font(A0Brand.ui(12, weight: .medium))
                                        if row.type == "user" || row.type == "response" {
                                            Text(row.content).font(A0Brand.ui(12)).foregroundStyle(A0Theme.muted).lineLimit(4)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                                }
                            }
                        }.padding(22)
                    }
                    composer(chat)
                } else {
                    VStack(spacing: 14) {
                        ZeroView(tint: A0Theme.accent, animated: false).frame(width: 120, height: 120)
                        Text(store.live.mode == .live ? "Start a conversation." : "Connect to Agent Zero.").font(A0Brand.ui(24, weight: .medium))
                        Text(store.connectionMessage).foregroundStyle(A0Theme.muted).multilineTextAlignment(.center)
                        Button(store.live.mode == .live ? "Create new chat" : "Connection settings…") {
                            if store.live.mode == .live { store.createChat() } else { store.showConnection() }
                        }.buttonStyle(IslandButtonStyle(primary: true)).disabled(store.live.mode == .live && !store.canCreate)
                    }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !store.mutationMessage.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            if store.mutationBusy { ProgressView().controlSize(.small) }
                            Text(store.mutationMessage).font(A0Brand.ui(12)).fixedSize(horizontal: false, vertical: true)
                        }
                        if store.uncertainOutcome {
                            HStack {
                                Button("Open WebUI", action: store.openWebUI)
                                Button("I've checked the chat", action: store.acknowledgeOutcome)
                            }
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(A0Theme.panel)
                }
            }.frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(A0Brand.ui(13)).background(A0Theme.background).foregroundStyle(.white).preferredColorScheme(.dark)
        .onChange(of: composerFocused) { _, value in store.chatComposerEditing = value }
        .onDisappear { store.chatComposerEditing = false }
        .onChange(of: store.selection) { _, _ in confirmStop = false; stopTarget = nil }
        .confirmationDialog("Stop work in “\(stopName)”?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop this chat", role: .destructive) {
                if let stopTarget { store.perform(.stop, target: stopTarget) }
            }
            Button("Cancel", role: .cancel) { stopTarget = nil }
        } message: { Text("The running process will be cancelled. Chat history is preserved. This does not stop other chats.") }
    }
    private func chatHeader(_ chat: LiveContext) -> some View {
        let captured = ChatTarget(context: chat.id, generation: store.live.generation, selection: store.selection, incarnation: chat.incarnation)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.name(chat)).font(A0Brand.ui(17, weight: .medium)).lineLimit(1)
                Text("\(store.connectedOrigin) · \(chat.id)").font(A0Brand.mono(10)).foregroundStyle(A0Theme.muted).lineLimit(1)
            }
            Spacer()
            Button(store.chatSnapshot?.paused == true ? "Resume" : "Pause") {
                store.perform(.pause(!(store.chatSnapshot?.paused ?? false)), target: captured)
            }.disabled(!store.canMutate)
            Button("Stop…") { stopTarget = captured; stopName = chat.name; confirmStop = true }
                .disabled(!store.canMutate || !chat.running)
        }.padding(18)
    }
    private func composer(_ chat: LiveContext) -> some View {
        let captured = ChatTarget(context: chat.id, generation: store.live.generation, selection: store.selection, incarnation: chat.incarnation)
        return VStack(alignment: .leading, spacing: 9) {
            Text("MESSAGE TO \(chat.name)").font(A0Brand.mono(10)).foregroundStyle(A0Theme.accent).lineLimit(1)
            TextEditor(text: Binding(get: { store.target == captured ? store.draft : "" },
                                     set: { if store.target == captured { store.draft = $0 } }))
                .id(store.selection).focused($composerFocused).font(A0Brand.ui(14)).scrollContentBackground(.hidden)
                .padding(8).frame(height: 76).background(A0Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("notch-composer")
                .accessibilityLabel("Message or intervention reply to \(chat.name)")
                .disabled(store.mutationBusy)
            HStack {
                DictationControls(store: store, surface: .chat)
                ModelInformationControl(store: store)
                Text("Replies and interventions use the normal chat message flow.")
                    .font(A0Brand.ui(10)).foregroundStyle(A0Theme.muted)
                Spacer()
                Button("Send  ⌘↩") { store.perform(.send, target: captured) }
                    .buttonStyle(IslandButtonStyle(primary: true))
                    .disabled(!store.canMutate || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.draft.utf8.count > 64 * 1024)
            }
        }.padding(18).background(A0Theme.background)
    }
}
