import SwiftData
import SwiftUI

/// A month where the days that have photographs show one, instead of a number.
///
/// Tapping a day opens that date across every year, which is the whole reason a calendar
/// belongs in this app at all.
struct CalendarView: View {
    @Environment(\.app) private var app

    @State private var anchor = Date.now
    @State private var buckets: [Int: DayBucket] = [:]
    @State private var openDay: TimeWindow?

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                monthHeader

                HStack(spacing: 6) {
                    ForEach(weekdaySymbols, id: \.self) { symbol in
                        Text(symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.textTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, Space.gutter)

                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(0..<leadingBlanks, id: \.self) { index in
                        Color.clear.frame(height: 46).id("blank\(index)")
                    }
                    ForEach(daysInMonth, id: \.self) { day in
                        dayCell(day)
                    }
                }
                .padding(.horizontal, Space.gutter)
            }
            .padding(.top, Space.s)
            .padding(.bottom, 132)
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
            Button { step(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous month")

            Spacer()
            Text(anchor, format: .dateTime.month(.wide).year())
                .font(Typo.editorial(20))
                .foregroundStyle(Palette.textPrimary)
            Spacer()

            Button { step(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(isCurrentMonth)
            .accessibilityLabel("Next month")
        }
        .padding(.horizontal, Space.gutter)
    }

    private func dayCell(_ day: Int) -> some View {
        let bucket = buckets[day]
        return Button {
            openDay = .dayAcrossYears(month: calendar.component(.month, from: anchor), day: day)
            Haptics.impact(.light)
        } label: {
            ZStack {
                if let cover = bucket?.coverIdentifier {
                    PhotoImageView(identifier: cover, targetSide: 120)
                        .frame(height: 46)
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28))
                        }
                    Text("\(day)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Palette.surfaceSunk.opacity(0.5))
                        .frame(height: 46)
                    Text("\(day)")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(bucket == nil)
        .accessibilityLabel("\(day), \(bucket?.count ?? 0) photos")
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

    private func step(_ months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: anchor) else { return }
        if months > 0 && next > Date.now { return }
        withAnimation(.smooth(duration: 0.25)) { anchor = next }
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
