import Foundation

/// Shared validation for the inline composer and persisted edits.
nonisolated enum TodoRules {
    static func normalizedTitle(_ title: String) -> String? {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Reorders visible rows without moving hidden rows out of their existing slots.
    static func mergingVisibleOrder<ID: Hashable>(fullOrder: [ID], visibleOrder: [ID]) -> [ID]? {
        let fullIDs = Set(fullOrder)
        let visibleIDs = Set(visibleOrder)
        guard fullIDs.count == fullOrder.count,
              visibleIDs.count == visibleOrder.count,
              visibleIDs.isSubset(of: fullIDs) else {
            return nil
        }

        var nextVisibleIndex = 0
        return fullOrder.map { id in
            guard visibleIDs.contains(id) else { return id }
            defer { nextVisibleIndex += 1 }
            return visibleOrder[nextVisibleIndex]
        }
    }
}
