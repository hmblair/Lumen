// RoomListView.swift
// Room UI, option B: the light list organized under room sections. Rooms
// are daemon-authoritative and may be empty — an empty room is a room like
// any other, it just renders without member rows. All room semantics live
// in LumenCore's RoomsModel; this view renders and forwards gestures. A
// header's tick is on iff all of the room's lights are selected; ticking
// adds the room's lights to the selection (rooms union naturally),
// unticking removes them. Double-click a room name to rename, − deletes the
// room (its lights become unassigned), + adds a room, and lights drag
// between sections (or outside any) to move.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI
import LumenCore

struct RoomListView: View {
    @ObservedObject var controller: LightController
    @ObservedObject var rooms: RoomsModel
    /// Bumped by the panel when the user clicks anywhere outside a control —
    /// any open inline edit dismisses without saving.
    var dismissToken: Int = 0

    @State private var renamingRoomID: String?
    @State private var renamingLightID: String?
    @State private var renameText = ""
    @State private var addingRoom = false
    @State private var newRoomText = ""
    @State private var dropTarget: String?   // room id, or "" for unassigned
    /// Which inline edit field (if any) holds keyboard focus; losing it
    /// cancels the edit, so clicking elsewhere dismisses without saving.
    private enum EditFocus: Hashable { case roomRename, newRoom, lightRename }
    @FocusState private var editFocus: EditFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("ROOMS").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    cancelInlineEdits()
                    newRoomText = ""
                    addingRoom = true
                    editFocus = .newRoom
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(HoverIconButtonStyle())
                .help("New room")
            }
            if let error = rooms.lastError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
            if controller.lights.isEmpty {
                Text(controller.isReachable ? "No lights found" : "Not connected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rooms.roomList, id: \.id) { id, room in
                roomSection(id: id, room: room)
            }
            if addingRoom {
                newRoomField
            }
            // Stray lights get their own titled section (no + — rooms are
            // added above); absent entirely when every light is roomed.
            if !rooms.unassignedLights.isEmpty {
                Text("UNASSIGNED")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(rooms.unassignedLights) { light in
                    lightRow(light)
                }
            }
        }
        .contentShape(Rectangle())
        // Clicking anywhere that isn't a control dismisses an open inline
        // edit without saving; so does focus moving away from its field.
        .onTapGesture { cancelInlineEdits() }
        .onChange(of: dismissToken) { _ in cancelInlineEdits() }
        .onChange(of: editFocus) { focus in
            if focus == nil { cancelInlineEdits() }
        }
        // Dropping outside any room section takes the light out of its room.
        .dropDestination(for: String.self) { ids, _ in
            rooms.move(ids, to: .unassigned)
            return true
        }
        // No layout animation: the panel self-sizes to its content, and
        // animating a genuine height change makes the window visibly
        // breathe. Sizing snaps, like every other screen change in this
        // panel; only the drop highlight fades.
        .animation(.easeOut(duration: 0.12), value: dropTarget)
    }

    /// Dismiss any open inline edit, saving nothing.
    private func cancelInlineEdits() {
        renamingRoomID = nil
        renamingLightID = nil
        addingRoom = false
        editFocus = nil
        rooms.clearError()
    }

    // MARK: - Sections

    private func roomSection(id: String, room: LightGroup) -> some View {
        let members = controller.lights.filter { room.lights.contains($0.id) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                roomTick(memberIDs: Set(room.lights))
                if renamingRoomID == id {
                    nameField(placeholder: room.name) { name in
                        Task {
                            if await rooms.renameRoom(id: id, to: name) == nil {
                                renamingRoomID = nil
                            }
                        }
                    } onDismiss: {
                        renamingRoomID = nil
                    }
                } else {
                    Text(room.name)
                        .fontWeight(.medium)
                        // Empty rooms read as dormant, like the old pending
                        // styling — grey until a light moves in.
                        .foregroundStyle(room.lights.isEmpty ? Color.secondary : Color.primary)
                        .onTapGesture(count: 2) {
                            cancelInlineEdits()
                            renameText = room.name
                            renamingRoomID = id
                            editFocus = .roomRename
                        }
                        .help("Double-click to rename")
                }
                Spacer()
                Button {
                    cancelInlineEdits()
                    Task { await rooms.deleteRoom(id: id) }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(HoverIconButtonStyle())
                .help("Remove this room (its lights stay, unassigned)")
            }
            ForEach(members) { light in
                lightRow(light).padding(.leading, 16)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(dropTarget == id ? 0.15 : 0)))
        .dropDestination(for: String.self) { ids, _ in
            rooms.move(ids, to: .room(id))
            return true
        } isTargeted: { over in
            dropTarget = over ? id : (dropTarget == id ? nil : dropTarget)
        }
    }

    // MARK: - Header pieces

    /// Tick rule: on iff all the section's lights are selected. Ticking adds
    /// them to the selection (rooms union), unticking removes them.
    private func roomTick(memberIDs: Set<String>) -> some View {
        let allSelected = !memberIDs.isEmpty && memberIDs.isSubset(of: controller.selection)
        return Button {
            cancelInlineEdits()
            if allSelected {
                controller.selection.subtract(memberIDs)
            } else {
                controller.selection.formUnion(memberIDs)
            }
        } label: {
            Image(systemName: allSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(allSelected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(memberIDs.isEmpty)
        .help("Select all lights in this room")
    }

    /// Shared room name field: submit commits (the model reports clashes and
    /// keeps the field open), empty submit or Esc dismisses without saving.
    private func nameField(placeholder: String,
                           onCommit: @escaping (String) -> Void,
                           onDismiss: @escaping () -> Void) -> some View {
        TextField(placeholder, text: $renameText)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 130)
            .focused($editFocus, equals: .roomRename)
            .onSubmit {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if name.isEmpty {
                    onDismiss()
                    rooms.clearError()
                } else {
                    onCommit(name)
                }
            }
            .onEscape {
                onDismiss()
                rooms.clearError()
            }
    }

    private var newRoomField: some View {
        TextField("Room name", text: $newRoomText)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 130)
            .focused($editFocus, equals: .newRoom)
            .onSubmit {
                let name = newRoomText.trimmingCharacters(in: .whitespaces)
                if name.isEmpty {
                    addingRoom = false
                    rooms.clearError()
                } else {
                    Task {
                        if await rooms.createRoom(named: name) == nil {
                            addingRoom = false
                        }
                    }
                }
            }
            .onEscape {
                addingRoom = false
                rooms.clearError()
            }
    }

    // MARK: - Light rows (selection tick, drag handle, rename, status)

    private func lightRow(_ light: Light) -> some View {
        HStack {
            Button {
                cancelInlineEdits()
                if controller.selection.contains(light.id) {
                    controller.selection.remove(light.id)
                } else {
                    controller.selection.insert(light.id)
                }
            } label: {
                Image(systemName: controller.selection.contains(light.id)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(controller.selection.contains(light.id)
                                     ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Include in manual control")
            if renamingLightID == light.id {
                TextField("", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($editFocus, equals: .lightRename)
                    .onSubmit {
                        let name = renameText.trimmingCharacters(in: .whitespaces)
                        renamingLightID = nil
                        guard !name.isEmpty else { return }
                        Task { await controller.renameLight(id: light.id, to: name) }
                    }
                    .onEscape { renamingLightID = nil }
            } else {
                Text(light.name)
                    .onTapGesture(count: 2) {
                        cancelInlineEdits()
                        renameText = light.name
                        renamingLightID = light.id
                        editFocus = .lightRename
                    }
                    .help("Double-click to rename · drag to a room")
            }
            Spacer()
            Text("\(light.brightnessPercent)%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Circle()
                .fill(light.swatchColor)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.75))
            if !light.reachable {
                Image(systemName: "wifi.slash")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        // Compact drag preview: the system's release animation fades the
        // preview over ~half a second, and a full-width row lingering was
        // conspicuous — a small name pill is barely noticeable.
        .draggable(light.id) {
            Text(light.name)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.2)))
        }
    }
}
