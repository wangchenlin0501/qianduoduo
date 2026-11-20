//
//  AIAssistantMemory.swift
//  钱多多
//

import CoreData
import SwiftUI

struct AIMemoryItem: Codable, Identifiable, Hashable {
    var id: String
    var text: String
    var createdAt: Date
}

/// Shared assistant memory, stored as JSON on the active SyncSpace so both partners see the same list.
enum AIMemoryStore {
    static let maxItems = 60

    static func load(in context: NSManagedObjectContext) -> [AIMemoryItem] {
        guard let space = try? PersistenceController.shared.existingActiveSyncSpace(in: context),
              let text = space.assistantMemory,
              let data = text.data(using: .utf8),
              let items = try? JSONDecoder().decode([AIMemoryItem].self, from: data) else { return [] }
        return items
    }

    static func save(_ items: [AIMemoryItem], in context: NSManagedObjectContext) throws {
        let space = try PersistenceController.shared.activeSyncSpace(in: context)
        let data = try JSONEncoder().encode(Array(items.suffix(maxItems)))
        space.assistantMemory = String(decoding: data, as: UTF8.self)
        space.updatedAt = Date()
        if let error = context.saveRollingBackOnFailure() { throw error }
    }

    static func add(_ text: String, in context: NSManagedObjectContext) throws -> AIMemoryItem {
        var items = load(in: context)
        let item = AIMemoryItem(id: UUID().uuidString, text: text, createdAt: Date())
        items.append(item)
        try save(items, in: context)
        return item
    }

    static func remove(id: String, in context: NSManagedObjectContext) throws -> AIMemoryItem? {
        var items = load(in: context)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = items.remove(at: index)
        try save(items, in: context)
        return removed
    }

    static func update(id: String, text: String, in context: NSManagedObjectContext) throws {
        var items = load(in: context)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].text = text
        try save(items, in: context)
    }

    static func restore(_ item: AIMemoryItem, in context: NSManagedObjectContext) throws {
        var items = load(in: context)
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        items.sort { $0.createdAt < $1.createdAt }
        try save(items, in: context)
    }
}

private struct AIBackupPart: Decodable {
    let assistantMemory: [AIMemoryItem]?
    let assistantModel: String?
    let assistantBaseURL: String?
}

enum AIBackup {
    /// Merges memory and endpoint settings from a backup. The API key is never part of a backup.
    static func restore(from data: Data, in context: NSManagedObjectContext) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        guard let part = try? decoder.decode(AIBackupPart.self, from: data) else { return }
        for item in part.assistantMemory ?? [] {
            try? AIMemoryStore.restore(item, in: context)
        }
        let model = AISharedConfig.nonEmpty(part.assistantModel)
        let baseURL = AISharedConfig.nonEmpty(part.assistantBaseURL)
        guard model != nil || baseURL != nil else { return }
        AISharedConfig.update(in: context) { config in
            if AISharedConfig.nonEmpty(config.model) == nil, let model { config.model = model }
            if AISharedConfig.nonEmpty(config.baseURL) == nil, let baseURL { config.baseURL = baseURL }
        }
    }
}

struct AIMemoryListView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @State private var items: [AIMemoryItem] = []
    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var editing: AIMemoryItem?
    @State private var editText = ""

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    TextField("新增一条，例如：SIRHUN 只用支付宝", text: $draft, axis: .vertical)
                    Button("添加") { add() }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: {
                Text("钱多多每次对话都会参考这些内容。与共享空间的成员共用。")
            }

            Section("已记住 \(items.count) 条") {
                if items.isEmpty {
                    Text("还没有记忆").foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    Button {
                        editText = item.text
                        editing = item
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Text(item.createdAt, format: .dateTime.year().month().day())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: delete)
            }
        }
        .navigationTitle("钱多多的记忆")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .sheet(item: $editing) { item in
            NavigationStack {
                TextEditor(text: $editText)
                    .padding()
                    .navigationTitle("编辑记忆")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { editing = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !text.isEmpty {
                                    do {
                                        try AIMemoryStore.update(id: item.id, text: text, in: viewContext)
                                        reload()
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                                editing = nil
                            }
                        }
                    }
            }
            .presentationDetents([.medium])
        }
        .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func reload() {
        items = AIMemoryStore.load(in: viewContext)
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            _ = try AIMemoryStore.add(text, in: viewContext)
            draft = ""
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        do {
            for index in offsets {
                _ = try AIMemoryStore.remove(id: items[index].id, in: viewContext)
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
