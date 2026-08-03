import Foundation

public enum BreakKind: String, Codable, Equatable, Sendable {
    case eye
    case long
    case pomodoro

    public var title: String {
        switch self {
        case .eye:
            "Goz molasi"
        case .long:
            "Buyuk mola"
        case .pomodoro:
            "Pomodoro molasi"
        }
    }

    public var displayTitle: String {
        switch self {
        case .eye:
            "Goz molasi"
        case .long:
            "Buyuk mola"
        case .pomodoro:
            "Pomodoro molasi"
        }
    }
}

public enum SessionMode: String, Codable, CaseIterable, Equatable, Sendable {
    case focusBreak
    case pomodoro

    public var title: String {
        switch self {
        case .focusBreak:
            "FocusBreak"
        case .pomodoro:
            "Pomodoro"
        }
    }

    public var description: String {
        switch self {
        case .focusBreak:
            "Goz molasi ve buyuk mola ritmi birlikte calisir."
        case .pomodoro:
            "Tek dongude odak ve kisa mola ile klasik pomodoro akisi kullanilir."
        }
    }
}

public enum ReminderMode: String, Codable, CaseIterable, Equatable, Sendable {
    case gentle
    case insistent

    public var title: String {
        switch self {
        case .gentle:
            "Nazik"
        case .insistent:
            "Israrci"
        }
    }

    public var description: String {
        switch self {
        case .gentle:
            "Goz molasini sadece ust bildirim olarak gosterir."
        case .insistent:
            "Goz molasini banner ile daha gorunur hale getirir."
        }
    }
}

public struct FocusBreakSettings: Codable, Equatable, Sendable {
    public var focusMinutes: Int
    public var longBreakMinutes: Int
    public var eyeBreakIntervalMinutes: Int
    public var eyeBreakSeconds: Int
    public var pomodoroFocusMinutes: Int
    public var pomodoroBreakMinutes: Int
    public var overlayDelaySeconds: Int
    public var sessionMode: SessionMode
    public var reminderMode: ReminderMode
    public var launchAtLogin: Bool
    public var notificationsEnabled: Bool
    public var eyeBreaksEnabled: Bool
    public var longBreaksEnabled: Bool

    public init(
        focusMinutes: Int = 60,
        longBreakMinutes: Int = 5,
        eyeBreakIntervalMinutes: Int = 20,
        eyeBreakSeconds: Int = 20,
        pomodoroFocusMinutes: Int = 25,
        pomodoroBreakMinutes: Int = 5,
        overlayDelaySeconds: Int = 60,
        sessionMode: SessionMode = .focusBreak,
        reminderMode: ReminderMode = .insistent,
        launchAtLogin: Bool = false,
        notificationsEnabled: Bool = true,
        eyeBreaksEnabled: Bool = true,
        longBreaksEnabled: Bool = true
    ) {
        self.focusMinutes = focusMinutes
        self.longBreakMinutes = longBreakMinutes
        self.eyeBreakIntervalMinutes = eyeBreakIntervalMinutes
        self.eyeBreakSeconds = eyeBreakSeconds
        self.pomodoroFocusMinutes = pomodoroFocusMinutes
        self.pomodoroBreakMinutes = pomodoroBreakMinutes
        self.overlayDelaySeconds = overlayDelaySeconds
        self.sessionMode = sessionMode
        self.reminderMode = reminderMode
        self.launchAtLogin = launchAtLogin
        self.notificationsEnabled = notificationsEnabled
        self.eyeBreaksEnabled = eyeBreaksEnabled
        self.longBreaksEnabled = longBreaksEnabled
    }

    public static let defaults = FocusBreakSettings()

    private enum CodingKeys: String, CodingKey {
        case focusMinutes
        case longBreakMinutes
        case eyeBreakIntervalMinutes
        case eyeBreakSeconds
        case pomodoroFocusMinutes
        case pomodoroBreakMinutes
        case overlayDelaySeconds
        case sessionMode
        case reminderMode
        case launchAtLogin
        case notificationsEnabled
        case eyeBreaksEnabled
        case longBreaksEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        focusMinutes = try container.decodeIfPresent(Int.self, forKey: .focusMinutes) ?? Self.defaults.focusMinutes
        longBreakMinutes = try container.decodeIfPresent(Int.self, forKey: .longBreakMinutes) ?? Self.defaults.longBreakMinutes
        eyeBreakIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .eyeBreakIntervalMinutes) ?? Self.defaults.eyeBreakIntervalMinutes
        eyeBreakSeconds = try container.decodeIfPresent(Int.self, forKey: .eyeBreakSeconds) ?? Self.defaults.eyeBreakSeconds
        pomodoroFocusMinutes = try container.decodeIfPresent(Int.self, forKey: .pomodoroFocusMinutes) ?? Self.defaults.pomodoroFocusMinutes
        pomodoroBreakMinutes = try container.decodeIfPresent(Int.self, forKey: .pomodoroBreakMinutes) ?? Self.defaults.pomodoroBreakMinutes
        overlayDelaySeconds = try container.decodeIfPresent(Int.self, forKey: .overlayDelaySeconds) ?? Self.defaults.overlayDelaySeconds
        sessionMode = try container.decodeIfPresent(SessionMode.self, forKey: .sessionMode) ?? Self.defaults.sessionMode
        reminderMode = try container.decodeIfPresent(ReminderMode.self, forKey: .reminderMode) ?? Self.defaults.reminderMode
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? Self.defaults.launchAtLogin
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? Self.defaults.notificationsEnabled
        eyeBreaksEnabled = try container.decodeIfPresent(Bool.self, forKey: .eyeBreaksEnabled) ?? Self.defaults.eyeBreaksEnabled
        longBreaksEnabled = try container.decodeIfPresent(Bool.self, forKey: .longBreaksEnabled) ?? Self.defaults.longBreaksEnabled
    }
}

