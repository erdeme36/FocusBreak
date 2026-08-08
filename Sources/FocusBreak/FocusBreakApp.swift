import AppKit
import Combine
import FocusBreakCore
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class FocusBreakApp: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusController: StatusBarController?
    private var mainWindow: NSWindow?
    private var overlayController: OverlayController?
    private var cancellables: Set<AnyCancellable> = []
    private var didBootstrap = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        bootstrap()
    }

    func bootstrap() {
        guard !didBootstrap else {
            openMainWindow()
            return
        }

        didBootstrap = true
        NSApp.setActivationPolicy(.regular)
        AppIcon.applyRuntimeIcon()
        statusController = StatusBarController(model: model)
        overlayController = OverlayController(model: model)
        openMainWindow()

        model.$overlayRequest
            .receive(on: RunLoop.main)
            .sink { [weak self] request in
                guard let self else { return }
                if let request {
                    self.overlayController?.show(request: request)
                } else {
                    self.overlayController?.close()
                }
            }
            .store(in: &cancellables)

        model.requestNotificationPermission()
        model.refreshLoginItemStatus()
        model.start()
        model.checkForUpdates(silent: true)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return true
    }

    private func openMainWindow() {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FocusBreak"
        window.minSize = NSSize(width: 760, height: 560)
        window.center()
        window.contentView = NSHostingView(rootView: DashboardView(model: model))
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        mainWindow = window
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [weak self] in
            self?.mainWindow?.makeKeyAndOrderFront(nil)
            self?.mainWindow?.orderFrontRegardless()
            NSApp.unhide(nil)
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: FocusBreakSettings
    @Published var counters: BreakCounters
    @Published var scheduler: BreakScheduler
    @Published var overlayRequest: OverlayRequest?
    @Published var notificationStatusText = "Bildirim izni kontrol ediliyor"
    @Published var loginStatusText = "Acilista baslatma kontrol ediliyor"
    @Published var updateStatusText = "Guncelleme kontrol edilmedi"
    @Published var isRunning = false
    @Published var lastEventText = "Baslatmaya hazir"
    @Published var hasStartedSession = false

    private var timer: Timer?
    private var overlayTask: Task<Void, Never>?
    private var pendingBreak: BreakKind?
    private var pausedEyeBreakRemaining: TimeInterval?
    private var pausedLongBreakRemaining: TimeInterval?
    private var lastWorkTickAt = Date()
    private let activeIdleThreshold: TimeInterval = 60
    private var isCheckingForUpdates = false
    private let defaults = UserDefaults.standard
    private let settingsKey = "focusbreak.settings"
    private let countersKey = "focusbreak.counters"

    init() {
        let storedSettings = Self.load(FocusBreakSettings.self, key: settingsKey)
        Self.migrateIntroPreference(hasStoredSettings: storedSettings != nil)
        let loadedSettings = (storedSettings ?? .defaults).normalizedForStorage
        let loadedCounters = Self.load(BreakCounters.self, key: countersKey) ?? BreakCounters()
        settings = loadedSettings
        counters = loadedCounters
        scheduler = BreakScheduler(settings: loadedSettings)
        if storedSettings != loadedSettings {
            Self.save(loadedSettings, key: settingsKey)
        }
        resetCountersIfNeeded()
    }

    var nextBreakLabel: String {
        if !hasEnabledBreaks {
            return "En az bir mola ac"
        }

        if !isRunning {
            if let pausedRemaining = pausedNextBreakRemaining {
                return "\(nextBreakKindText) icin \(DurationFormatter.compactRemaining(to: Date().addingTimeInterval(pausedRemaining)))"
            }
            return "Baslatmaya hazir"
        }

        return "\(nextBreakKindText) icin \(DurationFormatter.compactRemaining(to: scheduler.nextBreakDate()))"
    }

    var menuTitle: String {
        if isRunning {
            return "FocusBreak \(DurationFormatter.compactRemaining(to: scheduler.nextBreakDate()))"
        }

        if let pausedRemaining = pausedNextBreakRemaining {
            return "FocusBreak \(DurationFormatter.compactRemaining(to: Date().addingTimeInterval(pausedRemaining)))"
        }

        return "FocusBreak: Hazir"
    }

    var timerDisplay: String {
        guard hasEnabledBreaks else { return "--:--" }
        if !isRunning, let pausedRemaining = pausedNextBreakRemaining {
            return DurationFormatter.clockRemaining(to: Date().addingTimeInterval(pausedRemaining))
        }
        guard isRunning else { return "--:--" }
        return DurationFormatter.clockRemaining(to: scheduler.nextBreakDate())
    }

    var nextBreakProgress: Double {
        guard hasEnabledBreaks else { return 0 }
        let remaining: TimeInterval
        if isRunning {
            remaining = max(0, scheduler.nextBreakDate().timeIntervalSinceNow)
        } else if let pausedRemaining = pausedNextBreakRemaining {
            remaining = pausedRemaining
        } else {
            return 0
        }
        let total = max(1, nextBreakTotalSeconds)
        return min(1, max(0, 1 - (remaining / total)))
    }

    var nextBreakRemainingFraction: Double {
        1 - nextBreakProgress
    }

    var hasEnabledBreaks: Bool {
        if settings.sessionMode == .pomodoro {
            return true
        }

        return settings.eyeBreaksEnabled || settings.longBreaksEnabled
    }

    private var nextBreakTotalSeconds: TimeInterval {
        if settings.sessionMode == .pomodoro {
            return TimeInterval(settings.pomodoroFocusMinutes * 60)
        }

        if settings.eyeBreaksEnabled, settings.longBreaksEnabled {
            if scheduler.nextEyeBreakAt <= scheduler.nextLongBreakAt {
                return TimeInterval(settings.eyeBreakIntervalMinutes * 60)
            }
            return TimeInterval(settings.focusMinutes * 60)
        }

        if settings.eyeBreaksEnabled {
            return TimeInterval(settings.eyeBreakIntervalMinutes * 60)
        }

        return TimeInterval(settings.focusMinutes * 60)
    }

    var nextBreakKindText: String {
        if settings.sessionMode == .pomodoro {
            return "pomodoro molasi"
        }

        if settings.eyeBreaksEnabled, settings.longBreaksEnabled {
            return scheduler.nextBreakKind() == .eye ? "goz molasi" : "buyuk mola"
        }

        if settings.eyeBreaksEnabled {
            return "goz molasi"
        }

        return settings.longBreaksEnabled ? "buyuk mola" : "mola"
    }

    func start() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        newTimer.tolerance = 0.15
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
        tick()
    }

    func beginFocusSession() {
        guard hasEnabledBreaks else {
            isRunning = false
            lastEventText = "En az bir mola ac"
            objectWillChange.send()
            return
        }

        overlayTask?.cancel()
        pendingBreak = nil
        overlayRequest = nil
        pausedEyeBreakRemaining = nil
        pausedLongBreakRemaining = nil
        lastWorkTickAt = Date()
        scheduler = BreakScheduler(settings: settings)
        scheduler.isPaused = false
        isRunning = true
        hasStartedSession = true
        lastEventText = "Odak oturumu basladi"
        objectWillChange.send()
    }

    func toggleRunning() {
        if isRunning {
            pausedEyeBreakRemaining = max(0, scheduler.nextEyeBreakAt.timeIntervalSinceNow)
            pausedLongBreakRemaining = max(0, scheduler.nextLongBreakAt.timeIntervalSinceNow)
            isRunning = false
            scheduler.isPaused = true
            lastEventText = "Sayac duraklatildi"
        } else {
            let now = Date()
            if let pausedEyeBreakRemaining {
                scheduler.nextEyeBreakAt = now.addingTimeInterval(pausedEyeBreakRemaining)
            }
            if let pausedLongBreakRemaining {
                scheduler.nextLongBreakAt = now.addingTimeInterval(pausedLongBreakRemaining)
            }
            isRunning = true
            scheduler.isPaused = false
            lastWorkTickAt = now
            pausedEyeBreakRemaining = nil
            pausedLongBreakRemaining = nil
            lastEventText = "Sayac devam ediyor"
        }
        objectWillChange.send()
    }

    var canResumeSession: Bool {
        hasStartedSession && !isRunning
    }

    func skipCurrentBreak() {
        guard let request = overlayRequest else { return }
        counters.skippedBreaks += 1
        scheduler.complete(request.kind)
        pendingBreak = nil
        overlayRequest = nil
        overlayTask?.cancel()
        lastEventText = "Mola atlandi"
        saveCounters()
    }

    func skipUpcomingBreak() {
        if overlayRequest != nil {
            skipCurrentBreak()
            return
        }

        scheduler.complete(nextBreakKind())
        pendingBreak = nil
        overlayTask?.cancel()
        lastEventText = "Siradaki mola atlandi"
        objectWillChange.send()
    }

    func snoozeCurrentBreak(minutes: Int = 1) {
        guard let request = overlayRequest else { return }
        scheduler.snooze(request.kind, minutes: minutes)
        pendingBreak = nil
        overlayRequest = nil
        overlayTask?.cancel()
        lastEventText = "\(minutes) dk ertelendi"
    }

    func beginCurrentBreak() {
        guard var request = overlayRequest else { return }
        request.startedAt = Date()
        request.endsAt = Date().addingTimeInterval(durationSeconds(for: request.kind))
        overlayRequest = request
        lastEventText = "\(request.kind.displayTitle) basladi"
    }

    func finishCurrentBreak() {
        guard let request = overlayRequest else { return }
        completeBreak(request.kind)
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.title == "FocusBreak" })?.makeKeyAndOrderFront(nil)
    }

    func updateSettings(_ newSettings: FocusBreakSettings) {
        settings = newSettings
        overlayTask?.cancel()
        pendingBreak = nil
        overlayRequest = nil
        pausedEyeBreakRemaining = nil
        pausedLongBreakRemaining = nil
        scheduler = BreakScheduler(settings: newSettings)
        scheduler.isPaused = !isRunning
        lastWorkTickAt = Date()
        saveSettings()
        lastEventText = isRunning ? "Ayarlar guncellendi; sayac yeniden basladi" : "Ayarlar guncellendi"
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            let alert = NSAlert()
            alert.messageText = "FocusBreak Mac acilisinda baslasin mi?"
            alert.informativeText = "Onaylarsan FocusBreak login item olarak eklenir. macOS ayrica izin isteyebilir."
            alert.addButton(withTitle: "Ekle")
            alert.addButton(withTitle: "Vazgec")

            guard alert.runModal() == .alertFirstButtonReturn else {
                var updated = settings
                updated.launchAtLogin = false
                updateSettings(updated)
                loginStatusText = "Mac acilisinda baslatma kapali"
                return
            }
        }

        var updated = settings
        updated.launchAtLogin = enabled
        updateSettings(updated)
        applyLoginItemPreference()
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.notificationStatusText = granted ? "Bildirim izni aktif" : "Bildirim izni kapali; panel yedek olarak calisir"
            }
        }
    }

    func applyLoginItemPreference() {
        guard #available(macOS 13.0, *) else {
            loginStatusText = "Login item icin macOS 13+ gerekir"
            return
        }

        do {
            if settings.launchAtLogin {
                try SMAppService.mainApp.register()
                loginStatusText = "Mac acilisinda baslatma acik"
            } else {
                try SMAppService.mainApp.unregister()
                loginStatusText = "Mac acilisinda baslatma kapali"
            }
        } catch {
            loginStatusText = "Acilista baslatma macOS izni bekliyor"
        }
    }

    func refreshLoginItemStatus() {
        guard #available(macOS 13.0, *) else {
            loginStatusText = "Login item icin macOS 13+ gerekir"
            return
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            loginStatusText = "Mac acilisinda baslatma acik"
            if !settings.launchAtLogin {
                var updated = settings
                updated.launchAtLogin = true
                settings = updated
                saveSettings()
            }
        case .requiresApproval:
            loginStatusText = "macOS onayi bekliyor"
        case .notRegistered:
            loginStatusText = "Mac acilisinda baslatma kapali"
            if settings.launchAtLogin {
                var updated = settings
                updated.launchAtLogin = false
                settings = updated
                saveSettings()
            }
        case .notFound:
            loginStatusText = "Login item bulunamadi"
        @unknown default:
            loginStatusText = "Login item durumu bilinmiyor"
        }
    }

    func checkForUpdates(silent: Bool = false) {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        updateStatusText = "Guncelleme kontrol ediliyor"

        Task {
            do {
                let release = try await UpdateService.latestRelease()
                isCheckingForUpdates = false

                if release.version > AppVersion.current {
                    updateStatusText = "\(release.tagName) hazir"
                    showUpdatePrompt(for: release)
                } else {
                    updateStatusText = "Guncel: \(AppVersion.current.displayString)"
                }
            } catch {
                isCheckingForUpdates = false
                updateStatusText = "Guncelleme kontrol edilemedi"

                if !silent {
                    let alert = NSAlert()
                    alert.messageText = "Guncelleme kontrol edilemedi"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "Tamam")
                    alert.runModal()
                }
            }
        }
    }

    private func showUpdatePrompt(for release: UpdateRelease) {
        let alert = NSAlert()
        alert.messageText = "Yeni FocusBreak surumu var"
        alert.informativeText = "Kurulu surum \(AppVersion.current.displayString), son surum \(release.tagName). DMG indirilsin ve acilsin mi?"
        alert.addButton(withTitle: "Indir ve ac")
        alert.addButton(withTitle: "Release sayfasi")
        alert.addButton(withTitle: "Sonra")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            downloadAndOpenUpdate(release)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.htmlURL)
        default:
            break
        }
    }

    private func downloadAndOpenUpdate(_ release: UpdateRelease) {
        guard release.dmgURL != nil else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }

        updateStatusText = "\(release.tagName) indiriliyor"
        Task {
            do {
                let fileURL = try await UpdateService.downloadDMG(for: release)
                updateStatusText = "DMG indirildi"
                NSWorkspace.shared.open(fileURL)
            } catch {
                updateStatusText = "Indirme basarisiz"
                NSWorkspace.shared.open(release.htmlURL)
            }
        }
    }

    private func tick() {
        let now = Date()
        resetCountersIfNeeded()

        if var request = overlayRequest, let endsAt = request.endsAt {
            request.remainingSeconds = max(0, Int(ceil(endsAt.timeIntervalSinceNow)))
            overlayRequest = request

            if request.remainingSeconds == 0 {
                completeBreak(request.kind)
            }
            return
        }

        applyWorkingTimeGate(at: now)

        guard isRunning, overlayRequest == nil, pendingBreak == nil, let due = scheduler.dueBreak() else {
            objectWillChange.send()
            return
        }

        announceBreak(due)
    }

    private func applyWorkingTimeGate(at now: Date) {
        guard isRunning, overlayRequest == nil, pendingBreak == nil else {
            lastWorkTickAt = now
            return
        }

        let elapsed = max(0, now.timeIntervalSince(lastWorkTickAt))
        lastWorkTickAt = now

        guard elapsed > 0, userIsIdle else {
            if lastEventText == "Aktivite bekleniyor" {
                lastEventText = "Sayac calisiyor"
            }
            return
        }

        scheduler.postponeActiveDeadlines(by: elapsed)
        lastEventText = "Aktivite bekleniyor"
    }

    private var userIsIdle: Bool {
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .hidSystemState,
            eventType: .null
        )
        return idleSeconds >= activeIdleThreshold && !frontmostAppCountsAsWork
    }

    private var frontmostAppCountsAsWork: Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        let bundleID = app.bundleIdentifier?.lowercased() ?? ""
        let appName = app.localizedName?.lowercased() ?? ""
        let workSignals = [
            "zoom",
            "teams",
            "facetime",
            "webex",
            "skype",
            "discord",
            "slack"
        ]

        return workSignals.contains { signal in
            bundleID.contains(signal) || appName.contains(signal)
        }
    }

    private func announceBreak(_ kind: BreakKind) {
        var request = OverlayRequest(kind: kind)
        overlayRequest = nil
        pendingBreak = kind
        sendNotification(for: kind)
        BreakSound.playStart()
        lastEventText = "\(kind.displayTitle) zamani"

        if kind == .eye {
            if settings.reminderMode == .gentle {
                scheduler.complete(kind)
                pendingBreak = nil
                lastEventText = "Goz molasi bildirim olarak gosterildi"
                return
            }

            request.startedAt = Date()
            request.endsAt = Date().addingTimeInterval(durationSeconds(for: .eye))
            request.remainingSeconds = settings.eyeBreakSeconds
            overlayRequest = request
            return
        }

        request.startedAt = Date()
        request.endsAt = Date().addingTimeInterval(durationSeconds(for: kind))
        request.remainingSeconds = Int(durationSeconds(for: kind))
        overlayTask?.cancel()
        overlayRequest = request
    }

    private func completeBreak(_ kind: BreakKind) {
        switch kind {
        case .eye:
            counters.completedEyeBreaks += 1
        case .long:
            counters.completedLongBreaks += 1
        case .pomodoro:
            counters.completedPomodoroBreaks += 1
        }

        scheduler.complete(kind)
        pendingBreak = nil
        overlayRequest = nil
        overlayTask?.cancel()
        BreakSound.playEnd()
        lastEventText = "\(kind.displayTitle) tamamlandi"
        saveCounters()
    }

    private func sendNotification(for kind: BreakKind) {
        guard settings.notificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        switch kind {
        case .eye:
            content.title = "Gozlerini dinlendir"
            content.body = "20 saniye boyunca ekrandan uzak bir noktaya bak."
        case .long:
            content.title = "Buyuk mola zamani"
            content.body = "5 dakikalik kisa bir ara ver. Ayaga kalk, su ic, ekrandan uzaklas."
        case .pomodoro:
            content.title = "Pomodoro molasi"
            content.body = "Odak turu bitti. Kisa bir pomodoro molasi ver."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "focusbreak-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func nextBreakKind() -> BreakKind {
        scheduler.nextBreakKind()
    }

    private func durationSeconds(for kind: BreakKind) -> TimeInterval {
        switch kind {
        case .eye:
            TimeInterval(settings.eyeBreakSeconds)
        case .long:
            TimeInterval(settings.longBreakMinutes * 60)
        case .pomodoro:
            TimeInterval(settings.pomodoroBreakMinutes * 60)
        }
    }

    private func resetCountersIfNeeded() {
        let today = BreakCounters.currentDateKey()
        guard counters.dateKey != today else { return }
        counters = BreakCounters(dateKey: today)
        saveCounters()
    }

    private func saveSettings() {
        settings = settings.normalizedForStorage
        Self.save(settings, key: settingsKey)
    }

    private func saveCounters() {
        Self.save(counters, key: countersKey)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func migrateIntroPreference(hasStoredSettings: Bool) {
        let introKey = "focusbreak.showingIntro"
        guard UserDefaults.standard.object(forKey: introKey) == nil, hasStoredSettings else { return }
        UserDefaults.standard.set(false, forKey: introKey)
    }

    private var pausedNextBreakRemaining: TimeInterval? {
        switch settings.sessionMode {
        case .pomodoro:
            return pausedLongBreakRemaining
        case .focusBreak:
            switch (settings.eyeBreaksEnabled, settings.longBreaksEnabled) {
            case (true, true):
                guard let pausedEyeBreakRemaining, let pausedLongBreakRemaining else { return nil }
                return min(pausedEyeBreakRemaining, pausedLongBreakRemaining)
            case (true, false):
                return pausedEyeBreakRemaining
            case (false, true):
                return pausedLongBreakRemaining
            case (false, false):
                return nil
            }
        }
    }
}

struct OverlayRequest: Equatable, Identifiable {
    let id = UUID()
    var kind: BreakKind
    var startedAt: Date?
    var endsAt: Date?
    var remainingSeconds = 0
}

struct AppVersion: Comparable {
    static let current = AppVersion(
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    )

    let components: [Int]
    let displayString: String

    init(_ rawValue: String) {
        let cleaned = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let parsed = cleaned
            .split(separator: ".")
            .map { part in
                Int(part.prefix { $0.isNumber }) ?? 0
            }

        components = parsed.isEmpty ? [0] : parsed
        displayString = cleaned.isEmpty ? "0" : cleaned
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0

            if left != right {
                return left < right
            }
        }

        return false
    }
}

