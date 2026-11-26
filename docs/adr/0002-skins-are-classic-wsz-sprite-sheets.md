# Skins are classic `.wsz` sprite sheets, the Default Skin included

The Main, Equalizer and Playlist Windows are drawn only from a classic `.wsz` Skin: bitmap sprite sheets plus `viscolor.txt`, `pledit.txt` and `region.txt`. BitMachine's own original Default Skin is just another `.wsz`, not a hand-built UI. We want the thousands of existing classic skins to work, and we didn't want two renderers (a native UI and a skin engine) that drift apart. The cost is that the player windows are custom borderless AppKit windows drawn in pixels, not SwiftUI layouts. The Library Window, which classic skins don't describe, takes only the Skin's colors.

BitMachine never bundles Winamp's base skin, or uses the Winamp name or logo.
