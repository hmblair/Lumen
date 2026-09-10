// SummaryFormatting.swift
// Row-summary text shared by the macOS panel and the iOS screens: what a
// scene touches, when a schedule fires. Pure formatting over LumenCore
// types, so both platforms describe the same object with the same words.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import Foundation
import LumenCore

// MARK: - Scenes

/// e.g. "Bedroom, Living room · 60m" — the rooms the scene touches
/// (with "+n" for involved lights outside any room), falling back to a
/// light count when no rooms are involved.
func sceneSummary(_ scene: LumenCore.Scene, groups: [String: LightGroup]) -> String {
    let sceneLights = Set(scene.lights.keys)
    let roomNames = groups.values
        .filter { !sceneLights.isDisjoint(with: $0.lights) }
        .map(\.name)
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    let roomed = Set(groups.values.flatMap(\.lights))
    let strays = sceneLights.subtracting(roomed).count

    var what: String
    if roomNames.isEmpty {
        what = sceneLights.count == 1 ? "1 light" : "\(sceneLights.count) lights"
    } else {
        what = roomNames.joined(separator: ", ")
        if strays > 0 {
            what += " +\(strays)"
        }
    }
    guard scene.duration > 0 else { return what }
    let time = scene.duration < 90
        ? "\(Int(scene.duration))s"
        : "\(Int((scene.duration / 60).rounded()))m"
    return "\(what) · \(time)"
}

// MARK: - Schedules

let scheduleDayOrder = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

/// How a schedule names its time, mirroring the daemon's `at` grammar: a
/// wall-clock "HH:MM", or the literals "sunrise"/"sunset".
enum ScheduleTimeMode: String, CaseIterable {
    case clock, sunrise, sunset

    var symbol: String {
        switch self {
        case .clock: return "clock"
        case .sunrise: return "sunrise.fill"
        case .sunset: return "sunset.fill"
        }
    }

    var label: String {
        switch self {
        case .clock: return "At a time"
        case .sunrise: return "At sunrise"
        case .sunset: return "At sunset"
        }
    }

    var name: String {
        switch self {
        case .clock: return "Time"
        case .sunrise: return "Sunrise"
        case .sunset: return "Sunset"
        }
    }
}

/// Day sets with a nicer name than listing the days.
private let daySetSummaries: [Set<String>: String] = [
    Set(scheduleDayOrder): "daily",
    Set(scheduleDayOrder.prefix(5)): "weekdays",
    Set(scheduleDayOrder.prefix(5)).union(["sat"]): "weekdays sat",
    Set(scheduleDayOrder.prefix(5)).union(["sun"]): "weekdays sun",
    ["sat", "sun"]: "weekends",
]

/// A row's time text: "7:00 AM", or "sunset (8:10 PM)" — the parenthetical
/// is today's time per the daemon, dropped when it has no location to
/// compute one.
func scheduleTimeSummary(_ at: String, config: BridgeConfig?) -> String {
    guard let mode = ScheduleTimeMode(rawValue: at), mode != .clock else {
        return localizedTime(at)
    }
    let resolved = mode == .sunrise ? config?.sunrise : config?.sunset
    guard let resolved else { return at }
    return "\(at) (\(localizedTime(resolved)))"
}

/// The daemon's "HH:MM" rendered in the machine's locale (e.g. "7:00 AM"
/// in a 12-hour locale, "07:00" in a 24-hour one); non-times pass through
/// unchanged.
func localizedTime(_ at: String) -> String {
    let parts = at.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2,
          let date = Calendar.current.date(bySettingHour: parts[0], minute: parts[1],
                                           second: 0, of: Date())
    else { return at }
    return date.formatted(date: .omitted, time: .shortened)
}

func scheduleDaysSummary(_ schedule: Schedule) -> String {
    if let date = schedule.on { return date }
    let days = Set(schedule.days)
    return daySetSummaries[days]
        ?? scheduleDayOrder.filter(days.contains).joined(separator: " ")
}
