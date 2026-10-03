# 性能约束

旧的 SwiftUI 对话和 `SwiftStreamingMarkdown` 已经删除。针对那套界面的任务清单和微基准不再适用，这里只记当前实现必须守住的行为。

## 对话

- 只挂可见行。高度缓存在 `VirtualList` 里，行用绝对定位。
- 正文续写由桥的 `patch.append` 送后缀。页面不要因为一个 token 重传或重解析整段历史。
- 闭合的 Markdown 块在流式过程中保持不动。高亮用 Shiki，语法按需加载。
- 钉在底部时，行高测量不能解除钉住。只有滚轮、指针、触摸和导航键可以离开底部。见 [frontend.md](frontend.md)。
- 底部留白是流内垫片。最大滚动位置用 `scrollHeight - clientHeight`，不要写成 `scrollHeight`。

## 原生刷新

`WebShellBridge` 合并观察通知，大约 22 ms 刷一次，并且跳过 JSON 没变的快照。玻璃矩形一帧最多发一次，只在几何变化时发。

检查器终端的 PTY 输出大约 8 ms 合并一次再 base64 发给 xterm。切走终端标签时不拆掉 xterm。

## 额度

额度请求默认稀疏：自动 5 分钟、轮询 10 分钟、手动 30 秒，失败还有退避。菜单栏打开只触发一次「是否过期」的检查，页面里不要再加定时器。

## 窗口

客户区不要再用 SwiftUI 分栏或向 SwiftUI 回报内容的最小尺寸。那是跨屏幕拖动时约束循环的来源。尺寸只在 `WebShellHostView` 里用 frame 更新。