struct UpdateRelease {
    let tagName: String
    let version: AppVersion
    let htmlURL: URL
    let dmgURL: URL?
}

enum UpdateService {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/erdeme36/FocusBreak/releases/latest")!

    static func latestRelease() async throws -> UpdateRelease {
        var request = URLRequest(url: latestReleaseURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let dmgURL = release.assets
            .first(where: { $0.name == "FocusBreak.dmg" })?
            .browserDownloadURL ?? release.assets
            .first(where: { $0.name.lowercased().hasSuffix(".dmg") })?
            .browserDownloadURL

        return UpdateRelease(
            tagName: release.tagName,
            version: AppVersion(release.tagName),
            htmlURL: release.htmlURL,
            dmgURL: dmgURL
        )
    }

    static func downloadDMG(for release: UpdateRelease) async throws -> URL {
        guard let dmgURL = release.dmgURL else {
            throw URLError(.badURL)
        }

        let (temporaryURL, response) = try await URLSession.shared.download(from: dmgURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destinationURL = downloadsURL.appendingPathComponent("FocusBreak-\(release.tagName).dmg")

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL
        let assets: [GitHubAsset]

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: URL

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

enum BreakSound {
    static func playStart() {
        play(named: "Glass")
    }

    static func playEnd() {
        play(named: "Hero")
    }

    private static func play(named name: NSSound.Name) {
        if let sound = NSSound(named: name) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let model: AppModel
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "FocusBreak")
        item.button?.imagePosition = .imageOnly
        item.button?.title = ""
        menu.delegate = self
        item.menu = menu
        updateStatusItem()

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItem()
                }
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        item.button?.title = ""
        item.button?.toolTip = model.isRunning ? model.nextBreakLabel : "FocusBreak"
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let headerItem = NSMenuItem()
        let headerView = NSHostingView(rootView: StatusMenuHeaderView(model: model))
        headerView.frame = NSRect(x: 0, y: 0, width: 300, height: 248)
        headerItem.view = headerView
        menu.addItem(headerItem)
        menu.addItem(.separator())

        addMenuItem("Baslat", action: #selector(startSession), enabled: !model.isRunning)

        if model.isRunning {
            addMenuItem("Durdur", action: #selector(toggleRunning), enabled: true)
        } else if model.canResumeSession {
            addMenuItem("Devam ettir", action: #selector(toggleRunning), enabled: true)
        }

        addMenuItem("Molayi atla", action: #selector(skipBreak), enabled: model.isRunning)
        menu.addItem(.separator())
        addMenuItem("Guncelleme kontrol et", action: #selector(checkForUpdates), enabled: true)
        addMenuItem("Pencereyi ac", action: #selector(openSettings), enabled: true)
        addMenuItem("Cikis", action: #selector(quit), enabled: true)
    }

    private func addMenuItem(_ title: String, action: Selector, enabled: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func startSession() {
        model.beginFocusSession()
    }

    @objc private func toggleRunning() {
        model.toggleRunning()
    }

    @objc private func skipBreak() {
        model.skipUpcomingBreak()
    }

    @objc private func openSettings() {
        model.openSettings()
    }

    @objc private func checkForUpdates() {
        model.checkForUpdates(silent: false)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

struct StatusMenuHeaderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "eye")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("FocusBreak")
                        .font(.headline)
                    Text(model.isRunning ? "Sıradaki: \(model.nextBreakKindText)" : "Başlatmaya hazır")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            CircularTimerView(
                timeText: model.timerDisplay,
                progress: model.nextBreakProgress,
                isRunning: model.isRunning
            )
            .frame(maxWidth: .infinity, alignment: .center)

            Text(model.nextBreakLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(width: 300, height: 248, alignment: .top)
    }
}

struct CircularTimerView: View {
    let timeText: String
    let progress: Double
    let isRunning: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.16), lineWidth: 8)

            Circle()
                .trim(from: 0, to: isRunning ? progress : 0)
                .stroke(
                    AngularGradient(
                        colors: [.teal, .cyan, .teal],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 2) {
                Text(timeText)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                Text(isRunning ? "kalan" : "hazır")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 132, height: 132)
        .padding(.vertical, 2)
    }
}

@MainActor
final class OverlayController {
    private let model: AppModel
    private var centerPanel: NSPanel?
    private var bannerPanel: NSPanel?

    init(model: AppModel) {
        self.model = model
    }

    func show(request: OverlayRequest) {
        if request.kind == .eye {
            showEyeBanner()
        } else {
            showCenterPanel()
        }
    }

    private func showCenterPanel() {
        bannerPanel?.orderOut(nil)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)

        if centerPanel == nil {
            let panel = NSPanel(
                contentRect: screenFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "FocusBreak"
            panel.level = .modalPanel
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.contentView = NSHostingView(rootView: LongBreakOverlayView(model: model))
            self.centerPanel = panel
        }

        centerPanel?.setFrame(screenFrame, display: true)
        centerPanel?.orderFrontRegardless()
    }

    private func showEyeBanner() {
        centerPanel?.orderOut(nil)

        if bannerPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 118),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.contentView = NSHostingView(rootView: EyeBreakBannerView(model: model))
            bannerPanel = panel
        }

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let size = bannerPanel?.frame.size ?? NSSize(width: 420, height: 118)
            let x = frame.midX - size.width / 2
            let y = frame.maxY - size.height - 14
            bannerPanel?.setFrameOrigin(NSPoint(x: x, y: y))
        }

        bannerPanel?.orderFrontRegardless()
    }

    func close() {
        centerPanel?.orderOut(nil)
        bannerPanel?.orderOut(nil)
    }
}

struct EyeBreakBannerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1.0 / 30.0)) { timeline in
            let remaining = smoothRemaining(at: timeline.date)
            let progress = smoothProgress(at: timeline.date)
            let displaySeconds = Int(ceil(remaining))

            HStack(spacing: 14) {
                Image(systemName: "eye")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Göz molası")
                            .font(.headline)
                        Spacer()
                        Text(displaySeconds > 0 ? "\(displaySeconds) sn" : "Hazır")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }

                    Text(displaySeconds > 0 ? "Ekrandan uzak bir noktaya bak." : "Tamamlamak için tıkla.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ProgressView(value: progress)
                        .tint(.teal)
                        .animation(.linear(duration: 0.08), value: progress)
                }

                Button {
                    model.finishCurrentBreak()
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.borderless)
            }
            .padding(16)
            .frame(width: 420, height: 118)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
    }

    private func smoothRemaining(at date: Date) -> TimeInterval {
        guard let request = model.overlayRequest, let endsAt = request.endsAt else {
            return TimeInterval(model.settings.eyeBreakSeconds)
        }

        return max(0, endsAt.timeIntervalSince(date))
    }

    private func smoothProgress(at date: Date) -> Double {
        guard let request = model.overlayRequest,
              let startedAt = request.startedAt,
              let endsAt = request.endsAt else {
            return 0
        }

        let total = max(0.1, endsAt.timeIntervalSince(startedAt))
        let elapsed = date.timeIntervalSince(startedAt)
        return min(1, max(0, elapsed / total))
    }
}

enum AppIcon {
    static func image() -> NSImage? {
        if let bundledURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png") {
            return NSImage(contentsOf: bundledURL)
        }

