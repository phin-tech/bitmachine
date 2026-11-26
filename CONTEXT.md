# BitMachine

A Mac music player in the classic skinnable-desktop-player tradition that plays Apple Music, local audio files and self-hosted music servers.

## Language

### Sources

**Source**:
Where a Track's audio comes from: Apple Music, a Local File or a Server.
_Avoid_: provider, backend, service

**Apple Music Track**:
A Track whose audio is streamed from Apple Music, from the catalog or the user's Apple Music library.
_Avoid_: song, catalog item

**Local File**:
A Track whose audio is an audio file on the Mac's disk.
_Avoid_: MP3, file track, local song

**Music Folder**:
A folder the user has given BitMachine, whose audio files become Local Files that BitMachine knows by their tags.
_Avoid_: watch folder, library folder, root

**Server**:
A Subsonic-compatible music server, such as Navidrome, that the user has signed in to.
_Avoid_: Navidrome (as a generic term), remote library, instance

**Server Track**:
A Track whose audio is streamed from a Server.
_Avoid_: remote track, stream

**Track**:
One playable piece of audio from any Source.
_Avoid_: song, item, media

**Unavailable Track**:
A Track in the Playlist that its Source can't play right now. It keeps its place and becomes playable again when the cause goes away.
_Avoid_: broken track, missing track, dead entry

**Apple Music Catalog**:
Everything Apple Music offers to stream, whether or not the user has added it.
_Avoid_: store, Apple Music (when the catalog is meant)

**Apple Music Library**:
The albums, songs and Apple Music Playlists the user has added to their Apple Music account.
_Avoid_: library (unqualified), my music

### Playlists

**Playlist**:
BitMachine's own ordered list of Tracks, from any mix of Sources, that sets what plays next.
_Avoid_: queue, up next, list

**Apple Music Playlist**:
A playlist that lives in the user's Apple Music library. Opening one copies its Tracks into the Playlist, and later edits to the Playlist never change it.
_Avoid_: playlist (unqualified), library playlist

**Server Playlist**:
A playlist that lives on a Server. Opening one copies its Tracks into the Playlist, and saving it back replaces its contents with that Server's Tracks from the Playlist.
_Avoid_: remote playlist, playlist (unqualified)

**Playlist File**:
A Playlist saved to disk by BitMachine, whose entries can be Tracks from any Source.
_Avoid_: m3u, saved playlist

### Appearance

**Skin**:
A classic `.wsz` package of bitmaps and text files that sets how every BitMachine window looks.
_Avoid_: theme, appearance, wsz

**Default Skin**:
BitMachine's own original Skin, used when the user hasn't chosen another. It is in the same format as every other Skin.
_Avoid_: base skin, built-in theme

### Windows

**Main Window**:
The skinned window with the transport controls, time display, track title and visualizer.
_Avoid_: player, main view

**Equalizer Window**:
The skinned window with the preamp and band sliders.
_Avoid_: EQ panel

**Playlist Window**:
The skinned window that shows and edits the Playlist. It is a view of the Playlist, not the Playlist itself.
_Avoid_: playlist (when the window is meant), queue view

**Library Window**:
The window for finding Tracks to add to the Playlist: it searches the Apple Music Catalog and browses the Apple Music Library and Local Files. It follows the Skin's colors, but its layout is BitMachine's own.
_Avoid_: media library, browser, library (unqualified)

**Dock**:
A group of player windows snapped edge to edge that move together.
_Avoid_: group, cluster, stack

**Windowshade**:
A player window collapsed to a thin strip that keeps its essential controls.
_Avoid_: mini mode, collapsed, compact

**Double Size**:
A mode that draws every player window at twice its Skin's pixel size.
_Avoid_: zoom, 2x, retina mode
