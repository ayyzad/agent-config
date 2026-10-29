import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also needed when launched with `swift run` outside an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AgentConfigApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Agent Config", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 920, minHeight: 580)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // Pick up changes Claude Code made while the app was in the background.
                    if model.sheet == nil { model.reload() }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Rule…") { model.requestAddRule() }
                    .keyboardShortcut("n")
                Button("Add Project Folder…") { model.addProjectFolder() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Button("Reload Files") { model.reload() }
                    .keyboardShortcut("r")
            }
        }
    }
}
