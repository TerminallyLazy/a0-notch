import AppKit
import Darwin
import Foundation
import SwiftUI
import NotchCore

/// Parent compiles with real NotchCore and app sources EXCEPT A0NotchApp.swift.
/// Do not include another standalone @main or add this file to the app target.
/// Usage: IslandPerformanceChecks OUTPUT_DIRECTORY [--snapshots]
/// Run in an unlocked GUI session; park the pointer away from the top-center
/// island and leave it still. No network connection, fixture, or demo is started.
/// CPU includes this process's AppKit/SwiftUI and sampling overhead, not WindowServer.
@main
struct IslandPerformanceChecks {
    private struct Reading {
        let uptime: Double
        let cpuSeconds: Double
        let residentBytes: UInt64
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await execute()
            app.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { app.postEvent(event, atStart: true) }
        }
        app.run()
    }

    @MainActor static func execute() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let path = arguments.first, !path.hasPrefix("--"),
              arguments.dropFirst().allSatisfy({ $0 == "--snapshots" }) else {
            print("Usage: IslandPerformanceChecks OUTPUT_DIRECTORY [--snapshots]")
            exit(64)
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        var report: [String: Any] = [
            "schemaVersion": 1,
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "pid": ProcessInfo.processInfo.processIdentifier,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "cpuNormalization": "100 * delta(user + system seconds) / delta(monotonic wall seconds); 100% = one core",
            "rssSource": "task_info(MACH_TASK_BASIC_INFO).resident_size, bytes",
            "warmupSecondsPerMode": 3,
            "sampleCountPerMode": 12,
            "sampleIntervalSeconds": 1,
            "network": "Not connected; no HTTP fixture or connectLive call",
            "scope": "Real Store/controller/default main avatar, model-only compact activity seed; not live traffic, full app, or WindowServer cost",
            "performanceBudgetsAreInformational": true
        ]
        var succeeded = false
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            try require(!NSScreen.screens.isEmpty, "An unlocked macOS GUI session is required")
            let suite = "a0.notch.island-performance.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                throw failure("Cannot create isolated UserDefaults suite")
            }
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("", forKey: "connectionURL")
            defaults.set("", forKey: "connectionUsername")
            defaults.set("notch", forKey: "islandPresentation")
            let store = IslandStore(defaults: defaults, arguments: [])
            let controller = IslandWindowController(store: store)
            defer { controller.shutdown() }
            try require(store.connectionURL.isEmpty && !store.connecting && store.contexts.isEmpty,
                        "Store must start disconnected with no contexts")
            try require(!controller.visibleFrame.insetBy(dx: -30, dy: -30).contains(NSEvent.mouseLocation),
                        "Park the pointer away from the island before running")
            report["initialDiagnostics"] = controller.diagnostics()
            report["hidden"] = try await measure(mode: .hidden, store: store, controller: controller)

            // Reconcile requires a nonempty identity set; this seeds only the public
            // presentation model. Store.live/contexts/focused remain untouched, so
            // IslandView renders its real default main avatar, not a fake live chat.
            let identity = ProductContextIdentity(generation: UUID(),
                contextID: "performance-local", incarnation: "performance-local")
            store.expanded.reconcile(currentContexts: [identity], hasActivity: true, now: store.now)
            store.tick(hovering: false, moved: true)
            try require(store.mode == .compact, "Public reconciliation and tick must enter compact")
            report["compact"] = try await measure(mode: .compact, store: store, controller: controller)
            try require(store.contexts.isEmpty && store.focused == nil && store.connectionURL.isEmpty,
                        "Measurement must preserve disconnected default-avatar rendering")
            report["finalDiagnostics"] = controller.diagnostics()

            // Snapshot rendering and disk I/O happen only AFTER both timed phases.
            if arguments.contains("--snapshots") {
                var snapshots: [[String: Any]] = []
                for presentation in IslandPresentation.allCases {
                    store.selectPresentation(presentation)
                    for mode in [IslandMode.hidden, .compact, .expanded] {
                        store.expanded.reconcile(currentContexts: mode == .hidden ? [] : [identity],
                            hasActivity: mode != .hidden, now: store.now)
                        store.close()
                        store.tick(hovering: false, moved: true)
                        if mode == .expanded { store.open() }
                        await pump(seconds: 1)
                        try require(store.mode == mode, "Snapshot mode changed; keep pointer away from island")
                        let name = "\(presentation.rawValue)-\(mode.rawValue).png"
                        try snapshot(controller: controller, to: output.appendingPathComponent(name))
                        snapshots.append(["file": name, "diagnostics": controller.diagnostics()])
                    }
                }
                report["snapshots"] = snapshots
            }
            succeeded = true
        } catch {
            report["error"] = String(describing: error)
        }
        report["passed"] = succeeded
        report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("metrics.json"), options: .atomic)
            print("\(succeeded ? "PASS" : "FAIL"): \(output.appendingPathComponent("metrics.json").path)")
        } catch {
            print("FAIL: Could not write metrics.json: \(error)")
            exit(1)
        }
        if !succeeded { exit(1) }
    }

    @MainActor private static func measure(mode: IslandMode, store: IslandStore,
                                           controller: IslandWindowController) async throws -> [String: Any] {
        await pump(seconds: 3)
        try require(store.mode == mode, "Expected \(mode.rawValue) after warmup")
        try require(!store.suspended && controller.panel.isVisible, "Renderer must be visible and unsuspended")
        if mode == .compact {
            try require(!controller.motion.animationPaused, "Compact renderer must not be paused")
        }
        let beforeWakes = controller.driverWakeCount
        if mode == .hidden {
            try require(controller.motion.animationPaused, "Hidden renderer must be paused")
            try require(controller.diagnostics()["driverTimerActive"] as? Bool == false,
                        "Hidden mode must have no driver timer after warmup")
        }
        let first = try reading()
        var previous = first
        var samples: [[String: Any]] = []
        var peakRSS = first.residentBytes
        for index in 1...12 {
            await pump(seconds: 1)
            let current = try reading()
            try require(store.mode == mode && !store.suspended && controller.panel.isVisible,
                        "Mode/visibility changed during \(mode.rawValue) sample \(index)")
            if mode == .hidden {
                try require(controller.driverWakeCount == beforeWakes,
                            "Hidden driver timer woke during sampling")
                try require(controller.diagnostics()["driverTimerActive"] as? Bool == false,
                            "Hidden mode installed a timer during sampling")
            }
            let elapsed = current.uptime - previous.uptime
            samples.append(["index": index, "elapsedSeconds": elapsed,
                "cpuSeconds": current.cpuSeconds - previous.cpuSeconds,
                "cpuOneCorePercent": 100 * (current.cpuSeconds - previous.cpuSeconds) / elapsed,
                "rssBytes": current.residentBytes, "driverWakeCount": controller.driverWakeCount])
            peakRSS = max(peakRSS, current.residentBytes)
            previous = current
        }
        let elapsed = previous.uptime - first.uptime
        return ["mode": mode.rawValue, "elapsedSeconds": elapsed,
            "cpuSeconds": previous.cpuSeconds - first.cpuSeconds,
            "cpuOneCorePercent": 100 * (previous.cpuSeconds - first.cpuSeconds) / elapsed,
            "initialRSSBytes": first.residentBytes, "finalRSSBytes": previous.residentBytes,
            "peakSampledRSSBytes": peakRSS,
            "driverWakeCountBefore": beforeWakes, "driverWakeCountAfter": controller.driverWakeCount,
            "driverWakeDelta": controller.driverWakeCount - beforeWakes,
            "diagnostics": controller.diagnostics(), "samples": samples]
    }

    @MainActor private static func pump(seconds: TimeInterval) async {
        // Yield to NSApplication.run: a bare RunLoop.run(until:) does not service
        // the AppKit display cycle correctly on macOS 27 and can spin during animation.
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func reading() throws -> Reading {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw failure("getrusage failed: \(errno)") }
        let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        var info = mach_task_basic_info_data_t()
        let capacity = MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw failure("task_info failed: \(result)") }
        return Reading(uptime: ProcessInfo.processInfo.systemUptime,
                       cpuSeconds: cpu, residentBytes: UInt64(info.resident_size))
    }

    @MainActor private static func snapshot(controller: IslandWindowController, to url: URL) throws {
        guard let hosting = controller.panel.contentView?.subviews
            .compactMap({ $0 as? NSHostingView<IslandHostedContent> }).first else {
            throw failure("Controller-owned NSHostingView not found")
        }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw failure("Cannot allocate hosting-view bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw failure("Cannot encode hosting-view PNG")
        }
        try png.write(to: url, options: .atomic)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "IslandPerformanceChecks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
