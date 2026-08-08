import SwiftData
import SwiftUI

/// A month where the days that have photographs show one, instead of a number.
///
/// Tapping a day opens that date across every year, which is the whole reason a calendar
/// belongs in this app at all.
struct CalendarView: View {
    @Environment(\.app) private var app
    /// The floating bar publishes what it measured; this screen ends above that rather than
    /// above a number written down once on one phone.
    @Environment(\.bottomBarInset) private var bottomBarInset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var anchor = Date.now
    @State private var buckets: [Int: DayBucket] = [:]
    @State private var openDay: TimeWindow?
    /// The width the grid was actually handed, which is what makes a day square. Read with
    /// `onGeometryChange` rather than a `GeometryReader`, which inside a scroll view would take
    /// the height as well and collapse the month.
    @State private var gridWidth: CGFloat = 0

    private let calendar = Calendar.current
    /// Four points between cells rather than six, and a 16-point margin rather than 20.
    /// Seven columns inside the old measurements left each day 42 points across on the
    /// smallest iPhone, which is under what a fingertip can be relied on to hit.
    private let cellSpacing: CGFloat = 4
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: cellSpacing), count: 7)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                monthHeader

                HStack(spacing: cellSpacing) {
                    // By index, not by the symbol: English gives S, M, T, W, T, F, S — two Ts
                    // and two Ss — and a `ForEach` keyed on the letter itself silently drops
                    // Thursday and Saturday.
                    ForEach(weekdaySymbols.indices, id: \.self) { index in
                        Text(weekdaySymbols[index])
                            .font(Typo.scaled(11, .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(Palette.textTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, Space.l)
                // The same ceiling as the grid it heads: several locales use two characters
                // here, and a two-character symbol at the largest sizes is wider than the
                // column it names.
                .chromeTypeSize()
                // Seven initials read aloud are seven meaningless characters — "S, M, T, W, T,
                // F, S" tells a reader who cannot see the columns nothing at all. The day cells
                // each name their own weekday instead, which is the information this row is
                // carrying visually.
                .accessibilityHidden(true)

                LazyVGrid(columns: columns, spacing: cellSpacing) {
                    ForEach(0..<leadingBlanks, id: \.self) { index in
                        Color.clear
                            .frame(height: cellSide)
                            .id("blank\(index)")
                            .accessibilityHidden(true)
                    }
                    ForEach(daysInMonth, id: \.self) { day in
                        dayCell(day)
                    }
                }
                .measuringWidth($gridWidth)
                .padding(.horizontal, Space.l)
                // A seven-column month is fixed geometry in the way a keyboard is: the number of
                // columns is a fact about weeks, not a layout choice, so this is one of the few
                // places the app puts a ceiling on how far its text may grow.
                .chromeTypeSize()
            }
            // A month is a square grid, and stretched across an iPad it stops being one: seven
            // flexible columns in a thousand points give days that are wider than they are tall
            // three times over. Capped and centred, which is what the system Calendar does.
            .readableMeasure(560)
            .padding(.top, Space.s)
            .padding(.bottom, bottomBarInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $openDay) { window in
            TimeWindowResultsView(window: window)
        }
        .task(id: anchorKey) { await load() }
    }

    // MARK: Pieces

    private var monthHeader: some View {
        HStack {
            // `chevron.left` and `chevron.right` name sides of the screen and never mirror,
            // while the row around them does: in a right-to-left layout Previous moved to the
            // right and kept pointing left, so both arrows contradicted their own position.
            // The backward/forward pair name the direction of travel and mirror themselves.
            monthStep(-1, symbol: "chevron.backward", label: "Previous month")

            Spacer()
            Text(anchor, format: .dateTime.month(.wide).year())
                .font(Typo.editorial(20))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            Spacer()

            monthStep(1, symbol: "chevron.forward", label: "Next month")
                .disabled(isCurrentMonth)
        }
        .padding(.horizontal, Space.m)
    }

    /// A chevron is fifteen points across, and a button is hit where it is drawn — which made
    /// walking through the months a game of hitting a fifteen-point square twice a second.
    private func monthStep(_ months: Int, symbol: String, label: String) -> some View {
        Button {
            step(months)
            Haptics.selection()
        } label: {
            Image(systemName: symbol)
                // A glyph inside a control whose size is what makes the header line up. It is
                // the label below that carries this button for a reader who needs larger text.
                .font(Typo.glyph(15))
                .frame(width: Hit.min, height: Hit.min)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func dayCell(_ day: Int) -> some View {
        let bucket = buckets[day]
        let cover = showsCovers ? bucket?.coverIdentifier : nil
        return Button {
            openDay = .dayAcrossYears(month: calendar.component(.month, from: anchor), day: day)
            Haptics.impact(.light)
        } label: {
            ZStack {
                if let cover {
                    PhotoImageView(identifier: cover, targetSide: cellSide)
                        .frame(height: cellSide)
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8).fill(dayScrim)
                        }
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(emptyFill(hasPhotos: bucket != nil))
                        .frame(height: cellSide)
                }

                Text(day.formatted(.number.grouping(.never)))
                    .font(Typo.scaled(12, bucket == nil ? .regular : .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(numberColour(over: cover != nil, hasPhotos: bucket != nil))
                    // The same treatment the selection check uses over a photograph: a tight
                    // dark edge, so the digit survives a bright frame rather than relying on
                    // the veil underneath it alone.
                    .shadow(color: .black.opacity(cover != nil ? 0.5 : 0), radius: 2, y: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(bucket == nil)
        .accessibilityLabel(Text("\(dayName(day)), ^[\(bucket?.count ?? 0) photo](inflect: true)"))
        .accessibilityHint("Opens this day in every year")
        // A month has twenty or so days with nothing in them, and each one used to be a stop
        // that said "no photos" and went nowhere. The days that have photographs are the
        // content of this screen; the empty ones are the grid they are drawn on.
        .accessibilityHidden(bucket == nil)
    }

    // MARK: Cell appearance

    /// A day is square, because a month is a grid of squares.
    ///
    /// The height was a constant while the width was `.flexible()`, so on anything wider than a
    /// phone each cell became a letterbox strip with a date floating on it. Derived from the
    /// width the grid was given, and never shorter than a finger — on the narrowest iPhone that
    /// makes a day slightly taller than it is wide, which is the right way to be wrong.
    private var cellSide: CGFloat {
        guard gridWidth > 0 else { return Hit.min }
        return max(Hit.min, (gridWidth - cellSpacing * 6) / 7)
    }

    /// Whether a day still shows its photograph.
    ///
    /// Reduce Transparency is a request for surfaces rather than for things seen through other
    /// things, and a twelve-point number lying on an arbitrary crop of a photograph is the
    /// clearest case of the second in the app. Those days fall back to the same sunk panel an
    /// empty day uses, with the number in full label colour.
    private var showsCovers: Bool { !reduceTransparency }

    /// `Palette.labelScrim` is the rule this codebase already wrote down for small white type
    /// sitting directly on a photograph, and this cell was using half of it — below even
    /// `photoScrim`, which is tuned for veiling a whole frame rather than backing a badge. Over
    /// snow, a white wall or a blown-out sky the day number simply disappeared, and the day
    /// number is the only thing telling the reader which cell is which.
    private var dayScrim: Color {
        contrast == .increased ? Color.black.opacity(0.72) : Palette.labelScrim
    }

    private func emptyFill(hasPhotos: Bool) -> Color {
        // A day whose photograph is being withheld is still a day with something in it, so it
        // keeps the solid tile; a day with nothing stays a faint one. Increase Contrast pushes
        // the faint one up until the grid itself is visible rather than implied.
        if hasPhotos { return Palette.surfaceSunk }
        return Palette.surfaceSunk.opacity(contrast == .increased ? 0.9 : 0.5)
    }

    /// A day number is information before it is a control.
    ///
    /// Empty days used to be drawn in `tertiaryLabel`, which over the faint tile beneath them
    /// is around two to one — a screenshot of a month with no photographs in it shows a grid of
    /// blank squares with something ghosted inside each. The contrast rules exempt a disabled
    /// control, but the thing being read here is *which day this is*, and without that the
    /// month cannot be navigated at all. Apple's own Calendar draws every date in full label
    /// colour and dims only what belongs to another month.
    ///
    /// So the hierarchy stays — a day with photographs is heavier and darker — but the floor
    /// moves up to `secondaryLabel`, and to full label colour when the reader has asked for
    /// more contrast.
    private func numberColour(over photograph: Bool, hasPhotos: Bool) -> Color {
        if photograph { return .white }
        if hasPhotos { return Palette.textPrimary }
        return contrast == .increased ? Palette.textPrimary : Palette.textSecondary
    }

    // MARK: Data

    private var anchorKey: Int {
        calendar.component(.year, from: anchor) * 100 + calendar.component(.month, from: anchor)
    }

    private var isCurrentMonth: Bool {
        calendar.isDate(anchor, equalTo: .now, toGranularity: .month)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var daysInMonth: [Int] {
        guard let range = calendar.range(of: .day, in: .month, for: anchor) else { return [] }
        return Array(range)
    }

    private var leadingBlanks: Int {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: anchor))
        else { return 0 }
        let weekday = calendar.component(.weekday, from: first)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    /// What the cell is called out loud. The weekday is in it because the header row that
    /// carries it visually is a line of single letters no reader can be asked to decode.
    private func dayName(_ day: Int) -> String {
        guard let date = buckets[day]?.date else { return day.formatted(.number.grouping(.never)) }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private func step(_ months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: anchor) else { return }
        if months > 0 && next > Date.now { return }
        // Moving the anchor re-lays out up to forty-two cells, most of them photographs, and
        // these chevrons are built to be pressed twice a second — so with Reduce Motion on the
        // month simply changes.
        if reduceMotion {
            anchor = next
        } else {
            withAnimation(.smooth(duration: 0.25)) { anchor = next }
        }
        // Nothing else on the screen says which month is showing now: the header changes
        // silently, and the reader's focus is still on the button they pressed.
        AccessibilityNotification.Announcement(
            next.formatted(.dateTime.month(.wide).year())
        ).post()
    }

    private func load() async {
        let indexer = LibraryIndexer(modelContainer: app.container)
        let found = await indexer.dayBuckets(
            year: calendar.component(.year, from: anchor),
            month: calendar.component(.month, from: anchor),
            options: .browsing
        )
        buckets = Dictionary(uniqueKeysWithValues: found.map { ($0.day, $0) })
    }
}
