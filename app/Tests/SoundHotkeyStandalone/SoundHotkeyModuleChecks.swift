import AppKit
import AVFoundation
import Carbon
import Foundation

@MainActor
private final class FakeSoundVoice: NotchSoundVoice {
    var isPlaying = false
    var volume: Float = 0
    var currentTime: TimeInterval = 0
    var prepared = false
    var canPrepare = true
    var canPlay = true
    func prepareToPlay() -> Bool { prepared = true; return canPrepare }
    func play() -> Bool { isPlaying = canPlay; return canPlay }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
}

@MainActor
private final class FakeHotkeyRegistrar: NotchHotkeyRegistering {
    var onAction: ((NotchHotkeyAction) -> Void)?
    var codes: [NotchHotkeyAction: Int32] = [:]
    var registered: [NotchHotkeyBinding] = []
    var shutdownCount = 0
    func register(_ binding: NotchHotkeyBinding) -> Int32 {
        let code = codes[binding.action] ?? 0
        if code == 0 { registered.append(binding) }
        return code
    }
    func unregisterAll() { registered.removeAll() }
    func shutdown() { unregisterAll(); onAction = nil; shutdownCount += 1 }
}

@main
@MainActor
private enum SoundHotkeyModuleChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String,
                      file: StaticString = #file, line: UInt = #line) {
        precondition(condition(), message, file: file, line: line)
    }
    static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(u16(bytes, offset)) | UInt32(u16(bytes, offset + 2)) << 16
    }

    static func checkSynthesis() throws {
        let expected = Set("peek greet open close hover blip slap annoyed dizzy work think search attention question error finish approve gulp tick send attach love pop proud wink yawn sleep happy".split(separator: " ").map(String.init))
        check(Set(NotchSound.allCases.map(\.rawValue)) == expected, "all 28 specified sounds")
        var unique = Set<Data>()
        for sound in NotchSound.allCases {
            let wav = NotchSoundSynthesis.wavData(for: sound)
            check(wav == NotchSoundSynthesis.wavData(for: sound), "deterministic \(sound)")
            check(unique.insert(wav).inserted, "distinct recipe \(sound)")
            let bytes = Array(wav)
            check(String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF", "RIFF")
            check(String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE", "WAVE")
            check(String(bytes: bytes[12..<16], encoding: .ascii) == "fmt ", "fmt chunk")
            check(String(bytes: bytes[36..<40], encoding: .ascii) == "data", "data chunk")
            check(u32(bytes, 4) == UInt32(bytes.count - 8), "RIFF byte count")
            check(u32(bytes, 16) == 16 && u16(bytes, 20) == 1, "PCM encoding")
            check(u16(bytes, 22) == 2 && u32(bytes, 24) == 48_000, "48k stereo")
            check(u32(bytes, 28) == 192_000 && u16(bytes, 32) == 4 && u16(bytes, 34) == 16, "PCM16 layout")
            check(u32(bytes, 40) == UInt32(bytes.count - 44), "data byte count")
            let frames = (bytes.count - 44) / 4
            check(abs(Double(frames) / 48_000 - NotchSoundSynthesis.duration(of: sound)) < 1 / 48_000.0, "duration")
            var peak = 0
            var differs = false
            for offset in stride(from: 44, to: bytes.count, by: 4) {
                let left = Int(Int16(bitPattern: u16(bytes, offset)))
                let right = Int(Int16(bitPattern: u16(bytes, offset + 2)))
                peak = max(peak, max(abs(left), abs(right)))
                differs = differs || left != right
            }
            check(peak > 500 && peak < 31_200, "non-silent unclipped PCM")
            check(differs, "stereo image")
            check(u32(bytes, 44) == 0 && u32(bytes, bytes.count - 4) == 0, "silent envelope endpoints")
            let decoder = try AVAudioPlayer(data: wav)
            check(decoder.numberOfChannels == 2, "AVFoundation accepts PCM")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("a0-sound-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try NotchSoundSynthesis.writeWAVs(to: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        check(Set(names) == Set(expected.map { $0 + ".wav" }), "complete export")
        do {
            try NotchSoundSynthesis.writeWAVs(to: directory)
            preconditionFailure("export must not overwrite")
        } catch { /* existing assets are protected */ }
        print("PASS: deterministic original WAVs, PCM layout, decoder, export protection")
    }

    static func checkPlayback(_ defaults: UserDefaults) throws {
        var voices: [FakeSoundVoice] = []
        let player = try NotchSoundPlayer(defaults: defaults, maximumConcurrentVoices: 3, voicesPerSound: 2) { _ in
            let voice = FakeSoundVoice(); voices.append(voice); return voice
        }
        check(player.volume == 0.12 && !player.isMuted, "audio defaults")
        check(player.preloadedVoiceCount == 56 && voices.allSatisfy(\.prepared), "all players prepared once")
        check(player.play([.peek, .greet]) == [.played, .played], "layered greeting")
        check(player.activeVoiceCount == 2, "concurrent layers")
        player.play(.peek)
        check(player.activeVoiceCount == 3, "second same-sound voice")
        player.play(.peek)
        check(player.activeVoiceCount == 3, "bounded same-sound voice stealing")
        player.play(.error)
        check(player.activeVoiceCount == 3 && voices.count == 56, "global cap and no new player allocation")
        player.setMuted(true)
        check(player.activeVoiceCount == 0 && player.play(.finish) == .muted, "mute stops immediately")
        player.toggleMute()
        player.setVolume(100)
        check(player.volume == 0.2 && voices.allSatisfy { $0.volume == Float(0.2) }, "volume ceiling")
        player.setVolume(-1)
        check(player.volume == 0 && player.play(.tick) == .muted, "volume floor")
        player.setVolume(.nan)
        check(player.volume == 0.12, "nonfinite volume")
        player.setVolume(0.08)
        player.setMuted(true)
        let restored = try NotchSoundPlayer(defaults: defaults, voicesPerSound: 1) { _ in FakeSoundVoice() }
        check(restored.volume == 0.08 && restored.isMuted, "audio persistence")
        restored.shutdown()
        player.setMuted(false)
        voices.forEach { $0.canPlay = false }
        var failure: NotchSound?
        player.onPlaybackFailure = { failure = $0 }
        check(player.play(.sleep) == .unavailable && failure == .sleep, "play failure callback")
        player.shutdown()
        check(player.preloadedVoiceCount == 0 && player.play(.open) == .unavailable, "shutdown")
        do {
            _ = try NotchSoundPlayer(defaults: defaults) { _ in
                let voice = FakeSoundVoice(); voice.canPrepare = false; return voice
            }
            preconditionFailure("preparation failure must throw")
        } catch NotchSoundPlayer.LoadError.preparationFailed(.peek) { }
        print("PASS: audio preload, layering, budgets, mute, volume, persistence, failure, shutdown")
    }

    static func checkHotkeys(_ defaults: UserDefaults) {
        let registrar = FakeHotkeyRegistrar()
        let hotkeys = GlobalHotkeys(defaults: defaults, registrar: registrar)
        check(registrar.registered.isEmpty, "no registration during init")
        let expectedKeys: [NotchHotkeyAction: UInt32] = [.toggleIsland: 45, .openPrompt: 49, .goToAlert: 0,
            .openWebUI: 32, .attachWindow: 13, .nextContext: 30, .previousContext: 33, .mute: 46,
            .desktopZero: 2, .wardrobe: 5]
        check(hotkeys.bindings.count == 10, "exact action count")
        for binding in hotkeys.bindings {
            check(binding.chord.keyCode == expectedKeys[binding.action], "default physical key")
            let modifiers: NotchHotkeyModifiers = binding.action == .toggleIsland ? [.command, .shift] : [.control, .option]
            check(binding.chord.modifiers == modifiers, "default modifiers")
            check(binding.isEnabled == (binding.action != .toggleIsland), "default enablement")
        }
        check(NotchHotkeyModifiers([.command, .shift]).carbonFlags == UInt32(cmdKey | shiftKey), "Carbon conversion")
        hotkeys.start()
        check(registrar.registered.count == 9 && hotkeys.status(for: .toggleIsland) == .disabled, "default registrations")
        var received: [NotchHotkeyAction] = []
        hotkeys.onAction = { received.append($0) }
        registrar.onAction?(.mute)
        check(received == [.mute], "action dispatch")
        hotkeys.setEnabled(false, for: .mute)
        registrar.onAction?(.mute)
        check(received.count == 1 && registrar.registered.count == 8, "disabled dispatch guarded")
        hotkeys.setEnabled(true, for: .mute)
        let duplicate = hotkeys.binding(for: .goToAlert).chord
        check(hotkeys.setShortcut(duplicate, for: .openPrompt), "set shortcut")
        check(hotkeys.status(for: .openPrompt) == .internalConflict([.goToAlert]), "internal conflict A")
        check(hotkeys.status(for: .goToAlert) == .internalConflict([.openPrompt]), "internal conflict B")
        check(registrar.registered.count == 7, "neither duplicate registered")
        hotkeys.setEnabled(false, for: .goToAlert)
        check(hotkeys.status(for: .openPrompt) == .registered, "disabled duplicate ignored")
        registrar.codes[.openWebUI] = OSStatus(eventHotKeyExistsErr)
        registrar.codes[.attachWindow] = OSStatus(paramErr)
        hotkeys.retryRegistration()
        check(hotkeys.status(for: .openWebUI) == .systemConflict(OSStatus(eventHotKeyExistsErr)), "system conflict")
        check(hotkeys.status(for: .attachWindow) == .registrationFailed(OSStatus(paramErr)), "nonconflict failure")
        registrar.codes = [:]
        hotkeys.resetAll()
        var recording: [GlobalHotkeys.RecordingResult] = []
        hotkeys.onRecordingResult = { recording.append($0) }
        hotkeys.beginRecording(for: .mute)
        check(registrar.registered.isEmpty && hotkeys.status(for: .mute) == .recording, "recording suspends all")
        check(!hotkeys.record(keyCode: 46, modifiers: [.shift]), "plain/shift typing rejected")
        check(hotkeys.recordingAction == .mute, "invalid capture stays open")
        check(hotkeys.record(keyCode: 46, modifiers: [.command, .control]), "capture valid shortcut")
        check(hotkeys.recordingAction == nil && registrar.registered.count == 9, "recording resumes registrations")
        let savedChord = hotkeys.binding(for: .mute).chord
        hotkeys.beginRecording(for: .mute)
        hotkeys.cancelRecording()
        check(recording.last == .cancelled(.mute) && hotkeys.binding(for: .mute).chord == savedChord, "cancel preserves value")
        hotkeys.beginRecording(for: .mute)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        check(hotkeys.recordingAction == nil, "deactivation cancels recorder")
        check(!hotkeys.setShortcut(.init(keyCode: 999, modifiers: [.control]), for: .mute), "invalid key rejected")
        check(!hotkeys.setShortcut(.init(keyCode: 56, modifiers: [.control]), for: .mute), "modifier key rejected")
        let restored = GlobalHotkeys(defaults: defaults, registrar: FakeHotkeyRegistrar())
        check(restored.binding(for: .mute).chord == savedChord, "shortcut persistence")
        restored.shutdown()
        hotkeys.stop()
        check(registrar.registered.isEmpty && hotkeys.status(for: .mute) == .stopped, "stop cleanup")
        hotkeys.start()
        check(registrar.registered.count == 9, "restart")
        hotkeys.resetAll()
        check(hotkeys.bindings == NotchHotkeyBinding.defaults, "reset all")
        hotkeys.shutdown()
        check(registrar.registered.isEmpty && registrar.shutdownCount == 1 && registrar.onAction == nil, "final cleanup")
        defaults.set(Data("not JSON".utf8), forKey: "a0_notch.hotkeys.v1")
        let corrupt = GlobalHotkeys(defaults: defaults, registrar: FakeHotkeyRegistrar())
        check(corrupt.bindings == NotchHotkeyBinding.defaults, "corrupt preferences fall back")
        corrupt.shutdown()
        print("PASS: hotkey defaults, callbacks, internal/system conflicts, recording, persistence, lifecycle")
    }

    static func carbonSmoke() {
        let first = CarbonNotchHotkeyRegistrar()
        let second = CarbonNotchHotkeyRegistrar()
        defer { first.shutdown(); second.shutdown() }
        let binding = NotchHotkeyBinding(action: .openPrompt,
            chord: .init(keyCode: UInt32(kVK_F18), modifiers: [.control, .option, .command]), isEnabled: true)
        let result = first.register(binding)
        check(result == noErr, "Carbon smoke key unavailable or no GUI session: \(result)")
        check(second.register(binding) == OSStatus(eventHotKeyExistsErr), "real Carbon duplicate conflict")
        first.shutdown()
        check(second.register(binding) == noErr, "Carbon key released by shutdown")
        print("PASS: actual Carbon registration, OS conflict and release (not physical callback delivery)")
    }

    static func main() throws {
        _ = NSApplication.shared
        let suite = "a0-notch.sound-hotkey-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try checkSynthesis()
        try checkPlayback(defaults)
        checkHotkeys(defaults)
        if CommandLine.arguments.contains("--carbon-smoke") { carbonSmoke() }
        if CommandLine.arguments.contains("--audio-smoke") {
            let player = try NotchSoundPlayer(defaults: defaults)
            defer { player.shutdown() }
            player.setMuted(false)
            player.setVolume(0.12)
            check(player.play([.peek, .greet]) == [.played, .played], "actual audio play")
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            print("PASS: AVAudioPlayer start; audible quality still requires human listening")
        }
        if let index = CommandLine.arguments.firstIndex(of: "--export-wavs"), index + 1 < CommandLine.arguments.count {
            try NotchSoundSynthesis.writeWAVs(to: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
            print("Exported original WAV recipe v\(NotchSoundSynthesis.recipeVersion)")
        }
        print("PASS: standalone sound/hotkey module checks")
    }
}