        let developmentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/AppIcon.png")
        return NSImage(contentsOf: developmentURL)
    }

    @MainActor
    static func applyRuntimeIcon() {
        guard let image = image() else { return }
        NSApp.applicationIconImage = image
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @AppStorage("focusbreak.showingIntro") private var showingIntro = true
    @State private var introStep = 0

    var body: some View {
        Group {
            if showingIntro {
                onboarding
            } else {
                mainDashboard
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var mainDashboard: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    timerHero
                    settings
                    stats
                    rhythm
                    research
                }
                .padding(28)
            }
        }
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ProgressView(value: Double(introStep + 1), total: 3)
                        .tint(.teal)

                    if introStep == 0 {
                        introWarning
                    } else if introStep == 1 {
                        introResearch
                    } else {
                        introSettings
                    }

                    HStack {
                        if introStep > 0 {
                            Button {
                                introStep -= 1
                            } label: {
                                Label("Geri", systemImage: "chevron.left")
                            }
                        }

                        Spacer()

                        Button {
                            if introStep < 2 {
                                introStep += 1
                            } else {
                                model.beginFocusSession()
                                showingIntro = false
                            }
                        } label: {
                            Label(introStep < 2 ? "Devam" : "Kaydet ve baslat", systemImage: introStep < 2 ? "chevron.right" : "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 4)
                }
                .padding(28)
            }
        }
    }

