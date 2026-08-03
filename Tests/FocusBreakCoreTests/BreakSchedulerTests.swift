import XCTest
@testable import FocusBreakCore

final class BreakSchedulerTests: XCTestCase {
    func testEyeBreakBecomesDueBeforeLongBreak() {
        let start = Date(timeIntervalSince1970: 100)
        let settings = FocusBreakSettings(
            focusMinutes: 60,
            longBreakMinutes: 5,
            eyeBreakIntervalMinutes: 20,
            eyeBreakSeconds: 20,
            overlayDelaySeconds: 60
        )
        let scheduler = BreakScheduler(settings: settings, now: start)

        XCTAssertNil(scheduler.dueBreak(at: start.addingTimeInterval(19 * 60)))
        XCTAssertEqual(scheduler.dueBreak(at: start.addingTimeInterval(20 * 60)), .eye)
    }

    func testLongBreakTakesPriorityWhenBothAreDue() {
        let start = Date(timeIntervalSince1970: 100)
        let scheduler = BreakScheduler(now: start)

        XCTAssertEqual(scheduler.dueBreak(at: start.addingTimeInterval(60 * 60)), .long)
    }

    func testCompletingLongBreakResetsBothSchedules() {
        let start = Date(timeIntervalSince1970: 100)
        var scheduler = BreakScheduler(now: start)
        let completedAt = start.addingTimeInterval(60 * 60)

        scheduler.complete(.long, at: completedAt)

        XCTAssertEqual(
            Int(scheduler.nextEyeBreakAt.timeIntervalSince(completedAt)),
            20 * 60
        )
        XCTAssertEqual(
            Int(scheduler.nextLongBreakAt.timeIntervalSince(completedAt)),
            60 * 60
        )
    }

    func testPausedSchedulerDoesNotReturnDueBreak() {
        let start = Date(timeIntervalSince1970: 100)
        var scheduler = BreakScheduler(now: start)
        scheduler.isPaused = true

        XCTAssertNil(scheduler.dueBreak(at: start.addingTimeInterval(61 * 60)))
    }

    func testPomodoroBreakBecomesDueAtFocusDeadline() {
        let start = Date(timeIntervalSince1970: 100)
        let settings = FocusBreakSettings(
            pomodoroFocusMinutes: 25,
            pomodoroBreakMinutes: 5,
            sessionMode: .pomodoro
        )
        let scheduler = BreakScheduler(settings: settings, now: start)

        XCTAssertNil(scheduler.dueBreak(at: start.addingTimeInterval(24 * 60)))
        XCTAssertEqual(scheduler.dueBreak(at: start.addingTimeInterval(25 * 60)), .pomodoro)
    }

    func testCompletingPomodoroResetsNextPomodoroFocusWindow() {
        let start = Date(timeIntervalSince1970: 100)
        let settings = FocusBreakSettings(
            pomodoroFocusMinutes: 25,
            pomodoroBreakMinutes: 5,
            sessionMode: .pomodoro
        )
        var scheduler = BreakScheduler(settings: settings, now: start)
        let completedAt = start.addingTimeInterval(25 * 60)

        scheduler.complete(.pomodoro, at: completedAt)

        XCTAssertEqual(
            Int(scheduler.nextLongBreakAt.timeIntervalSince(completedAt)),
            25 * 60
        )
    }
}
