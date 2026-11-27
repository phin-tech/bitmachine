import SwiftUI

@main
struct BitMachineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
        DebugDriver.startIfAsked()   // only when launched with DEBUG_SOCKET (`just debug-app`)
        #endif
    }

    var body: some Scene {
        // The player windows are AppKit windows drawn from the Skin (AppDelegate); SwiftUI keeps Settings and the menus.
        Settings {
            SettingsView()
        }
        .commands {
            updateCommands
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Open Skin…") { AppDelegate.shared.openSkin(nil) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Use Default Skin") { AppDelegate.shared.useDefaultSkin(nil) }
                Divider()
                Button("Library…") { AppDelegate.shared.showLibrary(nil) }
                    .keyboardShortcut("l", modifiers: .command)
            }
            CommandGroup(before: .toolbar) {
                Button("Double Size") { AppDelegate.shared.toggleDoubleSize(nil) }
                    .keyboardShortcut("d", modifiers: .control)
                Button("Windowshade") { AppDelegate.shared.toggleWindowshade(nil) }
                    .keyboardShortcut("w", modifiers: .control)
                Button("Equalizer") { AppDelegate.shared.toggleEqualizer(nil) }
                    .keyboardShortcut("g", modifiers: .option)
                Button("Playlist") { AppDelegate.shared.togglePlaylist(nil) }
                    .keyboardShortcut("e", modifiers: .option)
                Button("Radio") { AppDelegate.shared.toggleRadio(nil) }
                    .keyboardShortcut("r", modifiers: .option)
                Divider()
                Button("Speakers…") { AppDelegate.shared.showSpeakers(nil) }
                Divider()
            }
        }
    }

    @CommandsBuilder private var updateCommands: some Commands {
        #if !APP_STORE
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdateChecker.shared.checkForUpdates() }
            Button("Permissions…") { AppDelegate.shared.showPermissions(nil) }
        }
        #endif
    }
}
