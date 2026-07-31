// SceneEditorView.swift
// The axis-style scene editor: x = time, y = brightness, points carry their
// own color (click a point, then use the wheel). The drawn course is the
// same monotone cubic the daemon executes (SceneCurve). A scene is edited as
// curve groups — the lights sharing an identical curve — matching the
// per-light model faithfully; saving expands groups back to one curve per
// light. Presented full-panel; the panel widens while editing.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI
import LumenCore

struct SceneEditorView: View {
    @ObservedObject var controller: LightController
    /// Existing scene being edited, or nil to create.
    let originalName: String?
    let original: LumenCore.Scene?
    /// The main panel's wheel/slider color, seeding new curves.
    var currentColor: () -> (hue: Double, saturation: Double, level: Double)
    var onClose: () -> Void

    @State private var draft: Draft
    @State private var errorMessage: String?
    @State private var previewActive = false
    /// Playhead position while a preview run scans the timeline (nil = idle).
    @State private var previewT: Double?
    @State private var lastScrubSend = Date.distantPast
    /// Light state captured before temporary writes, restored afterwards.
    @State private var scrubSnapshot: [Light]?
    @State private var previewSnapshot: [Light]?

    fileprivate struct Draft {
        struct Group: Identifiable {
            let id = UUID()
            var points: [ScenePoint]
            var lights: Set<String>
        }
        var name: String
        var durationValue: String
        var durationUnit: DurationUnit
        var groups: [Group]
        var selectedGroup = 0
        var selectedPoint: Int?
    }

