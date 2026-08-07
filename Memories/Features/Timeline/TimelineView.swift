import SwiftData
import SwiftUI

/// The whole library, in time order, with a scrubber that makes years reachable in one drag.
struct TimelineView: View {
    @Environment(\.app) private var app

    @State private var sections: [YearSection] = []
    @State private var isLoading = true
    @State private var scrollTarget: Int?
    @State private var openMonth: MonthBucket?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .trailing) {
                Palette.canvas.ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Space.xl) {
                            if isLoading {
                                QuietStatusView(title: "Reading your library", symbol: "clock")
                            } else if sections.isEmpty {
                                QuietStatusView(
                                    title: "Nothing here yet",
                                    detail: "Once there are photos in your library they will appear along this timeline.",
                                    symbol: "calendar"
                                )
                            } else {
                                ForEach(sections) { section in
                                    yearSection(section)
                                        .id(section.year)
                                }
                            }
                        }
                        .padding(.top, Space.s)
                        // Room for the scrubber. It floats over this list, and a row that runs
                        // underneath it is a row whose right-hand end — the chevron, the part
                        // that most looks like the thing to press — silently scrubs the year
                        // instead of opening the month.
                        .padding(.trailing, scrubberInset)
                        .padding(.bottom, 132)
                    }
                    .scrollIndicators(.hidden)
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation(.smooth(duration: 0.4)) { proxy.scrollTo(target, anchor: .top) }
                    }
                }

                if showsScrubber {
                    YearScrubber(years: sections.map(\.year)) { year in
                        scrollTarget = year
                        Haptics.selection()
                    }
                    .padding(.trailing, 2)
                    .padding(.bottom, 132)
                }
            }
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.hidden, for: .tabBar)   // the app draws its own; see RootView.surface
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { CalendarView() } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Calendar")
                }
            }
            .navigationDestination(item: $openMonth) { bucket in
                MonthGridView(bucket: bucket)
            }
        }
        .task { await load() }
        .onChange(of: app.library.changeGeneration) { _, _ in Task { await load() } }
        // On a first run this screen is built before the library has been read, so without
        // these it would say "Nothing here yet" until something in Photos changed.
        .onChange(of: app.coordinator.hasUsableIndex) { _, usable in
            if usable { Task { await load() } }
        }
        .onChange(of: app.coordinator.isRunning) { _, running in
            if !running { Task { await load() } }
        }
    }

    // MARK: Sections

    private var showsScrubber: Bool { sections.count > 1 }

    /// Only reserved when the scrubber is actually drawn, so a library with a single year
    /// keeps the full width.
    private var scrubberInset: CGFloat { showsScrubber ? YearScrubber.width + 4 : 0 }

    private func yearSection(_ section: YearSection) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(String(section.year))
                    .font(Typo.editorial(30))
                    .foregroundStyle(Palette.textPrimary)
                Text("\(section.count)")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
            }
            .padding(.horizontal, Space.gutter)

            ForEach(section.months) { month in
                Button { openMonth = month } label: {
                    MonthRow(bucket: month)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Reads the library and, only if the answer changed, hands it to the list.
    ///
    /// Both of those matter. Grouping used to happen inside `body`, which meant walking every
    /// month of the library again on each redraw; and this runs again whenever indexing stops,
    /// so replacing an identical array — or flashing the loading state a second time — would
    /// restart the list under whoever was reading it.
    private func load() async {
        let indexer = LibraryIndexer(modelContainer: app.container)
        let buckets = await indexer.monthBuckets(options: .browsing)
        let fresh = YearSection.group(buckets)
        if fresh != sections { sections = fresh }
        isLoading = false
    }
}

/// One year of the timeline, grouped once when the library is read rather than on every frame.
private struct YearSection: Identifiable, Equatable {
    let year: Int
    let months: [MonthBucket]
    let count: Int

    var id: Int { year }

    /// The buckets arrive newest first and already in order, so one walk is enough — the years
    /// come out in the order they were met and each keeps its months as it found them.
    static func group(_ buckets: [MonthBucket]) -> [YearSection] {
        var years: [Int] = []
        var months: [Int: [MonthBucket]] = [:]
        for bucket in buckets {
            if months[bucket.year] == nil { years.append(bucket.year) }
            months[bucket.year, default: []].append(bucket)
        }
        return years.map { year in
            let group = months[year] ?? []
            return YearSection(year: year,
                               months: group,
                               count: group.reduce(0) { $0 + $1.count })
        }
    }
}

/// A month as a row: its best frame, its name, its size.
private struct MonthRow: View {
    let bucket: MonthBucket

    var body: some View {
        HStack(spacing: Space.l) {
            if let cover = bucket.coverIdentifier {
                PhotoThumbnail(identifier: cover, side: 72, radius: Radius.tile)
            } else {
                RoundedRectangle(cornerRadius: Radius.tile)
                    .fill(Palette.surfaceSunk)
                    .frame(width: 72, height: 72)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(bucket.title)
                    .font(Typo.sectionTitle)
                    .foregroundStyle(Palette.textPrimary)
                Text("\(bucket.count) \(bucket.count == 1 ? "moment" : "moments")")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, Space.gutter)
        // The stretch between the month's name and its chevron is empty, and a button is hit
        // only where it is drawn — so the middle of the row, which is most of it, did nothing.
        .contentShape(.rect)
    }
}

/// Drag along the years. Deliberately thin and unobtrusive until touched.
private struct YearScrubber: View {
    let years: [Int]
    let onSelect: (Int) -> Void

    /// How much of the trailing edge this occupies, so the list can keep its rows clear of it.
    static let width: CGFloat = 44

    /// Tall enough to aim at, and the whole column is padded rather than the labels, so the
    /// glass that can be seen is the glass that can be touched.
    private static let idealRowHeight: CGFloat = 22
    /// Beyond this the rows shrink instead of the column running off the top of the screen,
    /// where the oldest years would be unreachable.
    private static let maxColumnHeight: CGFloat = 420

    private let rowSpacing: CGFloat = 2
    private let verticalPadding: CGFloat = Space.s

    @State private var active: Int?
    /// The year already handed over during the current touch, cleared when the finger lifts —
    /// so a drag fires once per year crossed, yet re-tapping the same label still jumps back.
    @State private var emitted: Int?

    var body: some View {
        VStack(spacing: rowSpacing) {
            ForEach(years, id: \.self) { year in
                Text(String(year).suffix(2))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(active == year ? Palette.accent : Palette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: rowHeight)
            }
        }
        .padding(.vertical, verticalPadding)
        .frame(width: Self.width)
        // Applied over the padding, not inside it. The glass panel is drawn around the whole
        // padded column, and a hit shape that stopped at the labels left a visible band of
        // material at each end that looked like the control and was not part of it.
        .contentShape(.rect)
        // A zero minimum distance makes a tap arrive as the first drag update, so one gesture
        // covers both without the labels racing the scrubber for the touch.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { select(under: $0.location.y - verticalPadding) }
                .onEnded { _ in emitted = nil }
        )
        .glassPanel(cornerRadius: 18)
        .accessibilityLabel("Jump to year")
    }

    private var rowHeight: CGFloat {
        guard years.count > 1 else { return Self.idealRowHeight }
        let gaps = rowSpacing * CGFloat(years.count - 1)
        let available = (Self.maxColumnHeight - gaps) / CGFloat(years.count)
        return max(11, min(Self.idealRowHeight, available))
    }

    private func select(under y: CGFloat) {
        guard !years.isEmpty else { return }
        let index = min(max(Int(y / (rowHeight + rowSpacing)), 0), years.count - 1)
        let year = years[index]
        guard year != emitted else { return }   // haptics and scrolling belong to changes only

        emitted = year
        active = year
        onSelect(year)
    }
}

/// Every frame from one month, a day at a time.
struct MonthGridView: View {
    let bucket: MonthBucket

    @Environment(\.app) private var app
    @State private var days: [DaySlice] = []
    @State private var isLoading = true
    @State private var viewing: String?

    var body: some View {
        ScrollView {
            // One grid per day rather than one grid for the month: a day that is scrolled
            // past stays a few hundred bytes of dates and identifiers instead of tiles.
            LazyVStack(alignment: .leading, spacing: Space.l) {
                if days.isEmpty, !isLoading {
                    QuietStatusView(
                        title: "Nothing left in this month",
                        detail: "The photographs taken here are no longer in your library.",
                        symbol: "calendar"
                    )
                }
                ForEach(days) { day in
                    VStack(alignment: .leading, spacing: Space.s) {
                        dayHeader(day)
                        // The same grid as every other screen, so a pinch means the same
                        // thing here as it does in the library and the density carries over.
                        PhotoGrid {
                            ForEach(day.records, id: \.localIdentifier) { record in
                                Button { viewing = record.localIdentifier } label: {
                                    tile(record)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.top, Space.s)
            .padding(.bottom, 132)
        }
        .scrollIndicators(.hidden)
        .background(Palette.canvas)
        .navigationTitle("\(bucket.title) \(String(bucket.year))")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: Binding(
            get: { viewing.map(ViewerRequest.init(identifier:)) },
            set: { viewing = $0?.identifier }
        )) { request in
            PhotoViewerView(identifiers: monthIdentifiers, startAt: request.identifier)
        }
        // A busy month is thousands of rows to fetch and split. Yielding first lets the push
        // animation finish on an empty month rather than stalling half way through it.
        .task {
            await Task.yield()
            load()
        }
    }

    /// Opening one frame hands the viewer the whole month, not the day it was tapped in,
    /// so a swipe carries on past midnight the way scrolling does.
    private var monthIdentifiers: [String] {
        days.flatMap { $0.records.map(\.localIdentifier) }
    }

    private func dayHeader(_ day: DaySlice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(day.date, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(Typo.sectionTitle)
                .foregroundStyle(Palette.textPrimary)
            Text("\(day.records.count)")
                .font(Typo.meta)
                .foregroundStyle(Palette.textTertiary)
            Spacer()
        }
        .padding(.horizontal, Space.gutter)
    }

    private func tile(_ record: AssetRecord) -> some View {
        PhotoImageView(identifier: record.localIdentifier, targetSide: 240)
            .aspectRatio(1, contentMode: .fill)
            .clipShape(.rect(cornerRadius: 6))
            .overlay(alignment: .bottomLeading) {
                if record.isVideo || record.isLivePhoto {
                    MediaBadge(record: record).padding(5)
                }
            }
    }

    private func load() {
        defer { isLoading = false }
        let calendar = Calendar.current
        guard let interval = calendar.interval(year: bucket.year, month: bucket.month) else { return }
        let records: [AssetRecord] = LibraryQuery.assets(in: [interval], options: .browsing,
                                                         context: app.container.mainContext).reversed()
        days = DaySlice.split(records, calendar: calendar)
    }
}

/// One day of a month, with the frames taken that day.
private struct DaySlice: Identifiable {
    var date: Date
    var records: [AssetRecord]

    var id: Date { date }

    /// The month arrives newest first, so each day is already one unbroken run — walking it
    /// once keeps the newest day on top without sorting a hundred thousand rows again.
    static func split(_ records: [AssetRecord], calendar: Calendar) -> [DaySlice] {
        var slices: [DaySlice] = []
        for record in records {
            let day = calendar.startOfDay(for: record.momentDate)
            if slices.last?.date == day {
                slices[slices.count - 1].records.append(record)
            } else {
                slices.append(DaySlice(date: day, records: [record]))
            }
        }
        return slices
    }
}
