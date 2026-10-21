import Foundation
import AVFoundation

/// Stable resource names. These sounds are original synthesized cues, not sampled assets.
public enum NotchSound: String, CaseIterable, Codable, Sendable {
    case peek, greet, open, close, hover, blip, slap, annoyed, dizzy
    case work, think, search, attention, question, error, finish, approve
    case gulp, tick, send, attach, love, pop, proud, wink, yawn, sleep, happy
}

/// Pure, deterministic synthesis: RIFF/WAVE, signed PCM16 LE, 48 kHz, interleaved stereo.
/// No random source, clocks, files, third-party recordings or platform audio state.
public enum NotchSoundSynthesis {
    public static let sampleRate = 48_000
    public static let channels = 2
    public static let bitsPerSample = 16
    public static let recipeVersion = 1

    private struct Recipe {
        let notes: [Double]
        let duration: Double
        let glide: Double
        let roughness: Double
        init(_ notes: [Double], _ duration: Double, _ glide: Double = 1, _ roughness: Double = 0) {
            self.notes = notes
            self.duration = duration
            self.glide = glide
            self.roughness = roughness
        }
    }

    private static func recipe(_ sound: NotchSound) -> Recipe {
        switch sound {
        case .peek: return Recipe([660, 880], 0.18, 1.12)
        case .greet: return Recipe([523.25, 659.25, 783.99], 0.42)
        case .open: return Recipe([320, 480], 0.25, 1.55)
        case .close: return Recipe([480, 320], 0.23, 0.65)
        case .hover: return Recipe([1046.5], 0.07, 1.04)
        case .blip: return Recipe([880], 0.055, 0.85)
        case .slap: return Recipe([160], 0.12, 0.5, 0.7)
        case .annoyed: return Recipe([220, 207.65], 0.27, 0.88, 0.25)
        case .dizzy: return Recipe([440, 554, 370, 622, 330], 0.65, 0.8, 0.1)
        case .work: return Recipe([330, 440], 0.16, 1, 0.12)
        case .think: return Recipe([587.33, 880], 0.34, 1.08)
        case .search: return Recipe([740, 988, 740], 0.32, 1.05)
        case .attention: return Recipe([659.25, 659.25, 880], 0.58)
        case .question: return Recipe([440, 587.33], 0.36, 1.3)
        case .error: return Recipe([293.66, 233.08, 196], 0.48, 0.9, 0.18)
        case .finish: return Recipe([523.25, 659.25, 783.99, 1046.5], 0.7)
        case .approve: return Recipe([659.25, 880], 0.26)
        case .gulp: return Recipe([220, 110], 0.22, 0.52, 0.2)
        case .tick: return Recipe([1320], 0.04, 0.9, 0.15)
        case .send: return Recipe([440, 880], 0.23, 1.4)
        case .attach: return Recipe([392, 523.25, 659.25], 0.3, 1, 0.05)
        case .love: return Recipe([523.25, 659.25, 523.25, 783.99], 0.72)
        case .pop: return Recipe([330], 0.13, 2.4)
        case .proud: return Recipe([392, 523.25, 783.99], 0.53)
        case .wink: return Recipe([988, 740], 0.16, 0.95)
        case .yawn: return Recipe([220, 174.61], 0.8, 0.75)
        case .sleep: return Recipe([261.63, 196, 130.81], 1.0, 0.98)
        case .happy: return Recipe([659.25, 783.99, 1046.5, 783.99], 0.48, 1.08)
        }
    }

    public static func duration(of sound: NotchSound) -> TimeInterval { recipe(sound).duration }

    public static func wavData(for sound: NotchSound) -> Data {
        let spec = recipe(sound)
        let frames = Int((spec.duration * Double(sampleRate)).rounded())
        let byteCount = frames * channels * bitsPerSample / 8
        var data = Data(capacity: 44 + byteCount)
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func word(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func dword(_ value: UInt32) {
            word(UInt16(truncatingIfNeeded: value))
            word(UInt16(truncatingIfNeeded: value >> 16))
        }
        text("RIFF"); dword(UInt32(36 + byteCount)); text("WAVE")
        text("fmt "); dword(16); word(1); word(UInt16(channels))
        dword(UInt32(sampleRate)); dword(UInt32(sampleRate * 4)); word(4); word(16)
        text("data"); dword(UInt32(byteCount))
        var noiseState: UInt32 = 0xA0C0FFEE
        for frame in 0..<frames {
            let position = Double(frame) / Double(frames - 1) * Double(spec.notes.count)
            let note = min(spec.notes.count - 1, Int(position))
            let local = min(1, position - Double(note))
            let noteLength = spec.duration / Double(spec.notes.count)
            let t = local * noteLength
            // Analytically integrated linear chirp; every note starts/ends at zero gain.
            let phase = 2 * Double.pi * spec.notes[note]
                * (t + (spec.glide - 1) * t * t / (2 * noteLength))
            let envelope = pow(sin(Double.pi * local), 1.6) * exp(-1.7 * local)
            noiseState = 1_664_525 &* noiseState &+ 1_013_904_223
            let noise = Double(noiseState) / Double(UInt32.max) * 2 - 1
            let tone = sin(phase) + 0.18 * sin(2 * phase) + 0.06 * sin(3 * phase)
            let mono = (tone * (1 - spec.roughness) + noise * spec.roughness) * envelope * 0.58
            let pan = 0.12 * sin(Double(frame) / Double(sampleRate) * 2 * Double.pi * 1.7)
            for gain in [1 - pan, 1 + pan] {
                let bounded = max(-0.95, min(0.95, mono * gain))
                word(UInt16(bitPattern: Int16((bounded * 32767).rounded())))
            }
        }
        return data
    }

    /// Explicit export only; normal playback needs no disk assets. Refuses existing files.
    public static func writeWAVs(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for sound in NotchSound.allCases {
            let path = directory.appendingPathComponent(sound.rawValue).appendingPathExtension("wav")
            try wavData(for: sound).write(to: path, options: .withoutOverwriting)
        }
    }
}

/// Injectable seam for silent tests. All production voices are preloaded AVAudioPlayers.
@MainActor
public protocol NotchSoundVoice: AnyObject {
    var isPlaying: Bool { get }
    var volume: Float { get set }
    var currentTime: TimeInterval { get set }
    @discardableResult func prepareToPlay() -> Bool
    @discardableResult func play() -> Bool
    func pause()
    func stop()
}

extension AVAudioPlayer: NotchSoundVoice {}

@MainActor
public final class NotchSoundPlayer {
    public enum PlaybackResult: Equatable, Sendable { case played, muted, unavailable }
    public enum LoadError: Error { case preparationFailed(NotchSound) }
    public typealias VoiceFactory = @MainActor (Data) throws -> any NotchSoundVoice

