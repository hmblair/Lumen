// LumenApp.swift
// macOS shell: a menu-bar-only app. The NSStatusItem toggles a custom
// non-activating NSPanel dressed as a menu (Liquid Glass on macOS 26+, the
// classic menu material earlier; fade on dismiss). A panel rather than NSMenu
// because menu windows can never become key: SwiftUI controls inside them
// render in the grey inactive style, text fields can't take keyboard focus,
// and hover cursors don't update. A .nonactivatingPanel becomes key without
// activating the app, so everything behaves normally while feeling like a menu.
// Panel behavior and positioning follow FluidMenuBarExtra
// (github.com/wadetregaskis/FluidMenuBarExtra), the de-facto template for
// menu-like panels; the glass chrome is NSGlassEffectView as the content view.
// All reusable logic lives in LumenCore/LumenUI; this file is the composition
// root and the only place AppKit appears.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI
import AppKit
import Combine
import ServiceManagement
import LumenCore
import LumenUI

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Qualified: LumenCore.Scene (a light scene) shadows SwiftUI.Scene here.
    var body: some SwiftUI.Scene {
        // No visible window; the status item drives everything.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let controller = LightController()
    private var statusItem: NSStatusItem!
    private var panel: MenuPanel!
    private var iconObserver: AnyCancellable?
    private var outsideClickMonitor: Any?
    private var pollActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        updateStatusButton()

        // No fixed width here: the panel sizes to the SwiftUI content, and
        // ControlPanel widens itself while the scene editor is open.
        panel = MenuPanel(rootView:
            ControlPanel(
                controller: controller,
                onQuit: { NSApp.terminate(nil) },
                loginItem: Self.loginItem)
        )
        panel.delegate = self
        panel.onDismissRequest = { [weak self] in self?.closePanel() }

        // Keep the icon in sync with light state. Deliver on DispatchQueue.main
        // (not RunLoop.main) so updates aren't starved by event tracking.
        iconObserver = controller.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateStatusButton() }

        // Poll every second while awake so state and reachability stay current.
        // Opt out of App Nap so the cadence is honored while the app is idle;
        // the "AllowingIdleSystemSleep" variant still lets the Mac sleep when
        // the user steps away, at which point polling naturally stops.
        pollActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Poll light state")
        controller.startPolling(every: .seconds(1))
    }

    /// Login-item control backed by SMAppService. Registering only works from a
    /// proper .app bundle (see `make app`), not from `swift run`; a failure
    /// leaves the toggle reflecting the real (still-disabled) status.
    private static var loginItem: LoginItem {
        LoginItem(
            isEnabled: { SMAppService.mainApp.status == .enabled },
            setEnabled: { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("Login item update failed: \(error.localizedDescription)")
                }
            })
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        guard let buttonWindow = statusItem.button?.window else { return }
        panel.present(below: buttonWindow.frame)
        statusItem.button?.highlight(true)

        // Menus also dismiss on outside clicks that don't move key status
        // (the desktop, another status item). Global monitors never see this
        // app's own events, so clicks inside the panel are unaffected.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        statusItem.button?.highlight(false)
        panel.fadeOut()
    }

    /// Anything that takes key status away (another app or window) dismisses
    /// the panel, like a menu.
    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }

    /// Update the status item's icon and dim it when the lights are unreachable,
    /// so disconnection reads at a glance even with the panel closed.
    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = statusImage
        button.alphaValue = controller.isReachable ? 1 : 0.4
    }

    /// The menu bar icon. Palette rendering keeps the bulb neutral (Primary =
    /// label color) and tints the accent rays with the representative light's
    /// color. The rays fade in with brightness via alpha — transparent when off
    /// (brightness 0), fully opaque at 100% — so no separate off state is needed.
    /// When unreachable the icon drops to a plain monochrome template (the
    /// dimming is applied on the button) rather than showing a stale color. A
    /// colored NSImage must set `isTemplate = false`, otherwise the menu bar
    /// flattens it.
    private var statusImage: NSImage {
        let base = NSImage(systemSymbolName: "warninglight.fill",
                           accessibilityDescription: "Lumen")
            ?? NSImage(systemSymbolName: "lightbulb.fill",
                       accessibilityDescription: "Lumen")!

        guard controller.isReachable else {
            base.isTemplate = true
            return base
        }

        let light = controller.representative
        let accent = NSColor(hue: light?.hue ?? 0,
                             saturation: light?.saturation ?? 0,
                             brightness: 1,
                             alpha: light?.brightness ?? 0)
        let config = NSImage.SymbolConfiguration(paletteColors: [.labelColor, accent])
        let tinted = base.withSymbolConfiguration(config) ?? base
        tinted.isTemplate = false
        return tinted
    }
}

