//
//  SaveFailureHandling.swift
//  钱多多
//

import CoreData
import SwiftUI

extension NSManagedObjectContext {
    /// Saves pending changes and returns the error instead of crashing or swallowing it.
    ///
    /// On failure the context is rolled back, so a rejected edit cannot ride along with the next
    /// unrelated save. `rollback()` discards *every* unsaved change in this context, not only the
    /// caller's: on the shared view context that includes edits still pending from other screens.
    /// Objects inserted since the last save are discarded too, so a caller must create a fresh object
    /// on retry instead of reusing one it inserted earlier. Present `saveFailureAlert` afterwards.
    ///
    /// - Parameter operation: Short description for the log; the call site is always logged as well.
    func saveRollingBackOnFailure(
        _ operation: String? = nil,
        fileID: String = #fileID,
        line: Int = #line
    ) -> NSError? {
        do {
            try save()
            return nil
        } catch {
            let nsError = error as NSError
            let label = operation.map { "\($0)，\(fileID):\(line)" } ?? "\(fileID):\(line)"
            let discarded = "新增 \(insertedObjects.count)、修改 \(updatedObjects.count)、删除 \(deletedObjects.count)"
            AppLogger.shared.log(
                "保存失败（\(label)），已撤销该上下文全部未保存修改（\(discarded)）: \(PersistenceController.describe(nsError))"
            )
            rollback()
            return nsError
        }
    }
}

private struct SaveFailureAlertModifier: ViewModifier {
    @Binding var error: NSError?

    func body(content: Content) -> some View {
        content.alert("没有保存成功", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("好的", role: .cancel) { error = nil }
        } message: {
            // Rollback also discards other unsaved edits, so do not promise that nothing else changed.
            Text("这次修改没有保存。为避免出错的内容之后被一起保存，App 已撤销所有尚未保存的修改，其中可能包括其他页面里还没保存的内容。请检查后重新操作。（错误：\(error?.domain ?? "") \(error?.code ?? 0)）")
        }
    }
}

extension View {
    /// Tells the user that a save was rejected. Pair with `saveRollingBackOnFailure()`.
    func saveFailureAlert(_ error: Binding<NSError?>) -> some View {
        modifier(SaveFailureAlertModifier(error: error))
    }
}
