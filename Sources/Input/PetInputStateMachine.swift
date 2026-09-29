import Dispatch
import Foundation

/// Multi-key input state machine driving the paw behavior: only one pose shows
/// at a time, the most recently pressed held key owns it, and the pet returns
/// to idle only after `resetDelay` has elapsed since the last release.
@MainActor
final class PetInputStateMachine {
    /// Seconds from the last key release until an "idle" selection is emitted.
    var resetDelay: Double = 0.15

    /// Swaps only the fallback left/right paws. Dedicated key art is unaffected by
    /// design: the swap toggle never re-picks or renames image files.
    /// Callers invoke `reset()` when toggling, so held keys never keep stale sides.
    var swapSides: Bool = false

    /// Whether the current pet provides an image for a token. The caller's contract
    /// guarantees "idle" always reports true, so resolution can always land somewhere.
    var tokenAvailable: @MainActor (String) -> Bool = { $0 == "idle" }

    /// Emitted whenever a token must (re)start playback from its first frame.
    /// `restartSerial` increases on every emission so unchanged tokens still restart.
    var onSelection: (@MainActor (PlaybackSelection) -> Void)?

    /// Emitted once per genuine new key press; never on auto-repeat or re-selection.
    var onBounce: (@MainActor () -> Void)?

    var heldKeyCount: Int { heldKeys.count }

    init() {}

    /// A held key together with the token resolved at its initial press. Keeping
    /// the press-time token for the whole hold keeps the pose stable when assets
    /// hot-reload mid-hold, and lets auto-repeat restart the same image.
    private struct HeldKey {
        let keyCode: UInt16
        let token: String
    }

    /// Last element is the most recently pressed (or auto-repeated) key.
    private var heldKeys: [HeldKey] = []
    /// Key whose token is currently displayed; nil while idle is showing.
    private var currentKeyCode: UInt16?
    /// Monotonic restart counter carried by every PlaybackSelection.
    private var selectionSerial: UInt64 = 0
    /// Next paw for unclassified keys. Alternation starts from left and advances
    /// only on genuine presses, never on system auto-repeat.
    private var nextAutoSide: PawSide = .left
    /// Bumped on every schedule and cancel, so a stale asyncAfter closure can detect
    /// it has been superseded; this is what keeps exactly one reset pending at a time.
    private var resetGeneration: UInt64 = 0

    func handle(_ event: NormalizedKeyEvent) {
        switch (event.phase, event.isRepeat) {
        case (.down, true) where heldIndex(for: event.keyCode) != nil:
            handleAutoRepeat(event)
        case (.down, _):
            // A non-repeat .down for a key already tracked means its key-up was lost;
            // treat it as a brand-new press rather than ignoring it.
            if let index = heldIndex(for: event.keyCode) {
                heldKeys.remove(at: index)
            }
            handleNewPress(event)
        case (.up, _):
            handleRelease(event)
        }
    }

    /// Pause / hide / pet switch / monitor interruption: drop every held key, cancel
    /// any pending reset and stay silent so no stale callback reaches a pet that is
    /// being swapped out. Alternation restarts from left, its initial state.
    func reset() {
        heldKeys.removeAll()
        currentKeyCode = nil
        nextAutoSide = .left
        cancelPendingReset()
    }

    private func handleNewPress(_ event: NormalizedKeyEvent) {
        cancelPendingReset()
        let token = resolveToken(for: event)
        heldKeys.append(HeldKey(keyCode: event.keyCode, token: token))
        currentKeyCode = event.keyCode
        emitSelection(token)
        onBounce?()
    }

    private func handleAutoRepeat(_ event: NormalizedKeyEvent) {
        guard let index = heldIndex(for: event.keyCode) else { return }
        // Keep the press-time token and only refresh recency plus playback restart;
        // auto-repeat must not advance the left/right alternation or re-bounce.
        let held = heldKeys.remove(at: index)
        heldKeys.append(held)
        currentKeyCode = event.keyCode
        emitSelection(held.token)
    }

    private func handleRelease(_ event: NormalizedKeyEvent) {
        guard let index = heldIndex(for: event.keyCode) else { return }
        let wasDisplayed = currentKeyCode == event.keyCode
        heldKeys.remove(at: index)
        if heldKeys.isEmpty {
            // Keep the pose on screen; idle arrives only when the deadline fires.
            if wasDisplayed { scheduleReset() }
        } else if wasDisplayed {
            let next = heldKeys[heldKeys.count - 1]
            currentKeyCode = next.keyCode
            emitSelection(next.token)
        }
        // Releasing a held key that is not on display must not disturb the display.
    }

    /// Dedicated key art beats the paw fallback, so "1" shows its own image when
    /// the pet provides one and falls back to its classified paw otherwise.
    private func resolveToken(for event: NormalizedKeyEvent) -> String {
        guard let base = PetKeyMapping.baseToken(for: event.keyCode) else {
            return fallbackToken(defaultSide: nil)
        }
        if tokenAvailable(base) { return base }
        return fallbackToken(defaultSide: PetKeyMapping.defaultSide(forBaseToken: base))
    }

    private func fallbackToken(defaultSide: PawSide?) -> String {
        let side: PawSide
        if let defaultSide {
            side = defaultSide
        } else {
            side = nextAutoSide
            nextAutoSide = nextAutoSide.swapped
        }
        // The swap toggle applies to every fallback paw, classified or alternating.
        let effective = swapSides ? side.swapped : side
        let token = effective == .left ? "left" : "right"
        // Without the paw image nothing else remains except idle.
        return tokenAvailable(token) ? token : "idle"
    }

    private func scheduleReset() {
        resetGeneration &+= 1
        let generation = resetGeneration
        // DispatchTime is monotonic, so the deadline is immune to wall-clock jumps.
        DispatchQueue.main.asyncAfter(deadline: .now() + resetDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.resetGeneration == generation else { return }
                self.currentKeyCode = nil
                self.emitSelection("idle")
            }
        }
    }

    private func cancelPendingReset() {
        resetGeneration &+= 1
    }

    private func emitSelection(_ token: String) {
        selectionSerial &+= 1
        onSelection?(PlaybackSelection(token: token, restartSerial: selectionSerial))
    }

    private func heldIndex(for keyCode: UInt16) -> Int? {
        heldKeys.firstIndex { $0.keyCode == keyCode }
    }
}
