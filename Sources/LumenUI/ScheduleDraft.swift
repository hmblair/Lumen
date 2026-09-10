// ScheduleDraft.swift
// The schedule form's working state and its conversion to and from the wire
// Schedule, shared by the macOS editor and the iOS one. Schedules are
// anonymous in the UI — a row is identified by when + what — so the daemon's
// key is a hidden id (UUID for new schedules, whatever key an existing one
// has). Time is kept as hour/minute directly, mirroring the daemon's "HH:MM".
// Author: Hamish M. Blair <hmblair@stanford.edu>

import Foundation
import LumenCore

struct ScheduleDraft {
    var key: String?   // nil = creating
    var mode: ScheduleTimeMode = .clock
    var hour = 7
    var minute = 0
    var days: Set<String> = Set(scheduleDayOrder.prefix(5))
    var scene = "sunrise"

    init(scene: String) {
        self.scene = scene
    }

    init(key: String, schedule: Schedule) {
        self.key = key
        self.scene = schedule.scene
        self.days = Set(schedule.days)
        if let mode = ScheduleTimeMode(rawValue: schedule.at) {
            self.mode = mode
        } else {
            let parts = schedule.at.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 {
                hour = parts[0]
                minute = parts[1]
            }
        }
    }

    /// The daemon's `at` string: "HH:MM", or the solar literal.
    var atString: String {
        mode == .clock ? String(format: "%02d:%02d", hour, minute) : mode.rawValue
    }

    /// The wire schedule this draft describes.
    var built: Schedule {
        Schedule(at: atString, days: scheduleDayOrder.filter(days.contains), scene: scene)
    }

    /// The key to save under: the existing one, or a fresh id for a new
    /// schedule.
    var saveKey: String { key ?? UUID().uuidString }

    /// The words around the time picker, so both platforms phrase the row
    /// identically: "From [time] to 7:30 AM" when the selected scene has a
    /// duration (noting a wrap past midnight), "At [time]" when it applies
    /// instantly. Clock mode only — a solar start has no fixed clock time.
    func timeSentence(scenes: [String: Scene]) -> (lead: String, end: String?) {
        guard mode == .clock,
              let scene = scenes[scene], scene.duration > 0,
              let start = Calendar.current.date(bySettingHour: hour, minute: minute,
                                                second: 0, of: Date())
        else { return ("At", nil) }
        let end = start.addingTimeInterval(scene.duration)
        let wrapped = !Calendar.current.isDate(end, inSameDayAs: start)
        let ends = end.formatted(date: .omitted, time: .shortened) + (wrapped ? " (next day)" : "")
        return ("From", "to \(ends)")
    }
}

/// A sensible pre-selection for a new schedule's scene picker.
@MainActor
func defaultScheduleScene(_ controller: LightController) -> String {
    controller.visibleScenes.keys.contains("sunrise") ? "sunrise"
        : controller.visibleScenes.keys.sorted().first ?? "sunrise"
}
