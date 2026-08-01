// ScenesView.swift
// The scenes screen: list, run, edit (via the curve editor), delete, and
// save-the-current-color-as-scene. Scenes are the *what* — per-light
// color/brightness programs — managed here as first-class objects;
// schedules (the *when*) live on their own screen.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI
import LumenCore

struct ScenesView: View {
    @ObservedObject var controller: LightController
    /// The wheel/slider state, for "save current color as scene".
    var currentColor: () -> (hue: Double, saturation: Double, level: Double)
    /// Open the curve editor: (existing name, existing scene), or (nil, nil)
    /// to create.
    var onEditScene: (String?, LumenCore.Scene?) -> Void

    @State private var newSceneName = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Text("SCENES").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    onEditScene(nil, nil)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(HoverIconButtonStyle())
                .help("New scene (curve editor)")
            }
            if controller.scenes.isEmpty {
                Text("No scenes yet").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(controller.scenes.sorted(by: { $0.key < $1.key }), id: \.key) { name, scene in
                sceneRow(name: name, scene: scene)
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
                .buttonStyle(HoverIconButtonStyle())
                .disabled(newSceneName.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Save the wheel/slider color as a solid scene")
            }
        }
        .task { await controller.loadLibrary() }
    }

    private func sceneRow(name: String, scene: LumenCore.Scene) -> some View {
        HStack(spacing: 6) {
            Image(systemName: scene.isSolid ? "circle.fill" : "chart.xyaxis.line")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(name)
            Text(sceneSummary(scene))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // Tight spacing, like the header tabs: the hover style pads each
            // icon by 3pt for its hover background.
            HStack(spacing: 2) {
                Button {
                    Task { errorMessage = await controller.runScene(named: name) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(HoverIconButtonStyle())
                // One scene at a time: the running one must finish or be
                // stopped first (the daemon would 409 anyway).
                .disabled(controller.running != nil)
                .help("Run this scene")
                Button {
                    onEditScene(name, scene)
                } label: {
                    Image(systemName: "slider.horizontal.below.sun.max")
                }
                .buttonStyle(HoverIconButtonStyle())
                .help("Edit in the curve editor")
                Button {
                    Task { errorMessage = await controller.deleteScene(named: name) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(HoverIconButtonStyle())
                .help("Delete")
            }
        }
    }

    /// e.g. "Bedroom, Living room · 60m" — the rooms the scene touches
    /// (with "+n" for involved lights outside any room), falling back to a
    /// light count when no rooms are involved.
    private func sceneSummary(_ scene: LumenCore.Scene) -> String {
        let sceneLights = Set(scene.lights.keys)
        let roomNames = controller.groups.values
            .filter { !sceneLights.isDisjoint(with: $0.lights) }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let roomed = Set(controller.groups.values.flatMap(\.lights))
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

    /// Capture the wheel/slider color for the currently selected lights (all
    /// lights when nothing is selected) as a solid scene.
    private func saveCurrentColor() async {
        let name = newSceneName.trimmingCharacters(in: .whitespaces)
        let ids = controller.selection.isEmpty
            ? controller.lights.map(\.id)
            : Array(controller.selection)
        let color = currentColor()
        let scene = LumenCore.Scene.solid(hue: color.hue, saturation: color.saturation,
                                          level: color.level, lightIDs: ids)
        if let error = await controller.save(scene: scene, named: name) {
            errorMessage = error
        } else {
            errorMessage = nil
            newSceneName = ""
        }
    }
}
