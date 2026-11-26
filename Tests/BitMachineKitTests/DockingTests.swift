import CoreGraphics
import Testing
@testable import BitMachineKit

/// A window by its top left, y up as on screen: `window(0, 500, 275, 116)` has its top at 500.
private func window(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: top - h, width: w, height: h)
}

@Suite struct DockingTests {
    let main = window(100, 800, 275, 116)

    @Test func windowsTouchEdgeToEdge() {
        let below = window(100, 684, 275, 116)
        let beside = window(375, 800, 275, 116)
        let apart = window(100, 600, 275, 116)
        let corner = window(375, 684, 275, 116)  // only corners meet
        #expect(Docking.touch(main, below))
        #expect(Docking.touch(main, beside))
        #expect(!Docking.touch(main, apart))
        #expect(!Docking.touch(main, corner))
    }

    @Test func aDockIsEverythingConnected() {
        let eq = window(100, 684, 275, 116)
        let playlist = window(100, 568, 275, 232)
        let away = window(900, 800, 275, 116)
        #expect(Docking.group(of: 0, in: [main, eq, playlist, away]) == [0, 1, 2])
        #expect(Docking.group(of: 3, in: [main, eq, playlist, away]) == [3])
    }

    @Test func aDraggedWindowSnapsUnderAnother() {
        let dragged = window(108, 690, 275, 116)  // 8 right, 6 too high
        let snapped = Docking.snap(dragged, to: [main], screen: nil)
        #expect(snapped == window(100, 684, 275, 116))
    }

    @Test func farAwayDoesNotSnap() {
        let dragged = window(100, 600, 275, 116)
        #expect(Docking.snap(dragged, to: [main], screen: nil) == dragged)
    }

    @Test func snapsToTheScreenEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let dragged = window(9, 300, 275, 116)
        #expect(Docking.snap(dragged, to: [], screen: screen).minX == 0)
    }

    @Test func windowsHangingUnderFollowAResize() {
        let eq = window(100, 684, 275, 116)
        let playlist = window(100, 568, 275, 232)
        let beside = window(375, 800, 275, 116)
        #expect(Docking.hanging(under: 0, in: [main, eq, playlist, beside]) == [1, 2])
        #expect(Docking.hanging(under: 1, in: [main, eq, playlist, beside]) == [2])
    }
}
