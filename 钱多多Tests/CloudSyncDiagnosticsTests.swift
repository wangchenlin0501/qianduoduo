import CloudKit
import CoreData
import Foundation
import Testing
@testable import 钱多多

struct CloudSyncDiagnosticsTests {
    @Test func preservesNestedFailureDetailsWithoutDumpingUserInfo() {
        let cloudError = NSError(domain: CKErrorDomain, code: CKError.Code.invalidArguments.rawValue, userInfo: [
            NSLocalizedDescriptionKey: "Cloud operation failed",
            NSLocalizedFailureReasonErrorKey: "Missing production field",
            NSDebugDescriptionErrorKey: "Schema validation failed",
            "ServerDescription": "Cannot create field in production",
            "access_token": "DO-NOT-EXPORT-THIS-TOKEN"
        ])
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 134406,
                              userInfo: [NSUnderlyingErrorKey: cloudError])
        let description = CloudSyncDiagnostics.describe(wrapped)
        #expect(description.contains("NSCocoaErrorDomain code 134406"))
        #expect(description.contains("CKErrorDomain code 12"))
        #expect(description.contains("failureReason: Missing production field"))
        #expect(description.contains("debug: Schema validation failed"))
        #expect(description.contains("server: Cannot create field in production"))
        #expect(!description.contains("DO-NOT-EXPORT-THIS-TOKEN"))
    }

    @Test func explainsWhenCloudKitHidesPartialFailureDetails() {
        let error = NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue)
        let description = CloudSyncDiagnostics.describe(error)
        #expect(description.contains("系统未提供子错误"))
        let message = CloudSyncDiagnostics.userMessage(for: error)
        #expect(message.contains("部分更改尚未同步"))
        #expect(!message.contains("网络"))
    }

    @Test func includesSeveralPartialErrorsWithoutExportingTheirRecordKeys() {
        let error = NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue, userInfo: [
            CKPartialErrorsByItemIDKey: [
                "PRIVATE-RECORD-ONE": NSError(domain: CKErrorDomain, code: CKError.Code.quotaExceeded.rawValue),
                "PRIVATE-RECORD-TWO": NSError(domain: CKErrorDomain, code: CKError.Code.permissionFailure.rawValue)
            ]
        ])
        let description = CloudSyncDiagnostics.describe(error)
        #expect(description.contains("partial[1]"))
        #expect(description.contains("partial[2]"))
        #expect(description.contains("code 25"))
        #expect(description.contains("code 10"))
        #expect(!description.contains("PRIVATE-RECORD"))
        #expect(!description.contains("系统未提供子错误"))
        #expect(CloudSyncDiagnostics.userMessage(for: error).contains("iCloud 空间不足"))
    }

    @Test func traversesMultipleUnderlyingAndDetailedErrors() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 1560, userInfo: [
            NSMultipleUnderlyingErrorsKey: [NSError(domain: "MultipleChild", code: 101)],
            NSDetailedErrorsKey: [NSError(domain: "DetailedChild", code: 102)]
        ])
        let description = CloudSyncDiagnostics.describe(error)
        #expect(description.contains("MultipleChild code 101"))
        #expect(description.contains("DetailedChild code 102"))
    }

    @Test func limitsDeepAndOversizedDiagnostics() {
        var deepError = NSError(domain: "Deep", code: 0)
        for index in 1...100 {
            deepError = NSError(domain: "Deep", code: index,
                                userInfo: [NSUnderlyingErrorKey: deepError])
        }
        let deepDescription = CloudSyncDiagnostics.describe(deepError)
        #expect(deepDescription.contains("嵌套过深"))
        #expect(deepDescription.count <= 8_000)

        let oversized = String(repeating: "Long server message ", count: 1_000)
        let child = NSError(domain: "OversizedChild", code: 1, userInfo: [
            NSLocalizedDescriptionKey: oversized,
            NSLocalizedFailureReasonErrorKey: oversized,
            NSDebugDescriptionErrorKey: oversized,
            "ServerDescription": oversized
        ])
        let children = (0..<200).map { _ in child }
        let manyErrors = NSError(domain: NSCocoaErrorDomain, code: 1560,
                                 userInfo: [NSDetailedErrorsKey: children])
        let manyDescription = CloudSyncDiagnostics.describe(manyErrors)
        #expect(manyDescription.contains("192 项子错误已省略"))
        #expect(manyDescription.count <= 8_000)

        let uniqueChildren = (0..<8).map { index in
            NSError(domain: "UniqueChild", code: index, userInfo: child.userInfo)
        }
        let longError = NSError(domain: NSCocoaErrorDomain, code: 1560,
                                userInfo: [NSDetailedErrorsKey: uniqueChildren])
        let longDescription = CloudSyncDiagnostics.describe(longError)
        #expect(longDescription.count <= 8_000)
        #expect(longDescription.hasSuffix("[诊断已截断]"))
    }

    @Test func redactsCredentialsEvenInsideAllowedTextFields() {
        let error = NSError(domain: CKErrorDomain, code: CKError.Code.invalidArguments.rawValue, userInfo: [
            NSDebugDescriptionErrorKey: "Authorization: Bearer PRIVATE-BEARER; password=PRIVATE-PASSWORD; api_key=PRIVATE-API-KEY"
        ])
        let description = CloudSyncDiagnostics.describe(error)
        #expect(!description.contains("PRIVATE-BEARER"))
        #expect(!description.contains("PRIVATE-PASSWORD"))
        #expect(!description.contains("PRIVATE-API-KEY"))
        #expect(description.contains("<redacted>"))
    }

    @Test(arguments: [CKError.Code.networkFailure, .networkUnavailable])
    func explainsNetworkRecoveryOnlyForNetworkErrors(code: CKError.Code) {
        let error = NSError(domain: CKErrorDomain, code: code.rawValue)
        #expect(CloudSyncDiagnostics.userMessage(for: error).contains("检查网络"))
    }

    @Test func explainsAccountAndEntitlementRecovery() {
        let signedOut = NSError(domain: CKErrorDomain, code: CKError.Code.notAuthenticated.rawValue)
        #expect(CloudSyncDiagnostics.userMessage(for: signedOut).contains("登录 Apple 账户"))
        let entitlement = NSError(domain: CKErrorDomain, code: CKError.Code.missingEntitlement.rawValue)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 134406,
                              userInfo: [NSMultipleUnderlyingErrorsKey: [entitlement]])
        #expect(CloudSyncDiagnostics.userMessage(for: wrapped) ==
                CloudSyncConfigurationError.missingSharingEntitlement.localizedDescription)
        let unrelatedDomain = NSError(domain: "OtherDomain", code: CKError.Code.quotaExceeded.rawValue)
        #expect(!CloudSyncDiagnostics.userMessage(for: unrelatedDomain).contains("空间不足"))
    }
}
