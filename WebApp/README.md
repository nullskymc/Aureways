# WebApp

主窗口里的界面：侧栏、对话与文件标签、输入框、设置。菜单栏额外窗口用同一份构建，哈希 `#menubar`。Swift 只提供窗口壳。桥和玻璃见 [docs/web-shell.md](../docs/web-shell.md)。

```sh
make web        # 在仓库根：按需 npm ci，再 npm run build，写入 Aureways/WebAppBundle/
npm run dev     # Vite。没有 Swift 时用 demo.ts 的假数据
npm test        # Node 测试：路径、锚点、分栏与终端生命周期（建议 Node 22+）
```

`Aureways/WebAppBundle/` 不提交。`make build` / `open` / `test` / `release` 会先编它。在 Xcode 里运行之前要先 `make web`；改了 `src/` 却没重编，装进包里的仍是旧页面。

## 栈

- Preact 与 `@preact/signals`。JSX 由 Vite / esbuild 转换。
- 对话用 `components/VirtualList.tsx`：测量行高，默认钉在底部，底部留白是流内垫片。
- Markdown：`marked` 按顶层块切，DOMPurify，Shiki 按需加载语法。`src/reader/` 负责主区域里 Markdown 标签的大纲、本地图片和文内链接。Finder 和 `⌘O` 打开的文件是这里的一个标签。
- 终端标签：`@xterm/xterm`。PTY 在 Swift 里（`WebTerminalService`）。
- 选择器、右键和附件面板回调到 `NSMenu` / `NSOpenPanel`。

打开会话后，输入框可以画在第二个透明 WebView 里，盖在系统 Liquid Glass 上。主页面只留 `.composer-slot`。空白页和设置页不拆这层。

## 测试

`npm test` 用 esbuild 编译 `src/**/*.test.ts` 和 `tests/**/*.test.mjs`，再由 Node 内置测试器执行。构建结果写到系统临时目录并自动清理，不修改源码。`make web-test` 只执行前端测试；`make test` 同时执行前端测试、Web 构建与原生测试。

终端组件测试使用真实 Preact 和轻量 DOM，替换 xterm 的绘制层与原生 PTY，验证跨栏/工作区重挂载时实例、屏幕历史和输出订阅不会丢失，以及关闭时释放资源。它不替代 WKWebView、真实终端和多屏 Finder 打开的人工冒烟测试。

PR 与 main push 由 `.github/workflows/ci.yml` 自动验证；发版 tag 则由 `release.yml` 先测试再打包。
