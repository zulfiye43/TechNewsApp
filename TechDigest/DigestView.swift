import SwiftUI
import AVFoundation
import Combine

// MARK: - Design-Tokens (aus design/techdigest-design.html)

extension Color {
    static let sage = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.639, green: 0.694, blue: 0.541, alpha: 1)
            : UIColor(red: 0.490, green: 0.561, blue: 0.388, alpha: 1)
    })
    static let bgMain = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.067, blue: 0.075, alpha: 1)
            : UIColor(red: 0.949, green: 0.953, blue: 0.941, alpha: 1)
    })
    static let surface = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.090, green: 0.106, blue: 0.118, alpha: 1)
            : .white
    })
    static let cardBorder = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.165, green: 0.188, blue: 0.212, alpha: 1)
            : UIColor(red: 0.867, green: 0.882, blue: 0.847, alpha: 1)
    })
}

// MARK: - UX-Helfer (Haptik + Press-Feedback, HIG-konform)

enum Haptics {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

/// Karten reagieren sichtbar auf Touch – wie in Apple News.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8),
                       value: configuration.isPressed)
    }
}

// MARK: - Player (MP3 von ElevenLabs, Fallback Systemstimme)

final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var playbackRate: Float = 1.0

    private let synth = AVSpeechSynthesizer()
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var currentURL: URL?

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: Steuerung

    func toggle(digest: Digest, audioURL: URL?) {
        if let url = audioURL {
            toggleAudio(url: url)
        } else {
            toggleSpeech(digest: digest)
        }
    }

    func stop() {
        teardown()
        synth.stopSpeaking(at: .immediate)
        isPlaying = false
    }

    func seek(to time: Double) {
        let clamped = max(0, min(time, duration))
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
    }

    func skip(_ seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func cycleRate() {
        let rates: [Float] = [1.0, 1.5, 2.0]
        playbackRate = rates[((rates.firstIndex(of: playbackRate) ?? 0) + 1) % rates.count]
        if isPlaying { player?.rate = playbackRate }
    }

    // MARK: Audio (lokal gebündelt oder von GitHub gestreamt)

    private func toggleAudio(url: URL) {
        if let player, currentURL == url {
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                player.rate = playbackRate
                isPlaying = true
            }
            return
        }
        teardown()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        currentURL = url

        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            if let d = self.player?.currentItem?.duration.seconds, d.isFinite, d > 0 {
                self.duration = d
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(playerDidFinish),
            name: .AVPlayerItemDidPlayToEndTime, object: item)

        newPlayer.rate = playbackRate
        isPlaying = true
    }

    @objc private func playerDidFinish() {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.currentTime = 0
            self.player?.seek(to: .zero)
        }
    }

    private func teardown() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        NotificationCenter.default.removeObserver(self)
        player?.pause()
        player = nil
        currentURL = nil
        currentTime = 0
        duration = 0
    }

    // MARK: Fallback Systemstimme

    private func toggleSpeech(digest: Digest) {
        if synth.isSpeaking && !synth.isPaused {
            synth.pauseSpeaking(at: .word)
            isPlaying = false
        } else if synth.isPaused {
            synth.continueSpeaking()
            isPlaying = true
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            let utterance = AVSpeechUtterance(string: script(for: digest))
            utterance.voice = Self.bestGermanVoice()
            utterance.rate = 0.5
            synth.speak(utterance)
            isPlaying = true
        }
    }

    static func bestGermanVoice() -> AVSpeechSynthesisVoice? {
        let german = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("de") }
        if #available(iOS 16.0, *), let premium = german.first(where: { $0.quality == .premium }) {
            return premium
        }
        if let enhanced = german.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: "de-DE")
    }

    private func script(for digest: Digest) -> String {
        var text = "Dein Tech-Digest. \(digest.greeting) "
        for (index, item) in digest.items.enumerated() {
            text += "Nachricht \(index + 1): \(item.headline). \(item.summary) "
        }
        text += "Das war dein Digest für heute. Bis morgen!"
        return text
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isPlaying = false }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isPlaying = false }
    }
}

// MARK: - Root: 4 Tabs + Darstellungsmodus

