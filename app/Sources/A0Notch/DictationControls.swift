import SwiftUI
import AppKit

/// Wire beside a composer. Consent is bound to the exact selection at click time.
struct DictationControls: View {
    @Bindable var store: IslandStore
    let surface: IslandStore.DictationSurface
    @State private var presented = false
    @State private var consentSelection: UUID?
    var body: some View {
        Button {
            consentSelection = store.selection
            presented = true
        } label: {
            Label(store.dictation.active ? "Listening…" : "Dictate", systemImage: store.dictation.active ? "mic.fill" : "mic")
        }
        .disabled(!store.canDictate && !store.dictation.active)
        .accessibilityLabel("Dictate into this chat draft")
        .help("Review microphone privacy options before starting. Never sends automatically.")
        .popover(isPresented: $presented) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Dictate a draft").font(.headline)
                Text(store.dictationOnDeviceOnly
                     ? "Audio stays on this Mac. If on-device recognition is unavailable, capture will not start."
                     : "On-device recognition is preferred. If unavailable, audio may be sent to Apple for recognition. Agent Zero receives no text until you explicitly send the draft.")
                    .font(.caption)
                if store.dictation.phase == .idle {
                    Button("Start microphone — I agree") {
                        guard consentSelection == store.selection else { presented = false; return }
                        store.beginDictation(surface: surface, consent: true)
                    }.disabled(!store.canDictate)
                }
                Text(store.dictation.message).font(.caption).foregroundStyle(store.dictation.phase == .failed ? A0Theme.error : A0Theme.muted)
                if !store.dictation.transcript.isEmpty {
                    ScrollView { Text(store.dictation.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 130)
                }
                HStack {
                    if store.dictation.active { Button("Stop recording", action: store.stopDictation) }
                    else if !store.dictation.transcript.isEmpty {
                        Button("Insert into draft") { if store.insertDictation() { presented = false } }
                    }
                    Button("Cancel", role: .cancel) { store.cancelDictation(); presented = false }
                }
                Text("Maximum 45 seconds. Changing chat, connection, or leaving this composer cancels dictation.").font(.caption2)
            }.padding(18).frame(width: 340)
        }
        .onChange(of: presented) { _, showing in if !showing { store.cancelDictation() } }
        .onChange(of: store.selection) { _, _ in presented = false }
        .onDisappear { if store.dictationSurface == surface { store.cancelDictation() } }
    }
}

struct ModelInformationControl: View {
    let store: IslandStore
    @State private var presented = false
    var body: some View {
        Button(store.modelInformation) { store.loadModelPresets(); presented = true }
            .lineLimit(1)
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(store.modelInformation).font(.headline)
                    Text(store.modelSettingsGuidance).font(.caption)
                    Text(store.modelPresetMessage).font(.caption)
                    if let list = store.modelPresets, let captured = store.modelPresetTarget {
                        ScrollView {
                            VStack(alignment: .leading) {
                                ForEach(list.presets) { preset in
                                    Button {
                                        store.selectModelPreset(preset.id, target: captured)
                                    } label: {
                                        Text((preset.id == list.current_id ? "✓ " : "") + preset.label + (preset.model.isEmpty ? "" : " · " + preset.model))
                                    }.disabled(!store.canMutate || !list.allowed || captured != store.target)
                                }
                                Button("Use inherited preset") { store.selectModelPreset(nil, target: captured) }
                                    .disabled(!store.canMutate || !list.allowed || captured != store.target)
                            }
                        }.frame(maxHeight: 180)
                    }
                    Button("Open A0 model settings (in WebUI)", action: store.openModelSettings)
                    Text("Opens the WebUI; choose Settings → Models there. No automatic settings deep-link is available.").font(.caption2)
                }.padding(18).frame(width: 340)
            }
            .onChange(of: store.selection) { _, _ in presented = false }
    }
}
