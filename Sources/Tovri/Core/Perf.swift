import Foundation
import QuartzCore

/// Opt-in timing logs (set TOVRI_PERF=1) for profiling hot paths.
enum Perf {
    static let enabled: Bool = {
        guard let v = ProcessInfo.processInfo.environment["TOVRI_PERF"] else { return false }
        return !v.isEmpty && v != "0"
    }()

    static func log(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }

    @inline(__always)
    static func measure<T>(_ label: @autoclosure () -> String, threshold ms: Double = 4, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let t0 = CACurrentMediaTime()
        let r = try body()
        let dt = (CACurrentMediaTime() - t0) * 1000
        if dt >= ms { log("[perf] \(label()) \(String(format: "%.1f", dt)) ms") }
        return r
    }

    private static var lastTick: CFTimeInterval = 0

    /// Logs main-thread stalls longer than 50 ms (only when TOVRI_PERF is set).
    static func startStallDetector() {
        guard enabled else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 0.01, repeats: true) { _ in
            let now = CACurrentMediaTime()
            let gap = (now - lastTick) * 1000
            if gap > 50 { log("[perf] main thread stall \(Int(gap)) ms") }
            lastTick = now
        }
        RunLoop.main.add(t, forMode: .common)
    }
}
