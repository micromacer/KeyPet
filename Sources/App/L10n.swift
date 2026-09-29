import Foundation

/// Resolve through the main bundle so AppKit panels and app text share the
/// language selected by macOS, including per-app language preferences.
enum L10n: String, CaseIterable {
    case petMenu, hidePet, showPet, pause, resume
    case size, opacity, resetDelay, shadow, shadowBlur, shadowOpacity
    case flip, swap, bounce, frameRate, alwaysOnTop, clickThrough, resetPosition
    case restoreDefaultsMenu, aboutMenu, quit
    case noPets, chooseRoot, revealRoot, rescan, choose, chooseRootMessage
    case allowKeyboard, enableKeyboard, retryKeyboard
    case permissionTitle, permissionMessage, permissionAllow, permissionContinue, permissionLater, permissionMissing
    case aboutMessage, ok, cancel, restoreTitle, restoreMessage, restoreConfirm
    case currentAssetUnreadable, petUnavailable, missingReadableIdle
    case switchFailureStatus, switchFailureTitle, switchFailureMessage, pausedStatus, fileError
    case fileTooLarge, canvasTooLarge, tooManyFrames, notPNG, unreadableFile, corruptImage
    case unreadableDirectory, missingIdle, missingActions, tokenConflict, oversizedFile, oversizedCanvas, excessiveFrames
    case listSeparator, petAccessibilityHelp, points, milliseconds, percentage, framesPerSecond
    case languageMenu, followSystem, restartTitle, restartMessage, restartNow, restartLater

    static let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

    var text: String {
        Bundle.main.localizedString(forKey: rawValue, value: nil, table: "Localizable")
    }

    func format(_ arguments: CVarArg...) -> String {
        String(format: text, locale: Self.locale, arguments: arguments)
    }
}
