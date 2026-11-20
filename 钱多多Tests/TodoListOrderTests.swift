import Testing
@testable import 钱多多

struct TodoListOrderTests {
    @Test func acceptsEmptyListWithoutAddingRows() {
        #expect(TodoRules.mergingVisibleOrder(fullOrder: [Int](), visibleOrder: []) == [])
    }

    @Test func preservesEntireOrderWhenNoRowsAreVisible() {
        #expect(TodoRules.mergingVisibleOrder(fullOrder: [1, 2, 3], visibleOrder: []) == [1, 2, 3])
    }

    @Test func preservesHiddenRowsBeforeBetweenAndAfterVisibleRows() {
        let full = ["hidden-first", "a", "hidden-middle", "b", "hidden-last"]
        let result = TodoRules.mergingVisibleOrder(fullOrder: full, visibleOrder: ["b", "a"])
        #expect(result == ["hidden-first", "b", "hidden-middle", "a", "hidden-last"])
    }

    @Test func handlesMovesAcrossMultipleHiddenSlots() {
        #expect(TodoRules.mergingVisibleOrder(
            fullOrder: [1, 2, 3, 4, 5],
            visibleOrder: [5, 1, 3]
        ) == [5, 2, 1, 4, 3])
    }

    @Test func canReorderAllRowsWhenNothingIsHidden() {
        #expect(TodoRules.mergingVisibleOrder(
            fullOrder: [1, 2, 3, 4],
            visibleOrder: [4, 2, 1, 3]
        ) == [4, 2, 1, 3])
    }

    @Test func rejectsDuplicateIDsInFullOrderEvenWhenHidden() {
        #expect(TodoRules.mergingVisibleOrder(fullOrder: [1, 2, 2], visibleOrder: [1]) == nil)
        #expect(TodoRules.mergingVisibleOrder(fullOrder: [1, 1], visibleOrder: []) == nil)
    }

    @Test func rejectsDuplicateIDsInVisibleOrder() {
        #expect(TodoRules.mergingVisibleOrder(fullOrder: [1, 2, 3], visibleOrder: [2, 2]) == nil)
    }

    @Test func rejectsForeignIDsWithoutInsertingOrDeletingRows() {
        #expect(TodoRules.mergingVisibleOrder(fullOrder: [1, 2, 3], visibleOrder: [2, 4]) == nil)
        #expect(TodoRules.mergingVisibleOrder(fullOrder: [Int](), visibleOrder: [1]) == nil)
    }

    @Test func everyVisiblePermutationKeepsHiddenPositionsAndAllOriginalIDs() throws {
        let full = Array(0..<8)
        let visible = [0, 2, 4, 6]
        for order in permutations(of: visible) {
            let result = try #require(TodoRules.mergingVisibleOrder(fullOrder: full, visibleOrder: order))
            #expect(result.count == full.count)
            #expect(Set(result) == Set(full))
            #expect([result[1], result[3], result[5], result[7]] == [1, 3, 5, 7])
            #expect([result[0], result[2], result[4], result[6]] == order)
        }
    }

    private func permutations(of items: [Int]) -> [[Int]] {
        guard !items.isEmpty else { return [[]] }
        return items.indices.flatMap { index in
            var remaining = items
            let first = remaining.remove(at: index)
            return permutations(of: remaining).map { [first] + $0 }
        }
    }
}
