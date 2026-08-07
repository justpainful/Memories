import SwiftUI

enum AppTab: Hashable {
    case memories, timeline, library
}

/// Three tabs, as decided: the smart feed, the whole library in time order, and direct
/// access by kind. Calendar, Places and Search live *inside* Timeline and Library rather
/// than claiming tabs of their own.
///
/// This is the native iOS 26 `TabView`, which renders its own Liquid Glass bar. Nothing
/// here fakes a floating control out of a blurred rectangle.
struct RootView: View {
    @State private var selection: AppTab = .memories

    var body: some View {
        TabView(selection: $selection) {
            Tab("Memories", systemImage: "rectangle.stack", value: AppTab.memories) {
                PlaceholderSurface(
                    title: "Memories",
                    line: "Your photos. Remembered privately."
                )
            }
            Tab("Timeline", systemImage: "calendar.day.timeline.left", value: AppTab.timeline) {
                PlaceholderSurface(title: "Timeline", line: "Every year you have photographed.")
            }
            Tab("Library", systemImage: "square.grid.2x2", value: AppTab.library) {
                PlaceholderSurface(title: "Library", line: "Everything, by kind.")
            }
        }
    }
}

/// Temporary scaffold so the shell can be built and screenshotted before the real
/// surfaces land. Replaced feature by feature.
private struct PlaceholderSurface: View {
    let title: String
    let line: String

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(Typo.dateHeadline)
                        .foregroundStyle(Palette.textSecondary)
                    Text(line)
                        .font(Typo.memoryTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.l)
            }
            .background(Palette.canvas)
            .navigationTitle(title)
        }
    }
}

#Preview {
    RootView()
}
