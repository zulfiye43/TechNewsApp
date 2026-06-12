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

/// Datum folgt der gewählten App-Sprache, nicht der Geräte-Locale.
enum AppDate {
    static func formatted(_ isoDate: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: isoDate) else { return isoDate }
        let lang = UserDefaults.standard.string(forKey: "language") ?? "de"
        let out = DateFormatter()
        out.locale = Locale(identifier: lang == "en" ? "en_US" : "de_DE")
        out.dateStyle = .full
        return out.string(from: date)
    }
}

// MARK: - Player (MP3 von ElevenLabs, Fallback Systemstimme)

final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var playbackRate: Float = 1.0

    private var synth = AVSpeechSynthesizer()
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var currentURL: URL?

    // Sprachmodus: Position im Text (UTF-16-Einheiten) mitverfolgen
    private var speechText = ""
    private var speechBaseOffset = 0
    private var speechCharIndex = 0
    private weak var currentUtterance: AVSpeechUtterance?
    private var usingSpeech = false
    private var speechTimer: Timer?

    /// Geschätzte Sprechgeschwindigkeit (Zeichen/Sekunde) bei 1×.
    private let charsPerSecond: Double = 15.0

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: Steuerung

    func toggle(digest: Digest, audioURL: URL?) {
        if let url = audioURL {
            usingSpeech = false
            toggleAudio(url: url)
        } else {
            usingSpeech = true
            toggleSpeech(digest: digest)
        }
    }

    func stop() {
        teardown()
        stopSpeechTimer()
        currentUtterance = nil
        synth.stopSpeaking(at: .immediate)
        speechCharIndex = 0
        isPlaying = false
    }

    func seek(to time: Double) {
        let clamped = max(0, min(time, duration))
        if usingSpeech {
            let offset = Int(clamped * effectiveCharsPerSecond())
            speakFrom(offset: min(offset, max(textLength() - 1, 0)))
        } else {
            player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
            currentTime = clamped
        }
    }

    func skip(_ seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func cycleRate() {
        let rates: [Float] = [1.0, 1.5, 2.0]
        playbackRate = rates[((rates.firstIndex(of: playbackRate) ?? 0) + 1) % rates.count]
        if usingSpeech {
            if isPlaying { speakFrom(offset: speechCharIndex) }
        } else if isPlaying {
            player?.rate = playbackRate
        }
    }

    // MARK: MP3

    private func toggleAudio(url: URL) {
        stopSpeechTimer()
        currentUtterance = nil
        synth.stopSpeaking(at: .immediate)
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
        if !usingSpeech {
            currentTime = 0
            duration = 0
        }
    }

    // MARK: Systemstimme mit Spulen/Tempo

    private func textLength() -> Int {
        (speechText as NSString).length
    }

    /// Zeitachse bewusst tempo-unabhängig (1×-Basis): so bleiben Regler
    /// und Dauer beim Tempo-Wechsel stabil, nur die Stimme wird schneller.
    private func effectiveCharsPerSecond() -> Double {
        charsPerSecond
    }

    private func updateSpeechDuration() {
        duration = Double(textLength()) / effectiveCharsPerSecond()
    }

    private func toggleSpeech(digest: Digest) {
        if synth.isSpeaking && !synth.isPaused {
            synth.pauseSpeaking(at: .word)
            isPlaying = false
            stopSpeechTimer()
            return
        }
        if synth.isPaused {
            synth.continueSpeaking()
            isPlaying = true
            startSpeechTimer()
            return
        }
        speechText = script(for: digest)
        updateSpeechDuration()
        speakFrom(offset: 0)
    }

    private func speakFrom(offset: Int) {
        let ns = speechText as NSString
        guard ns.length > 0 else { return }
        let clamped = max(0, min(offset, ns.length - 1))
        let remainder = ns.substring(from: clamped)
        guard !remainder.isEmpty else {
            isPlaying = false
            speechCharIndex = 0
            currentTime = 0
            return
        }

        // Frische Synthesizer-Instanz: der zuverlässigste Weg, einen
        // laufenden Sprecher sofort neu zu positionieren.
        currentUtterance = nil
        synth.stopSpeaking(at: .immediate)
        synth = AVSpeechSynthesizer()
        synth.delegate = self

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)

        speechBaseOffset = clamped
        speechCharIndex = clamped
        currentTime = Double(clamped) / effectiveCharsPerSecond()

        let utterance = AVSpeechUtterance(string: remainder)
        utterance.voice = Self.bestVoice()
        // 1x -> 0.5 (normal), 1.5x -> ~0.59, 2x -> ~0.68 (deutlich schneller)
        utterance.rate = min(0.5 + (playbackRate - 1.0) * 0.18, 0.68)
        currentUtterance = utterance
        synth.speak(utterance)
        isPlaying = true
        startSpeechTimer()
    }

    private func startSpeechTimer() {
        speechTimer?.invalidate()
        speechTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.usingSpeech, self.isPlaying else { return }
            // Fortschritt interpolieren; Wort-Callbacks korrigieren bei Bedarf
            self.currentTime = min(self.currentTime + 0.25 * Double(self.playbackRate),
                                   self.duration)
            self.speechCharIndex = Int(self.currentTime * self.charsPerSecond)
        }
    }

    private func stopSpeechTimer() {
        speechTimer?.invalidate()
        speechTimer = nil
    }

    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let lang = UserDefaults.standard.string(forKey: "language") ?? "de"
        let matching = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        if #available(iOS 16.0, *), let premium = matching.first(where: { $0.quality == .premium }) {
            return premium
        }
        if let enhanced = matching.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: lang == "en" ? "en-US" : "de-DE")
    }

    private func script(for digest: Digest) -> String {
        // Bevorzugt das von Claude geschriebene Podcast-Skript –
        // die rohe News-Liste ist nur der allerletzte Fallback.
        if let script = digest.podcastScript, !script.isEmpty {
            return script
        }
        var text = "\(digest.greeting) "
        for (index, item) in digest.items.enumerated() {
            text += "Nachricht \(index + 1): \(item.headline). \(item.summary) "
        }
        return text
    }

    // MARK: AVSpeechSynthesizerDelegate (nur aktuelle Utterance zählt)

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        DispatchQueue.main.async {
            self.speechCharIndex = self.speechBaseOffset + characterRange.location
            self.currentTime = Double(self.speechCharIndex) / self.effectiveCharsPerSecond()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        DispatchQueue.main.async {
            self.stopSpeechTimer()
            self.isPlaying = false
            self.speechCharIndex = 0
            self.speechBaseOffset = 0
            self.currentTime = 0
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        DispatchQueue.main.async {
            self.isPlaying = false
        }
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
        AppDate.formatted(isoDate)
    }
}

