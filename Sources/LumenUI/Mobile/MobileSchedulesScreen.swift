// MobileSchedulesScreen.swift
// The iOS schedules screen: a list of schedules (toggle to enable, tap to
// edit, swipe to delete) and a form sheet for editing. The form's working
// state and all summary text come from the shared ScheduleDraft and
// formatting helpers.
// Author: Hamish M. Blair <hmblair@stanford.edu>

#if os(iOS)

import SwiftUI
import LumenCore

struct MobileSchedulesScreen: View {
    @ObservedObject var controller: LightController

    @State private var editing: EditContext?
    @State private var errorMessage: String?

    private struct EditContext: Identifiable {
        let id = UUID()
        var draft: ScheduleDraft
    }

    private var sortedSchedules: [(key: String, value: Schedule)] {
        controller.schedules.sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedSchedules, id: \.key) { name, schedule in
                    scheduleRow(name: name, schedule: schedule)
                }
            }
            .overlay {
                if sortedSchedules.isEmpty {
                    ContentUnavailableView {
                        Label("No Schedules", systemImage: "calendar.badge.clock")
                    } description: {
                        Text("A schedule runs a scene at a time of day, at sunrise, or at sunset.")
                    }
                }
            }
            .navigationTitle("Schedules")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editing = EditContext(
                            draft: ScheduleDraft(scene: defaultScheduleScene(controller)))
                    } label: {
                        Label("New Schedule", systemImage: "plus")
                    }
                }
            }
            .task {
                await controller.loadLibrary()
                // For today's sunrise/sunset, so solar rows can show the time.
                await controller.loadBridgeConfig()
            }
        }
        .sheet(item: $editing) { context in
            MobileScheduleForm(controller: controller, draft: context.draft) {
                editing = nil
            }
        }
        .alert("Schedules", isPresented: isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func scheduleRow(name: String, schedule: Schedule) -> some View {
        HStack(spacing: 12) {
            Button {
                editing = EditContext(draft: ScheduleDraft(key: name, schedule: schedule))
            } label: {
                // Grey only the description when disabled — dimming the
                // whole row would make the toggle look disabled too.
                VStack(alignment: .leading, spacing: 1) {
                    Text(schedule.scene)
                        .foregroundStyle(.primary)
                    Text("\(scheduleTimeSummary(schedule.at, config: controller.bridgeConfig)) · \(scheduleDaysSummary(schedule))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .opacity(schedule.enabled ? 1 : 0.5)
                .contentShape(Rectangle())
            }
            // Plain, so the label renders primary/secondary instead of the tint.
            .buttonStyle(.plain)
            Spacer()
            Toggle("Enabled", isOn: Binding(
                get: { schedule.enabled },
                set: { enabled in
                    var updated = schedule
                    updated.enabled = enabled
                    Task { errorMessage = await controller.save(schedule: updated, named: name) }
                }))
                .labelsHidden()
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { errorMessage = await controller.deleteSchedule(named: name) }
            }
        }
    }

    private var isShowingError: Binding<Bool> {
        Binding(get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
    }
}

/// The schedule form: scene, time (wall clock or solar), and days.
private struct MobileScheduleForm: View {
    @ObservedObject var controller: LightController
    @State var draft: ScheduleDraft
    var onClose: () -> Void

    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Scene", selection: $draft.scene) {
                        ForEach(controller.scenes.keys.sorted(), id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("When") {
                    Picker("Time", selection: $draft.mode) {
                        ForEach(ScheduleTimeMode.allCases, id: \.self) { mode in
                            Label(mode.label, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    if draft.mode == .clock {
                        DatePicker("At", selection: timeBinding, displayedComponents: .hourAndMinute)
                    }
                    dayCircles
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(draft.key == nil ? "New Schedule" : "Edit Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel) { onClose() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }
                        .disabled(draft.days.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var dayCircles: some View {
        HStack(spacing: 8) {
            ForEach(scheduleDayOrder, id: \.self) { day in
                let selected = draft.days.contains(day)
                Button {
                    if selected { draft.days.remove(day) } else { draft.days.insert(day) }
                } label: {
                    Text(String(day.prefix(1)).uppercased())
                        .font(.subheadline.weight(.medium))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(selected ? Color.accentColor : Color.primary.opacity(0.08)))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Bridge the DatePicker's Date to the draft's hour/minute (the daemon's
    /// native format — no Date survives past this control).
    private var timeBinding: Binding<Date> {
        Binding<Date>(
            get: {
                Calendar.current.date(bySettingHour: draft.hour, minute: draft.minute,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.hour = parts.hour ?? 0
                draft.minute = parts.minute ?? 0
            })
    }

    private func save() async {
        if let error = await controller.save(schedule: draft.built, named: draft.saveKey) {
            errorMessage = error
            return
        }
        onClose()
    }
}

#endif
