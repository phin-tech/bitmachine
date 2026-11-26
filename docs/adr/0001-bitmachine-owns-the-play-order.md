# BitMachine owns the play order

The Playlist mixes Apple Music Tracks, Local Files and Server Tracks, but MusicKit's `ApplicationMusicPlayer` queue can only hold Apple Music items. So BitMachine keeps the Playlist as its own model, and gives one Track at a time to the engine for its Source: MusicKit for Apple Music, AVAudioEngine for everything else. MusicKit's queue never holds more than the current Apple Music Track, plus the next one when that is also from Apple Music. We gave up gapless playback and crossfades across Sources, and accept a short gap when the Source changes, so that next, previous, shuffle, repeat and the Playlist Window all follow one source of truth.

## Considered Options

- **Hand runs of consecutive Apple Music Tracks to MusicKit's queue.** Transitions within a run are smoother, but there would be two sources of truth for what plays next, and shuffle and reordering would have to resync them.
- **Remote-control Music.app.** This would leave BitMachine a skin over another app, with no control of the queue, and no way to mix in Local Files or Server Tracks.
