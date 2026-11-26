import Foundation
import Testing
@testable import BeeCore

@Suite struct ListOrderTests {
    private struct Item: Identifiable, Equatable {
        let id: Int
        let name: String
    }

    private static let items = [
        Item(id: 1, name: "staging"), Item(id: 2, name: "API 10"), Item(id: 3, name: "Éclair"),
        Item(id: 4, name: "api 2"), Item(id: 5, name: "Zebra"), Item(id: 6, name: "staging"),
    ]

    private static func ids(_ items: [Item]?) -> [Int]? { items?.map(\.id) }

    @Test func aListIsShownAsArrangedOrByNameAsAPersonReadsIt() {
        #expect(Self.ids(ListOrder.manual.arranged(Self.items, name: \.name)) == [1, 2, 3, 4, 5, 6])
        // Capitals and accents count for nothing, numbers count as numbers; a tie keeps the order arranged.
        #expect(Self.ids(ListOrder.nameAscending.arranged(Self.items, name: \.name)) == [4, 2, 3, 1, 6, 5])
        #expect(Self.ids(ListOrder.nameDescending.arranged(Self.items, name: \.name)) == [5, 1, 6, 3, 2, 4])
        #expect(ListOrder.nameAscending.arranged([Item](), name: \.name).isEmpty)
    }

    @Test func aDroppedItemTakesThePlaceOfTheOneItLandsOn() {
        let manual = ListOrder.manual
        // Down the list it goes after the target, up the list before it: every place can be reached.
        #expect(Self.ids(manual.moving(1, toPlaceOf: 3, in: Self.items, name: \.name)) == [2, 3, 1, 4, 5, 6])
        #expect(Self.ids(manual.moving(5, toPlaceOf: 2, in: Self.items, name: \.name)) == [1, 5, 2, 3, 4, 6])
        #expect(Self.ids(manual.moving(1, toPlaceOf: 6, in: Self.items, name: \.name)) == [2, 3, 4, 5, 6, 1])
        #expect(Self.ids(manual.moving(6, toPlaceOf: 1, in: Self.items, name: \.name)) == [6, 1, 2, 3, 4, 5])
        // Nothing moves on itself, nor for an item that is not there.
        #expect(manual.moving(3, toPlaceOf: 3, in: Self.items, name: \.name) == nil)
        #expect(manual.moving(9, toPlaceOf: 3, in: Self.items, name: \.name) == nil)
        #expect(manual.moving(3, toPlaceOf: 9, in: Self.items, name: \.name) == nil)
    }

    @Test func aDraggedIdentifierTakesThePlaceOfTheOneUnderThePointer() {
        // What the sidebar does while the pointer goes: each row it passes gives its place.
        var order = ["a", "b", "c", "d"]
        for target in ["b", "c", "d"] { order = ListOrder.moving("a", toPlaceOf: target, in: order) ?? order }
        #expect(order == ["b", "c", "d", "a"])
        order = ListOrder.moving("a", toPlaceOf: "b", in: order) ?? order
        #expect(order == ["a", "b", "c", "d"])
        // Over itself, or over what is not there, nothing moves.
        #expect(ListOrder.moving("a", toPlaceOf: "a", in: order) == nil)
        #expect(ListOrder.moving("a", toPlaceOf: "z", in: order) == nil)
        #expect(ListOrder.moving("z", toPlaceOf: "a", in: order) == nil)
    }

    @Test func aMoveInAListSortedByNameStartsFromWhatIsShown() {
        // Shown A to Z: api 2, API 10, Éclair, staging, staging, Zebra. Zebra dropped on Éclair.
        let moved = ListOrder.nameAscending.moving(5, toPlaceOf: 3, in: Self.items, name: \.name)
        #expect(Self.ids(moved) == [4, 2, 5, 3, 1, 6])
        // It is the order arranged from then on: shown as it is.
        #expect(Self.ids(moved.map { ListOrder.manual.arranged($0, name: \.name) }) == [4, 2, 5, 3, 1, 6])
    }

    @Test func anItemMovesOnePlaceUpOrDownTheListAsShown() {
        #expect(Self.ids(ListOrder.manual.moving(3, by: -1, in: Self.items, name: \.name)) == [1, 3, 2, 4, 5, 6])
        #expect(Self.ids(ListOrder.manual.moving(3, by: 1, in: Self.items, name: \.name)) == [1, 2, 4, 3, 5, 6])
        #expect(ListOrder.manual.moving(1, by: -1, in: Self.items, name: \.name) == nil)
        #expect(ListOrder.manual.moving(6, by: 1, in: Self.items, name: \.name) == nil)
        // Sorted Z to A, Zebra is first and Éclair stands between staging and API 10.
        #expect(ListOrder.nameDescending.moving(5, by: -1, in: Self.items, name: \.name) == nil)
        #expect(Self.ids(ListOrder.nameDescending.moving(3, by: 1, in: Self.items, name: \.name)) == [5, 1, 6, 2, 3, 4])
    }

