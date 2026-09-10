// MobileScenesScreen.swift
// The iOS scenes screen: a list of scenes (tap to edit, play to run, swipe
// to delete), a menu for new scenes and save-current-color, and the shared
// curve editor presented as a sheet.
// Author: Hamish M. Blair <hmblair@stanford.edu>

#if os(iOS)

import SwiftUI
import LumenCore

struct MobileScenesScreen: View {
    @ObservedObject var controller: LightController
    @ObservedObject var wheel: WheelState

    @State private var editing: SceneEditContext?
    @State private var savingColor = false
    @State private var newSceneName = ""
    @State private var errorMessage: String?

    private struct SceneEditContext: Identifiable {
        let id = UUID()
        var name: String?
        var scene: LumenCore.Scene?
    }

    private var sortedScenes: [(key: String, value: LumenCore.Scene)] {
        controller.visibleScenes.sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationStack {
            List {
                if controller.running != nil {
                    Section {
                        RunningSceneBanner(controller: controller)
                    }
                }
                ForEach(sortedScenes, id: \.key) { name, scene in
                    sceneRow(name: name, scene: scene)
                }
            }
            .overlay {
                if sortedScenes.isEmpty {
                    ContentUnavailableView {
                        Label("No Scenes", systemImage: "paintpalette")
                    } description: {
                        Text("A scene is a color or brightness program for your lights.")
                    }
                }
            }
            .navigationTitle("Scenes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New Scene", systemImage: "chart.xyaxis.line") {
                            editing = SceneEditContext()
                        }
                        Button("Save Current Color", systemImage: "circle.fill") {
                            newSceneName = ""
                            savingColor = true
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .task { await controller.loadLibrary() }
        }
        .sheet(item: $editing) { context in
            editorSheet(context)
        }
        .alert("Save Current Color", isPresented: $savingColor) {
            TextField("Scene name", text: $newSceneName)
            Button("Save") { Task { await saveCurrentColor() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the wheel's color and brightness for the selected lights as a scene.")
        }
        .alert("Scenes", isPresented: isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func sceneRow(name: String, scene: LumenCore.Scene) -> some View {
        HStack(spacing: 12) {
            Button {
                editing = SceneEditContext(name: name, scene: scene)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: scene.isSolid ? "circle.fill" : "chart.xyaxis.line")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .foregroundStyle(.primary)
                        Text(sceneSummary(scene, groups: controller.groups))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            // Plain, so the label renders primary/secondary instead of the tint.
            .buttonStyle(.plain)
            Spacer()
            Button {
                Task { errorMessage = await controller.runScene(named: name) }
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(IconButtonStyle())
            // One scene at a time: the running one must finish or be stopped
            // first (the daemon would 409 anyway).
            .disabled(controller.running != nil)
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { errorMessage = await controller.deleteScene(named: name) }
            }
        }
    }

    private func editorSheet(_ context: SceneEditContext) -> some View {
        NavigationStack {
            ScrollView {
                SceneEditorView(controller: controller,
                                originalName: context.name,
                                original: context.scene,
                                currentColor: { wheel.current },
                                onClose: { editing = nil })
                    .padding()
            }
            .navigationTitle(context.name ?? "New Scene")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Capture the wheel/slider color for the currently selected lights (all
    /// lights when nothing is selected) as a solid scene.
    private func saveCurrentColor() async {
        let name = newSceneName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let ids = controller.selection.isEmpty
            ? controller.lights.map(\.id)
            : Array(controller.selection)
        let color = wheel.current
        let scene = LumenCore.Scene.solid(hue: color.hue, saturation: color.saturation,
                                          level: color.level, lightIDs: ids)
        errorMessage = await controller.save(scene: scene, named: name)
    }

    private var isShowingError: Binding<Bool> {
        Binding(get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
    }
}

#endif
