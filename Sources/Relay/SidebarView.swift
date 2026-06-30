import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SidebarTypography {
    private static var base: CGFloat { CGFloat(SessionStore.shared.settings.uiFontSize) }
    static var label: CGFloat { max(10, base - 2) }
    static var body: CGFloat { max(11, base - 1) }
    static var time: CGFloat { max(10, base - 3) }
    static var shortcut: CGFloat { max(9, base - 4) }
}

struct SidebarView: View {
    @ObservedObject var store: SessionStore
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var query = ""
    @State private var renamingId: String?
    @State private var draggingId: String?
    @State private var searchHovered = false
    @FocusState private var searchFocused: Bool

    private struct SidebarTaskGroup: Identifiable {
        let id: String
        let name: String
        let tasks: [Session]
        let kind: WindowType?
    }

    private struct ProjectIdentity {
        let id: String
        let name: String
    }

    private var filteredTasks: [Session] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.tasks }
        return store.tasks.filter { root in
            let tabs = store.tabs(ofTask: root.id)
            let fields = ([projectName(for: root), root.name, root.group, root.host ?? ""] +
                          tabs.map { "\($0.name) \($0.group) \($0.kind.label) \(store.cwd(of: $0.id) ?? "")" })
                .joined(separator: " ")
                .lowercased()
            return fields.contains(q)
        }
    }

    private var sidebarGroups: [SidebarTaskGroup] {
        switch store.settings.taskGrouping {
        case .type: return typeGroups
        case .project: return projectGroups
        }
    }

    private var projectGroups: [SidebarTaskGroup] {
        var order: [String] = []
        var map: [String: (name: String, tasks: [Session])] = [:]
        for task in filteredTasks {
            let project = projectIdentity(for: task)
            if map[project.id] == nil { order.append(project.id) }
            map[project.id, default: (project.name, [])].tasks.append(task)
        }
        return order.map { key in
            let group = map[key]!
            return SidebarTaskGroup(id: key, name: group.name, tasks: group.tasks, kind: nil)
        }
    }

    private var typeGroups: [SidebarTaskGroup] {
        var map: [WindowType: [Session]] = [:]
        for task in filteredTasks {
            let kind = taskGroupingKind(for: task)
            map[kind, default: []].append(task)
        }

        let orderedKinds: [WindowType] = [.codex, .claude, .opencode, .shell, .ssh]
        return orderedKinds.compactMap { kind in
            guard let tasks = map[kind], !tasks.isEmpty else { return nil }
            return SidebarTaskGroup(
                id: "type:\(kind.rawValue)",
                name: typeGroupTitle(for: kind),
                tasks: tasks,
                kind: kind
            )
        }
    }

    private func projectName(for root: Session) -> String {
        projectIdentity(for: root).name
    }

    private func projectIdentity(for root: Session) -> ProjectIdentity {
        if let cwd = store.cwd(ofTask: root.id),
           let project = projectFolder(from: cwd) {
            return project
        }
        let name = root.group == WindowType.shell.group(host: nil) ? "本地" : root.group
        return ProjectIdentity(id: "group:\(name)", name: name)
    }

    private func projectFolder(from cwd: String) -> ProjectIdentity? {
        let url = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let pathComponents = url.pathComponents

        for container in ["Project", "Projects"] {
            let rootComponents = home.appendingPathComponent(container).standardizedFileURL.pathComponents
            guard pathComponents.count > rootComponents.count,
                  pathComponents.starts(with: rootComponents) else { continue }
            let projectRoot = NSURL.fileURL(withPathComponents: Array(pathComponents.prefix(rootComponents.count + 1))) ?? url
            return ProjectIdentity(id: projectRoot.standardizedFileURL.path, name: pathComponents[rootComponents.count])
        }

        let name = url.lastPathComponent
        return name.isEmpty ? nil : ProjectIdentity(id: url.path, name: name)
    }

    private func cmdIndex(of root: Session) -> Int? {
        guard shortcutsVisible,
              let i = store.tasks.firstIndex(where: { $0.id == root.id }), i < 9 else { return nil }
        return i + 1
    }

    private var windowActive: Bool {
        controlActiveState != .inactive
    }

    private var shortcutsVisible: Bool {
        windowActive && store.cmdHeld
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 42)

            VStack(spacing: 6) {
                SidebarActionRow(
                    icon: "square.and.pencil",
                    title: "新对话",
                    shortcut: "⌘N",
                    showsShortcut: shortcutsVisible
                ) {
                    _ = store.newTask()
                }
                searchField
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)

            Text(store.settings.taskGrouping == .type ? "任务" : "项目")
                .font(Theme.uiFont(size: SidebarTypography.label, weight: .semibold))
                .foregroundColor(Theme.sidebarSecondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)

            ScrollView {
                projectList
            }

            Spacer(minLength: 0)

            SidebarActionRow(
                icon: "gearshape",
                title: "设置",
                shortcut: "⌘,",
                showsShortcut: shortcutsVisible
            ) {
                store.openSettings()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: store.settings.sidebarWidth)
        .background {
            SidebarPanelBackground(
                isActive: windowActive,
                translucent: store.settings.translucentSidebar,
                themeBg: Color(hex: store.effectiveTheme.bg),
                bgOpacity: store.settings.bgOpacity
            )
            .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            sidebarToggleButton
                .padding(.top, 8)
                .padding(.trailing, 10)
        }
        .onDrop(of: [.text], isTargeted: nil) { _ in
            if draggingId != nil { store.commitTaskOrder() }
            draggingId = nil
            return true
        }
    }

    private var projectList: some View {
        let groups = sidebarGroups
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(groups.indices, id: \.self) { index in
                let project = groups[index]
                sidebarSection(project)
            }
            if filteredTasks.isEmpty {
                emptyState
            }
        }
        .padding(.bottom, 16)
    }

    private var sidebarToggleButton: some View {
        Button {
            store.settings.sidebarVisible.toggle()
            store.applySettings()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: SidebarTypography.label, weight: .semibold))
                .foregroundColor(Theme.sidebarSecondary)
                .frame(width: 25, height: 25)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.sidebarControl))
        }
        .buttonStyle(.plain)
        .help("显示/隐藏侧边栏")
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: SidebarTypography.body, weight: .medium))
                .frame(width: 18)
            TextField("搜索", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.uiFont(size: SidebarTypography.body, weight: .medium))
                .foregroundColor(Theme.sidebarPrimary)
                .focused($searchFocused)
            Spacer(minLength: 8)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: SidebarTypography.label))
                        .foregroundColor(Theme.sidebarSecondary)
                }
                .buttonStyle(.plain)
            } else if shortcutsVisible {
                SidebarShortcutPill(text: "⌘G")
            }
        }
        .foregroundColor(Theme.sidebarPrimary)
        .frame(height: 36)
        .padding(.horizontal, 8)
        .background(
            SidebarRowBackground(isActive: searchFocused || !query.isEmpty, isHovered: searchHovered)
        )
        .contentShape(Rectangle())
        .onHover { searchHovered = $0 }
        .onTapGesture { searchFocused = true }
    }

    private func sidebarSection(_ project: SidebarTaskGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.settings.taskGrouping == .project, project.tasks.count == 1, let root = project.tasks.first {
                ProjectTaskRow(
                    store: store,
                    root: root,
                    title: project.name,
                    isActive: store.activeId.map { store.taskId(of: $0) == root.id } ?? false,
                    hasUnread: store.hasUnread(taskOf: root.id),
                    cmdIndex: cmdIndex(of: root)
                )
                .opacity(draggingId == root.id ? 0.35 : 1)
                .onDrag {
                    guard query.isEmpty else { return NSItemProvider() }
                    draggingId = root.id
                    return NSItemProvider(object: root.id as NSString)
                }
                .onDrop(of: [.text], delegate: TaskDropDelegate(
                    targetId: root.id, store: store, draggingId: $draggingId))
            } else {
                let titles = taskTitles(for: project)
                SidebarGroupHeader(title: project.name)

                VStack(spacing: 2) {
                    ForEach(project.tasks) { root in
                        TaskRow(
                            store: store,
                            root: root,
                            title: titles[root.id] ?? root.name,
                            showsEmblem: true,
                            leadingInset: 16,
                            emblemKind: store.settings.taskGrouping == .type ? project.kind : nil,
                            isActive: store.activeId.map { store.taskId(of: $0) == root.id } ?? false,
                            hasUnread: store.hasUnread(taskOf: root.id),
                            cmdIndex: cmdIndex(of: root),
                            isRenaming: renamingId == root.id,
                            beginRename: { renamingId = root.id },
                            endRename: { renamingId = nil }
                        )
                        .opacity(draggingId == root.id ? 0.35 : 1)
                        .onDrag {
                            guard query.isEmpty else { return NSItemProvider() }
                            draggingId = root.id
                            return NSItemProvider(object: root.id as NSString)
                        }
                        .onDrop(of: [.text], delegate: TaskDropDelegate(
                            targetId: root.id, store: store, draggingId: $draggingId))
                    }
                }
            }
        }
    }

    private func taskTitles(for project: SidebarTaskGroup) -> [String: String] {
        let baseTitles = project.tasks.map { root in
            (root.id, taskTitle(for: root, groupName: project.name))
        }
        let counts = Dictionary(grouping: baseTitles.map(\.1), by: { $0 }).mapValues(\.count)
        var seen: [String: Int] = [:]
        return Dictionary(uniqueKeysWithValues: baseTitles.map { id, title in
            guard (counts[title] ?? 0) > 1 else { return (id, title) }
            let next = (seen[title] ?? 0) + 1
            seen[title] = next
            return (id, "\(title) \(next)")
        })
    }

    private func taskTitle(for root: Session, groupName: String) -> String {
        if store.settings.taskGrouping == .type {
            return typeGroupedTaskTitle(for: root)
        }
        let trimmed = root.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != groupName { return trimmed }
        let tabs = store.tabs(ofTask: root.id)
        if let tab = representativeTab(of: tabs) {
            let tabName = tab.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tabName.isEmpty, tabName != groupName { return tabName }
            return tab.kind.label
        }
        return root.kind.label
    }

    private func typeGroupedTaskTitle(for root: Session) -> String {
        let project = projectName(for: root)
        let trimmed = root.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !isDefaultTaskName(trimmed),
              trimmed.caseInsensitiveCompare(project) != .orderedSame else {
            return project
        }
        return "\(project) · \(trimmed)"
    }

    private func isDefaultTaskName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        var defaults = Set(WindowType.allCases.flatMap {
            [$0.rawValue, $0.label, $0.group(host: nil)].map { $0.lowercased() }
        })
        defaults.formUnion(["local", "本地", "open code"])
        return defaults.contains(normalized)
    }

    private func taskGroupingKind(for root: Session) -> WindowType {
        let tabs = store.tabs(ofTask: root.id)
        let tabKinds = tabs.map { groupingCategory(for: $0.kind) }
        if let agentKind = tabKinds.first(where: { $0.isAgent }) {
            return agentKind
        }
        if tabKinds.contains(.ssh) {
            return .ssh
        }
        if tabKinds.contains(.shell) {
            return .shell
        }
        if let remembered = rememberedKind(from: root.name) ?? rememberedKind(from: root.group) {
            return remembered
        }
        return groupingCategory(for: root.kind)
    }

    private func groupingCategory(for kind: WindowType) -> WindowType {
        kind == .remotion ? .shell : kind
    }

    private func typeGroupTitle(for kind: WindowType) -> String {
        switch kind {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .opencode: return "OpenCode"
        case .shell, .remotion: return "本地 Shell"
        case .ssh: return "远程 SSH"
        }
    }

    private func rememberedKind(from value: String) -> WindowType? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if text.contains("claude") { return .claude }
        if text.contains("codex") { return .codex }
        if text.contains("opencode") || text.contains("open code") { return .opencode }
        if text.contains("remotion") { return .shell }
        if text.contains("ssh") { return .ssh }
        return nil
    }

    private var emptyState: some View {
        Text(store.tasks.isEmpty ? "还没有项目。\n点「新对话」开始。" : "没有匹配的项目。")
            .font(Theme.uiFont(size: SidebarTypography.label))
            .foregroundColor(Theme.sidebarSecondary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, 34)
            .padding(.horizontal, 18)
    }
}

