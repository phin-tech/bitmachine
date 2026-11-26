# Apple Music's audio goes through BitMachine's own engine

MusicKit plays Apple Music in a system process (`com.apple.MediaPlayer.RemotePlayerService`), and its player has no volume control, so Apple Music Tracks would otherwise get no volume, balance or EQ from BitMachine, only a visualizer. Instead, BitMachine taps that process with Core Audio's *muted when tapped* mode: macOS silences the process's own output and hands the audio to BitMachine, which plays it through the same AVAudioEngine as Local Files and Server Tracks. That gives every Source the same volume, balance, EQ and visualizer. The spike proved it on macOS 27 (`spikes/tap/RESULTS.md`).

This replaces the "honest split" for Apple Music when the user grants the System Audio Recording permission. Without the permission, BitMachine falls back to the split: Apple Music plays unrouted, and the EQ and volume are shown as bypassed.

## Consequences

- BitMachine asks for System Audio Recording, and has to explain the prompt. A missing permission shows up as silence, not as an error, so BitMachine checks the permission itself.
- The tap's target is found after playback starts, and it changes whenever MusicKit restarts its process.
- The rerouting adds a little latency, and macOS may close this route in a later release; the fallback keeps Apple Music playable.
- This is undocumented use of a public API. It is fine outside the Mac App Store, and it may not pass App Review.