    private var introWarning: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Uzun sure ekrana bakmak gozlerini yorar", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.orange)

            Text("Odaklanirken saatler geciyor ve gozlerin ayni mesafeye kilitleniyor. Bu; kuruluk, yanma, bas agrisi, bulanık gorme ve boyun/omuz gerginligi gibi ekran yorgunlugu belirtilerini artirabilir.")
                .font(.system(size: 18))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                IntroFactTile(icon: "eye.trianglebadge.exclamationmark", title: "Goz kurulugu", detail: "Ekrana bakarken kirpma sayisi azalabilir.")
                IntroFactTile(icon: "timer", title: "Zaman kaybi", detail: "Derin odakta mola sinyali kolayca kacabilir.")
                IntroFactTile(icon: "figure.seated.side", title: "Vucut gerginligi", detail: "Kisa aralar durusu da resetler.")
            }
        }
        .padding(22)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var introResearch: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Denemeler 20-20-20 ritmini guclu bir baslangic yapar", systemImage: "checkmark.seal.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.teal)

            Text("Goz uzmanlarinin yaygin onerisi basit: her 20 dakikada, 20 saniye boyunca uzaktaki bir noktaya bak. FocusBreak bunu saatlik buyuk molalarla birlestirir; boylece hem gozlerini hem calisma ritmini korursun.")
                .font(.system(size: 18))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                IntroFactTile(icon: "20.circle", title: "20 dakika", detail: "Ekran odagini boler.")
                IntroFactTile(icon: "eye", title: "20 saniye", detail: "Uzak odaga gecmeyi hatirlatir.")
                IntroFactTile(icon: "figure.walk", title: "60/5", detail: "Saatlik buyuk mola ekler.")
                IntroFactTile(icon: "timer.circle", title: "Pomodoro", detail: "25 dakika odak ve 5 dakika ara ritmi sunar.")
            }

            Text("Bu bir tibbi tedavi iddiasi degil; amac, kanita dayali ve uygulanabilir bir ekran molasi aliskanligi kurmak.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var introSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ritmini ayarla", systemImage: "slider.horizontal.3")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.teal)
            Text("Calisma modunu sec. FocusBreak ritmiyle veya Pomodoro akisiyla baslayabilirsin.")
                .foregroundStyle(.secondary)
            settings
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            if let icon = AppIcon.image() {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            } else {
                Image(systemName: "eye")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 58, height: 58)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("FocusBreak")
                    .font(.system(size: 30, weight: .bold))
                Text("Yazilimcilar ve ofis calisanlari icin arastirma destekli ekran molalari.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !showingIntro {
                Button {
                    if model.isRunning {
                        model.toggleRunning()
                    } else {
                        model.beginFocusSession()
                    }
                } label: {
                    Label(model.isRunning ? "Duraklat" : "Baslat", systemImage: model.isRunning ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var timerHero: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.isRunning ? "\(model.nextBreakKindText.capitalized) kaldı" : "Odak oturumu hazır")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(model.timerDisplay)
                    .font(.system(size: 68, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                Text(model.lastEventText)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 10) {
                Button {
                    model.beginFocusSession()
                } label: {
                    Label("Baslat", systemImage: "play.fill")
                        .frame(width: 132)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunning)

                if model.isRunning || model.canResumeSession {
                    Button {
                        model.toggleRunning()
                    } label: {
                        Label(model.isRunning ? "Durdur" : "Devam ettir", systemImage: model.isRunning ? "pause.fill" : "play.fill")
                            .frame(width: 132)
                    }
                    .disabled(!model.isRunning && !model.canResumeSession)
                }

                Button {
                    model.skipUpcomingBreak()
                } label: {
                    Label("Molayi atla", systemImage: "forward.fill")
                        .frame(width: 132)
                }
                .disabled(!model.isRunning)
            }
        }
        .padding(22)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var stats: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                StatTile(title: "Siradaki mola", value: model.nextBreakLabel, icon: "timer")
                StatTile(title: "Goz molalari", value: "\(model.counters.completedEyeBreaks)", icon: "eye")
                StatTile(
                    title: model.settings.sessionMode == .pomodoro ? "Pomodoro molalari" : "Buyuk molalar",
                    value: model.settings.sessionMode == .pomodoro ? "\(model.counters.completedPomodoroBreaks)" : "\(model.counters.completedLongBreaks)",
                    icon: model.settings.sessionMode == .pomodoro ? "timer.circle" : "figure.walk"
                )
            }
            GridRow {
                StatTile(title: "Durum", value: model.lastEventText, icon: "checkmark.circle")
                StatTile(title: "Bildirim", value: model.notificationStatusText, icon: "bell")
                StatTile(title: "Acilis", value: model.loginStatusText, icon: "power")
            }
        }
    }

    private var rhythm: some View {
        SectionBlock(title: "Mola ritmi") {
            HStack(spacing: 12) {
                if model.settings.sessionMode == .pomodoro {
                    RhythmTile(
                        title: "Pomodoro",
                        subtitle: "\(model.settings.pomodoroFocusMinutes) dakika odak, \(model.settings.pomodoroBreakMinutes) dakika ara.",
                        icon: "timer.circle"
                    )
                } else {
                    RhythmTile(title: "20-20-20", subtitle: "20 dakikada bir 20 saniye ekrandan uzaklas.", icon: "eye.trianglebadge.exclamationmark")
                    RhythmTile(title: "60/5", subtitle: "60 dakika odaktan sonra 5 dakika buyuk mola.", icon: "clock.arrow.circlepath")
                }
            }
        }
    }

    private var research: some View {
        SectionBlock(title: "Neden bu ritim?") {
            VStack(alignment: .leading, spacing: 10) {
                Text("FocusBreak, AOA ve Mayo Clinic'in 20-20-20 goz molasi onerilerini, CDC/NIOSH'un bilgisayar basinda kisa mola yaklasimi ve mikro mola arastirmalariyla birlestirir.")
                Text("Bu bir tibbi tedavi araci degildir; amaci ekrana uzun sure kesintisiz bakmani engelleyen sade bir aliskanlik sistemi kurmaktir.")
                    .foregroundStyle(.secondary)
                HStack {
                    Link("AOA", destination: URL(string: "https://www.aoa.org/healthy-eyes/eye-and-vision-conditions/computer-vision-syndrome/")!)
                    Link("Mayo Clinic", destination: URL(string: "https://www.mayoclinic.org/diseases-conditions/eyestrain/diagnosis-treatment/drc-20372403")!)
                    Link("CDC/NIOSH", destination: URL(string: "https://www.cdc.gov/niosh/blogs/2020/working-from-home.html")!)
                    Link("Micro-break review", destination: URL(string: "https://pmc.ncbi.nlm.nih.gov/articles/PMC9432722/")!)
                }
            }
        }
    }

    private var settings: some View {
        SectionBlock(title: "Ayarlar") {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Calisma modu", selection: binding(\.sessionMode)) {
                    ForEach(SessionMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(model.settings.sessionMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Hatirlatma tarzi", selection: binding(\.reminderMode)) {
                    ForEach(ReminderMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.settings.reminderMode.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.settings.reminderMode == .gentle ? "Goz molasi sadece ust bildirim olarak gelir." : "Goz molasi ustten sabit banner olarak da görünür.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 320, alignment: .leading)

                    ReminderModePreview(mode: model.settings.reminderMode)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if model.settings.sessionMode == .pomodoro {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Pomodoro ayarlari", systemImage: "timer.circle")
                            .font(.headline)
                            .foregroundStyle(.pink)
                        NumberSettingRow(
                            title: "Odak suresi",
                            unit: "dk",
                            value: boundedIntBinding(\.pomodoroFocusMinutes, in: 5...90),
                            range: 5...90,
                            step: 5
                        )
                        NumberSettingRow(
                            title: "Ara suresi",
                            unit: "dk",
                            value: boundedIntBinding(\.pomodoroBreakMinutes, in: 1...30),
                            range: 1...30,
                            step: 1
                        )
                    }
                    .padding(16)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Goz molasini kullan", isOn: binding(\.eyeBreaksEnabled))
                                .toggleStyle(.switch)
                                .font(.headline)
                                .tint(.teal)
                            NumberSettingRow(
                                title: "Goz molasi araligi",
                                unit: "dk",
                                value: boundedIntBinding(\.eyeBreakIntervalMinutes, in: 1...120),
                                range: 1...120,
                                step: 1
                            )
                            NumberSettingRow(
                                title: "Goz molasi suresi",
                                unit: "sn",
                                value: boundedIntBinding(\.eyeBreakSeconds, in: 5...300),
                                range: 5...300,
                                step: 5
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(16)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Buyuk molayi kullan", isOn: binding(\.longBreaksEnabled))
                                .toggleStyle(.switch)
                                .font(.headline)
                                .tint(.orange)
                            NumberSettingRow(
                                title: "Buyuk mola araligi",
                                unit: "dk",
                                value: boundedIntBinding(\.focusMinutes, in: 1...240),
                                range: 1...240,
                                step: 5
                            )
                            NumberSettingRow(
                                title: "Buyuk mola suresi",
                                unit: "dk",
                                value: boundedIntBinding(\.longBreakMinutes, in: 1...60),
                                range: 1...60,
                                step: 1
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(16)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                HStack(spacing: 18) {
                    Toggle("Bildirimleri kullan", isOn: binding(\.notificationsEnabled))
                    Toggle(
                        "Mac acilisinda baslat",
                        isOn: Binding(
                            get: { model.settings.launchAtLogin },
                            set: { model.setLaunchAtLogin($0) }
                        )
                    )
                    Spacer()
                }

                HStack(spacing: 12) {
                    Label("Guncelleme", systemImage: "arrow.down.circle")
                        .font(.headline)
                    Text(model.updateStatusText)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.checkForUpdates(silent: false)
                    } label: {
                        Label("Kontrol et", systemImage: "arrow.clockwise")
                    }
                }
                .padding(14)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if !showingIntro {
                    HStack {
                        Spacer()
                        Button("Bilgilendirmeyi tekrar goster") {
                            introStep = 0
                            showingIntro = true
                        }
                    }
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<FocusBreakSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in
                var settings = model.settings
                settings[keyPath: keyPath] = value
                model.updateSettings(settings)
            }
        )
    }

    private func boundedIntBinding(
        _ keyPath: WritableKeyPath<FocusBreakSettings, Int>,
        in range: ClosedRange<Int>
    ) -> Binding<Int> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in
                var settings = model.settings
                settings[keyPath: keyPath] = min(max(value, range.lowerBound), range.upperBound)
                model.updateSettings(settings)
            }
        )
    }
}

