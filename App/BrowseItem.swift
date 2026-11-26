/// An artist, album or playlist in a list to pick from: a Server's, or the Apple Music Library's.
struct BrowseItem: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    var year: Int?
    var count: Int?

    /// "Album (1999)" when its year is known.
    var label: String { year.map { "\(name) (\($0))" } ?? name }
}
