import AppKit
import SwiftUI

/// Control Another BitMachine: the other Macs on the network running BitMachine with sharing on, to connect to.
@MainActor
final class RemoteWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let controller: RemoteController

    init(controller: RemoteController) {
        self.controller = controller
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 380, height: 300),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Control Another BitMachine"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RemoteView(controller: controller))
        window.delegate = self
        window.center()
        controller.window = window
    }

    func show() {
        controller.startBrowsing()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_: Notification) { controller.stopBrowsing() }
}

struct RemoteView: View {
    @ObservedObject var controller: RemoteController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let host = controller.host, controller.isControlling {
                Text("BitMachine's windows are working \(host). Its music plays there; your own Playlist is "
                    + "waiting here for when you stop.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Stop Controlling \(host)") { controller.disconnect() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Text("Macs on this network with BitMachine open and “Allow other Macs to control this BitMachine” "
                    + "turned on in its Settings:")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
                if controller.found.isEmpty {
                    Text("Looking…").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(controller.found) { host in
                                HStack {
                                    Image(systemName: "hifispeaker")
                                    Text(host.name)
                                    Spacer()
                                    Button("Control") { controller.connect(to: host) }
                                        .disabled(controller.host != nil)
                                }
                            }
                        }
                    }
                }
            }
            if !controller.status.isEmpty, !controller.isControlling {
                Text(controller.status).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(minWidth: 340, minHeight: 200)
    }
}
