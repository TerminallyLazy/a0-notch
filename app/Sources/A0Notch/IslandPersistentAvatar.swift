import AppKit
import SwiftUI
import NotchCore

/// One instance per context survives compact/expanded layout changes.
struct IslandPersistentAvatar: View {
    @Bindable var store: IslandStore
    let context: LiveContext?
    let main: Bool
    @Environment(IslandMotionState.self) private var motion

    var body: some View {
        ZStack {
            ZeroView(tint: context.map(store.color) ?? store.tint, gaze: main ? store.gaze : .zero,
                     animated: main && !store.desktopVisible && !motion.avatarDragging,
                     happy: main ? store.characterState == .finished : context?.activity == .finished,
                     state: main ? store.characterState : .idle,
                     emote: main ? store.interaction.emote : nil,
                     outfit: store.wardrobe.resolved(), paused: store.suspended || store.mode == .hidden,
                     waving: main && store.interaction.waving, fileHover: main && motion.fileHover)
                .opacity(main && (motion.avatarDragging || store.desktopVisible) ? 0 : 1)
                .allowsHitTesting(false)
            if main {
                IslandAvatarInput(motion: motion)
            } else if let context {
                Button { store.focus(context) } label: { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Focus context \(store.name(context)), \(context.activity.rawValue)")
                    .help(store.name(context))
            }
        }
        .popover(isPresented: Binding(get: { main && store.wardrobePresented },
                                      set: { if main { store.wardrobePresented = $0 } })) {
            WardrobeView(wardrobe: store.wardrobe) { _ in store.interact() }.padding(16)
        }
    }
}
