import SwiftUI
import NotchCore

struct IslandView: View {
    let store: IslandStore
    private var slim: Bool { store.presentation == .slim }
    private var contentInset: Double { store.geometry.contentTopInset(hardwareNotchHeight: store.hardwareNotchHeight) }

    var body: some View {
        let geometry = store.geometry
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                Path(geometry.path).fill(store.presentation == .notch ? .black : A0Theme.background)
                if store.mode == .expanded {
                    expanded
                        .frame(width: store.presentation.expandedWidth,
                               height: store.presentation.contentHeight(hasContexts: !store.contexts.isEmpty))
                        .padding(.top, contentInset)
                } else if store.mode != .hidden || !store.hasNotch || store.presentation != .notch {
                    compact
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .overlay(alignment: .bottom) {
                if store.mode == .expanded && store.countdown < 1 {
                    Capsule().fill(.white.opacity(0.35))
                        .frame(width: 160 * store.countdown, height: 2).padding(.bottom, 3)
                        .accessibilityHidden(true)
                }
            }
            .overlay { Path(geometry.path).stroke(A0Theme.border, lineWidth: store.presentation == .notch ? 0 : 1) }
            .clipShape(Path(geometry.path))
            .contentShape(Path(geometry.path))
            .offset(y: geometry.topOffset)
        }
        .frame(width: 720, height: 320, alignment: .top)
        .font(A0Brand.ui(13))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        // Geometry is animated once by the native controller, not again by SwiftUI.
        .transaction { $0.animation = nil }
    }

