import Foundation

/// How a list of the sidebar (the collections, the environments) is ordered: as the person arranged it,
/// or by name. The order they arranged is kept whichever they choose, and comes back with `manual`.
public enum ListOrder: String, Codable, CaseIterable, Sendable {
    case manual
    case nameAscending
    case nameDescending

    /// The items as they are shown. Names compare as Finder compares them (capitals, accents and numbers
    /// read as a person reads them: "API 2" before "API 10"); items of the same name keep the order
    /// arranged.
    public func arranged<Item>(_ items: [Item], name: (Item) -> String) -> [Item] {
        guard self != .manual else { return items }
        let ascending = self == .nameAscending
        return items.enumerated().sorted { left, right in
            switch name(left.element).localizedStandardCompare(name(right.element)) {
            case .orderedAscending: ascending
            case .orderedDescending: !ascending
            case .orderedSame: left.offset < right.offset
            }
        }.map(\.element)
    }

    /// The order a person leaves when they drop the item `id` on the item `target` as the list is shown:
    /// it takes the place of the target, which moves aside towards where the item came from. That order is
    /// the arranged one from then on, whichever order was chosen. `nil` when nothing moves.
    public func moving<Item: Identifiable>(
        _ id: Item.ID, toPlaceOf target: Item.ID, in items: [Item], name: (Item) -> String
    ) -> [Item]? {
        let shown = arranged(items, name: name)
        guard let order = Self.moving(id, toPlaceOf: target, in: shown.map(\.id)) else { return nil }
        return order.compactMap { id in shown.first { $0.id == id } }
    }

    /// The same on identifiers alone, in the order given: `id` takes the place of `target`.
    public static func moving<ID: Equatable>(_ id: ID, toPlaceOf target: ID, in order: [ID]) -> [ID]? {
        guard id != target, let from = order.firstIndex(of: id), let to = order.firstIndex(of: target) else { return nil }
        var moved = order
        moved.insert(moved.remove(at: from), at: to)
        return moved
    }

    /// The same, one place up (`-1`) or down (`1`) the list as shown. `nil` at either end.
    public func moving<Item: Identifiable>(_ id: Item.ID, by step: Int, in items: [Item], name: (Item) -> String) -> [Item]? {
        let shown = arranged(items, name: name)
        guard let from = shown.firstIndex(where: { $0.id == id }), shown.indices.contains(from + step) else { return nil }
        return moving(id, toPlaceOf: shown[from + step].id, in: items, name: name)
    }
}
