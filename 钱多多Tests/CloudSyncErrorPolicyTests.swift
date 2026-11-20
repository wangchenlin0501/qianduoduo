import CloudKit
import Foundation
import Testing
@testable import 钱多多

struct CloudSyncErrorPolicyTests {
    private let entitlementDescription = "To use one time links, you must have the 'com.apple.developer.icloud-extended-share-access' entitlement with an array that includes 'InProcessOneTimeLinks'."

    @Test func recognizesTheExportedLogErrorWithoutAnUnderlyingError() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 134406, userInfo: [
            NSLocalizedDescriptionKey: "Mirroring delegate never successfully initialized: \(entitlementDescription)"
        ])
        #expect(CloudSyncErrorPolicy.configurationError(in: error) != nil)
    }

    @Test func recognizesCloudKitErrorsWrappedByCoreData() {
        let cloudError = NSError(domain: CKErrorDomain, code: CKError.Code.invalidArguments.rawValue,
                                 userInfo: [NSLocalizedDescriptionKey: entitlementDescription])
        let error = NSError(domain: NSCocoaErrorDomain, code: 134406,
                            userInfo: [NSUnderlyingErrorKey: cloudError])
        #expect(CloudSyncErrorPolicy.configurationError(in: error) != nil)
    }

    @Test func recognizesMissingEntitlementsInsidePartialFailures() {
        let error = NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue, userInfo: [
            CKPartialErrorsByItemIDKey: ["record": NSError(domain: CKErrorDomain,
                                                        code: CKError.Code.missingEntitlement.rawValue)]
        ])
        #expect(CloudSyncErrorPolicy.configurationError(in: error) != nil)
    }

    @Test(arguments: [CKError.Code.networkFailure, .networkUnavailable, .serviceUnavailable,
                      .requestRateLimited, .invalidArguments, .partialFailure])
    func doesNotPauseForTransientOrUnexplainedErrors(code: CKError.Code) {
        let error = NSError(domain: CKErrorDomain, code: code.rawValue)
        #expect(CloudSyncErrorPolicy.configurationError(in: error) == nil)
    }
}
