# WebApp

主窗口里的界面：侧栏、对话、输入框、检查器、设置。菜单栏额外窗口用同一份构建，哈希 `#menubar`。Swift 只提供窗口壳。桥和玻璃见 [docs/web-shell.md](../docs/web-shell.md)。

```sh
make web        # 在仓库根：npm ci && npm run build，写入 Aureways/WebAppBundle/
npm run dev     # Vite。没有 Swift 时用 demo.ts 的假数据
```

产物目录 `Aureways/WebAppBundle/` 已提交，Xcode 编 App 不需要 Node。改了 `src/` 却没跑 `make web`，装进包里的仍是旧页面。

## 栈

- Preact 与 `@preact/signals`。JSX 由 Vite / esbuild 转换。
- 对话用 `components/VirtualList.tsx`：测量行高，默认钉在底部，底部留白是流内垫片。
- Markdown：`marked` 按顶层块切，DOMPurify，Shiki 按需加载语法。
- 检查器终端：`@xterm/xterm`。PTY 在 Swift 里（`WebTerminalService`）。
- 选择器、右键和附件面板回调到 `NSMenu` / `NSOpenPanel`。

打开会话后，输入框可以画在第二个透明 WebView 里，盖在系统 Liquid Glass 上。主页面只留 `.composer-slot`。空白页和设置页不拆这层。