struct DigestView: View {
    @EnvironmentObject var store: DigestStore
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        TabView {
            FeedTab()
                .tabItem { Label("Feed", systemImage: "list.bullet") }
            HeuteTab()
                .tabItem { Label("Heute", systemImage: "star.fill") }
            SavedTab()
                .tabItem { Label("Gemerkt", systemImage: "bookmark.fill") }
            PodcastTab()
                .tabItem { Label("Podcast", systemImage: "play.circle.fill") }
        }
        .tint(.sage)
        .preferredColorScheme(appearance == "light" ? .light
                              : appearance == "dark" ? .dark : nil)
        .task { await store.load() }
    }
}

// MARK: - Heute (Top 3)

struct HeuteTab: View {
    @EnvironmentObject var store: DigestStore
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if let error = store.errorMessage {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }
                if let digest = store.digest {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(formatted(digest.date))
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Text(digest.greeting)
                            .font(.subheadline)
                            .lineSpacing(3)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.sage.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 16))

                        Text("TOP 3 DES TAGES")
                            .font(.caption.weight(.bold))
                            .kerning(1.2)
                            .foregroundStyle(Color.sage)

                        ForEach(Array(digest.items.prefix(3).enumerated()), id: \.element.id) { index, item in
                            NavigationLink(value: item) {
                                NewsCard(item: item, rank: index + 1)
                            }
                            .buttonStyle(PressableCardStyle())
                        }
                    }
                    .padding(.horizontal)
                } else {
                    ProgressView("Lade Digest …").padding(.top, 80)
                }
            }
            .background(Color.bgMain)
            .navigationTitle("Heute")
            .navigationDestination(for: DigestItem.self) { DetailView(item: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .refreshable { await store.load() }
        }
    }

    private func formatted(_ isoDate: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: isoDate) else { return isoDate }
        return date.formatted(date: .complete, time: .omitted)
    }
}

// MARK: - Feed

struct FeedTab: View {
    @EnvironmentObject var store: DigestStore
    @State private var filter: DigestItem.Topic?
    @State private var showSettings = false
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if let digest = store.digest {
                    VStack(alignment: .leading, spacing: 14) {
                        chips
                        ForEach(filtered(digest.items)) { item in
                            NavigationLink(value: item) {
                                NewsCard(item: item)
                            }
                            .buttonStyle(PressableCardStyle())
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .background(Color.bgMain)
            .navigationTitle("Feed")
            .navigationDestination(for: DigestItem.self) { DetailView(item: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            isRefreshing = true
                            await store.load()
                            isRefreshing = false
                        }
                    } label: {
                        if isRefreshing { ProgressView() }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .accessibilityLabel("Aktualisieren")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .refreshable { await store.load() }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "Alle", isActive: filter == nil) { filter = nil }
                ForEach(DigestItem.Topic.allCases, id: \.self) { topic in
                    Chip(title: topic.label, isActive: filter == topic) { filter = topic }
                }
            }
        }
    }

    private func filtered(_ items: [DigestItem]) -> [DigestItem] {
        guard let filter else { return items }
        return items.filter { $0.topic == filter }
    }
}

// MARK: - Gemerkt

struct SavedTab: View {
    @EnvironmentObject var store: DigestStore
    @EnvironmentObject var savedStore: SavedStore

