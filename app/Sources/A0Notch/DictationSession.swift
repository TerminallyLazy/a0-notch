import Foundation
import Observation

/// Native I/O is injected so tests never ask for permission or open an audio device.
@MainActor protocol DictationDriver: AnyObject {
    func authorize() async throws
    func supportsOnDevice(locale: String) -> Bool
    func start(locale: String, onDeviceOnly: Bool, update: @escaping @MainActor @Sendable (String, Bool, String?) -> Void) throws
    func cancel()
}

@MainActor @Observable final class DictationSession {
    enum Phase: Equatable { case idle, authorizing, recording, review, failed }
    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private(set) var message = "Dictation only fills a draft. Nothing is sent automatically."
    var active: Bool { phase == .authorizing || phase == .recording }
    @ObservationIgnored private let driver: any DictationDriver
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var ticket = UUID()
    @ObservationIgnored private let duration: Duration

    init(driver: any DictationDriver, duration: Duration = .seconds(45)) {
        self.driver = driver; self.duration = duration
    }
    func supportsOnDevice(locale: String) -> Bool { driver.supportsOnDevice(locale: locale) }

    /// Caller must obtain explicit consent for this specific attempt first.
    func begin(locale: String, onDeviceOnly: Bool, consent: Bool) {
        guard consent else { return }
        cancel()
        let id = ticket
        phase = .authorizing; message = "Waiting for microphone and Speech permission…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await driver.authorize()
                guard ticket == id, !Task.isCancelled else { return }
                if onDeviceOnly && !driver.supportsOnDevice(locale: locale) {
                    throw DictationFailure("On-device speech is unavailable for this language. Choose another language or explicitly allow Apple server recognition in Settings.")
                }
                try driver.start(locale: locale, onDeviceOnly: onDeviceOnly) { [weak self] text, final, error in
                    guard let self, self.ticket == id, self.phase == .recording else { return }
                    if !text.isEmpty { self.transcript = String(text.prefix(16_000)) }
                    if let error { self.finish(error: error) }
                    else if final { self.finish() }
                }
                phase = .recording
                message = "Listening · stops after 45 seconds · review before inserting"
                timer = Task { [weak self, duration] in
                    do { try await Task.sleep(for: duration) } catch { return }
                    guard let self, self.ticket == id else { return }
                    self.finish()
                }
            } catch {
                guard ticket == id, !Task.isCancelled else { return }
                finish(error: (error as? DictationFailure)?.message ?? "Dictation could not start. Check Speech and Microphone access in System Settings, then try again.")
            }
        }
    }
    /// Stop immediately; keep the most recent partial result for explicit review.
    func finish(error: String? = nil) {
        ticket = UUID(); task?.cancel(); task = nil; timer?.cancel(); timer = nil; driver.cancel()
        phase = error == nil ? .review : .failed
        message = error ?? (transcript.isEmpty ? "No speech detected. Try again when ready." : "Review your words, then insert into the draft. Nothing has been sent.")
    }
    func cancel() {
        ticket = UUID(); task?.cancel(); task = nil; timer?.cancel(); timer = nil
        driver.cancel(); transcript = ""; phase = .idle
        message = "Dictation only fills a draft. Nothing is sent automatically."
    }
}

struct DictationFailure: Error { let message: String; init(_ message: String) { self.message = message } }
