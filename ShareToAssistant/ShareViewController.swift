import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private static let groupID = Bundle.main.object(forInfoDictionaryKey: "QDDAppGroupIdentifier") as? String ?? "group.com.example.qianduoduo"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        Task { await handoff() }
    }

    private func handoff() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
            .prefix(4)

        guard let inbox = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.groupID)?
            .appendingPathComponent("ShareInbox", isDirectory: true) else {
            finish()
            return
        }
        try? FileManager.default.removeItem(at: inbox)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        var saved = 0
        for provider in providers {
            guard let data = await loadImageData(provider) else { continue }
            let file = inbox.appendingPathComponent("\(saved).jpg")
            if (try? data.write(to: file, options: .atomic)) != nil { saved += 1 }
        }

        guard saved > 0, let url = URL(string: "qianduoduo://assistant-share") else {
            finish()
            return
        }
        openHostApp(url)
        finish()
    }

    private func loadImageData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
                var image: UIImage?
                if let url = item as? URL, let data = try? Data(contentsOf: url) {
                    image = UIImage(data: data)
                } else if let picked = item as? UIImage {
                    image = picked
                } else if let data = item as? Data {
                    image = UIImage(data: data)
                }
                continuation.resume(returning: image?.jpegData(compressionQuality: 0.9))
            }
        }
    }

    private func openHostApp(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url)
                return
            }
            responder = current.next
        }
        let selector = NSSelectorFromString("openURL:")
        responder = self
        while let current = responder {
            if current.responds(to: selector) {
                _ = current.perform(selector, with: url)
                return
            }
            responder = current.next
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
