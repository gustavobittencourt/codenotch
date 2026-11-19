
import Foundation

/// How often the Claude and Codex session monitors really scan.
///
/// Each scan lists the session files and asks the kernel about every pid, a
/// few times a second's worth of work every 2 s, all day. Folded, the notch
/// only spins a ring, which can trail by a few seconds; open, the session
/// list is being read. So a monitor scans on its 2 s timer for
/// `lookWindow` after someone looked (the notch opened, a ring was hovered)
/// and every `restingInterval` otherwise.
@MainActor
enum ActivityPace {
    static let restingInterval: TimeInterval = 10
    static let lookWindow: TimeInterval = 30
    private(set) static var lastLook = Date.distantPast

    static func looked(at now: Date = Date()) { lastLook = now }

    static func isDue(lastScan: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastLook) < lookWindow
            || now.timeIntervalSince(lastScan) >= restingInterval
    }
}

