// 设置（⌘,）：cmux 式左侧分区导航 + 右侧分组卡片。全中文。
// 分区/设置行的元数据集中在 SettingsSections.swift（extension SettingsView）里定义，
// 本文件只负责外壳渲染、搜索、绑定与动作。改动即时生效并持久化（bind → applySettings）。
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store = SessionStore.shared
    @State private var selection: String = "appearance"
    @State private var query: String = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(minWidth: 720, idealWidth: 880, maxWidth: .infinity,
               minHeight: 460, idealHeight: 600, maxHeight: .infinity)
        .background(Theme.bg1)
    }

    // MARK: - 左侧分区导航

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundColor(Theme.fg3)
                TextField("搜索设置", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11)).foregroundColor(Theme.fg3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.bg2))
            .padding(10)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(sections) { sec in sidebarRow(sec) }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 212)
        .background(Theme.bg0)
    }

    private func sidebarRow(_ sec: SettingsSection) -> some View {
        let active = selection == sec.id && query.isEmpty
        return Button {
            query = ""
            selection = sec.id
        } label: {
            HStack(spacing: 9) {
                Image(systemName: sec.icon).font(.system(size: 13)).frame(width: 20)
                Text(sec.title)
                    .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundColor(active ? Color.accentColor : Theme.fg0)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(active ? Color.accentColor.opacity(0.15) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 右侧内容

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if query.isEmpty {
                    if let sec = sections.first(where: { $0.id == selection }) {
                        sectionHeader(sec.title)
                        ForEach(Array(sec.groups.enumerated()), id: \.offset) { _, g in
                            groupCard(g)
                        }
                    }
                } else {
                    searchResults
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var searchResults: some View {
        let q = query.lowercased()
        let hits: [SettingsRow] = sections.flatMap { sec in
            // 分区名命中则该分区全部行算命中（按分区名搜索是最自然的行为，
            // 如搜「终端」「窗口」「排版」应直达该分区，而非靠逐行手填关键词）。
            let sectionHit = sec.title.lowercased().contains(q)
            return sec.groups.flatMap(\.rows).filter { row in
                sectionHit
                || row.title.lowercased().contains(q)
                || (row.subtitle?.lowercased().contains(q) ?? false)
                || row.keywords.lowercased().contains(q)
            }
        }
        if hits.isEmpty {
            Text("没有匹配「\(query)」的设置")
                .font(.system(size: 12)).foregroundColor(Theme.fg3)
        } else {
            sectionHeader("搜索结果")
            groupCard(SettingsGroup(header: nil, rows: hits))
        }
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t).font(.system(size: 17, weight: .bold)).foregroundColor(Theme.fg0)
    }

    private func groupCard(_ g: SettingsGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let h = g.header {
                Text(h).font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.fg2)
                    .padding(.bottom, 6).padding(.leading, 2)
            }
            VStack(spacing: 0) {
                ForEach(Array(g.rows.enumerated()), id: \.element.id) { idx, row in
                    if idx > 0 { Divider().overlay(Theme.line) }
                    rowView(row)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
        }
    }

    @ViewBuilder private func rowView(_ row: SettingsRow) -> some View {
        switch row.layout {
        case .trailing:
            HStack(alignment: .center, spacing: 12) {
                rowLabel(row)
                Spacer(minLength: 8)
                row.control
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
        case .below:
            VStack(alignment: .leading, spacing: 9) {
                rowLabel(row)
                row.control
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 11)
        }
    }

    private func rowLabel(_ row: SettingsRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title).font(.system(size: 12.5)).foregroundColor(Theme.fg0)
            if let s = row.subtitle {
                Text(s).font(.system(size: 10.5)).foregroundColor(Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 绑定（set 即 applySettings：生效 + 持久化）

    func bind<T>(_ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: kp] },
            set: { store.settings[keyPath: kp] = $0; store.applySettings() }
        )
    }

    // MARK: - 动作

    func confirmReset() {
        let a = NSAlert()
        a.messageText = "恢复默认设置？"
        a.informativeText = "将重置所有外观与行为选项（任务模板会保留）。"
        a.addButton(withTitle: "恢复默认")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { resetSettings() }
    }

    private func resetSettings() {
        var s = AppSettings()
        s.taskTemplates = store.settings.taskTemplates   // 不动用户数据
        store.settings = s
        store.applySettings()
    }

    func revealDataDir() {
        NSWorkspace.shared.activateFileViewerSelecting([DataDir.url])
    }
}

// MARK: - 元数据模型

enum SettingsRowLayout { case trailing, below }

struct SettingsRow: Identifiable {
    let id: String
    let title: String
    var subtitle: String? = nil
    var keywords: String = ""
    var layout: SettingsRowLayout = .trailing
    let control: AnyView
}

struct SettingsGroup {
    var header: String? = nil
    let rows: [SettingsRow]
}

struct SettingsSection: Identifiable {
    let id: String
    let icon: String
    let title: String
    let groups: [SettingsGroup]
}
