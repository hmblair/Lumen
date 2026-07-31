// SchedulesView.swift
// The schedules screen: list and edit schedules, browse scenes, run a scene
// now, save the current color as a scene. Cross-platform, provider-neutral —
// everything goes through LightController's normalized client. Compact: it
// lives in the same 280 pt menu-bar panel as the main controls.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI
import LumenCore

private let dayOrder = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

struct SchedulesView: View {
    @ObservedObject var controller: LightController
    /// The wheel/slider state, for "save current color as scene".
    var currentColor: () -> (hue: Double, saturation: Double, level: Double)

    @State private var editing: EditState?
    @State private var newSceneName = ""
    @State private var errorMessage: String?

    /// The schedule form's working state; name identifies the schedule being
    /// edited (existing name = replace, new name = create). Time is kept as
    /// hour/minute directly — mirroring the daemon's "HH:MM" — because
    /// SwiftUI's DatePicker renders as a fixed-size capsule on macOS 26 that
    /// clips its own text and ignores style/frame modifiers.
    private struct EditState {
        var name: String
        var originalName: String?   // nil = creating
        var hour = 7
        var minute = 0
        var days: Set<String> = Set(dayOrder.prefix(5))
        var scene = "sunrise"
    }

    /// A sensible pre-selection for the editor's scene picker.
    private var defaultSceneName: String {
        controller.scenes.keys.contains("sunrise") ? "sunrise"
            : controller.scenes.keys.sorted().first ?? "sunrise"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if editing != nil {
                editor
            } else {
                scheduleList
                Divider()
                sceneList
            }
        }
        .task { await controller.loadLibrary() }
    }

    // MARK: - Schedule list

    private var scheduleList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("SCHEDULES").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    editing = EditState(name: "", scene: defaultSceneName)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add schedule")
            }
            if controller.schedules.isEmpty {
                Text("No schedules yet").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(controller.schedules.sorted(by: { $0.key < $1.key }), id: \.key) { name, schedule in
                scheduleRow(name: name, schedule: schedule)
            }
        }
    }

    private func scheduleRow(name: String, schedule: Schedule) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { schedule.enabled },
                set: { enabled in
                    var updated = schedule
                    updated.enabled = enabled
                    Task { errorMessage = await controller.save(schedule: updated, named: name) }
                }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text("\(schedule.at) · \(daysSummary(schedule)) · \(schedule.scene)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                editing = editState(for: name, schedule: schedule)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
            Button {
                Task { errorMessage = await controller.deleteSchedule(named: name) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .opacity(schedule.enabled ? 1 : 0.5)
    }

    private func daysSummary(_ schedule: Schedule) -> String {
        if let date = schedule.on { return date }
        let days = Set(schedule.days)
        if days.count == 7 { return "daily" }
        if days == Set(dayOrder.prefix(5)) { return "weekdays" }
        return dayOrder.filter(days.contains).joined(separator: " ")
    }

    // MARK: - Schedule editor

    private var editor: some View {
        let binding = Binding(get: { editing! }, set: { editing = $0 })
        return VStack(alignment: .leading, spacing: 8) {
            Text(binding.wrappedValue.originalName == nil ? "NEW SCHEDULE" : "EDIT SCHEDULE")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Name", text: binding.name)
                .textFieldStyle(.roundedBorder)
            HStack {
                // Known cosmetic issue: on macOS 26 the capsule slightly
                // clips its own text; its size is intrinsic and ignores
                // style/frame/locale adjustments. Accepted as-is.
                DatePicker("", selection: timeBinding(binding), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Picker("", selection: binding.scene) {
                    ForEach(controller.scenes.keys.sorted(), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            HStack(spacing: 4) {
                ForEach(dayOrder, id: \.self) { day in
                    dayToggle(day, binding: binding)
                }
            }
            HStack {
                Button("Cancel") { editing = nil }
                Spacer()
                Button("Save") { Task { await saveEdit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(binding.wrappedValue.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || binding.wrappedValue.days.isEmpty)
            }
        }
    }

    /// Bridge the DatePicker's Date to the edit state's hour/minute (the
    /// daemon's native format — no Date survives past this control).
    private func timeBinding(_ binding: Binding<EditState>) -> Binding<Date> {
        Binding<Date>(
            get: {
                Calendar.current.date(bySettingHour: binding.wrappedValue.hour,
                                      minute: binding.wrappedValue.minute,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                binding.wrappedValue.hour = parts.hour ?? 0
                binding.wrappedValue.minute = parts.minute ?? 0
            })
    }

    private func dayToggle(_ day: String, binding: Binding<EditState>) -> some View {
        let selected = binding.wrappedValue.days.contains(day)
        return Button {
            if selected { binding.wrappedValue.days.remove(day) }
            else { binding.wrappedValue.days.insert(day) }
        } label: {
            Text(String(day.prefix(1)).uppercased())
                .font(.caption2)
                .frame(width: 20, height: 20)
                .background(Circle().fill(selected ? Color.accentColor : Color.primary.opacity(0.1)))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .help(day)
    }

    private func editState(for name: String, schedule: Schedule) -> EditState {
        var state = EditState(name: name, scene: schedule.scene)
        state.originalName = name
        state.days = Set(schedule.days)
        let parts = schedule.at.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2 {
            state.hour = parts[0]
            state.minute = parts[1]
        }
        return state
    }

    private func saveEdit() async {
        guard let state = editing else { return }
        let name = state.name.trimmingCharacters(in: .whitespaces)
        let schedule = Schedule(
            at: String(format: "%02d:%02d", state.hour, state.minute),
            days: dayOrder.filter(state.days.contains),
            scene: state.scene)
        if let error = await controller.save(schedule: schedule, named: name) {
            errorMessage = error
            return
        }
        // Renaming = upsert under the new name + delete the old one.
        if let original = state.originalName, original != name {
            await controller.deleteSchedule(named: original)
        }
        errorMessage = nil
        editing = nil
    }

    // MARK: - Scenes

    private var sceneList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SCENES").font(.caption).foregroundStyle(.secondary)
            ForEach(controller.scenes.sorted(by: { $0.key < $1.key }), id: \.key) { name, scene in
                HStack(spacing: 6) {
                    Image(systemName: scene.isSolid ? "circle.fill" : "chart.xyaxis.line")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(name)
                    Text(sceneSummary(scene))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { errorMessage = await controller.runScene(named: name) }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    // One scene at a time: the running one must finish or be
                    // stopped first (the daemon would 409 anyway).
                    .disabled(controller.running != nil)
                    .help("Run this scene")
                    Button {
                        Task { errorMessage = await controller.deleteScene(named: name) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete")
                }
            }
            HStack(spacing: 6) {
                TextField("Save current color as…", text: $newSceneName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Button {
                    Task { await saveCurrentColor() }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(newSceneName.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Save the wheel/slider color as a solid scene")
            }
        }
    }

    /// e.g. "2 lights · 60m" for a curve, "2 lights" for a solid.
    /// (Qualified: LumenCore.Scene shadows SwiftUI.Scene in this module.)
    private func sceneSummary(_ scene: LumenCore.Scene) -> String {
        let count = scene.lights.count
        let lights = count == 1 ? "1 light" : "\(count) lights"
        guard scene.duration > 0 else { return lights }
        let time = scene.duration < 90
            ? "\(Int(scene.duration))s"
            : "\(Int((scene.duration / 60).rounded()))m"
        return "\(lights) · \(time)"
    }

    /// Capture the wheel/slider color for the currently selected lights (all
    /// lights when nothing is selected) as a solid scene.
    private func saveCurrentColor() async {
        let name = newSceneName.trimmingCharacters(in: .whitespaces)
        let ids = controller.selection.isEmpty
            ? controller.lights.map(\.id)
            : Array(controller.selection)
        let color = currentColor()
        let scene = Scene.solid(hue: color.hue, saturation: color.saturation,
                                level: color.level, lightIDs: ids)
        if let error = await controller.save(scene: scene, named: name) {
            errorMessage = error
        } else {
            errorMessage = nil
            newSceneName = ""
        }
    }
}
