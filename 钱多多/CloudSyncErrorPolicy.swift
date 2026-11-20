import CloudKit
import Foundation

nonisolated enum CloudSyncConfigurationError: LocalizedError {
    case missingSharingEntitlement

    var errorDescription: String? {
        "当前版本缺少 iCloud 共享权限，同步已暂停。请安装修复后的版本再试，本机记录会保留。"
    }
}

nonisolated enum CloudSyncErrorPolicy {
    /// Core Data may wrap the CloudKit error, or include it only in its description.
    static func configurationError(in error: Error) -> CloudSyncConfigurationError? {
        configurationError(in: error, depth: 0)
    }

    private static func configurationError(in error: Error, depth: Int) -> CloudSyncConfigurationError? {
        guard depth < 8 else { return nil }
        let error = error as NSError
        if error.domain == CKErrorDomain && error.code == CKError.Code.missingEntitlement.rawValue {
            return .missingSharingEntitlement
        }
        if (error.domain == CKErrorDomain || error.domain == NSCocoaErrorDomain),
           error.localizedDescription.contains("com.apple.developer.icloud-extended-share-access") ||
            error.localizedDescription.contains("InProcessOneTimeLinks") {
            return .missingSharingEntitlement
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error,
           let result = configurationError(in: underlying, depth: depth + 1) {
            return result
        }
        if let partialErrors = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            for partialError in partialErrors.values {
                if let result = configurationError(in: partialError, depth: depth + 1) {
                    return result
                }
            }
        }
        return nil
    }
}
