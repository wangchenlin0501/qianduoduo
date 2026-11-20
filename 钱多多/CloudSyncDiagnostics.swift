import CloudKit
import CoreData
import Foundation

/// Keep exported diagnostics useful without dumping record IDs, arbitrary userInfo, or credentials.
nonisolated enum CloudSyncDiagnostics {
    private static let maximumDepth = 6
    private static let maximumNodes = 32
    private static let maximumChildren = 8
    private static let maximumFieldLength = 512
    private static let maximumOutputLength = 8_000

    static func describe(_ error: Error) -> String {
        var renderer = Renderer()
        let description = renderer.render(error, depth: 0)
        guard description.count > maximumOutputLength else { return description }
        let suffix = "；[诊断已截断]"
        return String(description.prefix(maximumOutputLength - suffix.count)) + suffix
    }

    static func userMessage(for error: Error) -> String {
        if let configurationError = error as? CloudSyncConfigurationError {
            return configurationError.localizedDescription
        }
        let errors = flattenedErrors(error)
        for error in errors {
            // The traversal above is bounded; do not recursively traverse every subtree again.
            let directError = NSError(domain: error.domain, code: error.code, userInfo: [
                NSLocalizedDescriptionKey: error.localizedDescription
            ])
            if let configurationError = CloudSyncErrorPolicy.configurationError(in: directError) {
                return configurationError.localizedDescription
            }
        }
        let cloudCodes = Set(errors.compactMap { error -> Int? in
            guard error.domain == CKErrorDomain else { return nil }
            return error.code
        })
        if cloudCodes.contains(CKError.Code.quotaExceeded.rawValue) {
            return "iCloud 空间不足，部分更改尚未同步。请释放 iCloud 空间或增加容量后重试，本机记录会保留。"
        }
        if cloudCodes.contains(CKError.Code.notAuthenticated.rawValue) {
            return "尚未登录 iCloud，部分更改尚未同步。请在系统设置中登录 Apple 账户并开启本应用的 iCloud 后重试。"
        }
        if cloudCodes.contains(CKError.Code.networkUnavailable.rawValue) ||
            cloudCodes.contains(CKError.Code.networkFailure.rawValue) {
            return "暂时无法连接 iCloud，部分更改尚未同步。请检查网络后重试，本机记录会保留。"
        }
        if cloudCodes.contains(CKError.Code.accountTemporarilyUnavailable.rawValue) {
            return "iCloud 账户暂不可用，部分更改尚未同步。请稍后重试，本机记录会保留。"
        }
        if cloudCodes.contains(CKError.Code.serviceUnavailable.rawValue) ||
            cloudCodes.contains(CKError.Code.requestRateLimited.rawValue) ||
            cloudCodes.contains(CKError.Code.zoneBusy.rawValue) {
            return "iCloud 服务暂时繁忙，部分更改尚未同步。请稍后重试，本机记录会保留。"
        }
        if cloudCodes.contains(CKError.Code.partialFailure.rawValue) {
            return "部分更改尚未同步。请稍后重试；若持续失败，请导出最新诊断日志以检查具体原因。本机记录会保留。"
        }
        return "这次同步未完成，本机记录会保留。请稍后重试；若持续失败，请导出最新诊断日志。"
    }

    private struct ChildError {
        let label: String
        let error: Error
    }

    private static func children(of error: NSError) -> (items: [ChildError], omitted: Int) {
        var children: [ChildError] = []
        var total = 0
        func append(_ error: Error, label: String) {
            total += 1
            if children.count < maximumChildren {
                children.append(ChildError(label: label, error: error))
            }
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            append(underlying, label: "underlying")
        }
        for key in [NSMultipleUnderlyingErrorsKey, NSDetailedErrorsKey] {
            if let errors = error.userInfo[key] as? [Error] {
                total += errors.count
                let available = maximumChildren - children.count
                for (index, child) in errors.prefix(available).enumerated() {
                    children.append(ChildError(label: "\(key)[\(index + 1)]", error: child))
                }
            }
        }
        if let errors = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            total += errors.count
            let available = maximumChildren - children.count
            for (index, child) in errors.values.prefix(available).enumerated() {
                // Keys may contain private record identifiers or a participant's details.
                children.append(ChildError(label: "partial[\(index + 1)]", error: child))
            }
        }
        return (children, max(0, total - children.count))
    }

    private static func flattenedErrors(_ root: Error) -> [NSError] {
        var result: [NSError] = []
        var queue: [(Error, Int)] = [(root, 0)]
        var visited: Set<ObjectIdentifier> = []
        var next = 0
        while next < queue.count && result.count < maximumNodes {
            let (currentError, depth) = queue[next]
            next += 1
            let error = currentError as NSError
            guard visited.insert(ObjectIdentifier(error)).inserted else { continue }
            result.append(error)
            guard depth < maximumDepth else { continue }
            for child in children(of: error).items {
                queue.append((child.error, depth + 1))
            }
        }
        return result
    }

    private static func safeText(_ text: String) -> String {
        // Truncate before applying regular expressions so oversized server messages stay cheap.
        var text = String(text.prefix(maximumFieldLength))
        text = text.replacingOccurrences(
            of: #"(?i)\b(Bearer|Basic)\s+[^\s,;]+"#, with: "$1 <redacted>", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?i)\b(authorization|access[_-]?token|refresh[_-]?token|api[_-]?key|password|secret)\s*[:=]\s*(\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            with: "$1=<redacted>", options: .regularExpression
        )
        return text
    }

    private struct Renderer {
        var visited: Set<ObjectIdentifier> = []
        var retainedErrors: [NSError] = []
        var nodeCount = 0

        mutating func render(_ error: Error, depth: Int) -> String {
            guard depth <= maximumDepth else { return "[诊断已截断：嵌套过深]" }
            guard nodeCount < maximumNodes else { return "[诊断已截断：错误过多]" }
            let error = error as NSError
            guard visited.insert(ObjectIdentifier(error)).inserted else { return "[重复错误已省略]" }
            retainedErrors.append(error)
            nodeCount += 1
            var pieces = ["\(safeText(error.domain)) code \(error.code)", safeText(error.localizedDescription)]
            if let reason = error.localizedFailureReason, !reason.isEmpty {
                pieces.append("failureReason: \(safeText(reason))")
            }
            if let debug = error.userInfo[NSDebugDescriptionErrorKey] as? String, !debug.isEmpty {
                pieces.append("debug: \(safeText(debug))")
            }
            if let server = error.userInfo["ServerDescription"] as? String, !server.isEmpty {
                pieces.append("server: \(safeText(server))")
            }
            if let retryAfter = error.userInfo[CKErrorRetryAfterKey] as? NSNumber {
                pieces.append("retryAfter: \(retryAfter)")
            }
            let partialErrors = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error]
            if error.domain == CKErrorDomain, error.code == CKError.Code.partialFailure.rawValue,
               partialErrors?.isEmpty != false {
                pieces.append("部分失败：系统未提供子错误，无法确定具体失败原因")
            }
            let childErrors = CloudSyncDiagnostics.children(of: error)
            for child in childErrors.items {
                pieces.append("\(child.label): {\(render(child.error, depth: depth + 1))}")
            }
            if childErrors.omitted > 0 {
                pieces.append("[其余 \(childErrors.omitted) 项子错误已省略]")
            }
            return pieces.joined(separator: "；")
        }
    }
}
