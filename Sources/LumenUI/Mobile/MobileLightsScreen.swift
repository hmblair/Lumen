// MobileLightsScreen.swift
// The main iOS screen: the color wheel and brightness slider at full width
// on top, the rooms and lights as a grouped list beneath. Selection, rooms,
// and light writes all go through the shared LightController/RoomsModel —
// this file is layout and gestures only.
// Author: Hamish M. Blair <hmblair@stanford.edu>

#if os(iOS)

import SwiftUI
import LumenCore

struct MobileLightsScreen: View {
    @ObservedObject var controller: LightController
    @ObservedObject var rooms: RoomsModel
    @ObservedObject var wheel: WheelState

    @State private var renamingLight: Light?
    @State private var renamingRoomID: String?
    @State private var addingRoom = false
    @State private var nameText = ""

    var body: some View {
        NavigationStack {
            Group {
                if controller.isConfigured {
                    lightsList
                } else {
                    UnconfiguredPlaceholder()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        nameText = ""
                        addingRoom = true
                    } label: {
                        Label("New Room", systemImage: "plus")
                    }
                }
            }
        }
        .alert("New Room", isPresented: $addingRoom) {
            TextField("Room name", text: $nameText)
            Button("Add") {
                let name = nameText.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await rooms.createRoom(named: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Light", isPresented: isRenamingLight) {
            TextField("Name", text: $nameText)
            Button("Rename") {
                let name = nameText.trimmingCharacters(in: .whitespaces)
                if let light = renamingLight, !name.isEmpty {
                    Task { await controller.renameLight(id: light.id, to: name) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Room", isPresented: isRenamingRoom) {
            TextField("Name", text: $nameText)
            Button("Rename") {
                let name = nameText.trimmingCharacters(in: .whitespaces)
                if let id = renamingRoomID, !name.isEmpty {
                    Task { await rooms.renameRoom(id: id, to: name) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - List

    private var lightsList: some View {
        List {
            if !controller.isReachable || controller.running != nil || rooms.lastError != nil {
                Section {
                    UnreachableBanner(controller: controller)
                    RunningSceneBanner(controller: controller)
                    roomError
                }
            }
            controlsSection
            if controller.lights.isEmpty {
                Section {
                    Text(controller.isReachable ? "No lights found" : "Not connected")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(rooms.roomList, id: \.id) { id, room in
                roomSection(id: id, room: room)
            }
            if !rooms.unassignedLights.isEmpty {
                Section("Unassigned") {
                    ForEach(rooms.unassignedLights) { light in
                        lightRow(light)
                    }
                }
            }
        }
    }

    @ViewBuilder private var roomError: some View {
        if let error = rooms.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .onTapGesture { rooms.clearError() }
        }
    }

    private func roomSection(id: String, room: LightGroup) -> some View {
        let members = controller.lights.filter { room.lights.contains($0.id) }
        return Section {
            ForEach(members) { light in
                lightRow(light)
            }
        } header: {
            roomHeader(id: id, room: room)
        }
    }

    /// Room name plus the select-all tick. Tick rule matches the Mac panel:
    /// on iff all the room's lights are selected; ticking adds them all
    /// (rooms union naturally), unticking removes them. Renaming and
    /// deleting live in the header's context menu.
    private func roomHeader(id: String, room: LightGroup) -> some View {
        let memberIDs = Set(room.lights)
        let allSelected = !memberIDs.isEmpty && memberIDs.isSubset(of: controller.selection)
        return HStack {
            Text(room.name)
                .contextMenu {
                    Button("Rename", systemImage: "pencil") {
                        nameText = room.name
                        renamingRoomID = id
                    }
                    Button("Delete Room", systemImage: "trash", role: .destructive) {
                        Task { await rooms.deleteRoom(id: id) }
                    }
                }
            Spacer()
            Button {
                if allSelected {
                    controller.selection.subtract(memberIDs)
                } else {
                    controller.selection.formUnion(memberIDs)
                }
            } label: {
                Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(allSelected ? Color.accentColor : Color.secondary)
            }
            .disabled(memberIDs.isEmpty)
        }
    }

    /// A light row: the whole row toggles selection; rename and move live in
    /// the context menu.
    private func lightRow(_ light: Light) -> some View {
        let selected = controller.selection.contains(light.id)
        return Button {
            if selected {
                controller.selection.remove(light.id)
            } else {
                controller.selection.insert(light.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(light.name)
                        .foregroundStyle(.primary)
                    Text("\(light.brightnessPercent)%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !light.reachable {
                    Image(systemName: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Circle()
                    .fill(light.swatchColor)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.75))
            }
            .contentShape(Rectangle())
        }
        // Plain, so the label renders primary/secondary instead of the tint.
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                nameText = light.name
                renamingLight = light
            }
            moveMenu(for: light)
        }
    }

    private func moveMenu(for light: Light) -> some View {
        let currentRoom = controller.groups.first { $0.value.lights.contains(light.id) }?.key
        return Menu("Move to", systemImage: "folder") {
            ForEach(rooms.roomList, id: \.id) { id, room in
                Button(room.name) {
                    rooms.move([light.id], to: .room(id))
                }
                .disabled(id == currentRoom)
            }
            if currentRoom != nil {
                Divider()
                Button("No Room") {
                    rooms.move([light.id], to: .unassigned)
                }
            }
        }
    }

    // MARK: - Controls (wheel + brightness)

    /// Color is editable only when something is selected and every selected
    /// light is on — an off bulb can't store a color, so the wheel greys out
    /// rather than accepting a change the bridge would revert.
    private var colorEnabled: Bool {
        !controller.selection.isEmpty && !controller.selectionHasOffLights
    }

    /// Manual control pauses while the lights are unreachable (writes would
    /// silently fail) or while a scene owns them (writes would 409).
    private var controlsLocked: Bool {
        !controller.isReachable || controller.running != nil
    }

    /// The wheel and slider float on the screen background at full width —
    /// no card. The wheel sizes itself to the row.
    private var controlsSection: some View {
        Section {
            VStack(spacing: 16) {
                GeometryReader { geo in
                    ResettableColorWheel(hue: $wheel.hue, saturation: $wheel.saturation,
                                         diameter: geo.size.width) {
                        wheel.colorEdited(controller)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, 24)
                .disabled(!colorEnabled || controlsLocked)
                HStack(spacing: 14) {
                    Button { wheel.brightness = 0 } label: {
                        Image(systemName: "sun.min")
                    }
                    .buttonStyle(IconButtonStyle())
                    Slider(value: $wheel.brightness, in: 0...1)
                        .onChange(of: wheel.brightness) {
                            wheel.brightnessEdited(controller)
                        }
                    Button { wheel.brightness = 1 } label: {
                        Image(systemName: "sun.max.fill")
                    }
                    .buttonStyle(IconButtonStyle())
                }
                .disabled(controller.selection.isEmpty || controlsLocked)
                if controller.selectionIsMixed || controller.brightnessIsMixed,
                   let rep = controller.representative {
                    Label("Mixed — showing \(rep.name). Drag to unify.",
                          systemImage: "circle.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .opacity(controlsLocked ? 0.5 : 1)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        }
    }

    // MARK: - Alert presentation bindings

    private var isRenamingLight: Binding<Bool> {
        Binding(get: { renamingLight != nil },
                set: { if !$0 { renamingLight = nil } })
    }

    private var isRenamingRoom: Binding<Bool> {
        Binding(get: { renamingRoomID != nil },
                set: { if !$0 { renamingRoomID = nil } })
    }
}

#endif