    private var compact: some View {
        HStack(spacing: 0) {
            Button { store.open() } label: {
                ZeroView(tint: store.tint, gaze: store.gaze, animated: store.mode != .hidden && store.animatesActivity,
                         happy: store.focused?.activity == .finished)
                    .frame(width: store.mode == .peek ? 26 : 34, height: store.geometry.size.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open a0_notch")
            .help("Open activity overview")
            if store.mode != .hidden {
                Spacer(minLength: 0)
                if store.mode == .compact {
                    // Never place a centered label underneath a physical camera cutout,
                    // including while an appearance transition crosses the menu bar.
                    if contentInset == 0 {
                        Text("\(store.focused?.name ?? "Idle") · \(store.live.mode.rawValue)")
                            .font(A0Brand.mono(slim ? 10 : 11)).foregroundStyle(A0Theme.muted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 3) {
                        ForEach(store.contexts.prefix(4)) { context in
                            Capsule().fill(context.activity.color)
                                .frame(width: 3, height: context.id == store.focusedID ? 12 : 6)
                        }
                    }
                    .frame(width: 24)
                    .accessibilityLabel("\(store.contexts.count) contexts")
                }
            }
        }
        .padding(.horizontal, store.mode == .hidden ? 0 : (store.mode == .peek ? 3 : 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            header
            if store.contexts.isEmpty {
                empty
            } else {
                activity
                contextStrip
            }
        }
        .padding(.bottom, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            AgentZeroWordmark().frame(width: slim ? 96 : 108, height: 18)
            Text("/ notch").font(A0Brand.ui(10)).foregroundStyle(A0Theme.muted)
            Spacer(minLength: 8)
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

    private var activity: some View {
        HStack(spacing: slim ? 2 : 12) {
            ZeroView(tint: store.tint, gaze: store.gaze, animated: store.animatesActivity, happy: store.focused?.activity == .finished)
                .frame(width: slim ? 100 : 136, height: slim ? 104 : 132)
            VStack(alignment: .leading, spacing: slim ? 7 : 10) {
                HStack(spacing: 6) {
                    Circle().fill(store.tint).frame(width: 5, height: 5)
                    Text(store.focused?.name ?? "Main").font(A0Brand.ui(11, weight: .medium))
                    Text("/ \(store.focused?.activity.rawValue ?? "idle")")
                        .font(A0Brand.mono(10)).foregroundStyle(A0Theme.muted)
                }
                Text(store.lastResponse.isEmpty ? store.activityLine : store.lastResponse)
                    .font(A0Brand.ui(slim ? 18 : 22, weight: .medium))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: store.focused?.activity.symbol ?? "circle")
                        .font(.system(size: 11))
                    Text("\(store.focused?.activity.stream ?? "HDL")  ·  \("live activity")")
                        .font(A0Brand.mono(10))
                }
                .foregroundStyle(store.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // A single quiet activity wash; no nested dashboard cards.
            RadialGradient(colors: [store.tint.opacity(slim ? 0.08 : 0.13), .clear],
                           center: .leading, startRadius: 0, endRadius: 300)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }

    private var contextStrip: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(store.contexts) { context in contextButton(context).frame(width: 128) }
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
        return Button { store.focus(context.id) } label: {
            HStack(spacing: 3) {
                ZeroView(tint: context.activity.color, animated: false,
                         happy: context.activity == .finished).frame(width: slim ? 22 : 28, height: 28)
                Text(context.name).font(A0Brand.ui(slim ? 10 : 11, weight: selected ? .medium : .regular))
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

    private var empty: some View {
        HStack(spacing: slim ? 4 : 16) {
            ZeroView(tint: A0Theme.accent, gaze: store.gaze, animated: store.animatesActivity).frame(width: slim ? 96 : 124, height: 120)
            VStack(alignment: .leading, spacing: 8) {
                Text("Ready when you are.").font(A0Brand.ui(slim ? 18 : 22, weight: .medium))
                Text(store.live.mode == .live ? "Connected. Your chats appear automatically.\nCreate a chat to get started." : "\(store.live.mode.rawValue.capitalized).\nUse Connection settings in the menu.")
                    .font(A0Brand.ui(12)).foregroundStyle(A0Theme.muted)
                Button(store.live.mode == .live ? "Open chats" : "Connection settings…") {
                    if store.live.mode == .live { store.showChats() } else { store.showConnection() }
                }.buttonStyle(IslandButtonStyle(primary: true))
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @State private var stopTarget: ChatTarget?
    @State private var stopName = ""
    @State private var confirmStop = false
    private var filtered: [LiveContext] {
        search.isEmpty ? store.contexts : store.contexts.filter {
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
                            Button { store.focus(chat.id) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Circle().fill(chat.activity.color).frame(width: 6, height: 6).padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(chat.name).font(A0Brand.ui(13, weight: .medium)).lineLimit(2)
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
        .onChange(of: store.selection) { _, _ in confirmStop = false; stopTarget = nil }
        .confirmationDialog("Stop work in “\(stopName)”?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop this chat", role: .destructive) {
                if let stopTarget { store.perform(.stop, target: stopTarget) }
            }
            Button("Cancel", role: .cancel) { stopTarget = nil }
        } message: { Text("The running process will be cancelled. Chat history is preserved. This does not stop other chats.") }
    }
    private func chatHeader(_ chat: LiveContext) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.name).font(A0Brand.ui(17, weight: .medium)).lineLimit(1)
                Text("\(store.connectedOrigin) · \(chat.id)").font(A0Brand.mono(10)).foregroundStyle(A0Theme.muted).lineLimit(1)
            }
            Spacer()
            Button(store.chatSnapshot?.paused == true ? "Resume" : "Pause") {
                store.perform(.pause(!(store.chatSnapshot?.paused ?? false)), target: store.target)
            }.disabled(!store.canMutate)
            Button("Stop…") { stopTarget = store.target; stopName = chat.name; confirmStop = true }
                .disabled(!store.canMutate || !chat.running)
        }.padding(18)
    }
    private func composer(_ chat: LiveContext) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("MESSAGE TO \(chat.name)").font(A0Brand.mono(10)).foregroundStyle(A0Theme.accent).lineLimit(1)
            TextEditor(text: Binding(get: { store.focusedID == chat.id ? store.draft : "" },
                                     set: { if store.focusedID == chat.id { store.draft = $0 } }))
                .id(chat.id).font(A0Brand.ui(14)).scrollContentBackground(.hidden)
                .padding(8).frame(height: 76).background(A0Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("Message or intervention reply to \(chat.name)")
                .disabled(store.mutationBusy)
            HStack {
                Text("Replies and interventions use the normal chat message flow.")
                    .font(A0Brand.ui(10)).foregroundStyle(A0Theme.muted)
                Spacer()
                Button("Send  ⌘↩") { store.perform(.send, target: store.target) }
                    .buttonStyle(IslandButtonStyle(primary: true)).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.canMutate || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.draft.utf8.count > 64 * 1024)
            }
        }.padding(18).background(A0Theme.background)
    }
}
