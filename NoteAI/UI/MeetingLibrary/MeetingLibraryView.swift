import AVFoundation
import AppKit
import CoreGraphics
import SwiftUI

enum SidebarSelection: Hashable {
    case home
    case meetingsList
    case meeting(UUID)
}

private enum SidebarSectionID: Hashable {
    case meetings
}

struct SidebarListSlice<Element> {
    let items: [Element]
    let hiddenCount: Int
    let canToggle: Bool
}

enum SidebarListLimiter {
    static func slice<Element>(
        _ items: [Element],
        expanded: Bool,
        searchActive: Bool,
        limit: Int
    ) -> SidebarListSlice<Element> {
        let visibleLimit = max(0, limit)
        let canToggle = !searchActive && items.count > visibleLimit

        guard canToggle, !expanded else {
            return SidebarListSlice(items: items, hiddenCount: 0, canToggle: canToggle)
        }

        return SidebarListSlice(
            items: Array(items.prefix(visibleLimit)),
            hiddenCount: max(0, items.count - visibleLimit),
            canToggle: true
        )
    }
}

struct MeetingLibraryView: View {
    @ObservedObject var meetingManager: MeetingManager
    @ObservedObject var authManager: GoogleAuthManager
    @ObservedObject var ttsService: TextToSpeechService
    @State private var selection: SidebarSelection? = .home
    @State private var settingsWindow: NSWindow?
    @State private var sidebarWidth: CGFloat = 0
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var sidebarCollapsed = false
    @State private var collapsedSections: Set<SidebarSectionID> = []
    @State private var openTabs: [SidebarSelection] = [.home]
    @State private var sidebarSearchExpanded = false
    @State private var showTranscriptImport = false
    @FocusState private var searchFocused: Bool
    @AppStorage("noteai.commandCenterLayoutPreset") private var commandCenterLayoutPresetRaw = CommandCenterLayoutPreset.balanced.rawValue
    @AppStorage("noteai.sidebarExpandedLists.v1") private var sidebarExpandedListsRaw = ""

    private let sidebarDividerHitWidth: CGFloat = 8
    private let sidebarDefaultVisibleCount = 5

    private func datePrefix(_ date: Date) -> String {
        LibraryListPresentation.shortDateString(for: date)
    }

