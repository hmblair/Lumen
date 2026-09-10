// SchedulesView.swift
// The schedules screen: the *when* — list and edit time-only schedules that
// fire scenes. Cross-platform, provider-neutral; compact enough for the
// 280 pt menu-bar panel. Scenes themselves are managed on ScenesView.
// Author: Hamish M. Blair <hmblair@stanford.edu>

#if os(macOS)

import SwiftUI
import LumenCore
import AppKit

struct SchedulesView: View {
    @ObservedObject var controller: LightController

    @State private var editing: ScheduleDraft?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ErrorBanner(message: $errorMessage)
            if editing != nil {
                editor
            } else {
                scheduleList
            }
        }
        .task {
            await controller.loadLibrary()
            // For today's sunrise/sunset, so solar rows can show the time.
            await controller.loadBridgeConfig()
        }
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
                    editing = ScheduleDraft(scene: defaultScheduleScene(controller))
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(IconButtonStyle())
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
                Text("\(scheduleTimeSummary(schedule.at, config: controller.bridgeConfig)) · \(scheduleDaysSummary(schedule))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(schedule.enabled ? 1 : 0.5)
            Spacer()
            Button {
                errorMessage = nil
                editing = ScheduleDraft(key: name, schedule: schedule)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(IconButtonStyle())
            .help("Edit")
            Button {
                Task { errorMessage = await controller.deleteSchedule(named: name) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(IconButtonStyle())
            .help("Delete")
        }
    }

    // MARK: - Schedule editor

    private var editor: some View {
        let binding = Binding(get: { editing! }, set: { editing = $0 })
        // Three unlabeled rows — the controls speak for themselves:
        // scene, "start to end", days.
        return VStack(alignment: .leading, spacing: 10) {
            Text(binding.wrappedValue.key == nil ? "NEW SCHEDULE" : "EDIT SCHEDULE")
                .font(.caption).foregroundStyle(.secondary)
            // Scene and time mode share the first row; the mode chips echo
            // the day chips below so the editor speaks one visual language.
            HStack(spacing: 6) {
                Picker("", selection: binding.scene) {
                    ForEach(controller.visibleScenes.keys.sorted(), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                ForEach(ScheduleTimeMode.allCases, id: \.self) { mode in
                    modeChip(mode, binding: binding)
                }
            }
            // Only a wall-clock schedule needs a time input; sunrise/sunset
            // carry their own. The time field right-aligns its digits within
            // a two-digit-wide box, so its ragged left edge doesn't read as
            // misalignment.
            if binding.wrappedValue.mode == .clock {
                let sentence = binding.wrappedValue.timeSentence(scenes: controller.scenes)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(sentence.lead)
                    timeField(binding)
                    if let end = sentence.end {
                        Text(end).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 4) {
                ForEach(scheduleDayOrder, id: \.self) { day in
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

    /// The time control. SwiftUI's DatePicker renders as a fixed-size capsule
    /// on macOS 26 that clips its own text and ignores every adjustment, so
    /// on macOS this is the bare AppKit text-field picker instead — the same
    /// unboxed, stepper-less control Calendar.app uses.
    @ViewBuilder private func timeField(_ binding: Binding<ScheduleDraft>) -> some View {
        #if os(macOS)
        InlineTimePicker(date: timeBinding(binding))
        #else
        DatePicker("", selection: timeBinding(binding), displayedComponents: .hourAndMinute)
            .labelsHidden()
        #endif
    }

    /// Bridge the DatePicker's Date to the edit state's hour/minute (the
    /// daemon's native format — no Date survives past this control).
    private func timeBinding(_ binding: Binding<ScheduleDraft>) -> Binding<Date> {
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

    private func modeChip(_ mode: ScheduleTimeMode, binding: Binding<ScheduleDraft>) -> some View {
        let selected = binding.wrappedValue.mode == mode
        return Button {
            binding.wrappedValue.mode = mode
        } label: {
            Image(systemName: mode.symbol)
                .font(.caption2)
                .frame(width: 22, height: 22)
                .background(Circle().fill(selected ? Color.accentColor : Color.primary.opacity(0.1)))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .help(mode.label)
    }

    private func dayToggle(_ day: String, binding: Binding<ScheduleDraft>) -> some View {
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

    private func saveEdit() async {
        guard let draft = editing else { return }
        if let error = await controller.save(schedule: draft.built, named: draft.saveKey) {
            errorMessage = error
            return
        }
        errorMessage = nil
        editing = nil
    }

}

#endif
