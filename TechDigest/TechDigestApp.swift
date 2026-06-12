import SwiftUI

@main
struct TechDigestApp: App {
    @StateObject private var store = DigestStore()
    @StateObject private var savedStore = SavedStore()
    @StateObject private var readStore = ReadStore()
    @StateObject private var speech = SpeechManager()

    var body: some Scene {
        WindowGroup {
            DigestView()
                .environmentObject(store)
                .environmentObject(savedStore)
                .environmentObject(readStore)
                .environmentObject(speech)
        }
    }
}
