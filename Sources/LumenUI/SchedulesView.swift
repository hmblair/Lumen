// SchedulesView.swift
// The schedules screen: the *when* — list and edit time-only schedules that
// fire scenes. Cross-platform, provider-neutral; compact enough for the
// 280 pt menu-bar panel. Scenes themselves are managed on ScenesView.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI
import LumenCore
#if os(macOS)
import AppKit
#endif

private let dayOrder = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

/// Day sets with a nicer name than listing the days.
private let daySetSummaries: [Set<String>: String] = [
    Set(dayOrder): "daily",
    Set(dayOrder.prefix(5)): "weekdays",
    Set(dayOrder.prefix(5)).union(["sat"]): "weekdays sat",
    Set(dayOrder.prefix(5)).union(["sun"]): "weekdays sun",
    ["sat", "sun"]: "weekends",
]

struct SchedulesView: View {
    @ObservedObject var controller: LightController

    @State private var editing: EditState?
    @State private var errorMessage: String?

    /// The schedule form's working state. Schedules are anonymous in the UI —
    /// a row is identified by when + what — so the daemon's key is a hidden
    /// id (UUID for new schedules, whatever key an existing one has). Time is
    /// kept as hour/minute directly — mirroring the daemon's "HH:MM" —
    /// because SwiftUI's DatePicker renders as a fixed-size capsule on macOS
    /// 26 that clips its own text and ignores style/frame modifiers.
    private struct EditState {
        var key: String?   // nil = creating
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
            ErrorBanner(message: $errorMessage)
            if editing != nil {
                editor
            } else {
                scheduleList
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
                    // Entering the editor is a scope change: whatever failed
                    // before doesn't apply to a fresh form.
                    errorMessage = nil
                    editing = EditState(scene: defaultSceneName)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(HoverIconButtonStyle())
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
            // Grey only the description when disabled — dimming the whole row
            // made the controls look (and on macOS 26's glass controls,
            // behave) disabled, wedging the schedule off forever.
            VStack(alignment: .leading, spacing: 1) {
                Text(schedule.scene)
                Text("\(localizedTime(schedule.at)) · \(daysSummary(schedule))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(schedule.enabled ? 1 : 0.5)
            Spacer()
            Button {
                errorMessage = nil
                editing = editState(forKey: name, schedule: schedule)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(HoverIconButtonStyle())
            .help("Edit")
            Button {
                Task { errorMessage = await controller.deleteSchedule(named: name) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(HoverIconButtonStyle())
            .help("Delete")
        }
    }

    /// The daemon's "HH:MM" rendered in the machine's locale (e.g. "7:00 AM"
    /// in a 12-hour locale, "07:00" in a 24-hour one).
    private func localizedTime(_ at: String) -> String {
        let parts = at.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2,
              let date = Calendar.current.date(bySettingHour: parts[0], minute: parts[1],
                                               second: 0, of: Date())
        else { return at }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func daysSummary(_ schedule: Schedule) -> String {
        if let date = schedule.on { return date }
        let days = Set(schedule.days)
        return daySetSummaries[days]
            ?? dayOrder.filter(days.contains).joined(separator: " ")
    }

    // MARK: - Schedule editor

    private var editor: some View {
        let binding = Binding(get: { editing! }, set: { editing = $0 })
        // Three unlabeled rows — the controls speak for themselves:
        // scene, "start to end", days.
        return VStack(alignment: .leading, spacing: 10) {
            Text(binding.wrappedValue.key == nil ? "NEW SCHEDULE" : "EDIT SCHEDULE")
                .font(.caption).foregroundStyle(.secondary)
            // Scene and times share a row: the time field right-aligns its
            // digits within a two-digit-wide box, so mid-row (after the
            // popup) its ragged left edge doesn't read as misalignment.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Picker("", selection: binding.scene) {
                    ForEach(controller.scenes.keys.sorted(), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                timeField(binding)
                if let ends = endTimeText(binding.wrappedValue) {
                    Text("to").foregroundStyle(.secondary)
                    Text(ends).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                ForEach(dayOrder, id: \.self) { day in
                    dayToggle(day, binding: binding)
                }
            }
            HStack {
                Button("Cancel") {
                    errorMessage = nil
                    editing = nil
                }
                Spacer()
                Button("Save") { Task { await saveEdit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(binding.wrappedValue.days.isEmpty)
            }
        }
    }

    /// Start + the selected scene's duration, locale-formatted; nil for
    /// instant (solid) scenes. Notes a wrap past midnight.
    private func endTimeText(_ state: EditState) -> String? {
        guard let scene = controller.scenes[state.scene], scene.duration > 0,
              let start = Calendar.current.date(bySettingHour: state.hour, minute: state.minute,
                                                second: 0, of: Date())
        else { return nil }
        let end = start.addingTimeInterval(scene.duration)
        let wrapped = !Calendar.current.isDate(end, inSameDayAs: start)
        return end.formatted(date: .omitted, time: .shortened) + (wrapped ? " (next day)" : "")
    }

    /// The time control. SwiftUI's DatePicker renders as a fixed-size capsule
    /// on macOS 26 that clips its own text and ignores every adjustment, so
    /// on macOS this is the bare AppKit text-field picker instead — the same
    /// unboxed, stepper-less control Calendar.app uses.
    @ViewBuilder private func timeField(_ binding: Binding<EditState>) -> some View {
        #if os(macOS)
        InlineTimePicker(date: timeBinding(binding))
        #else
        DatePicker("", selection: timeBinding(binding), displayedComponents: .hourAndMinute)
            .labelsHidden()
        #endif
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

    #if os(macOS)
    /// AppKit's text-field date picker (Calendar.app's inline style),
    /// integrated properly into SwiftUI layout: the control's frame is larger
    /// than its *alignment rect* (`alignmentRectInsets`) — AppKit lays out by
    /// the latter, SwiftUI by the former, which reads as phantom padding and
    /// a drifting baseline. The wrapper reads the control's own metrics and
    /// compensates with negative padding plus a real firstTextBaseline guide.
    private struct InlineTimePicker: View {
        @Binding var date: Date
        @State private var insets = EdgeInsets()
        @State private var baselineFromTop: CGFloat?

        var body: some View {
            BareTimePicker(date: $date, onMetrics: { newInsets, baseline in
                insets = newInsets
                baselineFromTop = baseline
            })
            .fixedSize()
            .padding(EdgeInsets(top: -insets.top, leading: -insets.leading,
                                bottom: -insets.bottom, trailing: -insets.trailing))
            .alignmentGuide(.firstTextBaseline) { dimensions in
                baselineFromTop.map { $0 - insets.top } ?? dimensions[VerticalAlignment.center]
            }
        }
    }

    private struct BareTimePicker: NSViewRepresentable {
        @Binding var date: Date
        var onMetrics: (EdgeInsets, CGFloat) -> Void

        func makeNSView(context: Context) -> NSDatePicker {
            let picker = NSDatePicker()
            picker.datePickerStyle = .textField
            picker.datePickerElements = .hourMinute
            picker.isBezeled = false
            picker.drawsBackground = false
            picker.font = .systemFont(ofSize: NSFont.systemFontSize)
            picker.target = context.coordinator
            picker.action = #selector(Coordinator.changed(_:))
            picker.dateValue = date

            let insets = picker.alignmentRectInsets
            let baseline = picker.firstBaselineOffsetFromTop
            DispatchQueue.main.async {
                onMetrics(EdgeInsets(top: insets.top, leading: insets.left,
                                     bottom: insets.bottom, trailing: insets.right),
                          baseline)
            }
            return picker
        }

        func updateNSView(_ picker: NSDatePicker, context: Context) {
            context.coordinator.date = $date
            if picker.dateValue != date {
                picker.dateValue = date
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(date: $date)
        }

        final class Coordinator: NSObject {
            var date: Binding<Date>

            init(date: Binding<Date>) {
                self.date = date
            }

            @objc func changed(_ sender: NSDatePicker) {
                date.wrappedValue = sender.dateValue
            }
        }
    }
    #endif

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

    private func editState(forKey key: String, schedule: Schedule) -> EditState {
        var state = EditState(key: key, scene: schedule.scene)
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
        let schedule = Schedule(
            at: String(format: "%02d:%02d", state.hour, state.minute),
            days: dayOrder.filter(state.days.contains),
            scene: state.scene)
        if let error = await controller.save(schedule: schedule,
                                             named: state.key ?? UUID().uuidString) {
            errorMessage = error
            return
        }
        errorMessage = nil
        editing = nil
    }

}
