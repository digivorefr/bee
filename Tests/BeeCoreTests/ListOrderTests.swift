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
    }
}