struct OverlayView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            if let request = model.overlayRequest {
                Image(systemName: request.kind == .eye ? "eye" : "figure.walk")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.teal)

                Text(request.kind == .eye ? "Gozlerini dinlendirme zamani" : "Buyuk mola zamani")
                    .font(.system(size: 28, weight: .bold))

                if request.endsAt == nil {
                    Text(request.kind == .eye ? "20 saniye ekrandan uzak bir noktaya bak." : "5 dakika ayağa kalk, su ic ve ekrandan uzaklas.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button("Atla") { model.skipCurrentBreak() }
                        Button("1 dk ertele") { model.snoozeCurrentBreak() }
                        Button("Molaya basla") { model.beginCurrentBreak() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Text(DurationFormatter.compactRemaining(to: Date().addingTimeInterval(TimeInterval(request.remainingSeconds))))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Button("Molayi bitir") { model.finishCurrentBreak() }
                }
            }
        }
        .padding(30)
        .frame(width: 520, height: 300)
        .background(.regularMaterial)
    }
}

struct LongBreakOverlayView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            if let request = model.overlayRequest {
                TimelineView(.periodic(from: Date(), by: 1.0 / 15.0)) { timeline in
                    overlayCard(for: request, at: timeline.date)
                }
            }
        }
    }

    private func overlayCard(for request: OverlayRequest, at date: Date) -> some View {
        let remaining = smoothRemaining(for: request, at: date)
        let hasStarted = request.endsAt != nil
        let isDone = hasStarted && remaining <= 0

        return VStack(spacing: 24) {
            Image(systemName: request.kind == .pomodoro ? "timer.circle" : "figure.walk")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(request.kind == .pomodoro ? .pink : .teal)

            VStack(spacing: 8) {
                Text(request.kind == .pomodoro ? "POMODORO ARA" : "MOLA")
                    .font(.system(size: 58, weight: .black, design: .rounded))
                    .tracking(0)
                Text(isDone ? completionText(for: request.kind) : detailText(for: request.kind))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if hasStarted {
                Text(isDone ? "Hazır" : countdownText(remaining))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
            } else {
                Text(breakLengthText(for: request.kind))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            HStack(spacing: 12) {
                Button {
                    model.skipCurrentBreak()
                } label: {
                    Label("Pas geç", systemImage: "forward.fill")
                }

                Button {
                    model.snoozeCurrentBreak(minutes: request.kind == .pomodoro ? 1 : 5)
                } label: {
                    Label(request.kind == .pomodoro ? "1 dk ertele" : "5 dk ertele", systemImage: "clock.arrow.circlepath")
                }

                Button("Molayi bitir") {
                    model.finishCurrentBreak()
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(34)
        .frame(width: 560)
        .frame(minHeight: 360)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 28, x: 0, y: 18)
    }

    private func smoothRemaining(for request: OverlayRequest, at date: Date) -> TimeInterval {
        guard let endsAt = request.endsAt else { return durationFallback(for: request.kind) }
        return max(0, endsAt.timeIntervalSince(date))
    }

    private func countdownText(_ remaining: TimeInterval) -> String {
        let totalSeconds = max(0, Int(ceil(remaining)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func durationFallback(for kind: BreakKind) -> TimeInterval {
        switch kind {
        case .long:
            return TimeInterval(model.settings.longBreakMinutes * 60)
        case .pomodoro:
            return TimeInterval(model.settings.pomodoroBreakMinutes * 60)
        case .eye:
            return TimeInterval(model.settings.eyeBreakSeconds)
        }
    }

    private func breakLengthText(for kind: BreakKind) -> String {
        switch kind {
        case .long:
            return "\(model.settings.longBreakMinutes) dakikalik buyuk mola"
        case .pomodoro:
            return "\(model.settings.pomodoroBreakMinutes) dakikalik pomodoro arasi"
        case .eye:
            return "\(model.settings.eyeBreakSeconds) saniyelik goz molasi"
        }
    }

    private func detailText(for kind: BreakKind) -> String {
        switch kind {
        case .long:
            return "Gozlerini ve bedenini ekrandan uzaklastir."
        case .pomodoro:
            return "Kisa bir ara ver, sonra yeni odak turuna gec."
        case .eye:
            return "Kisa bir goz molasi ver."
        }
    }

    private func completionText(for kind: BreakKind) -> String {
        switch kind {
        case .long:
            return "Mola suresi tamamlandi."
        case .pomodoro:
            return "Pomodoro arasi tamamlandi."
        case .eye:
            return "Goz molasi tamamlandi."
        }
    }
}

struct IntroFactTile: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.teal)
                .frame(height: 24)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.teal)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct RhythmTile: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.teal)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ReminderModePreview: View {
    let mode: ReminderMode

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 14)
                .fill(backgroundGradient)

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("FocusBreak bildirimi")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("20 sn")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.88))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if mode == .insistent {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "eye")
                                .foregroundStyle(.teal)
                            Text("Goz molasi")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text("Hazır")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        }

                        Capsule()
                            .fill(Color.teal)
                            .frame(height: 6)

                        Text("Bildirimden sonra banner ekranda kalir.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "bell")
                                .foregroundStyle(.orange)
                            Text("Daha sakin akış")
                                .font(.caption.weight(.semibold))
                            Spacer()
                        }

                        Text("Sadece ust bildirim gelir, panel acilmaz.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(12)
        }
        .frame(width: 260, height: 148)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 8)
    }

    private var backgroundGradient: LinearGradient {
        if mode == .insistent {
            return LinearGradient(
                colors: [Color(red: 0.10, green: 0.14, blue: 0.20), Color(red: 0.16, green: 0.30, blue: 0.34)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [Color(red: 0.98, green: 0.77, blue: 0.38), Color(red: 0.93, green: 0.52, blue: 0.31)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct NumberSettingRow: View {
    let title: String
    let unit: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack(spacing: 8) {
                Text(title)
                    .frame(minWidth: 155, alignment: .leading)
                TextField("", value: $value, formatter: NumberFormatter.focusBreakInteger)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionBlock<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
            content
        }
    }
}

private extension NumberFormatter {
    static var focusBreakInteger: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 0
        return formatter
    }
}

private extension NSMenuItem {
    convenience init(title: String, action: Selector?, keyEquivalent: String, target: AnyObject) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        self.target = target
    }
}
