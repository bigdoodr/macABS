//
//  AudiobookshelfMenuApp.swift
//
//  App entry point. Uses SwiftUI's MenuBarExtra scene (macOS 13+) -- this
//  is the whole app; there's no separate window unless the user opens one
//  (log viewer, embedded web view) from the menu.
//
//  XCODE SETUP NOTES:
//  1. New Project > macOS > App. Interface: SwiftUI. Uncheck Core Data / Tests.
//  2. In the target's Info tab, add "Application is agent (UIElement)" = YES.
//     This hides the app from the Dock and Cmd-Tab -- it's a pure menu bar app.
//  3. Deployment target: macOS 13.0 or later (required for MenuBarExtra
//     and the modern SMAppService launch-at-login API used elsewhere).
//  4. Drop this file, ServerProcessManager.swift, and MenuContentView.swift
//     into the project, replacing the default ContentView.swift/App.swift.
//

import SwiftUI

@main
struct AudiobookshelfMenuApp: App {
    // Owns the server process for the lifetime of the app. @StateObject
    // (not @ObservedObject) so it's created exactly once here at the root.
    @StateObject private var serverManager: ServerProcessManager
    // Checks for newer Audiobookshelf payloads and applies them
    // automatically (see ABSUpdater.swift).
    @StateObject private var updater: ABSUpdater

    init() {
        let manager = ServerProcessManager()
        _serverManager = StateObject(wrappedValue: manager)
        let updater = ABSUpdater(server: manager)
        _updater = StateObject(wrappedValue: updater)
        updater.startAutomaticChecks()
        // "Start Server Automatically" preference -- fire this once at
        // launch, before the menu is ever opened, rather than from
        // MenuContentView (which can be recreated each time the menu
        // bar item is clicked).
        if manager.startServerAutomatically {
            manager.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(serverManager)
                .environmentObject(updater)
        } label: {
            // The menu bar icon itself. Swap for a custom asset later;
            // SF Symbols work fine as a placeholder and adapt to
            // light/dark menu bar automatically.
            Image(systemName: "headphones.dots")
        }
        .menuBarExtraStyle(.window) // gives a proper SwiftUI view, not a plain menu
    }
}