/// A borderless, non-activating panel styled like a menu. Unlike a real
/// NSMenu's window it can become key, so hosted SwiftUI controls render in
/// their active (accent-tinted) style and text fields accept typing.
final class MenuPanel: NSPanel {
    /// Called when the panel wants to close itself (Esc), so the owner can run
    /// its full teardown (monitor removal, status item highlight).
    var onDismissRequest: (() -> Void)?

    private var topLeft = NSPoint.zero
    private var isFading = false

    init<Content: View>(rootView: Content) {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        isMovable = false
        isReleasedWhenClosed = false

        // NSHostingController sizes the window to the SwiftUI content and
        // keeps it sized as the content changes — verified against the
        // alternatives (a bare NSHostingView with sizing disabled reports zero
        // for every size query and deadlocks the window at 0x0).
        contentViewController = NSHostingController(rootView:
            rootView.background(MenuChrome())
        )

        // Window resizes keep the bottom-left corner fixed; re-pin the top-left
        // so height changes grow downward from the menu bar, not upward.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(restoreTopLeft),
                                               name: NSWindow.didResizeNotification,
                                               object: self)
    }

    @objc private func restoreTopLeft() {
        guard isVisible else { return }
        setFrameTopLeftPoint(topLeft)
        invalidateShadow()
    }

    override var canBecomeKey: Bool { true }

    /// Esc closes the panel, like a menu.
    override func cancelOperation(_ sender: Any?) { onDismissRequest?() }

    /// Show the panel directly below the status item's window, aligned to its
    /// leading edge — the same math NSMenu uses (via FluidMenuBarExtra): flush
    /// against the bottom of the status item window, nudged left by the menu
    /// border inset. Appears instantly; menus only animate on the way out.
    func present(below statusItemFrame: NSRect) {
        // Matches the highlighted status item button, per FluidMenuBarExtra.
        let borderInset: CGFloat = 2

        var origin = NSPoint(x: statusItemFrame.minX - borderInset,
                             y: statusItemFrame.minY - frame.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(statusItemFrame) }) {
            origin.x = min(origin.x, screen.visibleFrame.maxX - frame.width - borderInset)
            origin.x = max(origin.x, screen.visibleFrame.minX + borderInset)
        }
        topLeft = NSPoint(x: origin.x, y: statusItemFrame.minY)

        alphaValue = 1
        setFrameOrigin(origin)
        // Keeps the menu bar visible while the panel is open in full screen.
        DistributedNotificationCenter.default().post(name: .beginMenuTracking, object: nil)
        makeKeyAndOrderFront(nil)
        // No control should show a focus ring until the user clicks one.
        makeFirstResponder(nil)
        invalidateShadow()
    }

    func fadeOut() {
        guard isVisible, !isFading else { return }
        isFading = true
        DistributedNotificationCenter.default().post(name: .endMenuTracking, object: nil)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
            self.alphaValue = 1
            self.isFading = false
        })
    }

}

/// Menu-style chrome. On macOS 26+ this is Liquid Glass via AppKit's
/// NSGlassEffectView — the same treatment system menus get, including the
/// adaptive tint and reactive edge highlight. Earlier systems fall back to the
/// classic menu material with a hairline border.
private struct MenuChrome: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassBackground(cornerRadius: 16)
        } else {
            MenuMaterial(cornerRadius: 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                )
        }
    }
}

@available(macOS 26.0, *)
private struct GlassBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = cornerRadius
        // The glass rounds its fill and rim to cornerRadius, but its internal
        // CABackdropLayer (the behind-window blur sample) stays square and
        // unmasked — invisible in an opaque window, but in a transparent panel
        // its corners protrude past the rounded glass as a faint square
        // outline. Clip the whole subtree to the same rounded shape.
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {}
}

private struct MenuMaterial: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        // Behind-window blur is shaped by maskImage, not layer masks — a
        // SwiftUI clipShape would clip the tint but leave square blur corners.
        view.maskImage = .roundedCornerMask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private extension Notification.Name {
    // Posting these keeps the system menu bar around during tracking in
    // full-screen spaces, like a real menu (via FluidMenuBarExtra).
    static let beginMenuTracking = Notification.Name("com.apple.HIToolbox.beginMenuTrackingNotification")
    static let endMenuTracking = Notification.Name("com.apple.HIToolbox.endMenuTrackingNotification")
}

private extension NSImage {
    /// A stretchable rounded-rect mask for NSVisualEffectView.maskImage.
    static func roundedCornerMask(radius: CGFloat) -> NSImage {
        let edge = 2 * radius + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