public struct BreakCounters: Codable, Equatable, Sendable {
    public var completedEyeBreaks: Int
    public var completedLongBreaks: Int
    public var completedPomodoroBreaks: Int
    public var skippedBreaks: Int
    public var dateKey: String

    public init(
        completedEyeBreaks: Int = 0,
        completedLongBreaks: Int = 0,
        completedPomodoroBreaks: Int = 0,
        skippedBreaks: Int = 0,
        dateKey: String = BreakCounters.currentDateKey()
    ) {
        self.completedEyeBreaks = completedEyeBreaks
        self.completedLongBreaks = completedLongBreaks
        self.completedPomodoroBreaks = completedPomodoroBreaks
        self.skippedBreaks = skippedBreaks
        self.dateKey = dateKey
    }

    private enum CodingKeys: String, CodingKey {
        case completedEyeBreaks
        case completedLongBreaks
        case completedPomodoroBreaks
        case skippedBreaks
        case dateKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        completedEyeBreaks = try container.decodeIfPresent(Int.self, forKey: .completedEyeBreaks) ?? 0
        completedLongBreaks = try container.decodeIfPresent(Int.self, forKey: .completedLongBreaks) ?? 0
        completedPomodoroBreaks = try container.decodeIfPresent(Int.self, forKey: .completedPomodoroBreaks) ?? 0
        skippedBreaks = try container.decodeIfPresent(Int.self, forKey: .skippedBreaks) ?? 0
        dateKey = try container.decodeIfPresent(String.self, forKey: .dateKey) ?? BreakCounters.currentDateKey()
    }

    public static func currentDateKey(date: Date = Date(), calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
}

public struct BreakScheduler: Equatable, Sendable {
    public var settings: FocusBreakSettings
    public var isPaused: Bool
    public var nextEyeBreakAt: Date
    public var nextLongBreakAt: Date

    public init(
        settings: FocusBreakSettings = .defaults,
        now: Date = Date(),
        isPaused: Bool = false
    ) {
        self.settings = settings
        self.isPaused = isPaused
        self.nextEyeBreakAt = now.addingTimeInterval(TimeInterval(settings.eyeBreakIntervalMinutes * 60))
        let initialFocusMinutes = settings.sessionMode == .pomodoro ? settings.pomodoroFocusMinutes : settings.focusMinutes
        self.nextLongBreakAt = now.addingTimeInterval(TimeInterval(initialFocusMinutes * 60))
    }

    public func dueBreak(at now: Date = Date()) -> BreakKind? {
        guard !isPaused else { return nil }

        if settings.sessionMode == .pomodoro {
            return now >= nextLongBreakAt ? .pomodoro : nil
        }

        if settings.longBreaksEnabled, now >= nextLongBreakAt {
            return .long
        }

        if settings.eyeBreaksEnabled, now >= nextEyeBreakAt {
            return .eye
        }

        return nil
    }

    public func nextBreakDate() -> Date {
        if settings.sessionMode == .pomodoro {
            return nextLongBreakAt
        }

        if settings.eyeBreaksEnabled, settings.longBreaksEnabled {
            return min(nextEyeBreakAt, nextLongBreakAt)
        }

        if settings.eyeBreaksEnabled {
            return nextEyeBreakAt
        }

        return nextLongBreakAt
    }

    public mutating func complete(_ kind: BreakKind, at now: Date = Date()) {
        switch kind {
        case .eye:
            nextEyeBreakAt = now.addingTimeInterval(TimeInterval(settings.eyeBreakIntervalMinutes * 60))
        case .long:
            nextEyeBreakAt = now.addingTimeInterval(TimeInterval(settings.eyeBreakIntervalMinutes * 60))
            nextLongBreakAt = now.addingTimeInterval(TimeInterval(settings.focusMinutes * 60))
        case .pomodoro:
            nextLongBreakAt = now.addingTimeInterval(TimeInterval(settings.pomodoroFocusMinutes * 60))
        }
    }

    public mutating func snooze(_ kind: BreakKind, minutes: Int = 1, at now: Date = Date()) {
        let date = now.addingTimeInterval(TimeInterval(minutes * 60))
        switch kind {
        case .eye:
            nextEyeBreakAt = date
        case .long:
            nextLongBreakAt = date
        case .pomodoro:
            nextLongBreakAt = date
        }
    }
}

public enum DurationFormatter {
    public static func compactRemaining(from now: Date = Date(), to date: Date) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now)))
        let minutes = remaining / 60
        let seconds = remaining % 60

        if minutes >= 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            return "\(hours)s \(rest)dk"
        }

        if minutes > 0 {
            return "\(minutes)dk \(seconds)sn"
        }

        return "\(seconds)sn"
    }

    public static func clockRemaining(from now: Date = Date(), to date: Date) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now)))
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }
}
