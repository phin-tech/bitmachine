import AppKit
import BitMachineKit

/// Audio files and folders dropped from the Finder onto a player window.
@MainActor
enum FileDrop {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL]

    static func urls(_ info: NSDraggingInfo) -> [URL] {
        let read = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true])
        return (read as? [URL]) ?? []
    }

    /// Copy when anything dropped could hold music: an audio file or a folder.
    static func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        urls(info).contains { $0.hasDirectoryPath || LocalFiles.isAudio($0) } ? .copy : []
    }
}
