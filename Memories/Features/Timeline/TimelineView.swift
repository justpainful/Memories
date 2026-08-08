import SwiftData
import SwiftUI

/// The whole library, in time order, with a scrubber that makes years reachable in one drag.
struct TimelineView: View {
    @Environment(\.app) private var app
    /// The floating bar measures itself and publishes what it came out at; the list ends above
    /// that rather than above the 132 points it happened to measure on one phone.
    @Environment(\.bottomBarInset) private var bottomBarInset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sections: [YearSection] = []
    @State private var isLoading = true
    @State private var scrollTarget: Int?
    @State private var openMonth: MonthBucket?

    /// The year under the finger, while a finger is on the scrubber.
    @State private var scrubbingYear: Int?
    /// The height this screen was actually given. The scrubber is sized from it, because the
    /// only thing that knows how tall a column of years may be is the container it stands in.
    @State private var availableHeight: CGFloat = 0

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
                        // A month row is a line of text with a picture beside it, and a line of
                        // text a thousand points wide is not a row, it is a horizon. Stopped at
                        // a readable measure and centred, exactly as Settings and Mail are.
                        .readableMeasure()
                        .padding(.bottom, bottomBarInset)
                    }
                    .scrollIndicators(.hidden)
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        // One scrubber step can be a decade, and a decade of photographs
                        // travelling past in four tenths of a second is the textbook vestibular
                        // trigger. With Reduce Motion on the list is simply already there.
                        if reduceMotion {
                            proxy.scrollTo(target, anchor: .top)
                        } else {
                            withAnimation(.smooth(duration: 0.4)) { proxy.scrollTo(target, anchor: .top) }
                        }
                    }
                }

                if let scrubbingYear { yearCallout(scrubbingYear) }

                if showsScrubber {
                    YearScrubber(years: sections.map(\.year),
                                 availableHeight: max(0, availableHeight - bottomBarInset),
                                 scrubbing: $scrubbingYear) { year in
                        scrollTarget = year
                        Haptics.selection()
                    }
                    // The one piece of furniture in the app that genuinely cannot grow: it is a
                    // fixed column of every year in the library, and its height is the screen's.
                    .chromeTypeSize()
                    .padding(.trailing, 2)
                    .padding(.bottom, bottomBarInset)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if abs(height - availableHeight) > 0.5 { availableHeight = height }
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
    /// keeps the full width. It is the *touchable* width that has to be kept clear, not the
    /// visible glass — the column answers a finger further in than it is drawn.
    private var scrubberInset: CGFloat { showsScrubber ? YearScrubber.touchWidth + 4 : 0 }

    /// The year under the finger, drawn large beside the scrubber while it is being dragged.
    ///
    /// A row in that column comes down to eleven points on a long library, which is legible as
    /// a position and not as a number. This is what the reader is actually reading during a
    /// drag; the column beside it is the map. It is placed here rather than inside the scrubber
    /// because a trailing-edge callout has to be laid out by something that knows which edge is
    /// trailing — `padding(.trailing:)` and this `ZStack`'s alignment both mirror, and an
    /// `offset(x:)` inside the control would not.
    private func yearCallout(_ year: Int) -> some View {
        Text(year.formatted(.number.grouping(.never)))
            .font(Typo.editorial(34))
            .foregroundStyle(Palette.textPrimary)
            .chromeTypeSize()
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.m)
            .glassPanel(cornerRadius: Radius.panel)
            .padding(.trailing, YearScrubber.touchWidth + Space.m)
            // Feedback for a finger that is already on the control, and noise to a reader who
            // is being told the year by the scrubber's own value.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func yearSection(_ section: YearSection) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                // Formatted rather than `String(year)`: a rendered integer is always ASCII, so
                // the headings ran Western digits down a screen whose dates were in the
                // reader's own numbering system.
                Text(section.year.formatted(.number.grouping(.never)))
                    .font(Typo.editorial(30))
                    .foregroundStyle(Palette.textPrimary)
                Text(section.count.formatted(.number))
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textTertiary)
                    // A bare number reads as "two thousand and nineteen, four hundred and six".
                    .accessibilityLabel(Text("^[\(section.count) photo](inflect: true)"))
                Spacer()
            }
            .padding(.horizontal, Space.gutter)
            // One stop that says "2019, 406 photos", and says it as a heading, so the rotor can
            // move between years instead of through every month of every one of them.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

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

    /// The cover grows with the type beside it. Seventy-two points against a fifteen-point line
    /// is a thumbnail; against a forty-point one it is a stamp with a headline next to it.
    @ScaledMetric(relativeTo: .body) private var coverSide: CGFloat = 72

    var body: some View {
        HStack(spacing: Space.l) {
            if let cover = bucket.coverIdentifier {
                PhotoThumbnail(identifier: cover, side: coverSide, radius: Radius.tile)
            } else {
                RoundedRectangle(cornerRadius: Radius.tile)
                    .fill(Palette.surfaceSunk)
                    .frame(width: coverSide, height: coverSide)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(bucket.title)
                    .font(Typo.sectionTitle)
                    .foregroundStyle(Palette.textPrimary)
                    // Month names run to fourteen letters in several languages; two lines and a
                    // little shrinking is a name, one clipped line is a guess.
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                // One phrase rather than a number and a noun chosen by a ternary: English is the
                // only language this app is written in, but it is not the only one with a plural
                // rule, and `inflect` lets the phrase carry the count instead of a `==` test.
                Text("^[\(bucket.count) moment](inflect: true)")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer()
            // `chevron.right` names a side of the screen; `chevron.forward` names the direction
            // the push travels, which is the left in a right-to-left layout. The row moved when
            // the layout mirrored and the arrow did not, so every row pointed back at itself.
            Image(systemName: "chevron.forward")
                .font(Typo.glyph(13))
                .foregroundStyle(Palette.textTertiary)
                // It repeats the button trait the row already carries, and read aloud it is the
                // name of a glyph.
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Space.gutter)
        // The row is as tall as its content, but never shorter than a finger.
        .frame(minHeight: Hit.min)
        // The stretch between the month's name and its chevron is empty, and a button is hit
        // only where it is drawn — so the middle of the row, which is most of it, did nothing.
        .contentShape(.rect)
        // Name, then count: one stop, one sentence, rather than two stops and a glyph.
        .accessibilityElement(children: .combine)
    }
}

