import SwiftUI

struct ToolTabView: View {
    @ObservedObject var toolState: ToolState
    let onSetMode: (ToolMode) -> Void
    let onActivate: () -> Void
    let onRefresh: () -> Void
    var onDisable: (() -> Void)? = nil

    private enum SpendPeriod: String {
        case today = "Today"
        case yesterday = "Yesterday"
        case last30Days = "Last 30 Days"
    }

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()
    @State private var selectedSpendPeriod: SpendPeriod? = nil

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
        .onChange(of: toolState.tool) { _, _ in selectedSpendPeriod = nil }
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
        VStack(alignment: .leading, spacing: toolState.tool == .antigravity ? 16 : 22) {
            if toolState.tool == .antigravity {
                if let metrics = toolState.quotaSnapshot?.displayMetrics, !metrics.isEmpty {
                    ForEach(metrics) { metric in
                        windowRow(
                            title: metric.name,
                            metric: metric,
                            resetAt: metric.resetAt,
                            windowDuration: metric.windowDurationSeconds
                                ?? AntigravityDisplaySlots.windowDuration(for: metric.name, tool: .antigravity)
                        )
                    }
                } else if toolState.primaryMetric != nil || toolState.weeklyMetric != nil {
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
                } else {
                    ForEach(AntigravityDisplaySlots.defaultTitles, id: \.self) { slotTitle in
                        windowRow(
                            title: slotTitle,
                            metric: nil,
                            resetAt: nil,
                            windowDuration: AntigravityDisplaySlots.windowDuration(for: slotTitle, tool: .antigravity)
                        )
                    }
                }
            } else {
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
            VStack(alignment: .leading, spacing: 5) {
                tokenUsageRow(.today, usage: toolState.tokenUsageSummary?.today)
                tokenUsageRow(.yesterday, usage: toolState.tokenUsageSummary?.yesterday)
                tokenUsageRow(.last30Days, usage: toolState.tokenUsageSummary?.last30Days)
            }
            if let period = selectedSpendPeriod,
               let day = usageDay(for: period) {
                TokenBreakdownCard(
                    title: period.rawValue,
                    day: day,
                    accent: DS.C.accent(toolState.tool)
                )
                .padding(.top, 2)
            }
        }
    }

    private func usageDay(for period: SpendPeriod) -> TokenUsageDay? {
        guard let summary = toolState.tokenUsageSummary else { return nil }
        switch period {
        case .today:      return summary.today
        case .yesterday:  return summary.yesterday
        case .last30Days: return summary.last30Days
        }
    }

    private func tokenUsageRow(_ period: SpendPeriod, usage: TokenUsageDay?) -> some View {
        let isSelected = selectedSpendPeriod == period
        let breakdown = tokenBreakdownText(usage)
        return Button(action: {
            guard usage != nil else { return }
            selectedSpendPeriod = isSelected ? nil : period
        }) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(period.rawValue)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.C.textSub)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(tokenUsageValue(usage))
                    .font(DS.mono(11, weight: .semibold))
                    .foregroundStyle(usage == nil ? DS.C.textMuted : DS.C.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
                    .padding(.horizontal, isSelected ? 7 : 0)
                    .padding(.vertical, isSelected ? 2 : 0)
                    .background(
                        Capsule()
                            .fill(isSelected ? DS.C.surfaceHigh : Color.clear)
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(breakdown ?? "Click to inspect token breakdown")
    }

    private func tokenBreakdownText(_ usage: TokenUsageDay?) -> String? {
        guard let usage, usage.totalTokens > 0 else { return nil }
        guard usage.uncachedInputTokens > 0 || usage.cachedInputTokens > 0 || usage.outputTokens > 0 else {
            return nil
        }
        return "Cache Read \(TokenFormatting.shortNumber(usage.cachedInputTokens)) · Input \(TokenFormatting.shortNumber(usage.uncachedInputTokens)) · Output \(TokenFormatting.shortNumber(usage.outputTokens))"
    }

    private func tokenUsageValue(_ usage: TokenUsageDay?) -> String {
        guard let usage else { return "--" }
        return "\(TokenFormatting.cost(usage.costUSD)) · \(TokenFormatting.tokensLabel(usage.totalTokens))"
    }

    private func fallbackResetText(metric: QuotaMetric?) -> String {
        ToolStatusCopy.resetFallback(for: toolState, metric: metric)
    }

    private var activeControl: some View {
        ToolModeMenu(mode: toolState.mode) { onSetMode($0) }
    }

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
