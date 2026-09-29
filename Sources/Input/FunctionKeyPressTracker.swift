import Foundation

/// Correlates the two reports of a physical Fn press even when one channel's
/// entire down/up pair arrives after the other has already released.
struct FunctionKeyPressTracker {
    enum Channel { case hid, quartz }

    private struct Press {
        let id: UInt64
        let channel: Channel
        let timestamp: Double
    }

    private struct HeldPress {
        let id: UInt64
        let contributes: Bool
    }

    // Compare input times, not callback arrival times. A small tolerance covers
    // clock conversion/translation; this is not a cooldown between real taps.
    private static let timestampTolerance = 0.002
    private static let historyLimit = 64
    private var unmatched: [Press] = []
    private var held: [Channel: HeldPress] = [:]
    private var nextID: UInt64 = 0

    var isDown: Bool { held.values.contains { $0.contributes } }

    func isPressed(on channel: Channel) -> Bool { held[channel] != nil }

    /// Snapshots (startup, removal and lost-release repair) have no event time
    /// and must never be matched to a physical press in the other channel.
    mutating func update(_ channel: Channel, down: Bool, timestamp: Double?) -> Bool {
        guard down else {
            held.removeValue(forKey: channel)
            return isDown
        }
        guard held[channel] == nil else { return isDown }
        nextID &+= 1
        var contributes = true
        if let timestamp, timestamp.isFinite, timestamp > 0 {
            if let index = unmatched.firstIndex(where: {
                $0.channel != channel && abs($0.timestamp - timestamp) <= Self.timestampTolerance
            }) {
                let original = unmatched.remove(at: index)
                // An overlapping report may keep the existing hold alive. A
                // replay of a completed press must not start another animation
                // or hold a newer press open until its delayed release arrives.
                contributes = held[original.channel]?.id == original.id
            } else {
                unmatched.append(Press(id: nextID, channel: channel, timestamp: timestamp))
                if unmatched.count > Self.historyLimit { unmatched.removeFirst() }
            }
        }
        held[channel] = HeldPress(id: nextID, contributes: contributes)
        return isDown
    }
}
