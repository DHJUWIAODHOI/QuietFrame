import Foundation

extension VaultMedia {
    /// When the media was captured, falling back to when it was imported.
    var viewerDate: Date {
        originalCreationDate ?? importedAt
    }
}

/// The viewer's two-line caption: "12 March 2026" over "Thursday at 18:42".
func viewerCaption(
    for date: Date,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> (title: String, subtitle: String) {
    let style = viewerDateStyle(locale: locale, timeZone: timeZone)
    let title = date.formatted(style.day().month(.wide).year())
    let weekday = date.formatted(style.weekday(.wide))
    return (title, "\(weekday) at \(viewerTime(of: date, locale: locale, timeZone: timeZone))")
}

/// The full capture moment for the details panel: "Thursday 12 March 2026 at 18:42".
func viewerLongDate(
    _ date: Date,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    let style = viewerDateStyle(locale: locale, timeZone: timeZone)
    let day = date.formatted(style.weekday(.wide).day().month(.wide).year())
    return "\(day) at \(viewerTime(of: date, locale: locale, timeZone: timeZone))"
}

/// A playback position or duration as "0:14" or "1:02:03"; invalid or negative values read as zero.
func formattedPlaybackTime(_ seconds: TimeInterval) -> String {
    let clamped = seconds.isFinite ? min(max(seconds, 0), 359_999) : 0
    let totalSeconds = Int(clamped.rounded(.down))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let remainder = totalSeconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainder)
    }
    return String(format: "%d:%02d", minutes, remainder)
}

private func viewerDateStyle(locale: Locale, timeZone: TimeZone) -> Date.FormatStyle {
    var calendar = locale.calendar
    calendar.timeZone = timeZone
    return Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
}

private func viewerTime(of date: Date, locale: Locale, timeZone: TimeZone) -> String {
    var calendar = locale.calendar
    calendar.timeZone = timeZone
    return date.formatted(
        Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone)
    )
}
