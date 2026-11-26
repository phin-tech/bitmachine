import SwiftUI

struct SettingsView: View {
    #if !APP_STORE
    @AppStorage(UpdateChecker.betaKey) private var betaUpdates = UpdateChecker.runningBeta
    #endif

    @AppStorage(Fonts.titleKey) private var titleInIntelOneMono = false
    @AppStorage(Fonts.listsInSkinFontKey) private var listsInSkinFont = false

    var body: some View {
        Form {
            Section {
                Toggle("Song title in Intel One Mono", isOn: $titleInIntelOneMono)
                Toggle("Lists in the skin's own font", isOn: $listsInSkinFont)
            } header: {
                Text("Fonts")
            } footer: {
                Text("The Main Window's title is drawn in the skin's pixel font unless you choose Intel One Mono, which "
                    + "is sharper and has every character. Lists use Intel One Mono unless the skin names a font you "
                    + "have installed and you choose it here.")
                    .foregroundStyle(.secondary)
            }
            #if APP_STORE
            Section("General") {
                Text("Nothing to set yet.").foregroundStyle(.secondary)
            }
            #else
            Section {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { UpdateChecker.shared.automaticChecks },
                    set: { UpdateChecker.shared.automaticChecks = $0 }))
                Toggle("Get beta versions", isOn: $betaUpdates)
                Button("Check Now") { UpdateChecker.shared.checkForUpdates() }
            } header: {
                Text("Updates")
            } footer: {
                Text("Once a day, BitMachine asks GitHub for a newer release, and offers to install it and relaunch. "
                    + "Betas come out before a release and may have rough edges; when the release ships, you move on to it.")
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
