# Remote Control: BitMachine's own protocol, paired with a code

A Controller works a Host over the local network (`App/Remote.swift`, `Sources/BitMachineKit/Remote`). The Host advertises itself with Bonjour (`_bitmachine._tcp`). The two exchange length-prefixed JSON messages over TCP. The Controller sends the same commands the Host's own windows give its Player, and the Host sends back its Playlist, equalizer and Main Window status as they change.

**Pairing:**
- A Controller pairs the first time it connects.
- The two do a Curve25519 key agreement and salt the result with a four-digit Pairing Code that the Host shows and the user types on the Controller. Each side proves it got the same key with an HMAC, so the key never crosses the network.
- The code allows one try and expires after two minutes, and only one pairing runs at a time.

**Later connections:**
- Both sides prove they hold the Pairing Key by HMAC over fresh nonces.
- From the result they derive that session's key, and every message after the handshake is sealed with ChaCha20-Poly1305.
- Each side keeps its Pairing Keys in the login Keychain.

We chose this over the alternatives:
- **Unauthenticated control:** anyone on the Wi-Fi could take over the player.
- **TLS with a pre-shared key:** Network.framework supports it, but a pre-shared key per paired Mac needs a key-selection hook that is hard to get right. Separate listeners for pairing and connecting would complicate discovery.
- **Mirroring the Host's windows:** too much.

The Controller shows the Host's state in its own windows instead, with its own Skin.

## Consequences

- **Active interception:** a passive listener on the network learns nothing, but someone deliberately intercepting the pairing could still try all ten thousand codes offline. That is acceptable for a home network, and Settings says so.
- **Local Files stay on their Mac:**
  - A Controller can't send its Local Files to the Host. They are left out, with a notice.
  - A Host ignores Local File Tracks from a Controller, so a Controller can't name files on the Host.
- **Server Tracks:** these name a Server account, and play on the Host only if it has a Server account of that name.
- **Mixed versions:** messages either side doesn't understand are skipped, so a newer copy can talk to an older one. A protocol version in the greeting refuses copies that can no longer work together.
- **Permission:** each Mac asks once to use the local network (`NSLocalNetworkUsageDescription`, `NSBonjourServices`).