private struct SidebarActionRow: View {
    let icon: String
    let title: String
    let shortcut: String
    let showsShortcut: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: SidebarTypography.body, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(Theme.uiFont(size: SidebarTypography.body, weight: .medium))
                Spacer(minLength: 8)
                if showsShortcut {
                    SidebarShortcutPill(text: shortcut)
                }
            }
            .foregroundColor(Theme.sidebarPrimary)
            .frame(height: 36)
            .padding(.horizontal, 8)
            .background(
                SidebarRowBackground(isActive: false, isHovered: hovered)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct SidebarShortcutPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.uiFont(size: SidebarTypography.shortcut, weight: .semibold))
            .foregroundColor(Theme.sidebarPrimary.opacity(0.88))
            .padding(.horizontal, 7)
            .frame(height: 19)
            .background(Capsule().fill(Theme.sidebarControl))
    }
}

private struct SidebarRowBackground: View {
    @ObservedObject private var store = SessionStore.shared
    @Environment(\.controlActiveState) private var controlActiveState
    let isActive: Bool
    let isHovered: Bool
    var cornerRadius: CGFloat = 7

    private var windowActive: Bool {
        controlActiveState != .inactive
    }

    private var contrast: Double {
        min(1.35, max(0.65, store.settings.uiContrast / 60))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let activeOverlay = (windowActive ? 0.080 : 0.045) * contrast
        let activeStroke = (windowActive ? 0.24 : 0.12) * contrast
        let hoverOverlay = 0.035 * contrast

        ZStack {
            if isActive {
                SidebarSelectionMaterial(cornerRadius: cornerRadius, windowActive: windowActive)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(shape)
                    .allowsHitTesting(false)
                shape.fill(
                    LinearGradient(
                        colors: windowActive
                            ? [Theme.sidebarSelectionHighlight, Theme.sidebarSelection]
                            : [Theme.sidebarSelectionInactiveStroke, Theme.sidebarSelectionInactive],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                shape.fill(Theme.pill.opacity(activeOverlay))
                shape.stroke(Theme.pill.opacity(activeStroke), lineWidth: 1)
                    .blendMode(.screen)
            } else if isHovered {
                shape.fill(Theme.pill.opacity(hoverOverlay))
            }
        }
        .shadow(color: Color.black.opacity(isActive && windowActive ? 0.18 : 0), radius: 7, x: 0, y: 2)
    }
}

private struct SidebarSelectionMaterial: NSViewRepresentable {
    let cornerRadius: CGFloat
    let windowActive: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .selection
        view.blendingMode = .withinWindow
        view.state = windowActive ? .active : .inactive
        view.isEmphasized = false
        view.alphaValue = windowActive ? 0.78 : 0.44
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .selection
        view.blendingMode = .withinWindow
        view.state = windowActive ? .active : .inactive
        view.isEmphasized = false
        view.alphaValue = windowActive ? 0.78 : 0.44
        view.layer?.cornerRadius = cornerRadius
    }
}

private struct SidebarGroupHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.uiFont(size: SidebarTypography.label, weight: .medium))
                .foregroundColor(Theme.sidebarSecondary.opacity(0.92))
                .lineLimit(1)
                .layoutPriority(1)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Theme.pill.opacity(0.060), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .padding(.leading, 2)
        }
        .padding(.leading, 18)
        .padding(.trailing, 18)
        .frame(height: 21)
    }
}

