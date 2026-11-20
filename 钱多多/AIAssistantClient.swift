//
//  AIAssistantClient.swift
//  钱多多
//

import CoreData
import Foundation

enum AIAssistantError: LocalizedError {
    case missingKey
    case missingModel
    case badURL
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            "还没有填写 API key，请到 设置 → AI 助手 填写。"
        case .missingModel:
            "还没有填写模型名，请到 设置 → AI 助手 填写。"
        case .badURL:
            "接口地址无效，请检查 设置 → AI 助手。"
        case let .http(code, message):
            "请求失败（\(code)）：\(message)"
        case .badResponse:
            "服务返回的内容无法解析，请稍后再试。"
        }
    }
}

/// OpenAI-compatible chat completions; bodies stay as Data so nothing non-Sendable crosses the await.
struct AIAssistantClient {
    let baseURL: String
    let model: String
    let apiKey: String

    static func current(context: NSManagedObjectContext) throws -> AIAssistantClient {
        let shared = AISharedConfig.load(in: context)
        guard let key = AIKeychain.load() ?? AISharedConfig.nonEmpty(shared.apiKey) else { throw AIAssistantError.missingKey }
        let model = AISharedConfig.nonEmpty(AIAssistantConfig.model) ?? AISharedConfig.nonEmpty(shared.model) ?? ""
        guard !model.isEmpty else { throw AIAssistantError.missingModel }
        let localURL = AISharedConfig.nonEmpty(UserDefaults.standard.string(forKey: AIAssistantConfig.baseURLKey))
        let baseURL = localURL ?? AISharedConfig.nonEmpty(shared.baseURL) ?? AIAssistantConfig.defaultBaseURL
        return AIAssistantClient(baseURL: baseURL, model: model, apiKey: key)
    }

    var endpoint: URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/chat/completions") { base += "/chat/completions" }
        return URL(string: base)
    }

    func send(body: Data) async throws -> Data {
        guard let endpoint else { throw AIAssistantError.badURL }
        var request = URLRequest(url: endpoint, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIAssistantError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AIAssistantError.http(http.statusCode, Self.errorMessage(from: data))
        }
        return data
    }

    /// DeepSeek Search / Fetch raw APIs (POST {origin}/v1/tools/{name}), billed per successful call.
    func webTool(_ name: String, body: [String: Any]) async throws -> Data {
        guard let base = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = base.scheme, let host = base.host,
              let url = URL(string: "\(scheme)://\(host)/v1/tools/\(name)") else { throw AIAssistantError.badURL }
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIAssistantError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AIAssistantError.http(http.statusCode, Self.errorMessage(from: data))
        }
        return data
    }

    static let webDefinitions: [[String: Any]] = [
        ["type": "function", "function": [
            "name": "web_search",
            "description": "联网搜索（每次约 0.005 元）。只在需要 App 外的信息时用：品牌背景、行情报价、新闻、平台规则等。App 里的数据不要搜。",
            "parameters": ["type": "object", "properties": [
                "query": ["type": "string", "description": "搜索词，1-128 字，可用 site:、after: 等语法"]
            ], "required": ["query"]]
        ] as [String: Any]],
        ["type": "function", "function": [
            "name": "fetch_page",
            "description": "读取一个网页的正文（Markdown）。用户发来链接或搜索摘要不够时用。",
            "parameters": ["type": "object", "properties": [
                "url": ["type": "string"]
            ], "required": ["url"]]
        ] as [String: Any]]
    ]

    func runWebTool(name: String, arguments: String) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
        do {
            if name == "web_search" {
                let query = String((args["query"] as? String ?? "").prefix(128))
                guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return #"{"error":"query 为空"}"# }
                let data = try await webTool("search", body: ["query": query, "count": 6])
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let results = (object?["results"] as? [[String: Any]] ?? []).map { item -> [String: Any] in
                    ["title": item["title"] ?? "", "url": item["url"] ?? "", "site": item["site_name"] ?? "",
                     "date": item["date"] ?? "", "summary": item["summary"] ?? item["snippet"] ?? ""]
                }
                let out = try JSONSerialization.data(withJSONObject: ["results": results])
                return String(decoding: out, as: UTF8.self)
            } else {
                let url = args["url"] as? String ?? ""
                let data = try await webTool("fetch", body: ["url": url])
                return String(String(decoding: data, as: UTF8.self).prefix(12_000))
            }
        } catch {
            return "{\"error\":\"\(error.localizedDescription.replacingOccurrences(of: "\"", with: "'"))\"}"
        }
    }

    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }
}
