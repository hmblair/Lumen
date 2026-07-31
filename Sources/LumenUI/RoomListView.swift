// RoomListView.swift
// Room UI, option B: the light list organized under room sections. Rooms are
// a partition — every light is in at most one room; unassigned lights render
// as bare top-level rows with no section chrome — enforced app-side on top
// of the daemon's group API. A header's tick is on iff all of the room's
// lights are selected; ticking adds the room's lights to the selection
// (rooms union naturally), unticking removes them. Double-click a room name
// to rename, − deletes the room (its lights become unassigned), + adds a
// room, and lights drag between sections (or outside any) to move.
//
// The bridge refuses empty groups, so a new room is "pending" (app-local)
// until its first light is dropped in, and a room whose last light leaves
// reverts to pending.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI
import LumenCore

struct RoomListView: View {
    @ObservedObject var controller: LightController
    /// Bumped by the panel when the user clicks anywhere outside a control —
    /// any open inline edit dismisses without saving.
    var dismissToken: Int = 0

    @State private var renamingRoomID: String?
    @State private var renamingLightID: String?
    @State private var renameText = ""
    @State private var addingRoom = false
    @State private var newRoomText = ""
    /// Named rooms with no bridge group yet — they exist only here until a
    /// light is dropped in (the bridge refuses empty groups).
    @State private var pendingRooms: [String] = []
    /// Lights shown inside a pending room while its bridge group is being
    /// created, so a drop lands there instantly instead of detouring
    /// through Other.
    @State private var pendingLights: [String: [String]] = [:]
    @State private var dropTarget: String?   // room id, pending name, or "" for Other
    @State private var errorMessage: String?
    /// Which inline edit field (if any) holds keyboard focus; losing it
    /// cancels the edit, so clicking elsewhere dismisses without saving.
    private enum EditFocus: Hashable { case roomRename, newRoom, lightRename }
    @FocusState private var editFocus: EditFocus?
    /// Pending room being renamed (rename is local — no bridge group yet).
    @State private var renamingPendingName: String?

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
            if let errorMessage {
                Text(errorMessage).font(.caption2).foregroundStyle(.orange)
            }
            if controller.lights.isEmpty {
                Text(controller.isReachable ? "No lights found" : "Not connected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(roomEntries, id: \.id) { entry in
                switch entry {
                case .real(let id, let room):
                    roomSection(id: id, room: room)
                case .pending(let name):
                    pendingSection(name)
                }
            }
            if addingRoom {
                newRoomField
            }
            // Stray lights get their own titled section (no + — rooms are
            // added above); absent entirely when every light is roomed.
            if !unassignedLights.isEmpty {
                Text("UNASSIGNED")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(unassignedLights) { light in
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
            moveLights(ids, toRoom: nil)
            return true
        }
        // No layout animation: the panel self-sizes to its content, and
        // animating a genuine height change (a room flipping between pending
        // and real) makes the window visibly breathe. Sizing snaps, like
        // every other screen change in this panel; only the drop highlight
        // fades.
        .animation(.easeOut(duration: 0.12), value: dropTarget)
    }

    /// Dismiss any open inline edit, saving nothing.
    private func cancelInlineEdits() {
        renamingRoomID = nil
        renamingLightID = nil
        renamingPendingName = nil
        addingRoom = false
        errorMessage = nil
        editFocus = nil
    }

    /// Real and pending rooms in one stable, case-insensitively alphabetical
    /// order — a room that empties (and turns pending) keeps its place
    /// instead of jumping below the real rooms.
    private enum RoomEntry {
        case real(String, LightGroup)
        case pending(String)

        var id: String {
            switch self {
            case .real(let id, _): return "room-\(id)"
            case .pending(let name): return "pending-\(name)"
            }
        }

        var name: String {
            switch self {
            case .real(_, let room): return room.name
            case .pending(let name): return name
            }
        }
    }

    private var roomEntries: [RoomEntry] {
        let real = controller.groups.map { RoomEntry.real($0.key, $0.value) }
        let pending = pendingRooms.map { RoomEntry.pending($0) }
        return (real + pending).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Sections

    /// Lights not in any room (nor headed into a pending one).
    private var unassignedLights: [Light] {
        let roomed = Set(controller.groups.values.flatMap(\.lights))
            .union(pendingLights.values.flatMap { $0 })
        return controller.lights.filter { !roomed.contains($0.id) }
    }

    private func roomSection(id: String, room: LightGroup) -> some View {
        let members = controller.lights.filter { room.lights.contains($0.id) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                roomTick(memberIDs: Set(room.lights))
                if renamingRoomID == id {
                    roomNameField(placeholder: room.name) { name in
                        Task {
                            if let error = await controller.updateGroup(id: id, name: name) {
                                errorMessage = error
                            } else {
                                errorMessage = nil
                                renamingRoomID = nil
                            }
                        }
                    }
                } else {
                    Text(room.name)
                        .fontWeight(.medium)
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
                    Task { errorMessage = await controller.deleteGroup(id: id) }
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
            moveLights(ids, toRoom: id)
            return true
        } isTargeted: { over in
            dropTarget = over ? id : (dropTarget == id ? nil : dropTarget)
        }
    }

    /// A room with no bridge group yet: named-but-empty, or holding lights
    /// whose group creation is in flight.
    private func pendingSection(_ name: String) -> some View {
        let incoming = controller.lights.filter { pendingLights[name, default: []].contains($0.id) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "square")
                    .foregroundStyle(Color.secondary.opacity(0.5))
                if renamingPendingName == name {
                    TextField(name, text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 130)
                        .focused($editFocus, equals: .roomRename)
                        .onSubmit { commitPendingRename(of: name) }
                        .onExitCommand {
                            renamingPendingName = nil
                            errorMessage = nil
                        }
                } else {
                    Text(name)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .onTapGesture(count: 2) {
                            cancelInlineEdits()
                            renameText = name
                            renamingPendingName = name
                            editFocus = .roomRename
                        }
                        .help("Double-click to rename")
                }
                Spacer()
                Button {
                    cancelInlineEdits()
                    pendingRooms.removeAll { $0 == name }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(HoverIconButtonStyle())
                .disabled(!incoming.isEmpty)
                .help("Remove")
            }
            ForEach(incoming) { light in
                lightRow(light).padding(.leading, 16)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(dropTarget == name ? 0.15 : 0)))
        .dropDestination(for: String.self) { ids, _ in
            createRoom(name, with: ids)
            return true
        } isTargeted: { over in
            dropTarget = over ? name : (dropTarget == name ? nil : dropTarget)
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
        .help("Select all lights in this room")
    }

    private func roomNameField(placeholder: String, onSubmit: @escaping (String) -> Void) -> some View {
        TextField(placeholder, text: $renameText)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 130)
            .focused($editFocus, equals: .roomRename)
            .onSubmit {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if name.isEmpty {
                    renamingRoomID = nil
                    errorMessage = nil
                } else if roomNameTaken(name, excluding: renamingRoomID) {
                    errorMessage = "A room named '\(name)' already exists"
                } else {
                    onSubmit(name)
                }
            }
            .onExitCommand {
                renamingRoomID = nil
                errorMessage = nil
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
                    errorMessage = nil
                } else if roomNameTaken(name, excluding: nil) {
                    errorMessage = "A room named '\(name)' already exists"
                } else {
                    pendingRooms.append(name)
                    addingRoom = false
                    errorMessage = nil
                }
            }
            .onExitCommand {
                addingRoom = false
                errorMessage = nil
            }
    }

    private func commitPendingRename(of name: String) {
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        if newName.isEmpty || newName.compare(name, options: .caseInsensitive) == .orderedSame {
            renamingPendingName = nil
            errorMessage = nil
        } else if roomNameTaken(newName, excluding: nil) {
            errorMessage = "A room named '\(newName)' already exists"
        } else {
            if let index = pendingRooms.firstIndex(of: name) {
                pendingRooms[index] = newName
            }
            if let incoming = pendingLights.removeValue(forKey: name) {
                pendingLights[newName] = incoming
            }
            renamingPendingName = nil
            errorMessage = nil
        }
    }

    private func roomNameTaken(_ name: String, excluding id: String?) -> Bool {
        let inGroups = controller.groups.contains { key, group in
            key != id && group.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
        let inPending = pendingRooms.contains { $0.compare(name, options: .caseInsensitive) == .orderedSame }
        return inGroups || inPending
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
                    .onExitCommand { renamingLightID = nil }
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

    // MARK: - Membership moves (the partition invariant lives here)

    /// Every room's membership after removing `ids`, plus the room names
    /// that would empty. Computed against the pre-move model so the network
    /// writes are derived from a consistent snapshot.
    private func detachPlan(_ ids: [String]) -> (changed: [String: [String]], emptied: [String: String]) {
        var changed: [String: [String]] = [:]
        var emptied: [String: String] = [:]
        for (key, room) in controller.groups where room.lights.contains(where: ids.contains) {
            let remaining = room.lights.filter { !ids.contains($0) }
            if remaining.isEmpty {
                emptied[key] = room.name
            } else {
                changed[key] = remaining
            }
        }
        return (changed, emptied)
    }

    /// Move lights into a room (nil = out of any room). The optimistic patch
    /// produces the *complete* end state in one frame — rows relocated,
    /// emptied rooms already converted to pending — so nothing dances while
    /// the batched bridge writes settle behind it.
    private func moveLights(_ ids: [String], toRoom target: String?) {
        let ids = ids.filter { id in
            controller.groups.first { $0.value.lights.contains(id) }?.key != target
        }
        guard !ids.isEmpty else { return }
        let (changed, emptied) = detachPlan(ids)
        let targetMembers = target.flatMap { controller.groups[$0] }.map {
            $0.lights.filter { !ids.contains($0) } + ids
        }

        // Optimistic end state, all in one frame.
        for id in ids {
            controller.locallyMoveLight(id: id, toGroup: target)
        }
        for (key, name) in emptied {
            controller.locallyRemoveGroup(id: key)
            if !pendingRooms.contains(name) {
                pendingRooms.append(name)
            }
        }

        Task {
            for (key, remaining) in changed {
                if let error = await controller.updateGroup(id: key, lights: remaining, reload: false) {
                    errorMessage = error
                    await controller.loadLibrary()
                    return
                }
            }
            for key in emptied.keys {
                if let error = await controller.deleteGroup(id: key, reload: false) {
                    errorMessage = error
                    await controller.loadLibrary()
                    return
                }
            }
            if let target, let members = targetMembers {
                if let error = await controller.updateGroup(id: target, lights: members, reload: false) {
                    errorMessage = error
                    await controller.loadLibrary()
                    return
                }
            }
            errorMessage = nil
            await controller.loadLibrary()
        }
    }

    /// A drop into a pending room: the lights land there instantly (held in
    /// pendingLights while the bridge group is created) instead of detouring
    /// through Other.
    private func createRoom(_ name: String, with ids: [String]) {
        guard !ids.isEmpty else { return }
        let (changed, emptied) = detachPlan(ids)

        for id in ids {
            controller.locallyMoveLight(id: id, toGroup: nil)
        }
        for (key, roomName) in emptied {
            controller.locallyRemoveGroup(id: key)
            if !pendingRooms.contains(roomName) {
                pendingRooms.append(roomName)
            }
        }
        pendingLights[name, default: []].append(contentsOf: ids)

        Task {
            defer { pendingLights[name] = nil }
            for (key, remaining) in changed {
                if let error = await controller.updateGroup(id: key, lights: remaining, reload: false) {
                    errorMessage = error
                    await controller.loadLibrary()
                    return
                }
            }
            for key in emptied.keys {
                if let error = await controller.deleteGroup(id: key, reload: false) {
                    errorMessage = error
                    await controller.loadLibrary()
                    return
                }
            }
            if let error = await controller.createGroup(named: name, lights: pendingLights[name] ?? ids) {
                errorMessage = error
                await controller.loadLibrary()
            } else {
                pendingRooms.removeAll { $0 == name }
                errorMessage = nil
            }
        }
    }
}
