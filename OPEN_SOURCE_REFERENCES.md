# MacTools 开源参考（2026-09-11）

本轮实际引入 LinearMouse 的滚轮引擎、事件字段处理和线程代码；其他项目仅完成源码与许可证评估，没有安装其应用或替换现有模块。公开仓库不等于允许复制，以下许可证已按固定提交读取核验。

| 模块 | 推荐参考 | 许可证 | 适合借鉴的内容 | 本轮决定 |
| --- | --- | --- | --- | --- |
| 鼠标滚动、指针 | [LinearMouse](https://github.com/linearmouse/linearmouse/tree/v0.11.4) | MIT | SmoothedScrollingEngine、ScrollWheelEventView、EventThread、PointerKit 的属性访问与更新顺序 | 引入滚动核心，指针保留自己的可恢复参数租约 |
| Hyper／Meh、单击映射 | [Switcheroo](https://github.com/mitchelljphayes/switcheroo/tree/09181df043fc32177c04b1f4b46434d5897cfbdc) | MIT | `src/engine.rs` 的 tap/hold 状态、超时、组合键消费；`event_tap.rs` 的监听 | 优先参考状态机与测试场景；Rust 代码不直接塞进 Swift 应用 |
| 复杂按键边界 | [Karabiner-Elements](https://github.com/pqrs-org/Karabiner-Elements/tree/9312593e1a3bf72b94c63c524ebabe2637442e8a) | 主仓库 Unlicense；依赖各自授权 | `src/share/manipulator/manipulators/basic` 的 held-down / other-key-pressed 状态处理 | 作为行为与测试参考，当前需求不引入守护进程和虚拟 HID 驱动 |
| 访达菜单组织 | [MenuMate](https://github.com/Hibrielle/menumate/tree/771dca788010fbdfd4ddae1dec06d4e92795954c) | MIT | `FinderExtension/FinderSync.swift` 菜单 tag、上下文分派、扩展与主应用通信 | 参考模块划分；跨进程请求需验证，不能直接信任分布式通知 |
| 新建文件 | [NewFile](https://github.com/mariusgm/newfile/tree/b3f665ab839dfe95e6925735ca2a8209d3100fb8) | MIT | `Extension/FinderSync.swift` 菜单目标快照、模板与重名处理 | 可以单独吸收新建文件边界处理，不用它代替跨卷移动校验 |
| 独立菜单的辅助功能访问 | [AXSwift](https://github.com/tmandry/AXSwift/tree/e18a18453d135ad45809a384ee5139e05ea52def) | MIT | `Sources/UIElement.swift` 类型化 AX 属性访问、错误表达 | 可参考封装；AX 同步 IPC 有超时，禁止放入 event tap 热路径 |
| 事件监听生命周期 | [Hammerspoon](https://github.com/Hammerspoon/hammerspoon/tree/23e387e2805a9890066366e0ac96c71b27f0cfd5) | MIT | `extensions/eventtap/libeventtap.m` 创建、释放和系统暂停处理 | 作为生命周期参考；自动恢复前必须处理我们自己的按键状态 |

推荐顺序：先完成本轮滚轮实机验收，再用 Switcheroo／Karabiner 的边界案例审查 Hyper／Meh 的短按、长按、连按和失焦释放；访达模块优先采用 NewFile 的目标快照思路与 AXSwift 的错误封装。

FinderSync 仍受系统实际回调覆盖范围约束。MenuMate/NewFile 也不能证明本机 iCloud 目录一定能触发扩展；已有独立菜单路径继续保留。此前本机 iCloud 回调缺失已有现场记录。

未选入可直接复用清单：Mos 当前许可带非商业限制，Mac Mouse Fix 使用自定义许可；FinderTools 仓库未找到 LICENSE。它们可以用于公开功能比较，但不据此复制实现。BetterMouse／Superkey 没有在本轮找到可验证的官方开源实现，不宣称它们开源。

LinearMouse 实际引入范围、固定提交和文件哈希见 `Sources/Vendor/LinearMouse/README.md` 与 `PROVENANCE.json`。

## 应用快捷键（1.2.0）

按用户替代 Thor 的需求核验以下固定源码：

- [Thor / ShortcutMonitor.swift](https://github.com/gbammc/Thor/blob/9f59d4506f4993aa4faecd3448456768ff133dff/Thor/ShortcutMonitor.swift)：MIT；用 MASShortcut 注册组合，NSWorkspace 激活应用，暂停时注销。1.2.1 起采用同样的“目标已在前台时再次按下隐藏”行为，由 macOS 恢复之前的应用。
- [MASShortcut / MASHotKey.m](https://github.com/cocoabits/MASShortcut/blob/6f2603c6b6cc18f64a799e5d2c9d3bbc467c413a/Framework/Monitoring/MASHotKey.m)：BSD-2-Clause；Carbon 注册与注销机制，仓库已归档。
- [HotKey / HotKeysController.swift](https://github.com/soffes/HotKey/blob/a3cf605d7a96f6ff50e04fcb6dea6e2613cfcbe4/Sources/HotKey/HotKeysController.swift)：MIT；事件分发目标、按下/释放分派及注册生命周期。

本次参考机制，独立实现小型 Carbon 注册器和 NSWorkspace 启动适配，不引入这些库或复制整份源文件。现有 UI、配置、辅助键录制继续复用。只在系统注册成功后接入内部 Hyper／Meh 路由，在已有输入事件回调中匹配，异步激活应用，不额外添加输入 tap。这样也避免依赖系统是否会对 session tap 修改后的 flags 再次进行 Carbon 匹配。

测试应分层：配置和生命周期使用假注册器；辅助键事件只检查成对输出；普通 Carbon 的真实物理组合和安装后应用切换需现场验证。本机模拟 CGEvent 未触发 Carbon 热键，因此该自动测试不作为物理快捷键失败或成功的结论。

## 系统操作（1.6.0）

- [Apple macOS 键盘快捷键](https://support.apple.com/zh-cn/102650)：锁屏、截图、桌面、全屏与字符检视器的系统按键。
- [Hammerspoon system-key event 文档](https://www.hammerspoon.org/docs/hs.eventtap.event.html#newSystemKeyEvent)：媒体按下／松开事件的参考；本项目按本机 IOKit `ev_keymap.h` 的 `NX_KEYTYPE_*` 及 AppKit API 独立实现，没有引入 Hammerspoon 运行时。
- Apple SDK `IOPMLib.h`：整机睡眠使用公开 `IOPMSleepSystem`，调用者可以是控制台用户；显示器睡眠使用固定系统命令 `pmset displaysleepnow`，不提权。
- Apple Carbon Text Input Sources API：在已启用且可选择的输入法之间轮换，不模拟 Fn，也不修改系统输入法设置。

所有输出事件带有内部标记，跳过 Hyper／Meh 再映射；配置及执行前另行检查输出与 MacTools 触发组合冲突，防止再次触发本应用绑定。
