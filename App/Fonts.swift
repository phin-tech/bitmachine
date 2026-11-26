import AppKit
import CoreText
import SwiftUI

/// The fonts BitMachine brings with it, and where it uses them.
enum Fonts {
    /// Intel One Mono (SIL Open Font License 1.1; THIRD_PARTY_NOTICES.md), bundled unmodified.
    static let intelOneMono = "Intel One Mono"
    static let intelOneMonoRegular = "IntelOneMono-Regular"

    /// Settings: draw the Main Window's title in Intel One Mono instead of the Skin's pixel font.
    static let titleKey = "titleInIntelOneMono"
    /// Settings: lists (Library, Playlist) in the Skin's Playlist font (pledit.txt) instead of Intel One Mono.
    static let listsInSkinFontKey = "listsInSkinFont"

    static func registerBundled() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? []
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }

    /// The font for lists: Intel One Mono, or the Skin's Playlist font if it's asked for and installed.
    static func list(skinFont: String, size: CGFloat) -> Font {
        if UserDefaults.standard.bool(forKey: listsInSkinFontKey), NSFont(name: skinFont, size: size) != nil {
            return .custom(skinFont, size: size)
        }
        return .custom(intelOneMono, size: size)
    }
}
