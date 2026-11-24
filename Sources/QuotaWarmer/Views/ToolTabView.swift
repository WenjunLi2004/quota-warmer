import SwiftUI

struct ToolTabView: View {
    @ObservedObject var toolState: ToolState
    let onSetMode: (ToolMode) -> Void
    let onActivate: () -> Void
    let onRefresh: () -> Void
    var onDisable: (() -> Void)? = nil

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                header
                quotaList
                actions
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 16)
        }
        .background(DS.C.bg)
        .onReceive(ticker) { t in now = t }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 9) {
                Image(toolState.tool.assetName)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(DS.C.text)
                // A page title, not a banner: 22pt bold here left this tab on a
                // different type scale from the overview it is reached from.
                Text(toolState.tool.shortName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DS.C.text)
            }
            Spacer()
            if toolState.isFetchingQuota {
                Image(systemName: "hourglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.C.textSub)
            }
            activeControl
        }
    }

    private var quotaList: some View {
        VStack(alignment: .leading, spacing: 22) {
            windowRow(
                title: "Session",
                metric: toolState.primaryMetric,
                resetAt: toolState.resetAt,
                windowDuration: toolState.tool.windowDuration
            )
            windowRow(
                title: "Weekly",
                metric: toolState.weeklyMetric,
                resetAt: toolState.weeklyMetric?.resetAt,
                windowDuration: toolState.tool.weeklyWindowDuration
            )
            if let extras = toolState.quotaSnapshot?.extras, !extras.isEmpty {
                extraPoolsSection(extras)
            }
            tokenUsageSection
            if let issue = ToolStatusCopy.providerIssue(for: toolState) {
                Text(issue)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DS.C.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func extraPoolsSection(_ extras: [QuotaMetric]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider().overlay(DS.C.borderSoft)
            Text("Other Pools")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.C.textMuted)
            ForEach(extras) { extra in
                let isWeekly = extra.name.lowercased().contains("week")
                windowRow(
                    title: extra.name,
                    metric: extra,
                    resetAt: extra.resetAt,
                    windowDuration: isWeekly ? toolState.tool.weeklyWindowDuration : toolState.tool.windowDuration
                )
            }
        }
    }

    private func windowRow(title: String, metric: QuotaMetric?, resetAt: Date?, windowDuration: TimeInterval) -> some View {
        let quotaLeft = metric?.remainingFraction ?? 0
        let effectiveReset = metric?.isIdleFiveHourWindow == true ? nil : resetAt
        let leftText = ToolStatusCopy.quotaLeftText(for: toolState, metric: metric)
        let pace = QuotaPace.compute(
            quotaLeft: quotaLeft,
            resetAt: effectiveReset,
            windowDuration: windowDuration,
            now: now,
            fallbackResetText: fallbackResetText(metric: metric)
        )
        return QuotaWindowRow(
            title: title,
            hasMetric: metric != nil,
            quotaLeft: quotaLeft,
            leftText: leftText,
            pace: pace,
            refreshing: toolState.isFetchingQuota,
            statusColor: ToolStatusCopy.rowStatusColor(for: toolState, hasMetric: metric != nil)
        )
    }

    private var tokenUsageSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
                .overlay(DS.C.borderSoft)
            HStack(spacing: 6) {
                Text("Token Spend")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.C.textMuted)
                Spacer(minLength: 8)
                if toolState.isFetchingTokenUsage {
                    Image(systemName: "hourglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.C.textMuted)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                tokenUsageRow("Today", usage: toolState.tokenUsageSummary?.today, showBreakdownInline: true)
                tokenUsageRow("Yesterday", usage: toolState.tokenUsageSummary?.yesterday)
                tokenUsageRow("Last 30 Days", usage: toolState.tokenUsageSummary?.last30Days)
            }
        }
    }

    private func tokenUsageRow(_ title: String, usage: TokenUsageDay?, showBreakdownInline: Bool = false) -> some View {
        let breakdown = tokenBreakdownText(usage)
        return VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.C.textSub)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(tokenUsageValue(usage))
                    .font(DS.mono(11, weight: .semibold))
                    .foregroundStyle(usage == nil ? DS.C.textMuted : DS.C.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }
            if showBreakdownInline, let breakdown {
                Text(breakdown)
                    .font(DS.mono(9.5, weight: .regular))
                    .foregroundStyle(DS.C.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .help(breakdown ?? "")
    }

    private func tokenBreakdownText(_ usage: TokenUsageDay?) -> String? {
        guard let usage, usage.totalTokens > 0 else { return nil }
        guard usage.uncachedInputTokens > 0 || usage.cachedInputTokens > 0 || usage.outputTokens > 0 else {
            return nil
        }
        return "New in \(shortTokenNumber(usage.uncachedInputTokens)) · Cached \(shortTokenNumber(usage.cachedInputTokens)) · Out \(shortTokenNumber(usage.outputTokens))"
    }

    private func tokenUsageValue(_ usage: TokenUsageDay?) -> String {
        guard let usage else { return "--" }
        return "\(formatCost(usage.costUSD)) · \(formatTokenCount(usage.totalTokens))"
    }

    private func formatCost(_ value: Double?) -> String {
        guard let value else { return "$--" }
        return String(format: "$%.2f", value)
    }

    private func shortTokenNumber(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return "\(compactCount(count, divisor: 1_000_000_000))B"
        }
        if count >= 1_000_000 {
            return "\(compactCount(count, divisor: 1_000_000))M"
        }
        if count >= 1_000 {
            return "\(compactCount(count, divisor: 1_000))K"
        }
        return Self.integerFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private func formatTokenCount(_ count: Int) -> String {
        "\(shortTokenNumber(count)) tokens"
    }

    private func compactCount(_ count: Int, divisor: Double) -> String {
        let scaled = Double(count) / divisor
        if scaled >= 10 {
            return "\(Int(scaled.rounded()))"
        }
        return trimmed(scaled)
    }

    private func trimmed(_ value: Double) -> String {
        let formatted = String(format: "%.1f", value)
        return formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted
    }

    private func fallbackResetText(metric: QuotaMetric?) -> String {
        ToolStatusCopy.resetFallback(for: toolState, metric: metric)
    }

    private var activeControl: some View {
        ToolModeMenu(mode: toolState.mode) { onSetMode($0) }
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: onActivate) {
                Label("Warm", systemImage: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(height: 32)
                    .padding(.horizontal, 14)
                    .foregroundStyle(.white)
                    .background(DS.C.accent(toolState.tool), in: Capsule())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(toolState.isWarming)
            .accessibilityLabel(Text("Warm \(toolState.tool.shortName) now"))

            Button(action: onRefresh) {
                Label("Refresh", systemImage: toolState.isFetchingQuota ? "hourglass" : toolState.quotaBackoffActive ? "clock.arrow.circlepath" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(height: 32)
                    .padding(.horizontal, 14)
                    .foregroundStyle(DS.C.textSub)
                    .background(DS.C.surfaceHigh, in: Capsule())
                    .overlay(Capsule().stroke(DS.C.border, lineWidth: 1))
            }
            .buttonStyle(PressableButtonStyle())
            // See MainTabView: a rate-limit backoff must not disable Refresh.
            .disabled(toolState.isFetchingQuota)
            .accessibilityLabel(Text("Refresh \(toolState.tool.shortName) quota now"))

            if let onDisable {
                Spacer(minLength: 4)
                Button(action: onDisable) {
                    Label("Turn Off", systemImage: "power")
                        .font(.system(size: 11.5, weight: .semibold))
                        .frame(height: 32)
                        .padding(.horizontal, 11)
                        .foregroundStyle(DS.C.textMuted)
                        .background(DS.C.surfaceHigh, in: Capsule())
                        .overlay(Capsule().stroke(DS.C.border, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
                .help("Turn off \(toolState.tool.displayName) — re-enable anytime in Overview or Settings")
                .accessibilityLabel(Text("Turn off \(toolState.tool.displayName)"))
            }
        }
    }
}

struct LogEntryView: View {
    let entry: WarmupLog
    let accent: Color

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(Self.formatter.string(from: entry.timestamp))
                    .font(DS.mono(8))
                    .foregroundStyle(DS.C.textMuted)
                Text(entry.mode.uppercased())
                    .font(DS.mono(8, weight: .bold))
                    .foregroundStyle(accent)
                Text(entry.command)
                    .font(DS.mono(9))
                    .foregroundStyle(DS.C.textSub)
            }
            Text(entry.output)
                .font(DS.mono(9))
                .foregroundStyle(DS.C.textSub)
                .textSelection(.enabled)
                .lineLimit(6)
        }
        .padding(DS.Space.sm)
        .background(DS.C.bg, in: RoundedRectangle(cornerRadius: DS.R.sm))
        .overlay(RoundedRectangle(cornerRadius: DS.R.sm).stroke(DS.C.border))
    }
}

/// Off / Monitor / Auto-warm selector used in the tool tab and the main
/// provider rows. Rendered as a plain, always-visible button (a colored dot +
/// the mode label) that cycles through the three modes on click — deliberately
/// not a `Menu`, which renders unreliably inside the menu-bar popover.
struct ToolModeMenu: View {
    let mode: ToolMode
    var compact: Bool = false
    let onSelect: (ToolMode) -> Void

    var body: some View {
        Button(action: { onSelect(mode.next) }) {
            HStack(spacing: 5) {
                StatusDot(color: ToolModeMenu.color(mode), size: 7)
                Text(mode.label)
                    .font(.system(size: compact ? 10 : 12, weight: .semibold))
                    .foregroundStyle(DS.C.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: compact ? 26 : 28)
            .background(DS.C.surface, in: Capsule())
            .overlay(Capsule().stroke(ToolModeMenu.color(mode).opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
        .help("Mode: \(mode.label). Click to cycle Off → Monitor → Auto-warm.")
        .accessibilityLabel(Text("Mode: \(mode.label). Activate to change."))
    }

    static func color(_ mode: ToolMode) -> Color {
        switch mode {
        case .off:      return DS.C.textMuted
        case .monitor:  return DS.C.blue
        case .autoWarm: return DS.C.green
        }
    }
}
