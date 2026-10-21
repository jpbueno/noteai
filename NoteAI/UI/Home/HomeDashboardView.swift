import SwiftUI

struct CommandCenterLayout: Equatable {
    let scale: CGFloat
    let sidebarWidth: CGFloat
    let minimumSidebarWidth: CGFloat
    let maximumSidebarWidth: CGFloat
    let contentMaxWidth: CGFloat
    let commandSearchMaxWidth: CGFloat
    let sidebarBrandLeadingInset: CGFloat
    let sidebarBrandHeaderHeight: CGFloat
    let sidebarBrandHeaderTopPadding: CGFloat
    let sidebarBrandHeaderBottomPadding: CGFloat
    let controlHeight: CGFloat
    let actionButtonHeight: CGFloat
    let panelPadding: CGFloat
    let dashboardSpacing: CGFloat
    let onboardingMinimumCardWidth: CGFloat
    let metricMinimumCardWidth: CGFloat
    let titleFontSize: CGFloat
    let metricValueFontSize: CGFloat
    let sectionTitleFontSize: CGFloat
    let bodyFontSize: CGFloat
    let smallFontSize: CGFloat
    let tinyFontSize: CGFloat

    static func metrics(
        forWindowWidth windowWidth: CGFloat,
        preset: CommandCenterLayoutPreset = .balanced
    ) -> CommandCenterLayout {
        let width = max(760, windowWidth)
        let scale = min(1.0, max(0.88, width / 1600))
        let typeScale = min(1.0, max(0.96, width / 1700))
        let sidebarWidth = min(292, max(216, width * 0.155 + preset.sidebarWidthAdjustment))
        let contentMaxWidth = max(780, width - sidebarWidth - 80)
        let sidebarBrandLeadingInset: CGFloat = 14

        return CommandCenterLayout(
            scale: scale,
            sidebarWidth: sidebarWidth,
            minimumSidebarWidth: max(218, sidebarWidth - 44),
            maximumSidebarWidth: min(320, sidebarWidth + 60),
            contentMaxWidth: contentMaxWidth,
            commandSearchMaxWidth: min(520, max(360, width * 0.30)),
            sidebarBrandLeadingInset: sidebarBrandLeadingInset,
            sidebarBrandHeaderHeight: round(58 * scale),
            sidebarBrandHeaderTopPadding: round(18 * scale),
            sidebarBrandHeaderBottomPadding: round(8 * scale),
            controlHeight: min(39, max(36, round(38 * scale))),
            actionButtonHeight: min(42, max(38, round(41 * scale))),
            panelPadding: round(16 * scale * preset.panelPaddingMultiplier),
            dashboardSpacing: round(14 * scale * preset.spacingMultiplier),
            onboardingMinimumCardWidth: round(236 * scale * preset.cardWidthMultiplier),
            metricMinimumCardWidth: round(112 * scale * preset.cardWidthMultiplier),
            titleFontSize: min(28, max(26, round(28 * typeScale))),
            metricValueFontSize: min(22, max(21, round(22 * typeScale))),
            sectionTitleFontSize: min(15, max(14, round(15 * typeScale))),
            bodyFontSize: min(14, max(13, round(14 * typeScale))),
            smallFontSize: 12,
            tinyFontSize: 11
        )
    }
}

private struct CommandCenterLayoutKey: EnvironmentKey {
    static let defaultValue = CommandCenterLayout.metrics(forWindowWidth: 1100)
}

extension EnvironmentValues {
    var commandCenterLayout: CommandCenterLayout {
        get { self[CommandCenterLayoutKey.self] }
        set { self[CommandCenterLayoutKey.self] = newValue }
    }
}

struct HomeDashboardView: View {
    @Environment(\.commandCenterLayout) private var layout
    @AppStorage("noteai.setupChecklistCollapsed") private var setupChecklistCollapsed = false
    @ObservedObject var meetingManager: MeetingManager
    let onSelectMeeting: (UUID) -> Void
    let onOpenHistory: () -> Void
    let onStartMeeting: () -> Void
    let onOnboardingAction: (OnboardingChecklistItem) -> Void

