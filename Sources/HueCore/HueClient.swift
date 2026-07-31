// HueClient.swift
// Platform-agnostic model + networking for the Hue bridge proxy. No UI imports,
// so this target is shared unchanged by the macOS and iOS apps.
// The proxy at lights.hmblair.com exposes the datastore at the root, so light
// endpoints are /lights and /lights/{id}/state.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import Foundation
import Combine

public struct Light: Identifiable, Hashable {
    public let id: String
    public var name: String
    public var on: Bool
    public var bri: Int          // 1...254
    public var hue: Int          // 0...65535
    public var sat: Int          // 0...254
    public var reachable: Bool

    public init(id: String, name: String, on: Bool, bri: Int, hue: Int, sat: Int, reachable: Bool) {
        self.id = id
        self.name = name
        self.on = on
        self.bri = bri
        self.hue = hue
        self.sat = sat
        self.reachable = reachable
    }
}

// MARK: - Single source of truth for Hue state <-> UI values

extension Light {
    public var hueFraction: Double { Double(hue) / 65_535 }
    public var satFraction: Double { Double(sat) / 254 }

    /// Perceived brightness, 0...1. Off and 0% are the same state: there is no
    /// brightness kept independently of power, so an off light reads as 0 and a
    /// light is off exactly when its brightness is 0.
    public var brightnessFraction: Double { on ? Double(bri) / 254 : 0 }
    public var brightnessPercent: Int { Int((brightnessFraction * 100).rounded()) }
}

/// Shortest distance on the 0...65535 hue circle (0 and 65535 are adjacent).
func hueDistance(_ a: Int, _ b: Int) -> Int {
    let d = abs(a - b) % 65_536
    return min(d, 65_536 - d)
}

@MainActor
public final class HueClient: ObservableObject {
    @Published public private(set) var lights: [Light] = []
    @Published public var selection: Set<String> = []
    @Published public private(set) var lastError: String?

    /// Whether the bridge is reachable, per the polling heartbeat. Only flips to
    /// false after several consecutive failed polls, so a transient blip (e.g. a
    /// write colliding with a poll) doesn't make the hint flicker.
    @Published public private(set) var isReachable = true

    /// Bumps whenever the client adopts fresh bridge state — first load or a
    /// reconnection. The panel reseeds on change. Steady-state polls don't bump
    /// it, so optimistic edits are never overridden while connected.
    @Published public private(set) var syncToken = 0

    /// Bridge base URL, persisted to `UserDefaults`. `nil` until the user
    /// configures it — there is no built-in default.
    @Published public var baseURL: URL? {
        didSet { persistBaseURL() }
    }

    public var isConfigured: Bool { baseURL != nil }

    private let session: URLSession
    private let defaults: UserDefaults
    private let baseURLKey = "HueBridgeBaseURL"

    /// Short per-request timeout so an unreachable bridge surfaces quickly; the
    /// URLSession default is 60s.
    private let requestTimeout: TimeInterval = 5

    /// Consecutive failed polls before the bridge is considered unreachable — a
    /// grace period so a single dropped request doesn't flip the UI.
    private let disconnectThreshold = 3
    private var failedPolls = 0
    private var hasSynced = false

    /// Inject `session`/`defaults` so both apps — and tests — can point at any
    /// bridge or a stub without touching this type.
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
        let hueTolerance = 655   // ~1% of the hue circle
        let satTolerance = 6
        return selectedLights.contains {
            hueDistance($0.hue, first.hue) > hueTolerance
                || abs($0.sat - first.sat) > satTolerance
        }
    }

    /// True when the selected lights don't all share the same brightness. Off
    /// counts as 0, so two off lights are never "mixed".
    public var brightnessIsMixed: Bool {
        guard let first = selectedLights.first else { return false }
        let tolerance = 0.02   // ~2%
        return selectedLights.contains {
            abs($0.brightnessFraction - first.brightnessFraction) > tolerance
        }
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
        guard let baseURL else { lastError = "No bridge configured"; return }
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("lights"))
            request.timeoutInterval = requestTimeout
            let (data, _) = try await session.data(for: request)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastError = "Unexpected response from the bridge"
                return
            }
            var parsed: [Light] = []
            for (id, value) in obj {
                guard let d = value as? [String: Any] else { continue }
                let state = d["state"] as? [String: Any] ?? [:]
                parsed.append(Light(
                    id: id,
                    name: d["name"] as? String ?? "Light \(id)",
                    on: state["on"] as? Bool ?? false,
                    bri: state["bri"] as? Int ?? 0,
                    hue: state["hue"] as? Int ?? 0,
                    sat: state["sat"] as? Int ?? 0,
                    reachable: state["reachable"] as? Bool ?? false))
            }
            // Adopt bridge state only on first load or a reconnection — never
            // during steady-state polling, so a poll that lands before a write
            // has propagated can't revert an optimistic edit.
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
                lastError = "Can't reach the bridge"
            }
        }
    }

    // MARK: - Writes

    /// Set hue/saturation without touching power. Brightness is the sole on/off
    /// control, so changing color never turns a light on or off — the color is
    /// stored and shows once the light is bright enough to see.
    public func applyColor(hue: Double, saturation: Double) {
        let ids = targets
        let hueInt = Int((hue * 65_535).rounded())
        let satInt = Int((saturation * 254).rounded())
        updateLocal(ids) { $0.hue = hueInt; $0.sat = satInt }

        colorTask?.cancel()
        colorTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000) // debounce drags
            if Task.isCancelled { return }
            await send(["hue": hueInt, "sat": satInt], to: ids)
        }
    }

    /// Brightness in 0...1 is the single power+level control: 0 turns lights off,
    /// any positive value turns them on at the mapped `bri`. A light is off iff
    /// its brightness is 0 — no brightness is remembered across off.
    public func applyBrightness(_ value: Double) {
        let ids = targets
        let isOff = value <= 0
        let bri = max(1, min(254, Int((value * 254).rounded())))
        updateLocal(ids) {
            if isOff { $0.on = false } else { $0.on = true; $0.bri = bri }
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
    // not by writes: a write can fail transiently (colliding with a poll, bridge
    // briefly busy) while the bridge is fine, and letting that flip the UI made
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