private struct ProjectEmblem: View {
    let session: Session?
    var kindOverride: WindowType?
    let size: CGFloat
    /// 非聚焦任务行：徽标去饱和成中性灰。
    var neutral: Bool = false

    var body: some View {
        let boxSize = max(24, size + 4)

        Group {
            if let session {
                EmblemView(kind: kindOverride ?? session.kind, phase: phaseOf(session).key, size: size, neutral: neutral)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "folder")
                    .font(.system(size: SidebarTypography.label, weight: .semibold))
                    .foregroundColor(Theme.sidebarPrimary)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: boxSize, height: boxSize)
    }
}

private struct TaskDropDelegate: DropDelegate {
    let targetId: String
    let store: SessionStore
    @Binding var draggingId: String?

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingId, dragging != targetId else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            store.moveTask(dragging, before: targetId)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        store.commitTaskOrder()
        draggingId = nil
        return true
    }
}

private struct ProjectTaskRow: View {
    let store: SessionStore
    let root: Session
    let title: String
    let isActive: Bool
    let hasUnread: Bool
    let cmdIndex: Int?

    @State private var hovered = false

    var body: some View {
        let tabs = store.tabs(ofTask: root.id)
        let rep = representativeTab(of: tabs) ?? root
        HStack(spacing: 8) {
            ProjectEmblem(session: rep, size: 22, neutral: true)
            Text(title)
                .font(Theme.uiFont(size: SidebarTypography.body, weight: isActive ? .semibold : .medium))
                .foregroundColor(isActive ? Theme.sidebarPrimary : Theme.sidebarPrimary.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 8)
            trailingAccessory
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(
            SidebarRowBackground(isActive: isActive, isHovered: hovered)
        )
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { store.showTask(root.id) }
        .contextMenu {
            Button("新建标签页") { store.showTask(root.id); _ = store.newTab() }
            Button("关闭任务", role: .destructive) { store.confirmCloseTask(root.id) }
        }
    }

    @ViewBuilder private var trailingAccessory: some View {
        if let n = cmdIndex {
            Text("⌘\(n)")
                .font(Theme.uiFont(size: SidebarTypography.shortcut, weight: .semibold))
                .foregroundColor(Theme.sidebarPrimary.opacity(0.92))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.sidebarControl))
        } else {
            SidebarStatusAccessory(
                age: sidebarRelativeAge(from: root.createdAt),
                hasUnread: hasUnread,
                showClose: hovered
            ) {
                store.confirmCloseTask(root.id)
            }
        }
    }
}

