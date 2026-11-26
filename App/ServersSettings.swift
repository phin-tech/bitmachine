import BitMachineKit
import SwiftUI

/// Settings ▸ Servers: the Servers BitMachine is signed in to, and signing in to another.
struct ServersSettings: View {
    @ObservedObject var servers: Servers
    @State private var adding = false
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var problem: String?
    @State private var signingIn = false

    var body: some View {
        Section {
            ForEach(servers.accounts) { account in
                HStack {
                    VStack(alignment: .leading) {
                        Text(account.name)
                        Text("\(account.username) at \(account.url.absoluteString)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { servers.remove(account.id) }
                }
            }
            if adding {
                TextField("Name", text: $name, prompt: Text("Home"))
                TextField("Address", text: $address, prompt: Text(verbatim: "https://music.example.com"))
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
                HStack {
                    if let problem { Text(problem).foregroundStyle(.red).font(.caption) }
                    Spacer()
                    if signingIn { ProgressView().controlSize(.small) }
                    Button("Cancel") { reset() }
                    Button("Sign In") { signIn() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(signingIn || address.isEmpty || username.isEmpty || password.isEmpty)
                }
            } else {
                Button("Add a Server…") { adding = true }
            }
        } header: {
            Text("Servers")
        } footer: {
            Text("Navidrome, or any Subsonic-compatible server. BitMachine signs in with a token rather than sending your "
                + "password, which it keeps in your Keychain. Songs you play are kept for a while, so they start at once "
                + "and play when the server can't be reached.")
                .foregroundStyle(.secondary)
        }
    }

    private func reset() {
        adding = false
        name = ""; address = ""; username = ""; password = ""; problem = nil
    }

    private func signIn() {
        var text = address.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { problem = "That address doesn't look right"; return }
        let account = ServerAccount(name: name.isEmpty ? (url.host ?? "Server") : name, url: url,
                                    username: username.trimmingCharacters(in: .whitespaces))
        signingIn = true
        problem = nil
        Task {
            defer { signingIn = false }
            do {
                try await servers.add(account, password: password)
                reset()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
