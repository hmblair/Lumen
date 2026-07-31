// LightController+Scenes.swift
// Scenes and schedules: models mirroring the daemon's wire schema exactly,
// plus the CRUD/run/stop client methods. See daemon/README.md for the API.
// A scene is a curve of points on a 0...1 timeline; a solid color is the
// one-point, zero-duration case; level 0 means off.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import Foundation

public struct ScenePoint: Codable, Hashable {
    public var t: Double
    public var hue: Double
    public var saturation: Double
    public var level: Double

    public init(t: Double, hue: Double, saturation: Double, level: Double) {
        self.t = t
        self.hue = hue
        self.saturation = saturation
        self.level = level
    }
}

/// A scene maps each light it touches to a curve; lights not in the map are
/// left alone. A solid color is a one-point, zero-duration curve. The scene
/// carries everything about *what* happens — schedules are time-only.
public struct Scene: Codable, Hashable {
    /// Total run time in seconds; 0 = apply the end state immediately.
    public var duration: Double
    /// Curve per light id.
    public var lights: [String: [ScenePoint]]

    public init(duration: Double, lights: [String: [ScenePoint]]) {
        self.duration = duration
        self.lights = lights
    }

    /// A solid color on the given lights: one point per light, zero duration.
    public static func solid(hue: Double, saturation: Double, level: Double,
                             lightIDs: [String]) -> Scene {
        let point = ScenePoint(t: 0, hue: hue, saturation: saturation, level: level)
        return Scene(duration: 0,
                     lights: Dictionary(uniqueKeysWithValues: lightIDs.map { ($0, [point]) }))
    }

    public var isSolid: Bool { lights.values.allSatisfy { $0.count == 1 } }
}

public struct Schedule: Codable, Hashable {
    /// "HH:MM" in the daemon's local timezone.
    public var at: String
    /// ["mon"..."sun"]; ignored when `on` is set.
    public var days: [String]
    /// One-shot date "YYYY-MM-DD"; the schedule deletes itself after firing.
    public var on: String?
    /// Name of the scene to run (the scene says which lights).
    public var scene: String
    public var enabled: Bool

    public init(at: String, days: [String], on: String? = nil,
                scene: String, enabled: Bool = true) {
        self.at = at
        self.days = days
        self.on = on
        self.scene = scene
        self.enabled = enabled
    }
}

/// A light group. Groups live on the bridge (like names), so the vendor
/// ecosystem sees the same membership. Named LightGroup to avoid colliding
/// with SwiftUI.Group.
public struct LightGroup: Codable, Hashable {
    public var name: String
    public var lights: [String]

    public init(name: String, lights: [String]) {
        self.name = name
        self.lights = lights
    }
}

/// The daemon's bridge configuration (GET /config): the explicit address
/// override (nil = mDNS auto-discovery), the address currently in use, and
/// whether the bridge is answering.
public struct BridgeConfig: Codable, Hashable {
    public let bridgeIP: String?
    public let activeIP: String?
    public let bridgeReachable: Bool
}

/// The run reported by GET /status while a scene is active.
public struct RunningInfo: Codable, Hashable {
    public let scene: String
    /// The schedule that fired it; nil for manual runs.
    public let schedule: String?
    /// Owned lights; empty = all.
    public let targets: [String]
    public let started: Date
    public let ends: Date
}

extension LightController {

    // MARK: - Library (scenes + schedules)

    /// Fetch scenes, schedules, and groups. Called when the panel opens and
    /// after mutations; not part of the 1 s poll.
    public func loadLibrary() async {
        if let data = await get("scenes"),
           let response = try? JSONDecoder().decode([String: [String: Scene]].self, from: data) {
            scenes = response["scenes"] ?? [:]
        }
        if let data = await get("schedules"),
           let response = try? JSONDecoder().decode([String: [String: Schedule]].self, from: data) {
            schedules = response["schedules"] ?? [:]
        }
        if let data = await get("groups"),
           let response = try? JSONDecoder().decode([String: [String: LightGroup]].self, from: data) {
            groups = response["groups"] ?? [:]
        }
    }

    // MARK: - Groups

    /// Create a bridge group from the given lights; returns the daemon's
    /// error or nil.
    @discardableResult
    public func createGroup(named name: String, lights: [String]) async -> String? {
        let body = try? JSONSerialization.data(withJSONObject: ["name": name, "lights": lights])
        let error = await send("POST", "groups", body: body)
        await loadLibrary()
        return error
    }

    /// Update a group's name and/or membership (nil = leave unchanged).
    @discardableResult
    public func updateGroup(id: String, name: String? = nil, lights: [String]? = nil) async -> String? {
        var fields: [String: Any] = [:]
        if let name { fields["name"] = name }
        if let lights { fields["lights"] = lights }
        let body = try? JSONSerialization.data(withJSONObject: fields)
        let error = await send("PUT", "groups/\(id)", body: body)
        await loadLibrary()
        return error
    }