/// Drag along the years. Deliberately thin and unobtrusive until touched.
private struct YearScrubber: View {
    let years: [Int]

    /// The height the screen has to give it.
    ///
    /// This column used to be capped at 420 points whatever it was standing in. The comment on
    /// that constant named the exact failure it was there to prevent — years running off the
    /// ends of the screen where they cannot be reached — and then produced it, because 420 is
    /// taller than a landscape iPhone and a third of an iPad. It asks the container now.
    var availableHeight: CGFloat

    /// The year under the finger, so the screen can draw a callout the reader can actually
    /// read. Nil whenever nothing is touching the control.
    @Binding var scrubbing: Int?

    let onSelect: (Int) -> Void

    /// How much of the trailing edge this occupies visually.
    static let width: CGFloat = 44
    /// How much of it answers a finger. The column sits flush against the trailing edge, which
    /// is where a thumb is least accurate, so the touch area reaches further in than the glass
    /// does — and the list reserves *this* width rather than the visible one.
    static let touchWidth: CGFloat = YearScrubber.width + Space.m

    /// Rows track the type size rather than sitting at a fixed 22. At the largest chrome size a
    /// year label is roughly twice its default height, and a row that stayed at 22 would have
    /// the years drawing through one another.
    @ScaledMetric(relativeTo: .caption2) private var idealRowHeight: CGFloat = 22
    /// The floor. Below this a row is not a target at all, so the column stops shrinking and
    /// starts dropping labels instead — see `labelStride`.
    @ScaledMetric(relativeTo: .caption2) private var minimumRowHeight: CGFloat = 11
    /// The vertical room one year label needs to be drawn clear of its neighbours.
    @ScaledMetric(relativeTo: .caption2) private var labelSlot: CGFloat = 15

    private let rowSpacing: CGFloat = 2
    private let verticalPadding: CGFloat = Space.s

