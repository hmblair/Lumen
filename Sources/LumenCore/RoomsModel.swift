// RoomsModel.swift
// The rooms domain model. Rooms are daemon-authoritative — created empty,
// persisted server-side, mirrored to bridge groups only as a convenience —
// and Lumen treats them as a *partition*: every light in at most one room,
// an invariant enforced here (the daemon's groups could technically
// overlap, reserved for the future tags axis). This model owns the sorted
// room list, naming rules, and the move orchestration (optimistic end state
// in one frame, batched writes behind, one reload to settle). Views render
// it and forward gestures.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import Foundation

@MainActor
public final class RoomsModel: ObservableObject {

    /// Where a light can be dropped.
    public enum Target: Equatable {
        case room(String)
        case unassigned
    }

    /// The latest room operation's error (shown by the room UI); cleared on
    /// success and via clearError().
    @Published public private(set) var lastError: String?

    // The controller owns this model, so it always outlives it.
    private unowned let controller: LightController

    init(controller: LightController) {
        self.controller = controller
    }

    public func clearError() {
        lastError = nil
    }

    // MARK: - Derived state

    /// Rooms in stable, case-insensitively alphabetical order.
    public var roomList: [(id: String, room: LightGroup)] {
        controller.groups
            .map { (id: $0.key, room: $0.value) }
            .sorted { $0.room.name.localizedCaseInsensitiveCompare($1.room.name) == .orderedAscending }
    }

    /// Lights not in any room.
    public var unassignedLights: [Light] {
        let roomed = Set(controller.groups.values.flatMap(\.lights))
        return controller.lights.filter { !roomed.contains($0.id) }
    }

    /// Case-insensitive name check, ignoring the room being renamed.
    public func nameTaken(_ name: String, excludingRoomID id: String? = nil) -> Bool {
        controller.groups.contains { key, room in
            key != id && room.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
    }

    // MARK: - Room CRUD

    /// Create an empty room (the daemon persists it; a bridge mirror appears
    /// once it gains lights).
    @discardableResult
    public func createRoom(named name: String) async -> String? {
        if nameTaken(name) {
            lastError = Self.duplicate(name)
            return lastError
        }
        lastError = await controller.createGroup(named: name, lights: [])
        return lastError
    }

    @discardableResult
    public func renameRoom(id: String, to name: String) async -> String? {
        if nameTaken(name, excludingRoomID: id) {
            lastError = Self.duplicate(name)
            return lastError
        }
        lastError = await controller.updateGroup(id: id, name: name)
        return lastError
    }

    /// Delete a room; its lights become unassigned.
    @discardableResult
    public func deleteRoom(id: String) async -> String? {
        lastError = await controller.deleteGroup(id: id)
        return lastError
    }

    // MARK: - Moves (the partition invariant lives here)

    /// Move lights into a room or out of any. The optimistic patch produces
    /// the complete end state in one frame — an emptied room simply stays,
    /// empty — and the batched writes settle behind it; a final reload
    /// restores server truth either way.
    public func move(_ ids: [String], to target: Target) {
        let targetID: String? = {
            if case .room(let id) = target { return id }
            return nil
        }()
        let ids = ids.filter { id in
            controller.groups.first { $0.value.lights.contains(id) }?.key != targetID
        }
        guard !ids.isEmpty else { return }

        // Membership of every touched room after the move, computed against
        // the pre-move model so the writes derive from a consistent snapshot.
        var changed: [String: [String]] = [:]
        for (key, room) in controller.groups where room.lights.contains(where: ids.contains) {
            changed[key] = room.lights.filter { !ids.contains($0) }
        }
        if let targetID, let room = controller.groups[targetID] {
            changed[targetID] = room.lights.filter { !ids.contains($0) } + ids
        }

        for id in ids {
            controller.locallyMoveLight(id: id, toGroup: targetID)
        }

        Task {
            for (key, members) in changed {
                if let error = await controller.updateGroup(id: key, lights: members, reload: false) {
                    lastError = error
                    await controller.loadLibrary()
                    return
                }
            }
            lastError = nil
            await controller.loadLibrary()
        }
    }

    private static func duplicate(_ name: String) -> String {
        "A room named '\(name)' already exists"
    }
}