    var body: some View {
        NavigationStack {
            ScrollView {
                let items = (store.digest?.items ?? []).filter { savedStore.isSaved($0) }
                if items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bookmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Noch nichts gemerkt.\nTippe das Lesezeichen auf einer News in Heute oder Feed.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 120)
                    .padding(.horizontal, 40)
                } else {
                    VStack(spacing: 10) {
                        ForEach(items) { item in
                            NavigationLink(value: item) {
                                NewsCard(item: item)
                            }
                            .buttonStyle(PressableCardStyle())
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .background(Color.bgMain)
            .navigationTitle("Gemerkt")
            .navigationDestination(for: DigestItem.self) { DetailView(item: $0) }
        }
    }
}

// MARK: - Podcast mit vollem Player

struct PodcastTab: View {
    @EnvironmentObject var store: DigestStore
    @EnvironmentObject var speech: SpeechManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 14) {
                        Text(store.digest?.podcastTitle ?? "Dein Digest")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text(store.digest?.date ?? "…")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if store.audioURL != nil {
                            // Fortschritt + Spulen
                            VStack(spacing: 4) {
                                Slider(
                                    value: Binding(
                                        get: { speech.currentTime },
                                        set: { speech.seek(to: $0) }
                                    ),
                                    in: 0...max(speech.duration, 1)
                                )
                                .tint(.sage)
                                HStack {
                                    Text(timeString(speech.currentTime))
                                    Spacer()
                                    Text(timeString(speech.duration))
                                }
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }

                            // Steuerung: -10s / Play / +10s / Tempo
                            HStack(spacing: 28) {
                                Button { speech.skip(-10) } label: {
                                    Image(systemName: "gobackward.10").font(.title2)
                                }
                                Button {
                                    Haptics.light(); if let digest = store.digest { speech.toggle(digest: digest, audioURL: store.audioURL) }
                                } label: {
                                    Image(systemName: speech.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.title)
                                        .foregroundStyle(Color.bgMain)
                                        .frame(width: 68, height: 68)
                                        .background(Color.sage, in: Circle())
                                }
                                Button { speech.skip(10) } label: {
                                    Image(systemName: "goforward.10").font(.title2)
                                }
                                Button { speech.cycleRate() } label: {
                                    Text(rateLabel)
                                        .font(.footnote.weight(.bold))
                                        .frame(width: 44, height: 30)
                                        .background(Color.surface, in: Capsule())
                                        .overlay(Capsule().stroke(Color.cardBorder))
                                }
                            }
                            .foregroundStyle(Color.primary)

                            Text("Gesprochen von Bella (ElevenLabs)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button {
                                Haptics.light(); if let digest = store.digest { speech.toggle(digest: digest, audioURL: store.audioURL) }
                            } label: {
                                Image(systemName: speech.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title)
                                    .foregroundStyle(Color.bgMain)
                                    .frame(width: 72, height: 72)
                                    .background(Color.sage, in: Circle())
                            }
                            .disabled(store.digest == nil)

                            Text("Noch keine digest.mp3 im Projekt. Führe die Pipeline mit --audio aus und ziehe out/digest.mp3 in Xcode – dann übernimmt Bella.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.cardBorder))
                }
                .padding(.horizontal)
            }
            .background(Color.bgMain)
            .navigationTitle("Podcast")
        }
    }

    private var rateLabel: String {
        switch speech.playbackRate {
        case 1.5: "1,5×"
        case 2.0: "2×"
        default: "1×"
        }
    }

    private func timeString(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Detail

struct DetailView: View {
    let item: DigestItem
    @EnvironmentObject var savedStore: SavedStore
    @EnvironmentObject var readStore: ReadStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    TopicBadge(topic: item.topic)
                    Text(item.source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(item.headline)
                    .font(.title2.weight(.bold))
                    .lineSpacing(2)

                Text(item.detail ?? item.summary)
                    .font(.body)
                    .lineSpacing(5)

                VStack(spacing: 8) {
                    Button {
                        if let url = URL(string: item.url) { openURL(url) }
                    } label: {
                        Label("Original lesen", systemImage: "arrow.up.right")
                            .font(.headline)
                            .foregroundStyle(Color.bgMain)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.sage, in: RoundedRectangle(cornerRadius: 14))
                    }
                    Button {
                        Haptics.light()
                        savedStore.toggle(item)
                    } label: {
                        Label(savedStore.isSaved(item) ? "Gemerkt – entfernen" : "Für später merken",
                              systemImage: savedStore.isSaved(item) ? "bookmark.fill" : "bookmark")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.surface, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cardBorder))
                    }
                    Button {
                        Haptics.light()
                        readStore.toggle(item)
                    } label: {
                        Label(readStore.isRead(item) ? "Als ungelesen markieren" : "Als gelesen markieren",
                              systemImage: readStore.isRead(item) ? "envelope.badge" : "envelope.open")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.surface, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cardBorder))
                    }
                }
                .padding(.top, 8)
            }
            .padding()
        }
        .background(Color.bgMain)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { readStore.markRead(item) }
    }
}

