import CoreGraphics
import Testing
@testable import BitMachineKit

@Suite struct PlaylistWindowTests {
    @Test func sizesSnapToTheTiles() {
        #expect(PlaylistLayout.snapped(CGSize(width: 100, height: 50)) == CGSize(width: 275, height: 116))
        #expect(PlaylistLayout.snapped(CGSize(width: 312, height: 260)) == CGSize(width: 300, height: 261))
    }

    @Test func listGeometry() {
        let size = PlaylistLayout.defaultSize
        #expect(PlaylistLayout.list(size) == CGRect(x: 12, y: 23, width: 243, height: 168))
        #expect(PlaylistLayout.visibleRows(size) == 12)
        #expect(PlaylistLayout.row(at: 23, size: size, scroll: 0) == 0)
        #expect(PlaylistLayout.row(at: 23 + 13 * 3 + 1, size: size, scroll: 5) == 8)
        #expect(PlaylistLayout.row(at: 10, size: size, scroll: 0) == nil)
    }

    @Test func scrolling() {
        let size = PlaylistLayout.defaultSize
        #expect(PlaylistLayout.maxScroll(rows: 5, size: size) == 0)
        #expect(PlaylistLayout.maxScroll(rows: 30, size: size) == 18)
        #expect(PlaylistLayout.handleY(scroll: 0, rows: 30, size: size) == 20)
        #expect(Int(PlaylistLayout.handleY(scroll: 18, rows: 30, size: size)) == 176)  // the track ends 18 above the bottom
        #expect(PlaylistLayout.scroll(atY: 1000, rows: 30, size: size) == 18)
    }

    @Test func hitTesting() {
        let size = PlaylistLayout.defaultSize
        #expect(PlaylistLayout.control(at: CGPoint(x: 20, y: 210), size: size) == .menu(.add))
        #expect(PlaylistLayout.control(at: CGPoint(x: 240, y: 210), size: size) == .menu(.list))
        #expect(PlaylistLayout.control(at: CGPoint(x: 140, y: 220), size: size) == .transport(.play))
        #expect(PlaylistLayout.control(at: CGPoint(x: 268, y: 7), size: size) == .close)
        #expect(PlaylistLayout.control(at: CGPoint(x: 100, y: 60), size: size) == .list)
        #expect(PlaylistLayout.control(at: CGPoint(x: 263, y: 60), size: size) == .scrollbar)
        #expect(PlaylistLayout.control(at: CGPoint(x: 270, y: 228), size: size) == .resize)
        #expect(PlaylistLayout.control(at: CGPoint(x: 100, y: 8), size: size) == .titleBar)
    }

    @Test func aWideWindowTilesItsTopAndBottom() {
        var state = PlaylistWindowState()
        state.size = CGSize(width: 350, height: 232)
        let placements = PlaylistLayout.placements(for: state)
        #expect(placements.filter { $0.sprite == PlaylistSprites.bottomTile }.map(\.origin.x) == [125, 150, 175])
        #expect(placements.contains { $0.sprite == PlaylistSprites.bottomRight && $0.origin.x == 200 })
        #expect(placements.filter { $0.sprite == PlaylistSprites.leftTile }.count == 6)
    }

    @Test func clock() {
        #expect(PlaylistLayout.clock(75) == "1:15")
        #expect(PlaylistLayout.clock(3725) == "1:02:05")
    }

    @Test func rendersAtItsSize() throws {
        var state = PlaylistWindowState()
        state.size = CGSize(width: 300, height: 261)
        state.runningTime = "1:15/12:00"
        let image = try #require(SkinRenderer.renderPlaylistWindow(state, skin: PlaceholderSkin.make()))
        #expect(image.width == 300 && image.height == 261)
    }
}