    private var recentMeetings: [Meeting] {
        Array(LibraryListOrdering.meetings(meetingManager.filteredMeetings).prefix(5))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: layout.dashboardSpacing) {
                header
                capturePanel
                recentMeetingsPanel
                onboardingPanel
            }
            .frame(maxWidth: layout.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 32)
        }
        .background(Theme.notionWindowBG)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Meeting workspace")
                .font(.system(size: layout.tinyFontSize + 1, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
            Text("Your meetings")
                .font(.system(size: layout.titleFontSize, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Capture conversations, revisit transcripts, and get help from AI Solutions Architect.")
                .font(.system(size: layout.bodyFontSize + 1))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var capturePanel: some View {
        CommandCenterPanel {
            DashboardPanelHeader(
                title: AppEnvironment.usesTranscriptImportPrimaryFlow ? "Import a meeting" : "Meeting capture",
                subtitle: AppEnvironment.usesTranscriptImportPrimaryFlow
                    ? "Bring a Teams transcript into your meeting history."
                    : "AI Solutions Architect follows the live transcript and answers your questions.",
                tone: .accent
            ) {
                EmptyView()
            }

            Button(action: onStartMeeting) {
                Label(
                    AppEnvironment.usesTranscriptImportPrimaryFlow
                        ? "Import Teams transcript"
                        : meetingManager.state == .recording
                            ? "Open live transcript"
                            : meetingManager.recordingReadiness.primaryActionTitle,
                    systemImage: AppEnvironment.usesTranscriptImportPrimaryFlow ? "text.badge.plus" : "waveform"
                )
                .font(.system(size: layout.bodyFontSize, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 14)
                .frame(height: layout.actionButtonHeight)
                .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.32), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var recentMeetingsPanel: some View {
        CommandCenterPanel {
            DashboardPanelHeader(
                title: "Recent meetings",
                subtitle: "\(meetingManager.filteredMeetings.count) meetings in your history",
                tone: .neutralAccent
            ) {
                Button("View all", action: onOpenHistory)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }

            if recentMeetings.isEmpty {
                Text(meetingManager.searchQuery.isEmpty
                    ? "Record or import a meeting to start your history."
                    : "No meetings match your search.")
                    .font(.system(size: layout.bodyFontSize))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 16)
            } else {
                ForEach(recentMeetings) { meeting in
                    Button {
                        onSelectMeeting(meeting.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: LibraryListPresentation.SidebarItemKind.meeting.icon)
                                .foregroundStyle(LibraryListPresentation.SidebarItemKind.meeting.tint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(meeting.title)
                                    .font(.system(size: layout.bodyFontSize, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Text("\(meeting.date.formatted(date: .abbreviated, time: .shortened)) • \(meeting.formattedDuration)")
                                    .font(.system(size: layout.smallFontSize))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: layout.smallFontSize, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var onboardingPanel: some View {
        let checklist = meetingManager.onboardingChecklist
        let isCollapsed = setupChecklistCollapsed && checklist.canCollapse
        return CommandCenterPanel {
            DashboardPanelHeader(
                title: "Setup checklist",
                subtitle: "\(checklist.completedCount)/\(checklist.totalCount) complete\(checklist.requiredReady ? " - ready for capture" : " - finish required items before the first recording")",
                tone: checklist.requiredReady ? .done : .warning
            ) {
                Text(checklist.requiredReady ? "Ready" : "Setup needed")
                    .font(.system(size: layout.tinyFontSize + 1, weight: .bold))
                    .foregroundStyle(checklist.requiredReady ? Theme.success : Theme.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        (checklist.requiredReady ? Theme.success : Theme.warning).opacity(0.13),
                        in: Capsule()
                    )
                if checklist.canCollapse {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            setupChecklistCollapsed.toggle()
                        }
                    } label: {
                        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: layout.smallFontSize, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 26, height: 26)
                            .background(Theme.notionSurfaceBG, in: Circle())
                            .overlay(Circle().stroke(Theme.rowBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(isCollapsed ? "Expand setup checklist" : "Collapse setup checklist")
                }
            }

            if !isCollapsed {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: layout.onboardingMinimumCardWidth), spacing: 8)], spacing: 8) {
                    ForEach(checklist.items) { item in
                        onboardingRow(item)
                    }
                }
                .padding(.top, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            meetingManager.refreshOnboardingChecklistState()
            if !checklist.canCollapse {
                setupChecklistCollapsed = false
            }
        }
        .onChange(of: checklist.canCollapse) { _, canCollapse in
            if !canCollapse {
                setupChecklistCollapsed = false
            }
        }
    }

    private func onboardingRow(_ item: OnboardingChecklistItem) -> some View {
        Button {
            onOnboardingAction(item)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: onboardingIcon(for: item.status))
                    .font(.system(size: layout.bodyFontSize + 2, weight: .semibold))
                    .foregroundStyle(onboardingColor(for: item.status))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(item.label)
                            .font(.system(size: layout.bodyFontSize, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if item.required {
                            Text("Required")
                                .font(.system(size: layout.tinyFontSize - 1, weight: .bold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(item.detail)
                        .font(.system(size: layout.smallFontSize))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(3)
                    if let actionLabel = item.actionLabel,
                       item.actionTarget != nil,
                       item.status != .complete {
                        Label(actionLabel, systemImage: "gearshape")
                            .font(.system(size: layout.tinyFontSize + 1, weight: .bold))
                            .foregroundStyle(Theme.accent)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: max(72, round(82 * layout.scale)), alignment: .topLeading)
            .background(Theme.notionSurfaceBG, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.rowBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(item.status == .complete || item.actionTarget == nil)
        .help(item.status == .complete || item.actionTarget == nil ? "" : "Open setup action")
    }

    private func onboardingIcon(for status: OnboardingItemStatus) -> String {
        switch status {
        case .complete:
            return "checkmark.circle.fill"
        case .needsAction:
            return "circle"
        case .blocked, .unsupported:
            return "exclamationmark.triangle.fill"
        }
    }

    private func onboardingColor(for status: OnboardingItemStatus) -> Color {
        switch status {
        case .complete:
            return Theme.success
        case .needsAction:
            return Theme.textTertiary
        case .blocked, .unsupported:
            return Theme.warning
        }
    }

}

private struct CommandCenterPanel<Content: View>: View {
    @Environment(\.commandCenterLayout) private var layout
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(layout.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.notionSurfaceBG, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
    }
}

private enum DashboardPanelTone {
    case neutralAccent
    case accent
    case danger
    case done
    case warning

    var color: Color {
        switch self {
        case .neutralAccent:
            return Color(hex: "60A5FA")
        case .accent:
            return Theme.accent
        case .danger:
            return Theme.danger
        case .done:
            return Theme.success
        case .warning:
            return Theme.warning
        }
    }
}

private struct DashboardPanelHeader<Accessory: View>: View {
    @Environment(\.commandCenterLayout) private var layout
    let title: String
    let subtitle: String
    let tone: DashboardPanelTone
    let accessory: Accessory

    init(
        title: String,
        subtitle: String,
        tone: DashboardPanelTone,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tone = tone
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(tone.color)
                .frame(width: 10, height: 10)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: layout.bodyFontSize + 1, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: layout.smallFontSize))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                accessory
            }
        }
        .padding(.bottom, 12)
    }
}
