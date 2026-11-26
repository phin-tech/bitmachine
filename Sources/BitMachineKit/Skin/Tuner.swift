import CoreGraphics

/// What the tuner shows while a Station plays: its Frequency, how full the buffer is, and which preset it's on.
public struct TunerReadout: Equatable, Sendable {
    public var frequency: Frequency
    /// 0...1: the buffer, shown as signal bars.
    public var signal: Double
    /// 1...6, when the Station is on a preset button.
    public var preset: Int?

    public init(frequency: Frequency, signal: Double = 0, preset: Int? = nil) {
        self.frequency = frequency
        self.signal = signal
        self.preset = preset
    }

    /// Signal bars lit, 0...4.
    public var bars: Int { Int((min(max(signal, 0), 1) * 4).rounded(.up)) }
}

/// The tuner face drawn in the Main Window's visualizer area, in the Skin's visualizer colours: seven-segment digits
/// (unlit segments faintly showing, as on a real display), FM and ST, the preset and the signal bars.
enum TunerFace {
    /// Seven-segment patterns: a (top), b (top right), c (bottom right), d (bottom), e (bottom left), f (top left),
    /// g (middle).
    static let segments: [Character: Set<Character>] = [
        "0": ["a", "b", "c", "d", "e", "f"], "1": ["b", "c"], "2": ["a", "b", "g", "e", "d"],
        "3": ["a", "b", "g", "c", "d"], "4": ["f", "g", "b", "c"], "5": ["a", "f", "g", "c", "d"],
        "6": ["a", "f", "g", "e", "c", "d"], "7": ["a", "b", "c"], "8": ["a", "b", "c", "d", "e", "f", "g"],
        "9": ["a", "b", "c", "d", "f", "g"], " ": [],
    ]

    /// A 3×5 pixel font for the little labels, each row three bits, left to right.
    static let tiny: [Character: [UInt8]] = [
        "F": [0b111, 0b100, 0b110, 0b100, 0b100], "M": [0b101, 0b111, 0b111, 0b101, 0b101],
        "S": [0b111, 0b100, 0b111, 0b001, 0b111], "T": [0b111, 0b010, 0b010, 0b010, 0b010],
        "P": [0b110, 0b101, 0b110, 0b100, 0b100],
        "1": [0b010, 0b110, 0b010, 0b010, 0b111], "2": [0b110, 0b001, 0b010, 0b100, 0b111],
        "3": [0b110, 0b001, 0b010, 0b001, 0b110], "4": [0b101, 0b101, 0b111, 0b001, 0b001],
        "5": [0b111, 0b100, 0b110, 0b001, 0b110], "6": [0b011, 0b100, 0b111, 0b101, 0b111],
    ]

    /// The pixels to light, and the ghosts of the unlit segments, in the 76×16 area from its top left.
    struct Pixels {
        var lit: [CGRect] = []
        var ghost: [CGRect] = []
    }

    static func pixels(_ tuner: TunerReadout, stereo: Bool) -> Pixels {
        var p = Pixels()
        func label(_ text: String, x: CGFloat, y: CGFloat, on: Bool) {
            for (i, c) in text.enumerated() {
                for (row, bits) in (tiny[c] ?? []).enumerated() {
                    for col in 0 ..< 3 where bits & (0b100 >> col) != 0 {
                        let r = CGRect(x: x + CGFloat(i * 4 + col), y: y + CGFloat(row), width: 1, height: 1)
                        if on { p.lit.append(r) } else { p.ghost.append(r) }
                    }
                }
            }
        }
        label("FM", x: 0, y: 1, on: true)
        label("ST", x: 0, y: 9, on: stereo)

        // "107.9" or " 94.3": three digit cells, a point, one more.
        let text = tuner.frequency.description
        let whole = String(text.split(separator: ".")[0])
        let digits = Array(String(repeating: " ", count: max(3 - whole.count, 0)) + whole) + [text.last ?? "0"]
        for (i, digit) in digits.enumerated() {
            let x = CGFloat(i < 3 ? 10 + i * 9 : 41)
            let on = segments[digit] ?? []
            for (segment, rect) in cell(x: x) {
                // A blank leading digit stays dark, ghosts and all, as on a real display.
                if on.contains(segment) { p.lit.append(rect) } else if digit != " " { p.ghost.append(rect) }
            }
        }
        p.lit.append(CGRect(x: 37, y: 13, width: 2, height: 2))

        if let preset = tuner.preset { label("P\(preset)", x: 52, y: 1, on: true) }
        for i in 0 ..< 4 {
            let height = CGFloat(3 + i * 3)
            let r = CGRect(x: CGFloat(63 + i * 3), y: 15 - height, width: 2, height: height)
            if i < tuner.bars { p.lit.append(r) } else { p.ghost.append(r) }
        }
        return p
    }

    /// One 7×13 digit cell's segments at `x`, one pixel thick.
    static func cell(x: CGFloat) -> [(Character, CGRect)] {
        [
            ("a", CGRect(x: x + 1, y: 1, width: 5, height: 1)),
            ("b", CGRect(x: x + 6, y: 2, width: 1, height: 5)),
            ("c", CGRect(x: x + 6, y: 8, width: 1, height: 5)),
            ("d", CGRect(x: x + 1, y: 13, width: 5, height: 1)),
            ("e", CGRect(x: x, y: 8, width: 1, height: 5)),
            ("f", CGRect(x: x, y: 2, width: 1, height: 5)),
            ("g", CGRect(x: x + 1, y: 7, width: 5, height: 1)),
        ]
    }
}
