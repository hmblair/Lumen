// LightController.swift
// Model + networking. The UI and shell depend only on this type and the
// normalized `Light` value; all provider-specific wire encoding (endpoints,
// JSON shape, the 0–65535 / 1–254 ranges) is confined here. This implementation
// targets a Philips Hue bridge (v1 API served at the datastore root, e.g.
// lights.hmblair.com), so supporting another provider means rewriting this one
// file. No UI imports, so it's shared by the macOS and iOS apps.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import Foundation
import Combine

/// A light in normalized, provider-agnostic units — no vendor encodings escape.
public struct Light: Identifiable, Hashable {
    public let id: String
    public var name: String
    public var on: Bool
    public var hue: Double         // 0...1
    public var saturation: Double  // 0...1
    public var level: Double       // 0...1 device brightness, independent of `on`
    public var reachable: Bool

    public init(id: String, name: String, on: Bool,
                hue: Double, saturation: Double, level: Double, reachable: Bool) {
        self.id = id
        self.name = name
        self.on = on
        self.hue = hue
        self.saturation = saturation
        self.level = level
        self.reachable = reachable
    }
}

extension Light {
    /// Perceived brightness, 0...1. Off and 0 are the same state: a light is off
    /// exactly when its brightness is 0, so an off light reads as 0.
    public var brightness: Double { on ? level : 0 }
    public var brightnessPercent: Int { Int((brightness * 100).rounded()) }
}

/// Shortest distance on the 0...1 hue circle (0 and 1 are adjacent).
func hueDistance(_ a: Double, _ b: Double) -> Double {
    let d = abs(a - b)
    return min(d, 1 - d)
}

@MainActor
public final class LightController: ObservableObject {
    @Published public private(set) var lights: [Light] = []
    @Published public var selection: Set<String> = []
    @Published public private(set) var lastError: String?

    /// Whether the light source is reachable, per the polling heartbeat. Only
    /// flips to false after several consecutive failed polls, so a transient blip
    /// (e.g. a write colliding with a poll) doesn't make the hint flicker.
    @Published public private(set) var isReachable = true

    /// Bumps whenever the controller adopts fresh state — first load or a
    /// reconnection. The panel reseeds on change. Steady-state polls don't bump
    /// it, so optimistic edits are never overridden while connected.
    @Published public private(set) var syncToken = 0

    /// Base URL, persisted to `UserDefaults`. `nil` until the user configures it
    /// — there is no built-in default.
    @Published public var baseURL: URL? {
        didSet {
            guard baseURL != oldValue else { return }
            persistBaseURL()
            // Pointing at a different source: drop the old lights and force the
            // next poll to adopt the new state.
            lights = []
            selection = []
            hasSynced = false
            failedPolls = 0
        }
    }

    public var isConfigured: Bool { baseURL != nil }

    private let session: URLSession
    private let defaults: UserDefaults
    private let baseURLKey = "HueBridgeBaseURL"

    /// Short per-request timeout so an unreachable source surfaces quickly; the
    /// URLSession default is 60s.
    private let requestTimeout: TimeInterval = 5

    /// Consecutive failed polls before the source is considered unreachable — a
    /// grace period so a single dropped request doesn't flip the UI.
    private let disconnectThreshold = 3
    private var failedPolls = 0
    private var hasSynced = false