    var body: some View {
        GeometryReader { proxy in
            let layoutPreset = CommandCenterLayoutPreset(rawValue: commandCenterLayoutPresetRaw) ?? .balanced
            let layout = CommandCenterLayout.metrics(forWindowWidth: proxy.size.width, preset: layoutPreset)
            let effectiveSidebarWidth = resolvedSidebarWidth(for: layout)

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if !sidebarCollapsed {
                        sidebar(layout: layout)
                            .frame(width: effectiveSidebarWidth)
                            .ignoresSafeArea(edges: .top)
                    }
                    ZStack {
                        VStack(spacing: 0) {
                            commandBar(layout: layout)
                            detail
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                }

                if !sidebarCollapsed {
                    sidebarResizeDivider(layout: layout, effectiveSidebarWidth: effectiveSidebarWidth)
                        .ignoresSafeArea(edges: .top)
                }
            }
            .environment(\.commandCenterLayout, layout)
        }
        .background(Theme.notionWindowBG)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            meetingManager.refreshOnboardingChecklistState()
        }
        .onChange(of: selection) { _, newSelection in
            if let newSelection {
                registerOpenTab(newSelection)
            }
        }
        .sheet(isPresented: $meetingManager.showMeetingNamePrompt) {
            MeetingNamePromptView(
                suggestedName: $meetingManager.pendingMeetingName,
                onSave: { name in
                    meetingManager.finishRecording(name: name)
                },
                onCancel: {
                    meetingManager.finishRecording(name: meetingManager.pendingMeetingName)
                },
                onDiscard: {
                    meetingManager.discardPendingRecording()
                }
            )
        }
        .sheet(isPresented: $showTranscriptImport) {
            TranscriptImportView { title, rawTranscript in
                Task {
                    if let meeting = await meetingManager.importTranscriptMeeting(
                        title: title,
                        rawTranscript: rawTranscript
                    ) {
                        selection = .meeting(meeting.id)
                    }
                }
            }
        }
    }

    private func resolvedSidebarWidth(for layout: CommandCenterLayout) -> CGFloat {
        guard sidebarWidth > 0 else { return layout.sidebarWidth }
        return min(layout.maximumSidebarWidth, max(layout.minimumSidebarWidth, sidebarWidth))
    }

    private func sidebarResizeDivider(layout: CommandCenterLayout, effectiveSidebarWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: max(0, effectiveSidebarWidth - sidebarDividerHitWidth / 2))
                .allowsHitTesting(false)
            ZStack {
                Color.clear
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1)
            }
            .frame(width: sidebarDividerHitWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(sidebarResizeGesture(layout: layout, effectiveSidebarWidth: effectiveSidebarWidth))
            Spacer(minLength: 0)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func sidebarResizeGesture(layout: CommandCenterLayout, effectiveSidebarWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let startWidth = sidebarDragStartWidth ?? effectiveSidebarWidth
                sidebarDragStartWidth = startWidth
                sidebarWidth = min(
                    layout.maximumSidebarWidth,
                    max(layout.minimumSidebarWidth, startWidth + value.translation.width)
                )
            }
            .onEnded { _ in
                sidebarDragStartWidth = nil
            }
    }

    // MARK: - Command bar

    private func commandBar(layout: CommandCenterLayout) -> some View {
        HStack(spacing: 12) {
            if sidebarCollapsed {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { sidebarCollapsed = false }
                } label: {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: layout.sectionTitleFontSize + 2, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: layout.controlHeight, height: layout.controlHeight)
                        .background(Theme.notionSurfaceBG.opacity(0.95), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Show sidebar")
            }

            notionTabBar(layout: layout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            topBarRecordingControl(layout: layout)

        }
        .padding(.leading, sidebarCollapsed ? round(10 * layout.scale) : round(18 * layout.scale))
        .padding(.trailing, round(18 * layout.scale))
        .frame(height: max(48, round(52 * layout.scale)))
        .background(Theme.notionTopBarBG)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
        }
    }

    private func notionTabBar(layout: CommandCenterLayout) -> some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { sidebarCollapsed.toggle() }
            } label: {
                Image(systemName: sidebarCollapsed ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: layout.bodyFontSize + 1, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: round(36 * layout.scale), height: max(34, layout.controlHeight))
            }
            .buttonStyle(.plain)
            .help(sidebarCollapsed ? "Show sidebar" : "Hide sidebar")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(openTabs, id: \.self) { tab in
                        notionTabButton(tab, layout: layout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .background(Theme.notionTopBarBG)
    }

    private func notionTabButton(_ tab: SidebarSelection, layout: CommandCenterLayout) -> some View {
        let isActive = selection == tab
        return HStack(spacing: 8) {
            Image(systemName: notionTabIcon(for: tab))
                .font(.system(size: layout.bodyFontSize + 1, weight: .semibold))
                .foregroundStyle(notionTabAccent(for: tab))
            Text(notionTabTitle(for: tab))
                .font(.system(size: layout.bodyFontSize + 1, weight: .semibold))
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button {
                closeTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: max(8, layout.tinyFontSize), weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: round(18 * layout.scale), height: round(18 * layout.scale))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close tab")
        }
        .padding(.horizontal, round(14 * layout.scale))
        .frame(minWidth: round(180 * layout.scale), maxWidth: round(280 * layout.scale), minHeight: max(34, layout.controlHeight))
        .background(isActive ? Theme.notionActiveTabBG : Theme.notionTopBarBG)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isActive ? Theme.notionActiveTabBG : Theme.border)
                .frame(height: 1)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            activateSelection(tab)
        }
        .help(notionTabTitle(for: tab))
    }

    private func notionTabTitle() -> String {
        notionTabTitle(for: selection)
    }

    private func notionTabTitle(for tab: SidebarSelection?) -> String {
        guard let tab else { return meetingManager.state == .recording ? "Live Recording" : "Meetings" }
        switch tab {
        case .home:
            return "Overview"
        case .meetingsList:
            return "Meetings"
        case .meeting(let id):
            return meetingManager.meetings.first(where: { $0.id == id })?.title.replacingOccurrences(of: "Microsoft Teams", with: "Teams") ?? "Meeting"
        }
    }

    private func notionTabIcon() -> String {
        notionTabIcon(for: selection)
    }

    private func notionTabIcon(for tab: SidebarSelection?) -> String {
        guard let tab else { return meetingManager.state == .recording ? "waveform" : "house" }
        switch tab {
        case .home:
            return LibraryListPresentation.SidebarItemKind.home.icon
        case .meetingsList, .meeting:
            return LibraryListPresentation.SidebarItemKind.meeting.icon
        }
    }

    private func notionTabAccent() -> Color {
        notionTabAccent(for: selection)
    }

    private func notionTabAccent(for tab: SidebarSelection?) -> Color {
        guard let tab else { return meetingManager.state == .recording ? Theme.danger : Theme.notionIconAccent }
        switch tab {
        case .home:
            return LibraryListPresentation.SidebarItemKind.home.tint
        case .meetingsList, .meeting:
            return LibraryListPresentation.SidebarItemKind.meeting.tint
        }
    }

    private func topBarRecordingControl(layout: CommandCenterLayout) -> some View {
        return Group {
            if AppEnvironment.usesTranscriptImportPrimaryFlow {
                Button {
                    showTranscriptImport = true
                } label: {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: layout.smallFontSize, weight: .bold))
                        .foregroundStyle(LibraryListPresentation.SidebarItemKind.meeting.tint.opacity(0.95))
                        .frame(width: round(34 * layout.scale), height: round(34 * layout.scale))
                        .background(LibraryListPresentation.SidebarItemKind.meeting.tint.opacity(0.08), in: Capsule())
                        .overlay(Capsule().stroke(LibraryListPresentation.SidebarItemKind.meeting.tint.opacity(0.42), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(meetingManager.state == .processing)
                .opacity(meetingManager.state == .processing ? 0.55 : 1)
                .accessibilityLabel(Text("Import Teams transcript"))
                .help("Import Teams transcript")
            } else if meetingManager.state == .recording {
                HStack(spacing: round(8 * layout.scale)) {
                    Circle()
                        .fill(Theme.danger)
                        .frame(width: round(8 * layout.scale), height: round(8 * layout.scale))
                    Image(systemName: LibraryListPresentation.SidebarItemKind.meeting.icon)
                        .font(.system(size: layout.smallFontSize, weight: .semibold))
                        .foregroundStyle(LibraryListPresentation.SidebarItemKind.meeting.tint)
                    Text(formattedDuration)
                        .font(.system(size: layout.tinyFontSize + 1, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.danger)
                    Button {
                        meetingManager.stopRecording()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: layout.tinyFontSize - 1, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: round(22 * layout.scale), height: round(22 * layout.scale))
                            .background(Theme.danger, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, round(10 * layout.scale))
                .frame(height: layout.controlHeight)
                .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.danger.opacity(0.30), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture {
                    selection = nil
                }
                .accessibilityLabel(Text("Show live transcription"))
                .accessibilityAddTraits(.isButton)
                .help("Show live transcription")
            } else {
                Button {
                    meetingManager.startRecording()
                    selection = nil
                } label: {
                    Image(systemName: LibraryListPresentation.SidebarItemKind.meeting.icon)
                        .font(.system(size: layout.smallFontSize, weight: .bold))
                        .foregroundStyle(LibraryListPresentation.SidebarItemKind.meeting.tint.opacity(0.95))
                        .frame(width: round(34 * layout.scale), height: round(34 * layout.scale))
                        .background(LibraryListPresentation.SidebarItemKind.meeting.tint.opacity(0.08), in: Capsule())
                        .overlay(Capsule().stroke(LibraryListPresentation.SidebarItemKind.meeting.tint.opacity(0.42), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(meetingManager.state == .processing)
                .opacity(meetingManager.state == .processing ? 0.55 : 1)
                .accessibilityLabel(Text(recordButtonLabel))
                .help(recordButtonLabel)
            }
        }
    }

    // MARK: - Sidebar

    private func sidebar(layout: CommandCenterLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader(layout: layout)
            searchAndFilters(layout: layout)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    homeSidebarRow(layout: layout)

                    sidebarSection(
                        .meetings,
                        title: "Meetings",
                        kind: .meeting,
                        selectionTarget: .meetingsList,
                        action: nil,
                        layout: layout
                    ) {
                        sidebarLimitedContent(
                            visibleMeetings,
                            expansionID: sidebarExpansionID(for: .meetings),
                            layout: layout
                        ) { meeting in
                            sidebarRow(meeting: meeting, layout: layout)
                        }
                        if visibleMeetings.isEmpty {
                            emptyHint(meetingManager.searchQuery.isEmpty ? "No meetings yet" : "No results", layout: layout)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 8)
            }

            Spacer()
            Divider().foregroundStyle(Theme.border)

            VStack(spacing: 0) {
                sidebarAction(icon: "gear", label: "Settings", layout: layout) {
                    openSettings()
                }
                if authManager.isAuthenticated && !UserDefaults.standard.bool(forKey: "skippedAuth") {
                    sidebarAction(icon: "rectangle.portrait.and.arrow.right", label: "Sign Out", layout: layout) {
                        authManager.signOut()
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(Theme.notionSidebarBG)
    }

    private var searchIsActive: Bool {
        !meetingManager.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var expandedSidebarListIDs: Set<String> {
        Set(sidebarExpandedListsRaw.split(separator: "\n").map(String.init))
    }

    private func isSidebarListExpanded(_ id: String) -> Bool {
        expandedSidebarListIDs.contains(id)
    }

    private func toggleSidebarListExpansion(_ id: String) {
        var ids = expandedSidebarListIDs
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        sidebarExpandedListsRaw = ids.sorted().joined(separator: "\n")
    }

    private func sidebarExpansionID(for section: SidebarSectionID) -> String {
        switch section {
        case .meetings: return "meetings"
        }
    }

    @ViewBuilder
    private func sidebarLimitedContent<Item: Identifiable, Row: View>(
        _ items: [Item],
        expansionID: String,
        layout: CommandCenterLayout,
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        let expanded = isSidebarListExpanded(expansionID)
        let slice = SidebarListLimiter.slice(
            items,
            expanded: expanded,
            searchActive: searchIsActive,
            limit: sidebarDefaultVisibleCount
        )

        ForEach(slice.items) { item in
            row(item)
        }

        if slice.canToggle {
            sidebarListToggleRow(
                expansionID: expansionID,
                isExpanded: expanded,
                hiddenCount: slice.hiddenCount,
                layout: layout
            )
        }
    }

    private func sidebarListToggleRow(
        expansionID: String,
        isExpanded: Bool,
        hiddenCount: Int,
        layout: CommandCenterLayout
    ) -> some View {
        Button {
            toggleSidebarListExpansion(expansionID)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: max(8, layout.tinyFontSize - 1), weight: .semibold))
                Text(isExpanded ? "Show less" : "Show more")
                    .font(.system(size: layout.tinyFontSize + 1, weight: .semibold))
                if !isExpanded {
                    Text("\(hiddenCount)")
                        .font(.system(size: max(8, layout.tinyFontSize), weight: .semibold))
                        .foregroundStyle(Theme.textTertiary.opacity(0.80))
                }
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, round(14 * layout.scale))
            .padding(.vertical, round(5 * layout.scale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .help(isExpanded ? "Hide older items" : "Show older items")
    }

    private func brandHeader(layout: CommandCenterLayout) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { sidebarCollapsed = true }
            } label: {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: layout.sectionTitleFontSize + 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide sidebar")

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    sidebarSearchExpanded.toggle()
                }
                if sidebarSearchExpanded {
                    searchFocused = true
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: layout.bodyFontSize + 2, weight: .medium))
                    .foregroundStyle(searchIsActive || sidebarSearchExpanded ? Theme.textPrimary : Theme.textTertiary)
                    .frame(width: round(30 * layout.scale), height: round(30 * layout.scale))
                    .background(
                        searchIsActive || sidebarSearchExpanded ? Theme.notionHoverBG : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search meetings")
        }
        .padding(.leading, layout.sidebarBrandLeadingInset)
        .padding(.trailing, layout.sidebarBrandLeadingInset)
        .padding(.top, layout.sidebarBrandHeaderTopPadding)
        .padding(.bottom, layout.sidebarBrandHeaderBottomPadding)
        .frame(height: layout.sidebarBrandHeaderHeight, alignment: .center)
    }

    @ViewBuilder
    private func searchAndFilters(layout: CommandCenterLayout) -> some View {
        if sidebarSearchExpanded || searchIsActive {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: layout.smallFontSize))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search meetings...", text: $meetingManager.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: layout.bodyFontSize))
                    .focused($searchFocused)
                if !meetingManager.searchQuery.isEmpty {
                    Button {
                        meetingManager.searchQuery = ""
                        sidebarSearchExpanded = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: layout.tinyFontSize, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, round(10 * layout.scale))
            .frame(height: max(32, layout.controlHeight - 2))
            .background(Theme.notionSurfaceBG.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            .padding(.horizontal, round(10 * layout.scale))
            .padding(.bottom, round(8 * layout.scale))
        } else {
            EmptyView()
        }
    }

    private func sidebarSection<Content: View>(
        _ id: SidebarSectionID,
        title: String,
        kind: LibraryListPresentation.SidebarItemKind,
        selectionTarget: SidebarSelection,
        action: (() -> Void)?,
        layout: CommandCenterLayout,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    toggleSection(id)
                } label: {
                    Image(systemName: collapsedSections.contains(id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: layout.tinyFontSize - 1, weight: .bold))
                        .foregroundStyle(Theme.sectionHeader)
                        .frame(width: round(12 * layout.scale), height: round(18 * layout.scale))
                }
                .buttonStyle(.plain)
                .help(collapsedSections.contains(id) ? "Expand \(title)" : "Collapse \(title)")

                sidebarSectionHeaderButton(
                    title: title,
                    kind: kind,
                    selectionTarget: selectionTarget,
                    layout: layout
                )

                Spacer()

                if let action {
                    Button(action: action) {
                        Label("New", systemImage: "plus")
                            .font(.system(size: layout.tinyFontSize + 1, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, round(7 * layout.scale))
                            .padding(.vertical, round(4 * layout.scale))
                            .background(Theme.notionHoverBG, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, round(14 * layout.scale))
            .padding(.top, round(14 * layout.scale))
            .padding(.bottom, round(5 * layout.scale))

            if !collapsedSections.contains(id) {
                content()
            }
        }
    }

    private func sidebarSectionHeaderButton(
        title: String,
        kind: LibraryListPresentation.SidebarItemKind,
        selectionTarget: SidebarSelection,
        layout: CommandCenterLayout
    ) -> some View {
        let isSelected = selection == selectionTarget

        return Button {
            selection = selectionTarget
        } label: {
            HStack(spacing: 6) {
                Image(systemName: kind.icon)
                    .font(.system(size: layout.smallFontSize, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.accent : kind.tint)
                Text(title.uppercased())
                    .font(.system(size: layout.tinyFontSize + 1, weight: .bold))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.sectionHeader)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(title)")
    }

    private func toggleSection(_ section: SidebarSectionID) {
        if collapsedSections.contains(section) {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
        }
    }

    private func emptyHint(_ text: String, layout: CommandCenterLayout) -> some View {
        Text(text)
            .font(.system(size: layout.smallFontSize))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, round(18 * layout.scale))
            .padding(.vertical, round(5 * layout.scale))
    }

    private func sidebarRow(meeting: Meeting, layout: CommandCenterLayout) -> some View {
        Button {
            selection = .meeting(meeting.id)
        } label: {
            HStack(spacing: 8) {
                sidebarItemIcon(
                    LibraryListPresentation.SidebarItemKind.meeting,
                    tint: meeting.summary.wasSummarized ? LibraryListPresentation.SidebarItemKind.meeting.tint : Theme.warning,
                    layout: layout
                )
                Text("\(datePrefix(meeting.date)) \(meeting.title.replacingOccurrences(of: "Microsoft Teams", with: "Teams"))")
                    .font(.system(size: layout.bodyFontSize))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, round(14 * layout.scale))
            .padding(.vertical, round(6 * layout.scale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selection == .meeting(meeting.id)
                    ? Theme.notionSelectedBG
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .contextMenu {
            Button("Export as Markdown") { exportMeeting(meeting) }
            Button("Export as PDF") { exportMeetingPDF(meeting) }
            Divider()
            Button("Delete", role: .destructive) {
                if selection == .meeting(meeting.id) { selection = nil }
                meetingManager.deleteMeeting(meeting)
            }
        }
    }

    private func homeSidebarRow(layout: CommandCenterLayout) -> some View {
        Button {
            selection = .home
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.grid.2x2")
                    .font(.system(size: layout.smallFontSize))
                    .foregroundStyle(Theme.textTertiary)
                Text("Overview")
                    .font(.system(size: layout.bodyFontSize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, round(14 * layout.scale))
            .padding(.vertical, round(6 * layout.scale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selection == .home ? Theme.notionSelectedBG : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.top, round(4 * layout.scale))
    }

    private var visibleMeetings: [Meeting] {
        LibraryListOrdering.meetings(meetingManager.filteredMeetings)
    }

    private func sidebarItemIcon(
        _ kind: LibraryListPresentation.SidebarItemKind,
        tint: Color? = nil,
        layout: CommandCenterLayout
    ) -> some View {
        Image(systemName: kind.icon)
            .font(.system(size: layout.bodyFontSize, weight: .medium))
            .foregroundStyle(tint ?? kind.tint)
            .frame(width: round(16 * layout.scale), alignment: .center)
    }

    private func sidebarAction(icon: String, label: String, layout: CommandCenterLayout, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: layout.bodyFontSize))
                    .foregroundStyle(Theme.textTertiary)
                Text(label)
                    .font(.system(size: layout.bodyFontSize))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, round(14 * layout.scale))
            .padding(.vertical, round(6 * layout.scale))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if meetingManager.state == .processing {
            processingView
        } else if case .meetingsList = selection {
            meetingsListPage
        } else if case .meeting(let id) = selection,
                  let meeting = meetingManager.meetings.first(where: { $0.id == id }) {
            NotionPageView(meeting: meeting, summarizationStatus: meetingManager.summarizationStatus, meetingManager: meetingManager, ttsService: ttsService)
                .id(meeting.id)
        } else if meetingManager.state == .recording && selection == nil {
            LiveTranscriptView(meetingManager: meetingManager)
                .background(Theme.notionWindowBG)
        } else {
            HomeDashboardView(
                meetingManager: meetingManager,
                onSelectMeeting: { id in selection = .meeting(id) },
                onOpenHistory: { selection = .meetingsList },
                onStartMeeting: {
                    if AppEnvironment.usesTranscriptImportPrimaryFlow {
                        showTranscriptImport = true
                    } else {
                        selection = nil
                        if meetingManager.state == .idle {
                            meetingManager.startRecording()
                        }
                    }
                },
                onOnboardingAction: handleOnboardingAction
            )
        }
    }

    private var meetingsListPage: some View {
        collectionListPage(
            eyebrow: "Meetings",
            title: "Meetings",
            subtitle: "\(visibleMeetings.count) meetings",
            isEmpty: visibleMeetings.isEmpty,
            emptyTitle: meetingManager.searchQuery.isEmpty ? "No meetings yet" : "No matching meetings",
            emptySubtitle: meetingManager.searchQuery.isEmpty
                ? "Record a meeting to start building your meeting library."
                : "Try a different search term or clear the meeting search."
        ) {
            ForEach(visibleMeetings) { meeting in
                collectionListRow(
                    icon: LibraryListPresentation.SidebarItemKind.meeting.icon,
                    tint: meeting.summary.wasSummarized ? LibraryListPresentation.SidebarItemKind.meeting.tint : Theme.warning,
                    title: "\(datePrefix(meeting.date)) \(meeting.title.replacingOccurrences(of: "Microsoft Teams", with: "Teams"))",
                    metadata: "\(meeting.date.formatted(date: .abbreviated, time: .shortened)) • \(meeting.formattedDuration)",
                    detail: meeting.summary.wasSummarized ? nil : "Summary needs review"
                ) {
                    selection = .meeting(meeting.id)
                }
            }
        }
    }

    private func collectionListPage<Content: View>(
        eyebrow: String,
        title: String,
        subtitle: String,
        isEmpty: Bool,
        emptyTitle: String,
        emptySubtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(eyebrow.uppercased())
                            .font(.system(size: Theme.smallSize, weight: .bold))
                            .foregroundStyle(Theme.sectionHeader)
                        Text(title)
                            .font(.system(size: Theme.pageTitleSize, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(subtitle)
                            .font(.system(size: Theme.bodySize))
                            .foregroundStyle(Theme.textTertiary)
                    }

                    Spacer(minLength: 0)

                    Button {
                        showTranscriptImport = true
                    } label: {
                        Label("Import transcript", systemImage: "text.badge.plus")
                    }
                    .disabled(meetingManager.state != .idle)
                }

                if isEmpty {
                    collectionEmptyState(title: emptyTitle, subtitle: emptySubtitle)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        content()
                    }
                }
            }
            .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 42)
        }
        .background(Theme.notionWindowBG)
    }

    private func collectionListRow(
        icon: String,
        tint: Color,
        title: String,
        metadata: String,
        detail: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: Theme.bodySize, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: Theme.bodySize, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(metadata)
                        .font(.system(size: Theme.smallSize))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: Theme.smallSize))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.smallSize, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.notionSurfaceBG.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border.opacity(0.85), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func collectionEmptyState(title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: Theme.bodySize, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(subtitle)
                .font(.system(size: Theme.smallSize))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(Theme.notionSurfaceBG.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border.opacity(0.70), lineWidth: 1))
    }

    private var processingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .padding(.bottom, 8)

            if case .summarizing(let model) = meetingManager.summarizationStatus {
                Text("Generating summary...")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Using \(model)")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text("Processing meeting...")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Finalizing transcription")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
            }

            Text("\(meetingManager.currentTranscript.count) segments transcribed")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.notionWindowBG)
    }

    private func activateSelection(_ target: SidebarSelection?) {
        selection = target
        if let target {
            registerOpenTab(target)
        }
    }

    private func registerOpenTab(_ target: SidebarSelection) {
        guard !openTabs.contains(target) else { return }
        openTabs.append(target)
    }

    private func closeTab(_ target: SidebarSelection) {
        guard let index = openTabs.firstIndex(of: target) else { return }
        openTabs.remove(at: index)

        if openTabs.isEmpty {
            openTabs = [.home]
        }

        if selection == target {
            let replacementIndex = min(index, openTabs.count - 1)
            selection = openTabs[replacementIndex]
        }
    }

    private var recordButtonLabel: String {
        switch meetingManager.state {
        case .recording:
            return "Stop Recording"
        case .processing:
            if case .summarizing = meetingManager.summarizationStatus {
                return "Summarizing..."
            }
            return "Processing..."
        case .idle:
            return meetingManager.recordingReadiness.primaryActionTitle
        }
    }

    private var formattedDuration: String {
        let total = Int(meetingManager.recordingDuration)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func handleOnboardingAction(_ item: OnboardingChecklistItem) {
        switch item.actionTarget {
        case .startRecording:
            meetingManager.startRecording()
        case .requestMicrophonePermission:
            requestMicrophonePermissionForOnboarding()
        case .openMicrophonePrivacySettings:
            if openSystemSettings(path: "com.apple.preference.security?Privacy_Microphone") {
                meetingManager.refreshOnboardingChecklistStateAfterExternalPermissionChange()
            }
        case .requestScreenRecordingPermission:
            requestScreenRecordingPermissionForOnboarding()
        case .openScreenRecordingPrivacySettings:
            if openSystemSettings(path: "com.apple.preference.security?Privacy_ScreenCapture") {
                meetingManager.refreshOnboardingChecklistStateAfterExternalPermissionChange()
            }
        case .requestNotificationPermission:
            meetingManager.requestNotificationPermissionForOnboarding()
        case .openNotificationSettings:
            openNotificationSettings()
        case .openGeneralSettings:
            openSettings(initialTab: .general)
        case .openAISettings:
            openSettings(initialTab: .ai)
        case .openAccountSettings:
            openSettings(initialTab: .account)
        case .openPrivacySettings:
            openSettings(initialTab: .privacy)
        case .none:
            break
        }
    }

    private func requestMicrophonePermissionForOnboarding() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in
                meetingManager.refreshOnboardingChecklistState()
            }
        }
    }

    private func requestScreenRecordingPermissionForOnboarding() {
        let granted = CGRequestScreenCaptureAccess()
        if granted {
            RecordingDiagnosticsSnapshot.recordSystemAudioAccessConfirmed(true)
            meetingManager.refreshOnboardingChecklistState()
            return
        }

        if openSystemSettings(path: "com.apple.preference.security?Privacy_ScreenCapture") {
            meetingManager.refreshOnboardingChecklistStateAfterExternalPermissionChange()
        } else {
            meetingManager.refreshOnboardingChecklistState()
        }
    }

    private func openSettings(initialTab: SettingsView.SettingsTab = .account) {
        if let existing = settingsWindow, existing.isVisible {
            existing.contentView = NSHostingView(rootView: SettingsView(initialTab: initialTab, authManager: authManager))
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NoteAI Settings"
        window.contentView = NSHostingView(rootView: SettingsView(initialTab: initialTab, authManager: authManager))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    private func openNotificationSettings() {
        openSystemSettings(path: "com.apple.preference.notifications")
    }

    @discardableResult
    private func openSystemSettings(path: String) -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:\(path)") else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private func exportMeeting(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.text]
        panel.nameFieldStringValue = ExportManager.markdownFilename(for: meeting)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? ExportManager.exportAsMarkdown(meeting).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func exportMeetingPDF(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = ExportManager.pdfFilename(for: meeting)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if let pdfData = try? ExportManager.exportAsPDFData(meeting) {
                try? pdfData.write(to: url, options: .atomic)
            }
        }
    }
}

// MARK: - Record Button (for toolbar fallback)

struct RecordButton: View {
    @ObservedObject var meetingManager: MeetingManager
    var body: some View {
        Button { meetingManager.toggleRecording() } label: {
            switch meetingManager.state {
            case .idle: Label("Record", systemImage: "record.circle")
            case .recording: Label("Stop", systemImage: "stop.circle.fill").foregroundStyle(.red)
            case .processing: ProgressView().controlSize(.small)
            }
        }
        .disabled(meetingManager.state == .processing)
    }
}
