import AppKit
import SwiftUI

/// Shared animation timing, from Settings → Island → Motion. Smooth by default; honours Reduce Motion.
enum Motion {
    static var speed: Double { max(Pref.animationSpeed.double, 0.25) }
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var style: String { Pref.openAnimation.string }

    static var standard: Animation {
        if reduce { return .easeInOut(duration: 0.15) }
        switch style {
        case "bouncy": return .bouncy(duration: 0.4 / speed, extraBounce: 0.04)
        case "snappy": return .snappy(duration: 0.26 / speed)
        default: return .smooth(duration: 0.38 / speed)
        }
    }

    static var open: Animation {
        if reduce { return .easeInOut(duration: 0.15) }
        switch style {
        case "bouncy": return .bouncy(duration: 0.5 / speed, extraBounce: 0.06)
        case "snappy": return .snappy(duration: 0.3 / speed)
        default: return .smooth(duration: 0.45 / speed)
        }
    }

    static var close: Animation { reduce ? .easeOut(duration: 0.12) : .smooth(duration: 0.32 / speed) }
    static var press: Animation { .smooth(duration: 0.18) }
}

/// Simple preferences read where they're used. Settings with side effects live in SettingsModel
/// or are applied by AppState.applySettings() when UserDefaults changes.
enum Pref: String {
    // Island
    case peekOnHover, peekDelay, panelWidth, panelHeight, pillOffset, targetDisplay, hideInFullscreen
    case hideNotch, pillOnNotch, idleAnimation, lottiePath, lottieSpeed, lottieScale, lottieOffset
    case mascot, multipleActivities, gestureSwipeOpen, gestureSkip, hideFromCapture, openAnimation, animationSpeed
    // Menu bar
    case menuBarIcon, menuBarCalendar, menuBarIconHiding, menuBarDetach
    // HUDs & alerts
    case hudStyle, hudSize, externalBrightness, capsLockHUD, keystrokeHUD, fullChargeAlert, lowBatteryAlert
    case messageIsland, notificationMirror, screenshotShelf, driveAlerts
    // Media
    case spectrum, showLyricLine
    // Widgets
    case weatherCity, weatherFahrenheit, stocks, desktopWidgets
    // Knock
    case knockEnabled, knockMethod, knockKey, knockSensitivity, knockSingle, knockDouble, knockTriple, typingProtection
    // Pomodoro
    case pomoLongBreak, pomoLongEvery, pomoAutoBreak, pomoAutoFocus, pomoGoal, pomoSound
    // Developer / AI
    case agentApprovals, shellActivity, aiShowClaude, aiShowCodex, aiShowCopilot, aiShowCursor, copilotAlert
    // Island appearance & behaviour (Notchy-style)
    case collapseDelay, invisibleUntilHover, hideIfMenusOverlap, pillHeight, clockFormat, dateFormat, clockSeconds
    case squareArt, fontDesign, monochrome, translucency, customColors, pillColor, panelColor, panelGradient, panelColor2
    case blackCorners, cornerRadius, doubleClickOpen, tabsHidden, defaultTab, homeCards
    // Now Playing
    case nowPlayingIsland, hideWhenPaused, announceTracks, mediaKeys, defaultPlayer, marquee, skipSeconds
    case listeningHistory, desktopLyrics
    // Clipboard & Shelf
    case clipLimit, clipKeepAfterQuit, clipPaused, clipIgnore, clipSound, clipAutoClear, clipStripTracking, clipSkipSecrets
    case shelfCleanupDays, shelfCopyFiles
    // Focus & time
    case focusSound, focusSoundVolume, focusSoundStopWithPomodoro, breakReminders, menuBarTimer, worldClocks
    // Input & screen
    case knockIgnoreClicks, typingSounds, typingSoundStyle, cursorEffect, colorTemperature
    // Search, AI, stocks, calendar, tracking
    case searchEngines, askAIModel, stockAlerts, meetingAlerts, menuBarNextMeeting, screenTime, dataUsage
    // Desk pet
    case petEnabled, petSpecies, petName, petHue, petSize, petPersonality, petBedStart, petBedEnd
    case petWindowRides, petSpeech, petWeatherOutfits, petHolidayOutfits
    // Screen light
    case screenLightBrightness, screenLightWarmth, screenLightWidth, screenLightAuto, screenLightAllDisplays

