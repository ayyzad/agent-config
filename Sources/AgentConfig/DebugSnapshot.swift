#if DEBUG
import AgentConfigCore
import AppKit
import SwiftUI

/// Debug builds only: renders the app's windows to PNGs so the UI can be checked
/// without screen-recording permission.
///   AGENTCONFIG_SNAPSHOT_DIR=/tmp/shots AGENTCONFIG_SNAPSHOT_STEPS=user,overview,add swift run AgentConfig
/// Steps: user, overview, project:<folder name>, add, review (previews a change, never saves), close.
@MainActor
enum DebugSnapshot {
    private static var started = false

    static func runIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard !started, let dir = env["AGENTCONFIG_SNAPSHOT_DIR"] else { return }
        started = true
        let steps = (env["AGENTCONFIG_SNAPSHOT_STEPS"] ?? "user").split(separator: ",").map(String.init)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            for (i, step) in steps.enumerated() {
                apply(step, model: model)
                try? await Task.sleep(for: .seconds(1.2))
                for (j, window) in NSApp.windows.enumerated() where window.isVisible {
                    capture(window, to: URL(fileURLWithPath: dir).appending(path: "\(i)-\(step.replacingOccurrences(of: ":", with: "_"))-\(j).png"))
                }
            }
            NSApp.terminate(nil)
        }
    }

    private static func apply(_ step: String, model: AppModel) {
        switch step {
        case "user": model.sheet = nil; model.selection = .user
        case "overview": model.sheet = nil; model.selection = .overview
        case "add": model.requestAddRule()
        case "review": model.propose(.add("Bash(gh pr merge *)", .ask), at: model.currentLocation ?? model.userLocation)
        case "close": model.sheet = nil
        case "homepane":
            let home = SettingsLocation.local(Paths.home)
            show(PermissionsEditor(title: "", locations: [home], initial: home), model: model, size: NSSize(width: 860, height: 700))
        case "movehome":
            let home = SettingsLocation.local(Paths.home)
            if let doc = model.state(home).document {
                let rules = RuleDecision.allCases.flatMap { d in doc.rules(d).map { (rule: $0, decision: d) } }
                model.moveToEverywhere(rules, from: home)  // opens the review sheet only; never saves
            }
        case "overviewpane": show(OverviewView(), model: model, size: NSSize(width: 1000, height: 900))
        case "panes":
            // Plain windows hosting the same views, which capture reliably.
            let location = model.currentLocation ?? model.userLocation
            let project = model.project(for: location)
            show(PermissionsEditor(title: "", locations: project?.locations ?? [location], initial: location), model: model,
                 size: NSSize(width: 860, height: 1100))
            show(SidebarView().frame(width: 280), model: model, size: NSSize(width: 280, height: 900))
        default:
            if step.hasPrefix("dotpane:") {
                let parts = step.dropFirst(8).split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2, let file = model.dotfiles.first(where: { $0.agent.rawValue == parts[0] && $0.title == parts[1] }) {
                    show(DotfileDetail(file: file), model: model, size: NSSize(width: 900, height: 800))
                }
            } else if step.hasPrefix("project:"), let p = model.projects.first(where: { $0.name == step.dropFirst(8) }) {
                model.sheet = nil
                model.selection = .project(p.id)
            }
        }
    }

    private static var extraWindows: [NSWindow] = []

    private static func show(_ view: some View, model: AppModel, size: NSSize) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: NavigationStack { view }.environment(model))
        window.orderFront(nil)
        extraWindows.append(window)
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let root = window.contentView else { return }
        // Composite every leaf-ish view's own drawing into one image, in window coordinates.
        let scale = window.backingScaleFactor
        let size = root.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        draw(root, in: root, rep: rep)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func draw(_ view: NSView, in root: NSView, rep: NSBitmapImageRep) {
        guard !view.isHidden, view.bounds.width > 0, view.bounds.height > 0 else { return }
        if !(view is NSVisualEffectView) {
            let frame = view.convert(view.bounds, to: root)
            if let sub = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: sub)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                sub.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
            return
        }
        for child in view.subviews { draw(child, in: root, rep: rep) }
    }
}
#endif
