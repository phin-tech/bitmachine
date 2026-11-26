# Spike: can a process tap hear Apple Music?

**Yes.** On macOS 27.0, with `ApplicationMusicPlayer` playing Apple Music, a Core Audio process tap on `com.apple.MediaPlayer.RemotePlayerService` gets real audio. A tap on BitMachine's own process gets none, because MusicKit plays its audio in that separate system process. The Apple Music visualizer can be real. The EQ stays bypassed for Apple Music, since a tap can only listen.

Run 2026-11-26. TapSpike was signed with Developer ID and the hardened runtime, with the `BitMachine` Developer ID provisioning profile embedded, under bundle `tech.phin.bitmachine`. Logs: `control-run.log`, `applemusic-devid-run.log` (token failure), `applemusic-profile-run.log` and `applemusic-noprofile-run.log`.

| Run | What played | Tap target | Result |
| --- | --- | --- | --- |
| No System Audio Recording permission | 440 Hz tone at −12 dBFS, in-app | own pid / global | callbacks arrive, all zeros |
| No System Audio Recording permission | same tone, played by `afplay` | afplay pid / global | callbacks arrive, all zeros |
| Permission granted (control) | 440 Hz tone, in-app | own pid | peak −23.8, rms −27.1 dBFS |
| Permission granted (control) | 440 Hz tone, `afplay` | afplay pid | peak −23.7, rms −27.1 dBFS |
| Permission granted | Apple Music library song (quiet solo violin) | own pid | no IO at all (0 callbacks) |
| Permission granted | same | `com.apple.MediaPlayer.RemotePlayerService` | **peak −34.1, rms −49.2 dBFS** |
| Permission granted | same | global | peak −28.1, rms −42.0 dBFS |
| Permission granted, no profile | Daft Punk, "One More Time" (catalog) | own pid | no IO at all |
| Permission granted, no profile | same | `RemotePlayerService` | **peak −15.1, rms −35.1 dBFS** |
| Permission granted, no profile | same | global | peak −14.7, rms −34.9 dBFS |

## What this means for BitMachine

- **The tap target is `RemotePlayerService`, not BitMachine.** It's launched for our app, and the HAL lists it as running output once playback starts. Look it up after `play()`, not before.
- **Without permission, a tap fails silently.** The tap and its callbacks look normal but carry zeros. BitMachine can't tell "permission missing" from "silence" by the audio alone, so it has to check the permission state itself and explain the System Audio Recording prompt.
- **Tapped levels are about 12 dB under the source.** The −12 dBFS tone came back at about −24 dBFS peak, probably from the stereo mixdown or gain. The visualizer should normalize, not assume full scale.

## Setup MusicKit needed (Developer ID)

1. The App ID `tech.phin.bitmachine`, with **MusicKit** ticked on the App Services tab. Until Apple's token service picks this up, MusicKit fails with `.developerTokenRequestFailed`.
2. `NSAppleMusicUsageDescription` and `NSAudioCaptureUsageDescription` in Info.plist.

**No provisioning profile is needed.** A Developer ID build signed for team J35P7AJDN7, with no embedded profile and no application-identifier entitlement, got tokens and played catalog music. The earlier token failures came before the App ID's MusicKit service had propagated, not from a missing profile. `BitMachine-DeveloperID.provisionprofile` is kept in case a later macOS starts requiring it.

## A MusicKit hiccup along the way

For a few minutes right after the MusicKit service was set up, `MusicCatalogSearchRequest.response()` threw `DecodingError.dataCorrupted` ("Unexpected end of file"), while a raw `MusicDataRequest` for the same search returned HTTP 200 with valid JSON. Minutes later the same request worked. It looks like part of the same propagation. BitMachine's catalog search should still treat this error as retryable.

## Not tested

- The permission-revoked run after a grant. The first control run, before the grant, already shows how denial looks.
- Long-running taps across track changes.

## Muted when tapped (2026-11-26)

With `muteBehavior = .mutedWhenTapped` on `RemotePlayerService`, the tap received the music at full level for 6 seconds (peak −14.7, rms −35.0 dBFS, 555 callbacks), and MusicKit kept playing normally (from 4 s to 10 s). Log: `applemusic-muted-run.log`. Confirmed by ear (through Jump Desktop's virtual output device): the music played, then went silent while the tap kept receiving it.

So BitMachine can play Apple Music's audio through its own AVAudioEngine, which gives Apple Music real volume, balance and EQ, not just a visualizer. MusicKit's player has no volume control of its own (checked in the macOS 27.2 SDK).
