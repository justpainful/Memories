import SwiftData
import SwiftUI

/// The whole library, in time order, with a scrubber that makes years reachable in one drag.
struct TimelineView: View {
    @Environment(\.app) private var app

    @State private var buckets: [MonthBucket] = []
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
                            } else if buckets.isEmpty {
                                QuietStatusView(
                                    title: "Nothing here yet",
                                    detail: "Once there are photos in your library they will appear along this timeline.",
                                    symbol: "calendar"
                                )
                            } else {
                                ForEach(groupedByYear, id: \.year) { group in
                                    yearSection(group)
                                        .id(group.year)
                                }
                            }
                        }
                        .padding(.top, Space.s)
                        .padding(.bottom, 132)
                    }
                    .scrollIndicators(.hidden)
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation(.smooth(duration: 0.4)) { proxy.scrollTo(target, anchor: .top) }
                    }
                }

                if years.count > 1 {
                    YearScrubber(years: years) { year in
                        scrollTarget = year
                        Haptics.selection()
                    }
                    .padding(.trailing, 2)
                    .padding(.bottom, 132)
                }
            }
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.large)
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
    }

    // MARK: Sections

    private var years: [Int] {
        var seen = Set<Int>()
        return buckets.map(\.year).filter { seen.insert($0).inserted }
    }

    private var groupedByYear: [(year: Int, months: [MonthBucket])] {
        years.map { year in (year, buckets.filter { $0.year == year }) }
    }

    private func yearSection(_ group: (year: Int, months: [MonthBucket])) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(String(group.year))
                    .font(Typo.editorial(30))
                    .foregroundStyle(Palette.textPrimary)
                Text("\(group.months.reduce(0) { $0 + $1.count })")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
            }
            .padding(.horizontal, Space.gutter)

            ForEach(group.months) { month in
                Button { openMonth = month } label: {
                    MonthRow(bucket: month)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func load() async {
        isLoading = true
        let indexer = LibraryIndexer(modelContainer: app.container)
        buckets = await indexer.monthBuckets(options: .browsing)
        isLoading = false
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
    }
}

/// Drag along the years. Deliberately thin and unobtrusive until touched.
private struct YearScrubber: View {
    let years: [Int]
    let onSelect: (Int) -> Void

    private let rowHeight: CGFloat = 20
    private let rowSpacing: CGFloat = 2

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
                    .frame(width: 30, height: rowHeight)
            }
        }
        .contentShape(.rect)
        // A zero minimum distance makes a tap arrive as the first drag update, so one gesture
        // covers both without the labels racing the scrubber for the touch.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { select(under: $0.location.y) }
                .onEnded { _ in emitted = nil }
        )
        .padding(.vertical, Space.s)
        .glassPanel(cornerRadius: 18)
        .accessibilityLabel("Jump to year")
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
    @State private var viewing: String?

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 4)]

    var body: some View {
        ScrollView {
            // One grid per day rather than one grid for the month: a day that is scrolled
            // past stays a few hundred bytes of dates and identifiers instead of tiles.
            LazyVStack(alignment: .leading, spacing: Space.l) {
                ForEach(days) { day in
                    VStack(alignment: .leading, spacing: Space.s) {
                        dayHeader(day)
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(day.records, id: \.localIdentifier) { record in
                                Button { viewing = record.localIdentifier } label: {
                                    tile(record)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 4)
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
        .task { load() }
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
