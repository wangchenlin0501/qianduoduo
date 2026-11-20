//
//  AIAssistantConfig.swift
//  钱多多
//

import CoreData
import Foundation
import Security
import SwiftUI

enum AIAssistantConfig {
    static let baseURLKey = "aiAssistantBaseURL"
    static let modelKey = "aiAssistantModel"
    static let defaultBaseURL = "https://api.deepseek.com"

    static var baseURL: String {
        let stored = UserDefaults.standard.string(forKey: baseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultBaseURL : stored
    }

    static var model: String {
        UserDefaults.standard.string(forKey: modelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Key, model and endpoint shared with the partner through the active SyncSpace (plain text in iCloud, by choice).
struct AISharedConfig: Codable {
    var apiKey: String?
    var model: String?
    var baseURL: String?

    static func load(in context: NSManagedObjectContext) -> AISharedConfig {
        guard let space = try? PersistenceController.shared.existingActiveSyncSpace(in: context),
              let data = space.assistantConfig?.data(using: .utf8),
              let config = try? JSONDecoder().decode(AISharedConfig.self, from: data) else { return AISharedConfig() }
        return config
    }

    static func update(in context: NSManagedObjectContext, _ change: (inout AISharedConfig) -> Void) {
        var config = load(in: context)
        change(&config)
        guard let space = try? PersistenceController.shared.activeSyncSpace(in: context),
              let data = try? JSONEncoder().encode(config) else { return }
        let text = String(decoding: data, as: UTF8.self)
        guard space.assistantConfig != text else { return }
        space.assistantConfig = text
        space.updatedAt = Date()
        _ = context.saveRollingBackOnFailure()
    }

    static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AIKeychain {
    private static let service = "com.qianduoduo.ai-assistant"
    private static let account = "api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

private struct DeepSeekBalanceRow: View {
    @Environment(\.managedObjectContext) private var viewContext
    let baseURL: String
    let sharedKey: Bool
    @State private var text = "未查询"
    @State private var loading = false

    private var isDeepSeek: Bool {
        URL(string: AISharedConfig.nonEmpty(baseURL) ?? AIAssistantConfig.defaultBaseURL)?
            .host?.hasSuffix("deepseek.com") == true
    }

    var body: some View {
        if isDeepSeek {
            Button {
                Task { await refresh() }
            } label: {
                HStack(spacing: 12) {
                    Label("DeepSeek 余额", systemImage: "yensign.circle")
                    Spacer(minLength: 8)
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(text).foregroundStyle(.secondary)
                        Image(systemName: "arrow.clockwise")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .settingsRow()
            }
            .disabled(loading)
            .task { await refresh() }
        }
    }

    private func refresh() async {
        let key = AIKeychain.load() ?? AISharedConfig.nonEmpty(AISharedConfig.load(in: viewContext).apiKey)
        guard let key, let url = URL(string: "https://api.deepseek.com/user/balance") else {
            text = "未配置 key"
            return
        }
        loading = true
        defer { loading = false }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let infos = json["balance_infos"] as? [[String: Any]],
                  let info = infos.first,
                  let total = info["total_balance"] as? String else {
                text = "查询失败"
                return
            }
            let symbol = (info["currency"] as? String) == "USD" ? "$" : "¥"
            let available = (json["is_available"] as? Bool) == false ? "（不可用）" : ""
            text = "\(symbol)\(total)\(available)"
        } catch {
            text = "查询失败"
        }
    }
}

struct AIAssistantSettingsSection: View {
    @Environment(\.managedObjectContext) private var viewContext
    @AppStorage(AIAssistantConfig.baseURLKey) private var baseURL = AIAssistantConfig.defaultBaseURL
    @AppStorage(AIAssistantConfig.modelKey) private var model = ""
    @State private var keyDraft = ""
    @State private var hasKey = AIKeychain.load() != nil
    @State private var sharedKey = false
    @State private var saveFailed = false

    private var trimmedDraft: String {
        keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SettingsCardSection("AI 助手") {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .foregroundStyle(AppTheme.readablePrimary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                SecureField(hasKey || sharedKey ? "已配置，输入新 key 替换" : "粘贴 API key", text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !trimmedDraft.isEmpty {
                    Button("保存") {
                        if AIKeychain.save(trimmedDraft) {
                            let key = trimmedDraft
                            AISharedConfig.update(in: viewContext) { $0.apiKey = key }
                            hasKey = true
                            sharedKey = true
                            keyDraft = ""
                        } else {
                            saveFailed = true
                        }
                    }
                    .fontWeight(.semibold)
                    .fixedSize()
                } else if hasKey || sharedKey {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.success)
                        .accessibilityLabel("已配置")
                }
            }
            .settingsRow()

            SettingsRowDivider()

            fieldRow("模型", prompt: "模型名", text: $model)

            SettingsRowDivider()

            fieldRow("接口", prompt: AIAssistantConfig.defaultBaseURL, text: $baseURL, url: true)

            SettingsRowDivider()

            DeepSeekBalanceRow(baseURL: baseURL, sharedKey: sharedKey)

            SettingsRowDivider()

            NavigationLink {
                AIMemoryListView()
            } label: {
                HStack(spacing: 12) {
                    Label("钱多多的记忆", systemImage: "brain")
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .settingsRow()
            }

            if hasKey || sharedKey {
                SettingsRowDivider()

                Button(role: .destructive) {
                    AIKeychain.delete()
                    AISharedConfig.update(in: viewContext) { $0.apiKey = nil }
                    hasKey = false
                    sharedKey = false
                } label: {
                    Label("删除 key", systemImage: "trash")
                        .settingsRow()
                }
            }
        }
        .onAppear {
            let shared = AISharedConfig.load(in: viewContext)
            sharedKey = AISharedConfig.nonEmpty(shared.apiKey) != nil
            if AISharedConfig.nonEmpty(model) == nil, let sharedModel = AISharedConfig.nonEmpty(shared.model) {
                model = sharedModel
            }
            if let localKey = AIKeychain.load(), AISharedConfig.nonEmpty(shared.apiKey) == nil {
                AISharedConfig.update(in: viewContext) { $0.apiKey = localKey }
                sharedKey = true
            }
        }
        .onDisappear { pushEndpoint() }
        .alert("保存失败", isPresented: $saveFailed) {
            Button("好", role: .cancel) {}
        } message: {
            Text("无法写入钥匙串，请重试。")
        }
    }

    private func fieldRow(_ title: String, prompt: String, text: Binding<String>, url: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(title)
            TextField(prompt, text: text)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(url ? .URL : .default)
                .onSubmit { pushEndpoint() }
        }
        .settingsRow()
    }

    private func pushEndpoint() {
        let currentModel = AISharedConfig.nonEmpty(model)
        let currentURL = AISharedConfig.nonEmpty(baseURL)
        AISharedConfig.update(in: viewContext) { config in
            if let currentModel { config.model = currentModel }
            if let currentURL { config.baseURL = currentURL }
        }
    }
}
