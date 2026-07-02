# cc-replay — 真实 CC PTY 字节流录制/回放排查工具

合成测试全绿但真机失效时，用这套工具拿**真实 Claude Code 的字节流**在无头引擎里复现。
v0.5.9→v0.5.10 的关键根因（CC 只滚 transcript 区、底部状态栏固定不动、Ink 增量 diff
重绘每帧仅 ~322B）就是它一次回放当场揭穿的——此前两轮盲修全部落空。

## 录制

```bash
python3 record.py cc-session.jsonl
```

- 在 PTY（105×38，与回放器 TerminalView 900×600 的字号推导一致）里跑真实 `claude`，
  发提示词产出多屏输出，再注入与 Relay 转发同款的 SGR 滚轮上报（button 4/5）。
- 每个 `os.read()` 块原样落盘（base64 + 时间戳）——保留真实的块边界。
- 内置 CPR（`ESC[6n`）/DA1（`ESC[c`）应答，避免 Ink 启动时等待终端回包卡死。

## 回放

```bash
swiftc -Onone -o replay replay-main.swift \
    $(find ../../Vendor/SwiftTerm/Sources/SwiftTerm -name '*.swift')
./replay cc-session.jsonl          # 加 --verbose 看全部块
```

- 源码级合编 SwiftTerm（internal API 全可见，等价 @testable），绕过本机 CLT 无
  swift-testing 的限制。
- Phase A：回放到第一次滚轮注入前，打印屏幕快照与 yBase/yDisp。
- Phase B：模拟「向上拖到顶边」拖选，逐块打印检测到的平移量 K、锚点位置。
- Phase C：打印 ⌘C 复制文本，检查完整性/重复块。

## 进程内 NSEvent 闭环 e2e（e2e-main.swift）

```bash
mkdir -p /tmp/e2e && cp e2e-main.swift /tmp/e2e/main.swift   # 顶层语句要求文件名为 main.swift
swiftc -Onone -o /tmp/e2e/e2e /tmp/e2e/main.swift \
    $(find ../../Vendor/SwiftTerm/Sources/SwiftTerm -name '*.swift')
/tmp/e2e/e2e cc-session.jsonl    # exit 0 = 复制文本连续、无重复、无 NUL
```

比无头回放器更进一步：真 NSEvent 打进 mouseDown/mouseDragged/mouseUp、20Hz 自动滚动
定时器真跑（RunLoop 驱动），转发出的 SGR 滚轮上报由录制的 CC 响应帧逐组应答——除了
系统级事件注入之外与真机链路完全一致，且不需要辅助功能权限、不动用户鼠标。
v0.5.11 的两个 bug（mouseUp 封存整屏前插污染块、NUL 混进剪贴板）只有这一层能抓到：
无头回放器不走 mouseUp，合成测试的行文本没有 null cell。

## 判读要点

- `相邻帧K=nil` 连续出现 = 平移检测被真实重绘模式打穿（去看 detectAlternateContentShift）。
- CC 每滚 1 行只发 ~322B 增量帧；`yBase` 全程 0；无 2J、无 2026 sync。
- 底部 8 行（输入框/边框/状态栏）滚动时不变——任何「整屏占比」类判据都会死在这里。
