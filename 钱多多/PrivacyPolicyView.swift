import SwiftUI

struct PrivacyPolicyView: View {
    @State private var policyText: String?
    @State private var loadingFailed = false

    var body: some View {
        Group {
            if let policyText {
                ScrollView {
                    Text(policyText)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(.horizontal, AppLayout.editorHorizontalInset)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                }
            } else if loadingFailed {
                ContentUnavailableView {
                    Label("隐私政策暂时无法读取", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("未能读取应用内的隐私政策，请重试。")
                } actions: {
                    Button("重新读取", action: loadPolicy)
                        .buttonStyle(.bordered)
                }
            } else {
                ProgressView("正在读取隐私政策")
            }
        }
        .navigationTitle("隐私政策")
        .navigationBarTitleDisplayMode(.inline)
        .softPageBackground()
        .tint(AppTheme.readablePrimary)
        .task { loadPolicy() }
    }

    private func loadPolicy() {
        loadingFailed = false
        guard let url = Bundle.main.url(forResource: "PrivacyPolicy", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            policyText = nil
            loadingFailed = true
            return
        }
        policyText = text
    }
}