// MARK: - Einstellungen (konfigurierbar, persistent)

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("pushMinutes") private var pushMinutes = 390          // 06:30
    @AppStorage("newsCount") private var newsCount = 9
    @AppStorage("weightAI") private var weightAI = 3
    @AppStorage("weightIOS") private var weightIOS = 3
    @AppStorage("weightTech") private var weightTech = 2
    @AppStorage("appearance") private var appearance = "system"

    private var pushTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: pushMinutes / 60,
                                      minute: pushMinutes % 60,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                pushMinutes = (c.hour ?? 6) * 60 + (c.minute ?? 30)
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Digest") {
                    DatePicker(selection: pushTime, displayedComponents: .hourAndMinute) {
                        Label("Push-Zeit", systemImage: "bell.badge")
                    }
                    Stepper(value: $newsCount, in: 5...15) {
                        Label("Anzahl News: \(newsCount)", systemImage: "list.number")
                    }
                }

                Section("Themen-Gewichtung") {
                    WeightRow(label: "AI", value: $weightAI)
                    WeightRow(label: "iOS / Apple", value: $weightIOS)
                    WeightRow(label: "Allgemeine Tech-News", value: $weightTech)
                }

                Section("Darstellung") {
                    Picker("Erscheinungsbild", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Hell").tag("light")
                        Text("Dunkel").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Text("Erscheinungsbild wirkt sofort. Push-Zeit, Anzahl und Gewichtung nutzt das Backend, sobald der tägliche Lauf angebunden ist.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Einstellungen")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .tint(.sage)
    }
}

struct WeightRow: View {
    let label: String
    @Binding var value: Int
    private let names = ["Aus", "Wenig", "Normal", "Viel"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text(names[value])
                    .font(.footnote)
                    .foregroundStyle(Color.sage)
            }
            Slider(
                value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                in: 0...3, step: 1
            )
            .tint(.sage)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Bausteine

struct NewsCard: View {
    let item: DigestItem
    var rank: Int? = nil
    @EnvironmentObject var savedStore: SavedStore
    @EnvironmentObject var readStore: ReadStore

    private var isRead: Bool { readStore.isRead(item) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let rank {
                Text("\(rank)")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(Color.sage)
                    .frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    if !isRead {
                        Circle()
                            .fill(Color.sage)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Ungelesen")
                    }
                    TopicBadge(topic: item.topic)
                    Text(item.source)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Haptics.light()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            savedStore.toggle(item)
                        }
                    } label: {
                        Image(systemName: savedStore.isSaved(item) ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(savedStore.isSaved(item) ? Color.sage : Color.secondary)
                            .frame(width: 44, height: 32)   // HIG: min. 44pt Touch-Target
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text(item.headline)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isRead ? Color.secondary : Color.primary)
                    .multilineTextAlignment(.leading)
                Text(item.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.cardBorder))
        .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 4)
        .opacity(isRead ? 0.75 : 1)
        .animation(.easeOut(duration: 0.2), value: isRead)
        .contextMenu {
            Button {
                readStore.toggle(item)
            } label: {
                Label(isRead ? "Als ungelesen markieren" : "Als gelesen markieren",
                      systemImage: isRead ? "envelope.badge" : "envelope.open")
            }
            Button {
                savedStore.toggle(item)
            } label: {
                Label(savedStore.isSaved(item) ? "Aus Merkliste entfernen" : "Merken",
                      systemImage: "bookmark")
            }
        }
    }
}

struct TopicBadge: View {
    let topic: DigestItem.Topic

    var body: some View {
        Text(topic.label)
            .font(.caption2.weight(.bold))
            .kerning(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.sage.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(Color.sage)
    }
}

struct Chip: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(isActive ? Color.sage : Color.surface, in: Capsule())
                .overlay(Capsule().stroke(isActive ? Color.sage : Color.cardBorder))
                .foregroundStyle(isActive ? Color.bgMain : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    DigestView()
        .environmentObject(DigestStore())
        .environmentObject(SavedStore())
        .environmentObject(ReadStore())
        .environmentObject(SpeechManager())
}
