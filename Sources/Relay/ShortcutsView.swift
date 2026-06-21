// 快捷键速查（⌘/）：一页列全所有快捷键，分组呈现。新增功能多了之后，
// 菜单虽全但不够「一眼可达」，这里集中速查。
import SwiftUI

struct ShortcutsView: View {
    @ObservedObject var store = SessionStore.shared

    private struct Group { let title: String; let items: [(String, String)] }

    private let groups: [Group] = [
        Group(title: "任务与标签页", items: [
            ("⌘N", "新建任务"),
            ("⌘⇧N", "新建任务（选目录与启动命令）"),
            ("⌘T", "新建标签页"),
            ("⌘W", "关闭标签页"),
            ("⌘⇧T", "撤销关闭标签页"),
            ("⌘⇧[ / ⌘⇧]", "上/下一个标签页"),
            ("⌘1–9", "切换到第 n 个任务"),
        ]),
        Group(title: "分屏", items: [
            ("⌘D", "左右分屏"),
            ("⌘⌥D", "上下分屏"),
            ("⌘⌥O", "切换分屏焦点"),
            ("⌘⇧D", "取消分屏"),
        ]),
        Group(title: "多会话编排", items: [
            ("⌘⌥→", "跳到下一个待处理会话"),
            ("⌘⌥B", "广播输入到所有会话"),
        ]),
        Group(title: "导航与查找", items: [
            ("⌘P", "命令面板（按紧急度跳转会话）"),
            ("⌘F", "搜索终端内容"),
            ("⌘G / ⌘⇧G", "下一处 / 上一处匹配"),
        ]),
        Group(title: "显示与工具", items: [
            ("⌘+ / ⌘- / ⌘0", "放大 / 缩小 / 默认字号"),
            ("⌘K", "清屏"),
            ("⌘⇧I", "诊断面板"),
            ("⌘/", "本快捷键速查"),
            ("⌘,", "偏好设置"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("快捷键")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.fg0)
            HStack(alignment: .top, spacing: 28) {
                column(groups[0...2])
                column(groups[3...4])
            }
            HStack {
                Spacer()
                Button("完成") { store.showShortcuts = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 540)
        .background(Theme.bg1)
    }

    private func column(_ slice: ArraySlice<Group>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(slice), id: \.title) { g in
                VStack(alignment: .leading, spacing: 5) {
                    Text(g.title).font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.fg2)
                    ForEach(g.items, id: \.0) { key, desc in
                        HStack(spacing: 10) {
                            Text(key)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(Theme.fg0)
                                .frame(width: 92, alignment: .leading)
                            Text(desc)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.fg3)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