    fileprivate enum DurationUnit: String, CaseIterable {
        case seconds = "sec"
        case minutes = "min"
        case hours = "hr"

        var seconds: Double {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            case .hours: return 3_600
            }
        }
    }

    init(controller: LightController,
         originalName: String?,
         original: LumenCore.Scene?,
         currentColor: @escaping () -> (hue: Double, saturation: Double, level: Double),
         onClose: @escaping () -> Void) {
        self.controller = controller
        self.originalName = originalName
        self.original = original
        self.currentColor = currentColor
        self.onClose = onClose
        _draft = State(initialValue: Self.makeDraft(
            name: originalName, scene: original,
            allLightIDs: controller.lights.map(\.id), seed: currentColor()))
    }

    /// Existing scenes open as their deduplicated curve groups; new scenes
    /// start with one gentle ramp on every light, colored from the wheel.
    private static func makeDraft(
        name: String?, scene: LumenCore.Scene?,
        allLightIDs: [String],
        seed: (hue: Double, saturation: Double, level: Double)
    ) -> Draft {
        if let scene {
            var buckets: [[ScenePoint]: Set<String>] = [:]
            for (id, points) in scene.lights {
                buckets[points, default: []].insert(id)
            }
            let groups = buckets
                .map { Draft.Group(points: $0.key, lights: $0.value) }
                .sorted { ($0.lights.min() ?? "") < ($1.lights.min() ?? "") }
            let (value, unit) = Self.displayDuration(scene.duration)
            return Draft(name: name ?? "",
                         durationValue: value,
                         durationUnit: unit,
                         groups: groups)
        }
        let ramp = [
            ScenePoint(t: 0, hue: seed.hue, saturation: seed.saturation, level: 0.05),
            ScenePoint(t: 1, hue: seed.hue, saturation: seed.saturation,
                       level: max(seed.level, 0.5)),
        ]
        return Draft(name: "",
                     durationValue: "30",
                     durationUnit: .minutes,
                     groups: [Draft.Group(points: ramp, lights: Set(allLightIDs))])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(originalName == nil ? "NEW SCENE" : "EDIT SCENE")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.orange)
                }
            }
            HStack {
                TextField("Name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                TextField("30", text: $draft.durationValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                Picker("", selection: $draft.durationUnit) {
                    ForEach(DurationUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }

            groupBar

            CurveCanvas(groups: $draft.groups,
                        selectedGroup: $draft.selectedGroup,
                        selectedPoint: $draft.selectedPoint,
                        duration: durationSeconds ?? 0,
                        playhead: previewT,
                        onScrub: { t in scrub(to: t) })
                .frame(height: 192)

            HStack(alignment: .top, spacing: 12) {
                pointInspector
                Divider()
                lightAssignment
            }

            Divider()
            HStack {
                Button("Cancel") { Task { await cleanupPreview(); onClose() } }
                Spacer()
                Button {
                    Task { await preview() }
                } label: {
                    Label("Preview", systemImage: "play.circle")
                }
                .help("Run the whole scene compressed to 15 seconds")
                // Unlike Save, previewing needs no name or duration — just
                // something to run.
                .disabled(controller.running != nil || !draftIsPreviewable)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draftIsSavable)
            }
        }
        // The editor can be dismissed without Cancel/Save (the palette x, or
        // the panel closing); make sure a preview in flight is stopped, the
        // lights restored, and the scratch scene removed. Idempotent with the
        // Cancel/Save paths.
        .onDisappear {
            Task { await cleanupPreview() }
        }
    }

    // MARK: - Groups

    private var groupBar: some View {
        HStack(spacing: 6) {
            ForEach(Array(draft.groups.enumerated()), id: \.element.id) { index, group in
                Button {
                    draft.selectedGroup = index
                    draft.selectedPoint = nil
                } label: {
                    Text("Curve \(index + 1) · \(group.lights.count)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(index == draft.selectedGroup
                                                   ? Color.accentColor.opacity(0.25)
                                                   : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(group.lights.isEmpty
                      ? "No lights — dropped on save"
                      : lightNames(group.lights))
            }
            Button {
                let seed = currentColor()
                let level = seed.level > 0 ? seed.level : 0.5
                draft.groups.append(Draft.Group(
                    points: [
                        ScenePoint(t: 0, hue: seed.hue, saturation: seed.saturation, level: level),
                        ScenePoint(t: 1, hue: seed.hue, saturation: seed.saturation, level: level),
                    ],
                    lights: []))
                draft.selectedGroup = draft.groups.count - 1
                draft.selectedPoint = nil
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add another curve (assign lights to it below)")
            Button {
                draft.groups.remove(at: draft.selectedGroup)
                draft.selectedGroup = min(draft.selectedGroup, draft.groups.count - 1)
                draft.selectedPoint = nil
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .disabled(draft.groups.count <= 1)
            .help("Delete the selected curve (its lights are left alone)")
            Spacer()
        }
    }

    private func lightNames(_ ids: Set<String>) -> String {
        controller.lights.filter { ids.contains($0.id) }.map(\.name).joined(separator: ", ")
    }

    /// Binding to the selected group's points.
    private var currentPoints: Binding<[ScenePoint]> {
        Binding(
            get: {
                guard draft.groups.indices.contains(draft.selectedGroup) else { return [] }
                return draft.groups[draft.selectedGroup].points
            },
            set: { points in
                guard draft.groups.indices.contains(draft.selectedGroup) else { return }
                draft.groups[draft.selectedGroup].points = points
            })
    }

    // MARK: - Point inspector (color wheel for the selected point)

    @ViewBuilder private var pointInspector: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("POINT COLOR").font(.caption2).foregroundStyle(.secondary)
            ColorWheel(hue: selectedPointHue, saturation: selectedPointSaturation) {}
                .frame(width: 110, height: 110)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .opacity(draft.selectedPoint == nil ? 0.3 : 1)
                .disabled(draft.selectedPoint == nil)
            HStack {
                Button {
                    if let index = draft.selectedPoint {
                        currentPoints.wrappedValue.remove(at: index)
                        draft.selectedPoint = nil
                    }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(draft.selectedPoint == nil || currentPoints.wrappedValue.count <= 1)
                .help("Delete selected point")
                Text(draft.selectedPoint == nil
                     ? "Click a point · double-click adds · drag timeline to try it live"
                     : "Drag to move")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedPointHue: Binding<Double> {
        Binding(
            get: {
                guard let i = draft.selectedPoint,
                      currentPoints.wrappedValue.indices.contains(i) else { return 0 }
                return currentPoints.wrappedValue[i].hue
            },
            set: { hue in
                guard let i = draft.selectedPoint,
                      currentPoints.wrappedValue.indices.contains(i) else { return }
                currentPoints.wrappedValue[i].hue = hue
            })
    }

    private var selectedPointSaturation: Binding<Double> {
        Binding(
            get: {
                guard let i = draft.selectedPoint,
                      currentPoints.wrappedValue.indices.contains(i) else { return 0 }
                return currentPoints.wrappedValue[i].saturation
            },
            set: { saturation in
                guard let i = draft.selectedPoint,
                      currentPoints.wrappedValue.indices.contains(i) else { return }
                currentPoints.wrappedValue[i].saturation = saturation
            })
    }

    // MARK: - Light assignment

    /// Membership in the selected group is exclusive: checking a light moves
    /// it here from any other group; unchecking leaves it out of the scene.
    private var lightAssignment: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LIGHTS ON THIS CURVE").font(.caption2).foregroundStyle(.secondary)
            ForEach(controller.lights) { light in
                Button {
                    toggleLight(light.id)
                } label: {
                    HStack(spacing: 5) {
                        let inGroup = draft.groups.indices.contains(draft.selectedGroup)
                            && draft.groups[draft.selectedGroup].lights.contains(light.id)
                        Image(systemName: inGroup ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(inGroup ? Color.accentColor : Color.secondary)
                        Text(light.name).font(.caption)
                        if let other = groupIndex(of: light.id), other != draft.selectedGroup {
                            Text("curve \(other + 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("Unchecked lights are left alone.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func groupIndex(of lightID: String) -> Int? {
        draft.groups.firstIndex { $0.lights.contains(lightID) }
    }

    private func toggleLight(_ lightID: String) {
        guard draft.groups.indices.contains(draft.selectedGroup) else { return }
        if draft.groups[draft.selectedGroup].lights.contains(lightID) {
            draft.groups[draft.selectedGroup].lights.remove(lightID)
        } else {
            for index in draft.groups.indices {
                draft.groups[index].lights.remove(lightID)
            }
            draft.groups[draft.selectedGroup].lights.insert(lightID)
        }
    }

    // MARK: - Save / preview

    private var draftIsPreviewable: Bool {
        draft.groups.contains { !$0.lights.isEmpty && !$0.points.isEmpty }
    }

    private var draftIsSavable: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && durationSeconds != nil
            && draftIsPreviewable
    }

    private var durationSeconds: Double? {
        guard let value = Double(draft.durationValue.replacingOccurrences(of: ",", with: ".")),
              value >= 0, value.isFinite else { return nil }
        return value * draft.durationUnit.seconds
    }

    /// Pick the largest unit that shows the stored duration as a clean number
    /// (3600 -> "1 hr", 900 -> "15 min", 45 -> "45 sec").
    private static func displayDuration(_ seconds: Double) -> (String, DurationUnit) {
        for unit in DurationUnit.allCases.reversed() {
            let value = seconds / unit.seconds
            if value >= 1, value == value.rounded() {
                return (String(Int(value)), unit)
            }
        }
        let clean = seconds == seconds.rounded()
            ? String(Int(seconds)) : String(format: "%.1f", seconds)
        return (clean, .seconds)
    }

    /// Groups expanded back to the per-light wire model.
    private func builtScene(duration: Double) -> LumenCore.Scene {
        var lights: [String: [ScenePoint]] = [:]
        for group in draft.groups where !group.points.isEmpty {
            for id in group.lights {
                lights[id] = group.points
            }
        }
        return LumenCore.Scene(duration: duration, lights: lights)
    }

    private func save() async {
        guard let duration = durationSeconds else { return }
        await cleanupPreview()
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        if let error = await controller.save(scene: builtScene(duration: duration), named: name) {
            errorMessage = error
            return
        }
        if let originalName, originalName != name {
            await controller.deleteScene(named: originalName)
        }
        onClose()
    }

    /// Run the draft compressed to 15 seconds under a scratch name, scanning
    /// the playhead across the canvas in sync. A preview is temporary: the
    /// lights return to their pre-preview state afterwards, and the scratch
    /// scene is removed when the editor closes.
    private func preview() async {
        errorMessage = nil
        if let error = await controller.save(scene: builtScene(duration: 15), named: "Preview") {
            errorMessage = error
            return
        }
        previewSnapshot = affectedLights()
        previewActive = true
        if let error = await controller.runScene(named: "Preview") {
            errorMessage = error
            previewSnapshot = nil
            return
        }
        let start = Date()
        previewT = 0
        while previewActive {
            let progress = Date().timeIntervalSince(start) / 15
            if progress >= 1 { break }
            // Track an early stop (the banner's Stop button) within a poll.
            if progress > 0.15, controller.running == nil { break }
            previewT = progress
            try? await Task.sleep(for: .milliseconds(50))
        }
        previewT = nil
        await restoreAfterPreview()
    }

    /// Restore the snapshot once the preview scene has released its lights —
    /// restoring earlier would be 409'd by the daemon's arbitration. If the
    /// run somehow outlives its schedule, stop it rather than skip the
    /// restore: a preview must never leave the lights changed.
    private func restoreAfterPreview() async {
        guard let snapshot = previewSnapshot else { return }
        let deadline = Date().addingTimeInterval(5)
        while controller.running?.scene == "Preview", Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if controller.running?.scene == "Preview" {
            await controller.stopScene()
        }
        controller.restoreLights(snapshot)
        previewSnapshot = nil
    }

    private func cleanupPreview() async {
        guard previewActive else { return }
        previewActive = false
        previewT = nil
        if controller.running?.scene == "Preview" {
            await controller.stopScene()
        }
        await restoreAfterPreview()
        await controller.deleteScene(named: "Preview")
    }

    /// The current state of every light the draft touches — the snapshot
    /// that temporary writes are restored to.
    private func affectedLights() -> [Light] {
        let ids = Set(draft.groups.flatMap(\.lights))
        return controller.lights.filter { ids.contains($0.id) }
    }

    /// Timeline scrubbing: push every curve's sampled state at `t` to its
    /// assigned lights, throttled so a drag doesn't flood the bridge. The
    /// pre-drag state is captured on the first event and restored when the
    /// drag ends (t == nil) — scrubbing is a look, not an edit.
    private func scrub(to t: Double?) {
        guard let t else {
            if let snapshot = scrubSnapshot {
                controller.restoreLights(snapshot)
                scrubSnapshot = nil
            }
            return
        }
        if scrubSnapshot == nil {
            scrubSnapshot = affectedLights()
        }
        guard Date().timeIntervalSince(lastScrubSend) > 0.12 else { return }
        lastScrubSend = Date()
        for group in draft.groups where !group.lights.isEmpty && !group.points.isEmpty {
            let sample = SceneCurve.sample(group.points, at: t)
            controller.setLights(Array(group.lights),
                                 hue: sample.hue,
                                 saturation: sample.saturation,
                                 level: sample.level)
        }
    }
}

// MARK: - Canvas

/// The axis: x = time (0...1 of the scene's duration), y = brightness. All
/// of the scene's curves share these axes; the selected one is emphasized
/// and clicking any point selects it and its curve. Double-click empty
/// space to add a point to the selected curve (it inherits that curve's
/// color there). Dragging empty space scrubs a playhead through the
/// timeline, pushing every curve's state at that moment to its lights.
private struct CurveCanvas: View {
    @Binding fileprivate var groups: [SceneEditorView.Draft.Group]
    @Binding var selectedGroup: Int
    @Binding var selectedPoint: Int?
    /// Scene length in seconds, for the x-axis labels (0 = no labels).
    var duration: Double
    /// External playhead (the preview run's scan); manual scrubbing wins.
    var playhead: Double?
    /// Scrub position while dragging; nil when the drag ends.
    var onScrub: (Double?) -> Void

    @State private var scrubT: Double?

    private let dotSize: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            // Inset the plot area by a dot radius (so point circles stay
            // fully inside and clickable even at the corners), plus room at
            // the bottom for the x-axis tick labels.
            let inset = dotSize / 2 + 2
            let labelSpace: CGFloat = duration > 0 ? 13 : 0
            let rect = CGRect(x: inset, y: inset,
                              width: geo.size.width - 2 * inset,
                              height: geo.size.height - 2 * inset - labelSpace)
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
                grid(rect)
                if duration > 0 {
                    xAxisLabels(rect)
                }
                ForEach(groups.indices, id: \.self) { g in
                    if !groups[g].points.isEmpty {
                        let isSelected = g == selectedGroup
                        curve(groups[g].points, rect)
                            .stroke(Color.primary.opacity(isSelected ? 0.55 : 0.18),
                                    style: StrokeStyle(lineWidth: isSelected ? 2 : 1.5,
                                                       lineCap: .round))
                    }
                }
                if let marker = scrubT ?? playhead {
                    Path { path in
                        let x = rect.minX + marker * rect.width
                        path.move(to: CGPoint(x: x, y: rect.minY))
                        path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    }
                    .stroke(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                }
                ForEach(groups.indices, id: \.self) { g in
                    ForEach(groups[g].points.indices, id: \.self) { i in
                        dot(group: g, point: i, rect: rect)
                    }
                }
            }
            .contentShape(Rectangle())
            // Double-click adds a point; a plain drag (or click) scrubs.
            .highPriorityGesture(SpatialTapGesture(count: 2).onEnded { tap in
                addPoint(at: tap.location, in: rect)
            })
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let t = value(at: drag.location, in: rect).t
                        scrubT = t
                        onScrub(t)
                    }
                    .onEnded { _ in
                        scrubT = nil
                        onScrub(nil)
                    }
            )
        }
    }

    private func position(_ point: ScenePoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.t * rect.width,
                y: rect.minY + (1 - point.level) * rect.height)
    }

    /// Pixel location -> (t, level), clamped to the plot area.
    private func value(at location: CGPoint, in rect: CGRect) -> (t: Double, level: Double) {
        (t: min(max((location.x - rect.minX) / rect.width, 0), 1),
         level: min(max(1 - (location.y - rect.minY) / rect.height, 0), 1))
    }

    /// Ticks at the quarters of the timeline, labeled in real time units
    /// (they follow the duration field live).
    private func xAxisLabels(_ rect: CGRect) -> some View {
        ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
            let x = rect.minX + fraction * rect.width
            Path { path in
                path.move(to: CGPoint(x: x, y: rect.maxY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY + 3))
            }
            .stroke(Color.primary.opacity(0.25), lineWidth: 1)
            Text(timeLabel(fraction * duration))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .position(x: min(max(x, rect.minX + 8), rect.maxX - 8),
                          y: rect.maxY + 10)
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        if seconds <= 0 { return "0" }
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        if seconds < 3_600 {
            let minutes = seconds / 60
            return minutes == minutes.rounded()
                ? "\(Int(minutes))m" : String(format: "%.1fm", minutes)
        }
        let hours = seconds / 3_600
        return hours == hours.rounded()
            ? "\(Int(hours))h" : String(format: "%.1fh", hours)
    }

    private func grid(_ rect: CGRect) -> some View {
        Path { path in
            for fraction in [0.25, 0.5, 0.75] {
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + fraction * rect.height))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fraction * rect.height))
                path.move(to: CGPoint(x: rect.minX + fraction * rect.width, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + fraction * rect.width, y: rect.maxY))
            }
        }
        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
    }

    private func curve(_ points: [ScenePoint], _ rect: CGRect) -> Path {
        Path { path in
            let steps = 120
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let p = position(SceneCurve.sample(points, at: t), in: rect)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
    }

    private func dot(group g: Int, point i: Int, rect: CGRect) -> some View {
        let point = groups[g].points[i]
        let isSelected = g == selectedGroup && selectedPoint == i
        let onSelectedCurve = g == selectedGroup
        return Circle()
            .fill(Color(hue: point.hue, saturation: point.saturation, brightness: 1))
            .frame(width: onSelectedCurve ? dotSize : dotSize - 4,
                   height: onSelectedCurve ? dotSize : dotSize - 4)
            .overlay(Circle().stroke(isSelected ? Color.accentColor : .white,
                                     lineWidth: isSelected ? 3 : 1.5))
            .shadow(radius: 1)
            .opacity(onSelectedCurve ? 1 : 0.65)
            .position(position(point, in: rect))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        // Selecting a point selects its curve.
                        selectedGroup = g
                        selectedPoint = i
                        movePoint(group: g, point: i, to: drag.location, in: rect)
                    }
            )
    }

    private func movePoint(group g: Int, point i: Int, to location: CGPoint, in rect: CGRect) {
        // Keep t strictly between the neighbors so points stay ordered and
        // never coincide (the daemon rejects duplicate times).
        let points = groups[g].points
        let gap = 0.01
        let lower = i > 0 ? points[i - 1].t + gap : 0
        let upper = i < points.count - 1 ? points[i + 1].t - gap : 1
        let (t, level) = value(at: location, in: rect)
        groups[g].points[i].t = min(max(t, lower), upper)
        groups[g].points[i].level = level
    }

    private func addPoint(at location: CGPoint, in rect: CGRect) {
        guard groups.indices.contains(selectedGroup) else { return }
        let points = groups[selectedGroup].points
        let (t, level) = value(at: location, in: rect)
        // Inherit the selected curve's color at that moment.
        var point = points.isEmpty
            ? ScenePoint(t: t, hue: 0.08, saturation: 0.3, level: level)
            : SceneCurve.sample(points, at: t)
        point.t = t
        point.level = level
        // Nudge off a duplicate time if the click lands exactly on one.
        if points.contains(where: { abs($0.t - t) < 0.005 }) {
            point.t = min(max(t + 0.005, 0), 1)
        }
        let index = points.firstIndex { $0.t > point.t } ?? points.count
        groups[selectedGroup].points.insert(point, at: index)
        selectedPoint = index
    }
}