// MARK: - Feed

struct FeedTab: View {
    @EnvironmentObject var store: DigestStore
    @State private var filter: DigestItem.Topic?
    @State private var showSettings = false

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
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 14) {
                        Text(store.digest?.podcastTitle ?? "Dein Digest")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text(store.digest.map { AppDate.formatted($0.date) } ?? "…")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        // Fortschritt + Spulen (MP3 exakt, Systemstimme geschätzt)
                        VStack(spacing: 4) {
                            Slider(
                                value: Binding(
                                    get: { isScrubbing ? scrubValue : speech.currentTime },
                                    set: { scrubValue = $0 }
                                ),
                                in: 0...max(speech.duration, 1),
                                onEditingChanged: { editing in
                                    if editing {
                                        scrubValue = speech.currentTime
                                        isScrubbing = true
                                    } else {
                                        isScrubbing = false
                                        speech.seek(to: scrubValue)
                                    }
                                }
                            )
                            .tint(.sage)
                            .disabled(speech.duration <= 0)
                            HStack {
                                Text(timeString(speech.currentTime))
                                Spacer()
                                Text(timeString(speech.duration))
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 28) {
                            Button { speech.skip(-10) } label: {
                                Image(systemName: "gobackward.10").font(.title2)
                            }
                            .disabled(speech.duration <= 0)
                            Button {
                                Haptics.light(); if let digest = store.digest { speech.toggle(digest: digest, audioURL: store.audioURL) }
                            } label: {
                                Image(systemName: speech.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title)
                                    .foregroundStyle(Color.bgMain)
                                    .frame(width: 68, height: 68)
                                    .background(Color.sage, in: Circle())
                            }
                            .disabled(store.digest == nil)
                            Button { speech.skip(10) } label: {
                                Image(systemName: "goforward.10").font(.title2)
                            }
                            .disabled(speech.duration <= 0)
                            Button { speech.cycleRate() } label: {
                                Text(rateLabel)
                                    .font(.footnote.weight(.bold))
                                    .frame(width: 44, height: 30)
                                    .background(Color.surface, in: Capsule())
                                    .overlay(Capsule().stroke(Color.cardBorder))
                            }
                        }
                        .foregroundStyle(Color.primary)

                        Text(store.audioURL != nil
                             ? "Täglich frisch generierte Folge"
                             : "Systemstimme (Offline-Modus)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
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
        guard speech.duration > 0 else { return "–:–" }
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
    @AppStorage("language") private var language = "de"
    @EnvironmentObject var store: DigestStore
    @EnvironmentObject var speech: SpeechManager

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

                Section("Sprache") {
                    Picker("Digest & Podcast", selection: $language) {
                        Text("Deutsch").tag("de")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: language) {
                        speech.stop()
                        Task { await store.load() }
                    }
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