    @Test func aRequestOrAFolderGoesRightBeforeOrAfterAnother() throws {
        let a = RequestItem(name: "A"), b = RequestItem(name: "B"), c = RequestItem(name: "C"), d = RequestItem(name: "D")
        let inner = Folder(name: "Inner", items: [.request(d)])
        let folder = Folder(name: "F", items: [.request(c), .folder(inner)])
        let collection = Collection(name: "API", items: [.request(a), .request(b), .folder(folder)])
        #expect(collection.place(of: b.id)! == (nil, 1))
        #expect(collection.place(of: d.id)! == (inner.id, 0))
        #expect(collection.place(of: UUID()) == nil)

        // Down among the same: after the target, counted once it has left its place.
        #expect(collection.destination(of: a.id, beside: b.id, after: true)! == (nil, 1))
        #expect(collection.destination(of: a.id, beside: folder.id, after: false)! == (nil, 1))
        // Up among the same.
        #expect(collection.destination(of: folder.id, beside: a.id, after: false)! == (nil, 0))
        // Into another folder, beside what it holds.
        #expect(collection.destination(of: a.id, beside: c.id, after: false)! == (folder.id, 0))
        #expect(collection.destination(of: a.id, beside: d.id, after: true)! == (inner.id, 1))
        // Where it already stands, or on itself: nothing moves.
        #expect(collection.destination(of: a.id, beside: b.id, after: false) == nil)
        #expect(collection.destination(of: b.id, beside: a.id, after: true) == nil)
        #expect(collection.destination(of: a.id, beside: a.id, after: true) == nil)
        // A folder never goes inside itself or what it holds.
        #expect(collection.destination(of: folder.id, beside: c.id, after: false) == nil)
        #expect(collection.destination(of: folder.id, beside: d.id, after: true) == nil)
        // A request from elsewhere (another collection, a draft) takes the target's place.
        #expect(collection.destination(of: UUID(), beside: b.id, after: false)! == (nil, 1))
    }

    @Test func aMoveInACollectionSortedByNameStartsFromWhatIsShown() throws {
        let path = RequestItem(name: "Get by path variable"), json = RequestItem(name: "Send JSON")
        let teapot = RequestItem(name: "Teapot"), token = RequestItem(name: "Get a token")
        let inner = Folder(name: "Inner")
        let flow = Folder(name: "Token flow", items: [.request(token), .folder(inner)])
        let collection = Collection(name: "API", items: [.request(path), .request(json), .folder(flow), .request(teapot)])
        // As arranged, right before what follows it: nothing moves.
        #expect(collection.destination(of: path.id, beside: json.id, after: false) == nil)
        // Sorted Z to A, it stands last: right before Send JSON is a move, right after it is where it is.
        let shown = collection.arranged(.nameDescending)
        #expect(shown.items.map(\.name) == ["Token flow", "Teapot", "Send JSON", "Get by path variable"])
        #expect(try #require(shown.destination(of: path.id, beside: json.id, after: false)) == (nil, 2))
        #expect(shown.destination(of: path.id, beside: json.id, after: true) == nil)
        #expect(collection.arranged(.manual).items.map(\.id) == collection.items.map(\.id))
        // What holds a node, itself included.
        #expect(shown.siblings(of: token.id)?.map(\.id) == [inner.id, token.id])
        #expect(shown.siblings(of: teapot.id)?.count == 4)
        #expect(shown.siblings(of: UUID()) == nil)
        // A folder does not go into itself or what it holds.
        #expect(collection.isFolder(flow.id, within: flow.id))
        #expect(collection.isFolder(inner.id, within: flow.id))
        #expect(!collection.isFolder(flow.id, within: inner.id))
        #expect(!collection.isFolder(flow.id, within: path.id))
    }

    @Test func whatACollectionHoldsIsSortedByNameFoldersFirst() {
        let inner = [CollectionNode.request(RequestItem(name: "zeta")), .request(RequestItem(name: "Alpha"))]
        let nodes: [CollectionNode] = [
            .request(RequestItem(name: "Teapot")), .folder(Folder(name: "Token flow", items: inner)),
            .request(RequestItem(name: "Get 10")), .folder(Folder(name: "Admin")), .request(RequestItem(name: "Get 2")),
        ]
        func names(_ nodes: [CollectionNode]) -> [String] { nodes.map(\.name) }
        #expect(names(ListOrder.manual.arranged(nodes)) == ["Teapot", "Token flow", "Get 10", "Admin", "Get 2"])
        #expect(names(ListOrder.nameAscending.arranged(nodes)) == ["Admin", "Token flow", "Get 2", "Get 10", "Teapot"])
        #expect(names(ListOrder.nameDescending.arranged(nodes)) == ["Token flow", "Admin", "Teapot", "Get 10", "Get 2"])
        // One level for what is shown; every level for the order a collection takes as its own.
        let shown = ListOrder.nameAscending.arranged(nodes)
        guard case .folder(let kept) = shown[1], case .folder(let sorted) = ListOrder.nameAscending.arrangedDeeply(nodes)[1] else {
            Issue.record("Token flow is not where it should be")
            return
        }
        #expect(names(kept.items) == ["zeta", "Alpha"])
        #expect(names(sorted.items) == ["Alpha", "zeta"])
        #expect(names(ListOrder.manual.arrangedDeeply(nodes)) == names(nodes))
    }

    @Test func theOrderOfEachListIsKeptWithTheSettings() throws {
        var settings = AppSettings()
        #expect(settings.collectionOrder == .manual && settings.environmentOrder == .manual)
        settings.collectionOrder = .nameDescending
        settings.environmentOrder = .nameAscending
        let read = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(read.collectionOrder == .nameDescending && read.environmentOrder == .nameAscending)
        // Settings written before, or by a later version with an order this one does not know, still open.
        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"timeout": 10}"#.utf8))
        #expect(older.collectionOrder == .manual && older.timeout == 10)
        let later = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"collectionOrder": "byDate"}"#.utf8))
        #expect(later.collectionOrder == .manual)
        // The order of what each collection holds: one this version does not know is left out, not all.
        settings.requestOrders = ["A": .nameAscending]
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).requestOrders == ["A": .nameAscending])
        let mixed = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"requestOrders": {"A": "nameDescending", "B": "byDate"}}"#.utf8))
        #expect(mixed.requestOrders == ["A": .nameDescending])
    }
}