    @discardableResult
    public func deleteGroup(id: String) async -> String? {
        let error = await send("DELETE", "groups/\(id)")
        await loadLibrary()
        return error
    }

    /// Upsert; returns an error message, or nil on success.
    @discardableResult
    public func save(schedule: Schedule, named name: String) async -> String? {
        let error = await send("PUT", "schedules/\(name)", body: try? JSONEncoder().encode(schedule))
        await loadLibrary()
        return error
    }

    @discardableResult
    public func deleteSchedule(named name: String) async -> String? {
        let error = await send("DELETE", "schedules/\(name)")
        await loadLibrary()
        return error
    }

    @discardableResult
    public func save(scene: Scene, named name: String) async -> String? {
        let error = await send("PUT", "scenes/\(name)", body: try? JSONEncoder().encode(scene))
        await loadLibrary()
        return error
    }

    @discardableResult
    public func deleteScene(named name: String) async -> String? {
        let error = await send("DELETE", "scenes/\(name)")
        await loadLibrary()
        return error
    }

    // MARK: - Runs

    /// Run a scene now (it applies to the lights it defines). Returns the
    /// daemon's error (e.g. another scene is running — 409) or nil.
    @discardableResult
    public func runScene(named name: String) async -> String? {
        let error = await send("POST", "scenes/\(name)/run")
        await refresh()
        return error
    }

    /// Stop the running scene, releasing manual control.
    public func stopScene() async {
        _ = await send("POST", "stop")
        await refresh()
    }

    /// Fire-and-forget write to specific lights, used by the scene editor's
    /// timeline scrubbing (level 0 = off, matching the app invariant).
    public func setLights(_ ids: [String], hue: Double, saturation: Double, level: Double) {
        markWritten(ids)
        let body: [String: Any] = level <= 0
            ? ["on": false]
            : ["on": true, "hue": hue, "saturation": saturation, "level": level]
        let data = try? JSONSerialization.data(withJSONObject: body)
        Task {
            for id in ids {
                _ = await send("PUT", "lights/\(id)", body: data)
            }
        }
    }

    /// Rename a light. The name lives on the bridge, so every client — the
    /// vendor's app included — sees it. Optimistic locally, guarded against
    /// poll clobber like any write; returns the daemon's error or nil.
    @discardableResult
    public func renameLight(id: String, to name: String) async -> String? {
        markWritten([id])
        if let index = lights.firstIndex(where: { $0.id == id }) {
            lights[index].name = name
        }
        let body = try? JSONSerialization.data(withJSONObject: ["name": name])
        return await send("PUT", "lights/\(id)", body: body)
    }

    /// Put lights back to a previously captured state — full state including
    /// power and the stored color of lights that were off. Used to undo the
    /// editor's temporary scrub/preview writes.
    public func restoreLights(_ snapshot: [Light]) {
        markWritten(snapshot.map(\.id))
        Task {
            for light in snapshot {
                let body: [String: Any] = ["on": light.on,
                                           "hue": light.hue,
                                           "saturation": light.saturation,
                                           "level": light.level]
                let data = try? JSONSerialization.data(withJSONObject: body)
                _ = await send("PUT", "lights/\(light.id)", body: data)
            }
        }
    }

    // MARK: - Bridge configuration

    public func loadBridgeConfig() async {
        if let data = await get("config"),
           let config = try? JSONDecoder().decode(BridgeConfig.self, from: data) {
            bridgeConfig = config
        }
    }

    /// Set (or clear, with nil/empty) the bridge address override. The daemon
    /// probes the address before committing; returns its error message on
    /// refusal, nil on success.
    @discardableResult
    public func setBridgeIP(_ ip: String?) async -> String? {
        let body: [String: Any] = ["bridgeIP": ip.flatMap { $0.isEmpty ? nil : $0 } as Any]
        let data = try? JSONSerialization.data(withJSONObject: body)
        let error = await send("PUT", "config", body: data)
        await loadBridgeConfig()
        return error
    }

    // MARK: - Plumbing

    private func get(_ path: String) async -> Data? {
        guard let baseURL else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 5
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { return nil }
        return data
    }

    /// Issue a mutating request; returns the daemon's error message on
    /// failure, nil on success.
    private func send(_ method: String, _ path: String, body: Data? = nil) async -> String? {
        guard let baseURL else { return "No server configured" }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 5
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        guard let (data, response) = try? await session.data(for: request) else {
            return "Can't reach the server"
        }
        guard let http = response as? HTTPURLResponse else { return nil }
        if (200...299).contains(http.statusCode) { return nil }
        let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
        return message ?? "Request failed (\(http.statusCode))"
    }
}
