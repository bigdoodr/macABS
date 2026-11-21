//
//  LogWindow.swift
//
//  The server log in its own window. It used to be a sheet attached to the
//  menu bar popover, which came back every time the menu was reopened
//  (issue #1). A regular window has its own lifetime and close button.
//

import AppKit
import SwiftUI

struct LogWindow: View {
    @EnvironmentObject private var serverManager: ServerProcessManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(serverManager.logLines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(serverManager.logLines.joined(separator: "\n"), forType: .string)
                }
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 260)
    }
}

@MainActor
final class LogWindowController {
    static let shared = LogWindowController()
    private var window: NSWindow?

    func show(server: ServerProcessManager) {
        if window == nil {
            let hosting = NSHostingController(rootView: LogWindow().environmentObject(server))
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "Audiobookshelf Server Log"
            newWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            newWindow.setContentSize(NSSize(width: 640, height: 420))
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        // The app is a menu bar agent, so bring it forward explicitly or the
        // window can open behind other apps.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
