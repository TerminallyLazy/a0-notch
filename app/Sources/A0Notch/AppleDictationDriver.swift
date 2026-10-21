import AVFoundation
import Speech
import Foundation

/// Serializes the realtime tap against endAudio without transferring an audio buffer
/// onto the main actor. The request never escapes this locked sink.
private final class SpeechAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) { lock.lock(); defer { lock.unlock() }; request?.append(buffer) }
    func end() { lock.lock(); defer { lock.unlock() }; request?.endAudio(); request = nil }
    nonisolated func tap() -> AVAudioNodeTapBlock { { [self] buffer, _ in append(buffer) } }
}

/// Construction and capability inspection never request authorization or start capture.
@MainActor final class AppleDictationDriver: NSObject, DictationDriver, SFSpeechRecognizerDelegate {
    private var engine: AVAudioEngine?
    private var sink: SpeechAudioSink?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var update: (@MainActor @Sendable (String, Bool, String?) -> Void)?
    private var configurationObserver: NSObjectProtocol?
    private var sessionID = UUID()

    static var locales: [String] { SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted() }
    func supportsOnDevice(locale: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: locale))?.supportsOnDeviceRecognition == true
    }
    func authorize() async throws {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
        }
        try Task.checkCancellation()
        guard speech else { throw DictationFailure("Speech permission was denied or restricted. Enable a0_notch in System Settings → Privacy & Security → Speech Recognition.") }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        try Task.checkCancellation()
        guard microphone else { throw DictationFailure("Microphone permission was denied. Enable a0_notch in System Settings → Privacy & Security → Microphone.") }
    }
    func start(locale: String, onDeviceOnly: Bool, update: @escaping @MainActor @Sendable (String, Bool, String?) -> Void) throws {
        cancel()
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw DictationFailure("Microphone and Speech permission are required.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            throw DictationFailure("Speech recognition is currently unavailable for this language. Try again later.")
        }
        guard !onDeviceOnly || recognizer.supportsOnDeviceRecognition else {
            throw DictationFailure("On-device recognition is unavailable for this language. No audio was recorded.")
        }
        let id = sessionID
        self.recognizer = recognizer; self.update = update; recognizer.delegate = self
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDeviceOnly || recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        let sink = SpeechAudioSink(request)
        self.sink = sink
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            cancel(); throw DictationFailure("No usable microphone was found. Check your input device in Sound settings.")
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: sink.tap())
        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id else { return }
                self.update?("", false, "Audio input changed. Recording stopped; start a new dictation when ready.")
            }
        }
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString ?? ""
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id else { return }
                self.update?(text, final, failed ? "Speech recognition stopped. Check your microphone, language, network (if allowed), and privacy permissions." : nil)
            }
        }
        do { engine.prepare(); try engine.start() }
        catch { cancel(); throw DictationFailure("Microphone capture could not start. Check the selected audio input and try again.") }
    }
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        guard !available else { return }
        let identity = ObjectIdentifier(speechRecognizer)
        Task { @MainActor [weak self] in
            guard let self, let current = self.recognizer, ObjectIdentifier(current) == identity else { return }
            self.update?("", false, "Speech service became unavailable. Recording stopped.")
        }
    }
    func cancel() {
        sessionID = UUID()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil; sink?.end(); sink = nil
        recognitionTask?.cancel(); recognitionTask = nil
        recognizer?.delegate = nil; recognizer = nil; update = nil
    }
}
