import SwiftUI

struct BlockedRootView: View {
    @Environment(AppModel.self) private var appModel
    @State private var pendingUnblock: MemoryCandidate?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundView(theme: appModel.appTheme)

                if appModel.blockedItems.isEmpty {
                    unavailableState
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(appModel.blockedItems) { candidate in
                                AppGlassCard(theme: appModel.appTheme) {
                                    HStack(spacing: 16) {
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(appModel.appTheme.secondaryAccent.opacity(0.24))
                                            .frame(width: 88, height: 88)
                                            .overlay {
                                                Image(systemName: candidate.mediaKind == .video ? "video" : "photo")
                                                    .foregroundStyle(.white)
                                            }

                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(candidate.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "Date unavailable")
                                                .font(.headline)
                                                .foregroundStyle(appModel.appTheme.primaryText)
                                            Text("Blocked from the Memories feed until you explicitly restore it.")
                                                .font(.subheadline)
                                                .foregroundStyle(appModel.appTheme.secondaryText)
                                        }

                                        Spacer()

                                        Button("Unblock") {
                                            pendingUnblock = candidate
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                }
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("Blocked")
        }
        .alert("Unblock this memory?", isPresented: pendingUnblockBinding) {
            Button("Cancel", role: .cancel) {
                pendingUnblock = nil
            }
            Button("Unblock") {
                guard let pendingUnblock else { return }
                appModel.unblock(pendingUnblock)
                self.pendingUnblock = nil
            }
        } message: {
            Text("It will become eligible for Memories again.")
        }
    }

    private var unavailableState: some View {
        AppGlassCard(theme: appModel.appTheme) {
            VStack(alignment: .leading, spacing: 10) {
                Text("No blocked memories")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(appModel.appTheme.primaryText)
                Text("Blocked items will appear here when you hide them from the feed.")
                    .foregroundStyle(appModel.appTheme.secondaryText)
            }
            .padding(20)
        }
        .padding(20)
    }

    private var pendingUnblockBinding: Binding<Bool> {
        Binding(
            get: { pendingUnblock != nil },
            set: { if !$0 { pendingUnblock = nil } }
        )
    }
}