    static let defaults: [String: Any] = [
        "peekOnHover": true, "peekDelay": 0.06, "panelWidth": 640.0, "panelHeight": 230.0, "pillOffset": 4.0,
        "targetDisplay": "auto", "hideInFullscreen": true, "hideNotch": false, "pillOnNotch": false,
        "idleAnimation": "clock", "lottiePath": "", "lottieSpeed": 1.0, "lottieScale": 1.0, "lottieOffset": 0.0,
        "mascot": "🐢", "multipleActivities": true, "gestureSwipeOpen": true, "gestureSkip": true,
        "hideFromCapture": false, "openAnimation": "smooth", "animationSpeed": 1.0,
        "menuBarIcon": true, "menuBarCalendar": false, "menuBarIconHiding": false, "menuBarDetach": false,
        "hudStyle": "island", "hudSize": 1.0, "externalBrightness": true, "capsLockHUD": true, "keystrokeHUD": false,
        "fullChargeAlert": true, "lowBatteryAlert": true, "messageIsland": false, "notificationMirror": false,
        "screenshotShelf": true, "driveAlerts": true,
        "spectrum": false, "showLyricLine": true,
        "weatherCity": "", "weatherFahrenheit": false, "stocks": "AAPL,MSFT,NVDA", "desktopWidgets": false,
        "knockEnabled": false, "knockMethod": "microphone", "knockKey": "Right Option", "knockSensitivity": 0.5,
        "knockSingle": "none", "knockDouble": "toggleIsland", "knockTriple": "playPause", "typingProtection": true,
        "pomoLongBreak": 15, "pomoLongEvery": 4, "pomoAutoBreak": true, "pomoAutoFocus": false, "pomoGoal": 8,
        "pomoSound": "Glass",
        "agentApprovals": false, "shellActivity": false, "aiShowClaude": true, "aiShowCodex": true,
        "aiShowCopilot": true, "aiShowCursor": true, "copilotAlert": 10,
        "collapseDelay": 0.35, "invisibleUntilHover": false, "hideIfMenusOverlap": false, "pillHeight": 0.0,
        "clockFormat": "time", "dateFormat": 0, "clockSeconds": false, "squareArt": false, "fontDesign": "rounded",
        "monochrome": false, "translucency": 0.35, "customColors": false, "pillColor": "#000000", "panelColor": "#000000",
        "panelGradient": false, "panelColor2": "#1E1B4B", "blackCorners": false, "cornerRadius": 10.0, "doubleClickOpen": false,
        "tabsHidden": "", "defaultTab": "home", "homeCards": "nowPlaying,calendar",
        "nowPlayingIsland": true, "hideWhenPaused": true, "announceTracks": false, "mediaKeys": false,
        "defaultPlayer": "com.apple.Music", "marquee": true, "skipSeconds": 15, "listeningHistory": true, "desktopLyrics": false,
        "clipLimit": 100, "clipKeepAfterQuit": true, "clipPaused": false,
        "clipIgnore": "com.1password.1password,com.agilebits.onepassword7,com.bitwarden.desktop,com.apple.keychainaccess,com.apple.Passwords",
        "clipSound": false, "clipSkipSecrets": true, "clipAutoClear": "never", "clipStripTracking": true, "shelfCleanupDays": 0, "shelfCopyFiles": false,
        "focusSound": "none", "focusSoundVolume": 0.4, "focusSoundStopWithPomodoro": true, "breakReminders": false,
        "menuBarTimer": false, "worldClocks": "",
        "knockIgnoreClicks": true, "typingSounds": false, "typingSoundStyle": "mechanical", "cursorEffect": "none",
        "colorTemperature": 6500.0,
        "searchEngines": "g=https://www.google.com/search?q=%s\nyt=https://www.youtube.com/results?search_query=%s\nw=https://en.wikipedia.org/w/index.php?search=%s\ngh=https://github.com/search?q=%s",
        "askAIModel": "claude-sonnet-5-5", "stockAlerts": "", "meetingAlerts": true, "menuBarNextMeeting": false,
        "screenTime": true, "dataUsage": true,
        "petEnabled": true, "petSpecies": "🐱", "petName": "", "petHue": 0.0, "petSize": 56.0, "petPersonality": "playful",
        "petBedStart": 23, "petBedEnd": 7, "petWindowRides": true, "petSpeech": true, "petWeatherOutfits": true,
        "petHolidayOutfits": true,
        "screenLightBrightness": 0.85, "screenLightWarmth": 0.3, "screenLightWidth": 0.12, "screenLightAuto": false,
        "screenLightAllDisplays": false,
    ]

    static func register() { UserDefaults.standard.register(defaults: defaults) }

    var bool: Bool { UserDefaults.standard.bool(forKey: rawValue) }
    var double: Double { UserDefaults.standard.double(forKey: rawValue) }
    var int: Int { UserDefaults.standard.integer(forKey: rawValue) }
    var string: String { UserDefaults.standard.string(forKey: rawValue) ?? "" }

    func set(_ value: Any?) { UserDefaults.standard.set(value, forKey: rawValue) }
}

extension Color {
    /// "#RRGGBB" → Color (black if malformed).
    init(hex: String) {
        let v = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), radix: 16) ?? 0
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

/// `update(\.x, to: v)` writes only when the value changes. Every write to an @Published property
/// re-renders the views observing it, even when the value is the same, so hot paths use this.
protocol ChangeTracking: AnyObject {}

extension ChangeTracking {
    func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Self, T>, to value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

/// Shared spacing so every tab lines up: outer margin, gap between cards, padding inside cards.
enum Layout {
    static let outer: CGFloat = 16
    static let gap: CGFloat = 10
    static let card: CGFloat = 12
    static let radius: CGFloat = 16
}