    /// The year the column is sitting on is drawn in the accent colour, which is the whole of
    /// the difference between it and the other thirty. Rendered in grey — or read by anyone who
    /// cannot separate the system blue from a tertiary label — that difference is nothing.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    @State private var active: Int?
    /// The year already handed over during the current touch, cleared when the finger lifts —
    /// so a drag fires once per year crossed, yet re-tapping the same label still jumps back.
    @State private var emitted: Int?

    var body: some View {
        VStack(spacing: rowSpacing) {
            // Indices rather than the years themselves, because whether a row is labelled
            // depends on where it sits in the column, not on which year it holds.
            ForEach(years.indices, id: \.self) { index in
                row(years[index], labelled: index % labelStride == 0)
            }
        }
        .padding(.vertical, verticalPadding)
        .frame(width: Self.width)
        .glassPanel(cornerRadius: Radius.panel)
        // The hit shape is taken over the padding and over this margin, never around the labels
        // alone: a shape that stopped at the text left a visible band of material at each end
        // that looked like the control and was not part of it, and the twelve points here give
        // the drag somewhere to start that is not the very edge of the screen, which is where a
        // thumb is least accurate. `scrubberInset` keeps the list clear of all of it.
        .padding(.leading, Space.m)
        .contentShape(.rect)
        // A zero minimum distance makes a tap arrive as the first drag update, so one gesture
        // covers both without the labels racing the scrubber for the touch.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { select(under: $0.location.y - verticalPadding) }
                .onEnded { _ in
                    emitted = nil
                    scrubbing = nil
                }
        )
        // A drag-only control is a control VoiceOver cannot operate: there is no gesture it
        // passes through that this could hear, so the entire Timeline had one destination —
        // wherever the list already was. As one adjustable element it steps a year at a time,
        // which is also how Switch Control and Full Keyboard Access reach it. The rows keep
        // their own drawing but stop being separate stops that are twenty points tall.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jump to year")
        .accessibilityValue(activeYearDescription)
        .accessibilityHint("Swipe up or down with one finger to move a year at a time")
        .accessibilityAdjustableAction { direction in
            // The list runs newest first, so "increment" — up — is the later year.
            switch direction {
            case .increment: step(by: -1)
            case .decrement: step(by: 1)
            default: break
            }
        }
    }

    private func row(_ year: Int, labelled: Bool) -> some View {
        Group {
            if labelled {
                Text(shortYear(year))
                    .font(Typo.scaled(10, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                // A tick rather than a smaller number. Below about fifteen points a label
                // cannot be drawn without touching the one above it, and two years overlapping
                // is less readable than one year and a mark saying "and the ones between".
                Capsule()
                    .frame(width: 10, height: 1.5)
            }
        }
        .foregroundStyle(active == year ? Palette.accent : Palette.textTertiary)
        .frame(maxWidth: .infinity)
        .frame(height: rowHeight)
        // A shape, not a hue: the year the column is sitting on grows a marker down its leading
        // edge, which survives being rendered in grey.
        .overlay(alignment: .leading) {
            if differentiateWithoutColor, active == year {
                Capsule()
                    .fill(Palette.textPrimary)
                    .frame(width: 3, height: max(4, rowHeight - 4))
            }
        }
    }

    // MARK: Geometry

    /// The room the rows themselves may occupy, inside the panel's own padding and clear of the
    /// navigation bar above it.
    private var columnRoom: CGFloat {
        let measured = availableHeight - verticalPadding * 2 - Space.section
        // 420 was the old hard-coded cap. It survives only as the value used for the one frame
        // before the container has reported its height, and in previews.
        guard measured > 0 else { return 420 }
        return max(idealRowHeight * 3, measured)
    }

    private var rowHeight: CGFloat {
        guard years.count > 1 else { return idealRowHeight }
        let gaps = rowSpacing * CGFloat(years.count - 1)
        let available = (columnRoom - gaps) / CGFloat(years.count)
        return max(minimumRowHeight, min(idealRowHeight, available))
    }

    /// How many rows apart a drawn label has to be for two of them never to meet.
    ///
    /// Every year still gets a row, and every year is still reachable by the drag — it is only
    /// the *labels* that thin out when the library is longer than the screen is tall. That is
    /// what the callout beside the column is for.
    private var labelStride: Int {
        let pitch = rowHeight + rowSpacing
        guard pitch > 0 else { return 1 }
        return max(1, Int((labelSlot / pitch).rounded(.up)))
    }

    // MARK: Values

    /// The last two digits, computed rather than sliced out of a rendered string.
    ///
    /// `String(year).suffix(2)` is a text operation standing in for arithmetic, and it always
    /// produces ASCII: the column ran Western digits down the side of a screen whose headings
    /// were formatted in the reader's own numbering system. The integer length keeps 2005
    /// reading as `05` rather than as `5`.
    /// The whole year, not the last two digits of it.
    ///
    /// Two digits read as a day of the month — a column showing 26, 25, 24, 23 beside headings
    /// that say 2026 and 2025 is asking the reader to do a conversion, and "09" beside "12" is
    /// ambiguous in a way a photo library cannot afford. Four digits fit in forty-four points
    /// at this size with room to spare, and shrink rather than clip when the reader's text is
    /// larger.
    private func shortYear(_ year: Int) -> String {
        year.formatted(.number.grouping(.never))
    }

    private var activeYearDescription: String {
        guard let year = active ?? years.first else { return "" }
        return year.formatted(.number.grouping(.never))
    }

    // MARK: Selection

    private func select(under y: CGFloat) {
        guard !years.isEmpty else { return }
        let index = min(max(Int(y / (rowHeight + rowSpacing)), 0), years.count - 1)
        let year = years[index]
        scrubbing = year
        guard year != emitted else { return }   // haptics and scrolling belong to changes only

        emitted = year
        active = year
        onSelect(year)
    }

    /// One year along the list, for the adjustable action.
    private func step(by offset: Int) {
        guard !years.isEmpty else { return }
        let current = active.flatMap { years.firstIndex(of: $0) } ?? 0
        let next = current + offset
        guard years.indices.contains(next) else { return }
        active = years[next]
        onSelect(years[next])
    }
}

/// Every frame from one month, a day at a time.
struct MonthGridView: View {
    let bucket: MonthBucket

    @Environment(\.app) private var app
    @Environment(\.bottomBarInset) private var bottomBarInset

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
                                // A grid of unlabelled buttons is a grid of "Button"s. What a
                                // tile is and when it was taken is the whole of its content.
                                .accessibilityLabel(description(of: record))
                            }
                        }
                    }
                }
            }
            .padding(.top, Space.s)
            .padding(.bottom, bottomBarInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.canvas)
        // Built by the date rather than by pasting a month name and a rendered integer
        // together: the order of the two is the locale's business, and so are the digits.
        .navigationTitle(Text(bucket.startDate, format: .dateTime.month(.wide).year()))
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
            Text(day.records.count.formatted(.number))
                .font(Typo.meta)
                .foregroundStyle(Palette.textTertiary)
                .accessibilityLabel(Text("^[\(day.records.count) photo](inflect: true)"))
            Spacer()
        }
        .padding(.horizontal, Space.gutter)
        // The date and its count are one sentence, and it is the heading of everything under
        // it — which is what lets the rotor step a day at a time through a busy month.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func tile(_ record: AssetRecord) -> some View {
        PhotoImageView(identifier: record.localIdentifier, targetSide: 240)
            .aspectRatio(1, contentMode: .fill)
            .clipShape(.rect(cornerRadius: Radius.gridTile))
            .overlay(alignment: .bottomLeading) {
                if record.isVideo || record.isLivePhoto {
                    MediaBadge(record: record).padding(5)
                }
            }
    }

    /// What a tile is, and when it was taken.
    ///
    /// The date is formatted rather than assembled, and the duration comes from `Duration`'s
    /// own units style, so a clip is announced as "forty-one seconds" in whatever language the
    /// reader has chosen rather than as the digits "0:41".
    private func description(of record: AssetRecord) -> String {
        let when = record.momentDate.formatted(date: .abbreviated, time: .omitted)
        if record.isVideo {
            let length = Duration.seconds(Int(record.duration.rounded()))
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
            return "Video, \(length), \(when)"
        }
        if record.isLivePhoto { return "Live Photo, \(when)" }
        return "Photo, \(when)"
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