    private final class Voice {
        let player: any NotchSoundVoice
        var sequence: UInt64 = 0
        init(_ player: any NotchSoundVoice) { self.player = player }
    }
    private let defaults: UserDefaults
    private let keyPrefix: String
    private var pool: [NotchSound: [Voice]] = [:]
    private var sequence: UInt64 = 0
    public let maximumConcurrentVoices: Int
    public let voicesPerSound: Int
    public private(set) var isMuted: Bool
    public private(set) var volume: Double
    public var onPlaybackFailure: ((NotchSound) -> Void)?

    /// Call once at startup, not from an animation frame. At most 28 * 4 players allocated.
    /// Throwing initialization leaves no partially usable player; callers may continue silently.
    public init(defaults: UserDefaults = .standard, keyPrefix: String = "a0_notch.sound",
                maximumConcurrentVoices: Int = 8, voicesPerSound: Int = 2,
                voiceFactory: VoiceFactory = { try AVAudioPlayer(data: $0) }) throws {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        self.maximumConcurrentVoices = min(16, max(1, maximumConcurrentVoices))
        self.voicesPerSound = min(4, max(1, voicesPerSound))
        isMuted = defaults.bool(forKey: keyPrefix + ".muted")
        let saved = defaults.object(forKey: keyPrefix + ".volume") as? NSNumber
        volume = Self.normalizedVolume(saved?.doubleValue ?? 0.12)
        for sound in NotchSound.allCases {
            let data = NotchSoundSynthesis.wavData(for: sound)
            var voices: [Voice] = []
            for _ in 0..<self.voicesPerSound {
                let player = try voiceFactory(data)
                player.volume = Float(volume)
                guard player.prepareToPlay() else { throw LoadError.preparationFailed(sound) }
                voices.append(Voice(player))
            }
            pool[sound] = voices
        }
    }

    private static func normalizedVolume(_ value: Double) -> Double {
        value.isFinite ? min(0.2, max(0, value)) : 0.12
    }
    public var activeVoiceCount: Int { pool.values.flatMap { $0 }.filter { $0.player.isPlaying }.count }
    public var preloadedVoiceCount: Int { pool.values.reduce(0) { $0 + $1.count } }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        defaults.set(muted, forKey: keyPrefix + ".muted")
        if muted { stopAll() }
    }
    public func toggleMute() { setMuted(!isMuted) }
    public func setVolume(_ value: Double) {
        volume = Self.normalizedVolume(value)
        defaults.set(volume, forKey: keyPrefix + ".volume")
        for voice in pool.values.flatMap({ $0 }) { voice.player.volume = Float(volume) }
        if volume == 0 { stopAll() }
    }

    /// Overlapping cues layer; saturation steals the oldest active voice, never queues.
    /// No new audio players or synthesized data are created on this path.
    @discardableResult
    public func play(_ sound: NotchSound) -> PlaybackResult {
        guard !isMuted, volume > 0 else { return .muted }
        guard let voices = pool[sound], !voices.isEmpty else { return .unavailable }
        let chosen = voices.first(where: { !$0.player.isPlaying })
            ?? voices.min(by: { $0.sequence < $1.sequence })!
        if !chosen.player.isPlaying, activeVoiceCount >= maximumConcurrentVoices {
            let oldest = pool.values.flatMap { $0 }.filter { $0.player.isPlaying }
                .min(by: { $0.sequence < $1.sequence })
            oldest?.player.pause()
        }
        chosen.player.pause()
        chosen.player.currentTime = 0
        chosen.player.volume = Float(volume)
        sequence &+= 1
        chosen.sequence = sequence
        guard chosen.player.play() else {
            onPlaybackFailure?(sound)
            return .unavailable
        }
        return .played
    }

    /// Layer a cue group, e.g. [.peek, .greet], subject to the same global voice budget.
    @discardableResult
    public func play(_ sounds: [NotchSound]) -> [PlaybackResult] { sounds.map { play($0) } }

    public func stopAll() {
        for voice in pool.values.flatMap({ $0 }) {
            voice.player.pause()
            voice.player.currentTime = 0
        }
    }
    /// Releases preloaded audio resources. Further play calls return .unavailable.
    public func shutdown() {
        for voice in pool.values.flatMap({ $0 }) { voice.player.stop() }
        pool.removeAll()
        onPlaybackFailure = nil
    }
}
