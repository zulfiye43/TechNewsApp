import Foundation
import Combine

struct Digest: Codable {
    let date: String
    let greeting: String
    let podcastTitle: String?
    let items: [DigestItem]
    let audioFile: String?

    enum CodingKeys: String, CodingKey {
        case date, greeting, items
        case podcastTitle = "podcast_title"
        case audioFile = "audio_file"
    }
}

struct DigestItem: Codable, Identifiable, Hashable {
    let topic: Topic
    let headline: String
    let summary: String
    let detail: String?
    let source: String
    let url: String

    var id: String { url + headline }

    enum Topic: String, Codable, CaseIterable {
        case ai, ios, tech

        var label: String {
            switch self {
            case .ai: "AI"
            case .ios: "iOS"
            case .tech: "Tech"
            }
        }
    }
}

@MainActor
final class DigestStore: ObservableObject {
    @Published var digest: Digest?
    @Published var errorMessage: String?

    /// Nach dem GitHub-Push ausfüllen (siehe DEPLOY.md), z.B.:
    /// URL(string: "https://raw.githubusercontent.com/DEIN-NAME/TechDigest/main/backend/out/")
    static let remoteBase: URL? = URL(string:
        "https://raw.githubusercontent.com/zulfiye43/TechNewsApp/main/backend/out/")

    @Published var audioURL: URL?

    private var bundledMP3: URL? {
        Bundle.main.url(forResource: "digest", withExtension: "mp3")
    }

    var language: String {
        UserDefaults.standard.string(forKey: "language") ?? "de"
    }

    func load() async {
        if let base = Self.remoteBase {
            do {
                var request = URLRequest(url: base.appendingPathComponent("digest_\(language).json"))
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, _) = try await URLSession.shared.data(for: request)
                let decoded = try JSONDecoder().decode(Digest.self, from: data)
                digest = decoded
                audioURL = decoded.audioFile.map { base.appendingPathComponent($0) } ?? bundledMP3
                errorMessage = nil
                return
            } catch {
                errorMessage = "Kein Netz – zeige letzten lokalen Stand."
            }
        }
        loadBundled()
    }

    private func loadBundled() {
        guard let url = Bundle.main.url(forResource: "digest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Digest.self, from: data)
        else {
            errorMessage = "digest.json fehlt im Bundle."
            return
        }
        digest = decoded
        audioURL = bundledMP3
    }
}

@MainActor
final class SavedStore: ObservableObject {
    @Published private(set) var saved: Set<String>
    private let key = "savedNews"

    init() {
        saved = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    func isSaved(_ item: DigestItem) -> Bool { saved.contains(item.id) }

    func toggle(_ item: DigestItem) {
        if saved.contains(item.id) {
            saved.remove(item.id)
        } else {
            saved.insert(item.id)
        }
        UserDefaults.standard.set(Array(saved), forKey: key)
    }
}

@MainActor
final class ReadStore: ObservableObject {
    @Published private(set) var read: Set<String>
    private let key = "readNews"

    init() {
        read = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    func isRead(_ item: DigestItem) -> Bool { read.contains(item.id) }

    func markRead(_ item: DigestItem) {
        guard !read.contains(item.id) else { return }
        read.insert(item.id)
        persist()
    }

    func toggle(_ item: DigestItem) {
        if read.contains(item.id) { read.remove(item.id) } else { read.insert(item.id) }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(read), forKey: key)
    }
}
