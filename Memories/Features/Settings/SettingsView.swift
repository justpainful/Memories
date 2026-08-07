import Photos
import SwiftData
import SwiftUI

/// Short on purpose. Every switch here changes something the user can actually see.
struct SettingsView: View {
    @Environment(\.app) private var app
    /// How much room the floating bar is actually taking at the bottom of this screen, on this
    /// device, at this text size. It used to be written here as `132`, a number measured once
    /// on one phone; the bar publishes the real figure now and every screen asks for it.
    @Environment(\.bottomBarInset) private var bottomBarInset
    @State private var confirmClearCache = false
    @State private var confirmResetSuggestions = false
    @State private var confirmReindex = false

    var body: some View {
        List {
            Section {
                Toggle("Smart Curation", isOn: Binding(
                    get: { app.settings.smartCuration },
                    set: { app.settings.smartCuration = $0 }
                ))
                Toggle("Include Screenshots", isOn: Binding(
                    get: { app.settings.includeScreenshots },
                    set: { app.settings.includeScreenshots = $0 }
                ))
                Toggle("Include Screen Recordings", isOn: Binding(
                    get: { app.settings.includeScreenRecordings },
                    set: { app.settings.includeScreenRecordings = $0 }
                ))
                Toggle("Include Downloads", isOn: Binding(
                    get: { app.settings.includeDownloads },
                    set: { app.settings.includeDownloads = $0 }
                ))
                Picker("Video in Memories", selection: Binding(
                    get: { app.settings.videoMix },
                    set: { app.settings.videoMix = $0 }
                )) {
                    ForEach(VideoMix.allCases, id: \.self) { mix in
                        Text(mix.title).tag(mix)
                    }
                }
                .pickerStyle(.menu)
                NavigationLink {
                    MemoryFrequencyView()
                } label: {
                    LabeledContent("Memory Frequency", value: app.settings.memoryFrequency.title)
                }
            } header: {
                Text("Memories")
            } footer: {
                Text("Smart Curation collapses near-identical shots to the best one and keeps weak frames out of memories. Turning it off shows everything, in order.\n\nVideo in Memories is a ceiling, not a quota: most libraries hold far more photos than clips, so asking for more video shows the clips you have rather than inventing any. It changes memories only — the Videos screen always shows everything.")
            }

            Section {
                LabeledContent("Photo Access", value: app.library.access.title)
                if app.library.access != .full {
                    Button("Change in Settings") { openSystemSettings() }
                }
                Button("Reindex Library") { confirmReindex = true }
                if app.coordinator.isRunning {
                    LabeledContent("Status", value: app.coordinator.statusLine)
                        .foregroundStyle(Palette.textSecondary)
                        // This line changes as each stage of indexing finishes. Without the
                        // trait a reader who lands on it hears whatever it said when they
                        // arrived and is never told it moved on.
                        .accessibilityAddTraits(.updatesFrequently)
                }
            } header: {
                Text("Library")
            } footer: {
                // Formatted rather than interpolated raw: a bare `\(count)` prints digits with
                // no grouping separator and in no particular numbering system, next to dates on
                // the same screen that are localized properly.
                Text("\(app.coordinator.indexedCount.formatted(.number)) items indexed on this iPhone.")
            }

            Section("Playback") {
                Toggle("Autoplay Videos", isOn: Binding(
                    get: { app.settings.autoplayVideos },
                    set: { app.settings.autoplayVideos = $0 }
                ))
                Toggle("Live Photos", isOn: Binding(
                    get: { app.settings.playLivePhotos },
                    set: { app.settings.playLivePhotos = $0 }
                ))
                Toggle("Audio", isOn: Binding(
                    get: { app.settings.playAudio },
                    set: { app.settings.playAudio = $0 }
                ))
            }

            Section {
                Picker("Appearance", selection: Binding(
                    get: { app.settings.appearance },
                    set: { app.settings.appearance = $0 }
                )) {
                    ForEach(AppearanceChoice.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)

                // Labelled rather than segmented: "System" and "Editorial" do not explain
                // themselves the way "Light" and "Dark" do, and two unlabelled segmented
                // controls in one section would be a guess.
                Picker("Typography", selection: Binding(
                    get: { app.settings.typography },
                    set: { app.settings.typography = $0 }
                )) {
                    ForEach(TypographyStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("System sets every word in SF Pro, the iPhone’s own typeface. Editorial sets memory titles, section headings and the date above the feed in New York, a serif; buttons, counts and settings stay in SF Pro either way.")
            }

            Section {
                NavigationLink("Local Processing") { PrivacyView() }
                NavigationLink("Storage") { StorageView() }
                Button("Reset Memory Suggestions") { confirmResetSuggestions = true }
                Button("Clear Analysis Data", role: .destructive) { confirmClearCache = true }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Clearing analysis data never touches your photos. It only removes what Memories computed, and it will be worked out again as needed.")
            }
        }
        .contentMargins(.bottom, bottomBarInset, for: .scrollContent)
        // A settings list stretched across a landscape iPad puts a switch a foot away from the
        // label that names it. Content that is read stops at a comfortable measure; applied
        // after the scroll modifiers above so they still reach the list itself.
        .readableMeasure()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog("Reindex your library?", isPresented: $confirmReindex, titleVisibility: .visible) {
            Button("Reindex") { Task { await app.coordinator.reindex() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything Memories computed is worked out again from scratch. Your photos are not touched.")
        }
        .confirmationDialog("Reset memory suggestions?", isPresented: $confirmResetSuggestions, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { app.feedback.resetLearning() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Forgets what Memories learned from what you opened, saved and hid, and starts over.")
        }
        .confirmationDialog("Clear analysis data?", isPresented: $confirmClearCache, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { Task { await app.coordinator.clearAnalysisCache() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes computed data only. Your photos stay exactly where they are.")
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// How often a memory may appear on the Lock Screen — local notifications, nothing else.
struct MemoryFrequencyView: View {
    @Environment(\.app) private var app
    @Environment(\.bottomBarInset) private var bottomBarInset
    @State private var authorization: String = "Not requested"

    var body: some View {
        List {
            Section {
                Picker("Frequency", selection: Binding(
                    get: { app.settings.memoryFrequency },
                    set: { app.settings.memoryFrequency = $0; reschedule() }
                )) {
                    ForEach(MemoryFrequency.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("Memories are chosen on this iPhone and scheduled locally. There is no server, no push service and no account involved.")
            }

            if app.settings.memoryFrequency != .off {
                Section("Time of day") {
                    Picker("Hour", selection: Binding(
                        get: { app.settings.reminderHour },
                        set: { app.settings.reminderHour = $0; reschedule() }
                    )) {
                        ForEach(6..<23, id: \.self) { hour in
                            Text(Self.hourLabel(hour)).tag(hour)
                        }
                    }
                }
                Section {
                    LabeledContent("Notifications", value: authorization)
                }
            }
        }
        // The app draws its own floating bar over every screen, so each scrolling surface has
        // to reserve room for it — the height the bar reported, not a number remembered from
        // one phone at one text size.
        .contentMargins(.bottom, bottomBarInset, for: .scrollContent)
        .readableMeasure()
        .navigationTitle("Memory Frequency")
        .navigationBarTitleDisplayMode(.inline)
        .task { authorization = await MemoryNotifications.authorizationDescription() }
    }

    private static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(.dateTime.hour())
    }

    private func reschedule() {
        Task {
            // Choosing a frequency is the moment the user asked for reminders, so this is
            // the one place allowed to raise the permission dialog.
            if app.settings.memoryFrequency == .off {
                MemoryNotifications.cancelAll()
            } else {
                await MemoryNotifications.enable(app: app)
            }
            authorization = await MemoryNotifications.authorizationDescription()
        }
    }
}