private struct TaskRow: View {
    let store: SessionStore
    let root: Session
    let title: String
    let showsEmblem: Bool
    let leadingInset: CGFloat
    let emblemKind: WindowType?
    let isActive: Bool
    let hasUnread: Bool
    let cmdIndex: Int?
    let isRenaming: Bool
    let beginRename: () -> Void
    let endRename: () -> Void

    @State private var draft = ""
    @State private var hovered = false
    @FocusState private var renameFocused: Bool

    var body: some View {
        let tabs = store.tabs(ofTask: root.id)
        let rep = representativeTab(of: tabs) ?? root
        HStack(spacing: 8) {
            if showsEmblem {
                ProjectEmblem(session: rep, kindOverride: emblemKind, size: 19, neutral: true)
            } else {
                Spacer().frame(width: 16)
            }
            if isRenaming {
                renameField
            } else {
                Text(title)
                    .font(Theme.uiFont(size: SidebarTypography.body, weight: isActive ? .semibold : .medium))
                    .foregroundColor(isActive ? Theme.sidebarPrimary : Theme.sidebarPrimary.opacity(0.86))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailingAccessory
        }
        .padding(.horizontal, 12)
        .frame(height: 31)
        .background(
            SidebarRowBackground(isActive: isActive, isHovered: hovered, cornerRadius: 8)
        )
        .padding(.leading, leadingInset)
        .padding(.trailing, 10)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .gesture(TapGesture(count: 2).onEnded { startRename() })
        .simultaneousGesture(TapGesture().onEnded { store.showTask(root.id) })
        .contextMenu {
            Button("重命名") { startRename() }
            Button("新建标签页") { store.showTask(root.id); _ = store.newTab() }
            Button("关闭任务", role: .destructive) { store.confirmCloseTask(root.id) }
        }
    }

    @ViewBuilder private var trailingAccessory: some View {
        if let n = cmdIndex {
            Text("⌘\(n)")
                .font(Theme.uiFont(size: SidebarTypography.shortcut, weight: .semibold))
                .foregroundColor(Theme.sidebarPrimary.opacity(0.92))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.sidebarControl))
        } else {
            SidebarStatusAccessory(
                age: sidebarRelativeAge(from: root.createdAt),
                hasUnread: hasUnread,
                showClose: hovered
            ) {
                store.confirmCloseTask(root.id)
            }
        }
    }

    private var renameField: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(Theme.uiFont(size: SidebarTypography.body, weight: .semibold))
            .foregroundColor(Theme.sidebarPrimary)
            .focused($renameFocused)
            .onSubmit { commit() }
            .onExitCommand { endRename() }
            .onChange(of: renameFocused) { focused in
                if !focused { commit() }
            }
    }

    private func startRename() {
        draft = root.name
        beginRename()
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commit() {
        store.rename(root.id, to: draft)
        endRename()
    }
}

private struct SidebarStatusAccessory: View {
    let age: String
    let hasUnread: Bool
    let showClose: Bool
    let closeAction: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if hasUnread {
                    Circle()
                        .fill(Theme.termAccent)
                        .frame(width: 6, height: 6)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Text(age)
                        .font(Theme.uiFont(size: SidebarTypography.time))
                        .foregroundColor(Theme.sidebarSecondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: 44, alignment: .trailing)

            Button(action: closeAction) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(Theme.sidebarPrimary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(showClose ? Theme.sidebarControl : Color.clear))
            }
            .buttonStyle(.plain)
            .opacity(showClose ? 1 : 0)
            .allowsHitTesting(showClose)
        }
        .frame(width: 68, alignment: .trailing)
    }
}

private func sidebarRelativeAge(from timestamp: Double) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince1970 - timestamp))
    if seconds < 60 { return "刚刚" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes) 分" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours) 时" }
    let days = hours / 24
    if days < 7 { return "\(days) 天" }
    return "\(days / 7) 周"
}