    /// Inject `session`/`defaults` so both apps — and tests — can point at any
    /// source or a stub without touching this type.
    public init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
        if let stored = defaults.string(forKey: baseURLKey), let url = URL(string: stored) {
            self.baseURL = url
        } else {
            self.baseURL = nil
        }
    }

    private func persistBaseURL() {
        if let baseURL {
            defaults.set(baseURL.absoluteString, forKey: baseURLKey)
        } else {
            defaults.removeObject(forKey: baseURLKey)
        }
    }

    // Separate debounce tasks so a color drag and a brightness drag don't
    // cancel each other.
    private var colorTask: Task<Void, Never>?
    private var briTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    private var targets: [String] { Array(selection) }

    private var selectedLights: [Light] {
        lights.filter { selection.contains($0.id) }
    }

    /// The light the wheel/slider should mirror: the first selected light in
    /// list order (nil if nothing is selected).
    public var representative: Light? { selectedLights.first }

    /// True when the selected lights don't all share the same color. Drives a
    /// "Mixed" hint, since the wheel can only show one position.
    public var selectionIsMixed: Bool {
        guard let first = selectedLights.first else { return false }
        let hueTolerance = 0.01
        let satTolerance = 0.02
        return selectedLights.contains {
            hueDistance($0.hue, first.hue) > hueTolerance
                || abs($0.saturation - first.saturation) > satTolerance
        }
    }

    /// True when the selected lights don't all share the same brightness. Off
    /// counts as 0, so two off lights are never "mixed".
    public var brightnessIsMixed: Bool {
        guard let first = selectedLights.first else { return false }
        let tolerance = 0.02   // ~2%
        return selectedLights.contains { abs($0.brightness - first.brightness) > tolerance }
    }

    // MARK: - Polling

    /// Repeatedly refresh so light state and reachability stay current without
    /// user action. Each cycle refreshes then sleeps, so a slow (timing-out)
    /// request naturally spaces attempts out. The loop pauses while the machine
    /// sleeps and resumes on wake, since Task.sleep can't fire while frozen.
    public func startPolling(every interval: Duration = .seconds(1)) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Reads

    public func refresh() async {
        guard let baseURL else { lastError = "No source configured"; return }
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("lights"))
            request.timeoutInterval = requestTimeout
            let (data, _) = try await session.data(for: request)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastError = "Unexpected response"
                return
            }
            var parsed: [Light] = []
            for (id, value) in obj {
                guard let d = value as? [String: Any] else { continue }
                let state = d["state"] as? [String: Any] ?? [:]
                // Hue-native encodings map to normalized 0...1 here, so no vendor
                // units reach the model.
                parsed.append(Light(
                    id: id,
                    name: d["name"] as? String ?? "Light \(id)",
                    on: state["on"] as? Bool ?? false,
                    hue: Double(state["hue"] as? Int ?? 0) / 65_535,
                    saturation: Double(state["sat"] as? Int ?? 0) / 254,
                    level: Double(state["bri"] as? Int ?? 0) / 254,
                    reachable: state["reachable"] as? Bool ?? false))
            }
            // Adopt state only on first load or a reconnection — never during
            // steady-state polling, so a poll that lands before a write has
            // propagated can't revert an optimistic edit.
            let reconnected = !isReachable
            failedPolls = 0
            isReachable = true
            lastError = nil
            if reconnected || !hasSynced {
                hasSynced = true
                lights = parsed.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
                if selection.isEmpty { selection = Set(lights.map(\.id)) }
                syncToken += 1
            }
        } catch {
            failedPolls += 1
            if failedPolls >= disconnectThreshold {
                isReachable = false
                lastError = "Can't reach the lights"
            }
        }
    }

    /// One-shot reachability probe for the settings field's status indicator.
    /// Independent of the polled `isReachable` and its grace period.
    public func checkReachable() async -> Bool {
        guard let baseURL else { return false }
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("lights"))
            request.timeoutInterval = requestTimeout
            _ = try await session.data(for: request)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Writes

    /// Set hue/saturation (0...1) without touching power. Brightness is the sole
    /// on/off control, so changing color never turns a light on or off — the
    /// color is stored and shows once the light is bright enough to see.
    public func applyColor(hue: Double, saturation: Double) {
        let ids = targets
        let hueInt = Int((hue * 65_535).rounded())
        let satInt = Int((saturation * 254).rounded())
        updateLocal(ids) { $0.hue = hue; $0.saturation = saturation }

        colorTask?.cancel()
        colorTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000) // debounce drags
            if Task.isCancelled { return }
            await send(["hue": hueInt, "sat": satInt], to: ids)
        }
    }

    /// Brightness in 0...1 is the single power+level control: 0 turns lights off,
    /// any positive value turns them on at the mapped level. A light is off iff
    /// its brightness is 0 — no brightness is remembered across off.
    public func applyBrightness(_ value: Double) {
        let ids = targets
        let isOff = value <= 0
        let bri = max(1, min(254, Int((value * 254).rounded())))
        updateLocal(ids) {
            if isOff { $0.on = false } else { $0.on = true; $0.level = value }
        }

        briTask?.cancel()
        briTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            if Task.isCancelled { return }
            let body: [String: Any] = isOff ? ["on": false] : ["on": true, "bri": bri]
            await send(body, to: ids)
        }
    }

    /// Mutate the local model for the given lights so the UI reflects a change
    /// before (and independently of) the network round-trip.
    private func updateLocal(_ ids: [String], _ transform: (inout Light) -> Void) {
        for i in lights.indices where ids.contains(lights[i].id) {
            transform(&lights[i])
        }
    }

    // Fire-and-forget. Reachability is judged solely by the polling heartbeat,
    // not by writes: a write can fail transiently (colliding with a poll, source
    // briefly busy) while the source is fine, and letting that flip the UI made
    // the disconnected hint flicker during drags.
    private func send(_ body: [String: Any], to ids: [String]) async {
        guard !ids.isEmpty, let baseURL else { return }
        let timeout = requestTimeout
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { [baseURL, session] in
                    var req = URLRequest(
                        url: baseURL.appendingPathComponent("lights/\(id)/state"))
                    req.httpMethod = "PUT"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                    req.timeoutInterval = timeout
                    _ = try? await session.data(for: req)
                }
            }
        }
    }
}
