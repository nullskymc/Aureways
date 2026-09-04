# Icon 制作规范

**A 轨道标志 · App Icon Production Guide**  
适用于 macOS 26 Tahoe 及以后（含 iOS 26 / iPadOS 26）

| 项目 | 内容 |
|---|---|
| 版本 | 1.1 |
| 日期 | 2026-09-04 |
| 依据 | [Apple HIG — App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)（2026-06-08 修订） |
| 工具 | Icon Composer / Xcode |
| 交付格式 | `.icon` + 平面矢量 / PNG |

本文档规定本标志作为 App Icon 时的图形结构、安全区、色彩、分层、外观变体、尺寸和交付清单。设计与开发按本文档出稿。

---

## 1. 标志解剖

完整标志由三个元素组成，缺一不可。**地球照片只属于宣传主视觉，不进入 App Icon。**

| 编号 | 元素 | 定义 |
|---|---|---|
| A | 字母 A | 无横杠、斜切、圆钝端点的大写 A。识别主体。 |
| B | 轨道弧 | 由左下绕到右上。左细右宽，穿过 A 的两腿，形成环绕感。 |
| C | 四角星 | 位于 A 右上角的四芒闪光。体积小，点题「太空 / 探索」，不可过大。 |
| — | 地球（排除） | 原图底部的地球曲率仅用于海报 / 启动画面，不进入 icon 分层。 |

### 1.1 轨道的前后关系

轨道穿过 A 时不是简单并集：

- **A 的右笔画**被轨道切断，两端各留约 **1.4%** 画布宽（1024 下约 14 px）的背景色间隙。这条间隙是轨道「压在 A 前面」的唯一提示，必须保留。
- **A 的左腿**与轨道直接相接，不留间隙——轨道在这一侧从 A 后方穿过。

间隙做在 A 的路径里（`A.svg` 因此是两条子路径），不是靠描边或背景色遮挡，这样透明底版本同样成立。

### 1.2 三种基础色版

日常平面使用只保留下面三种。App Icon 再额外做 Dark / Clear / Tinted，见第 5 节。

| 色版 | 用法 |
|---|---|
| 蓝底白标 | 主视觉 / Dock / Default 外观 |
| 黑底白标 | 深色界面 / 片头 / 投影 |
| 白底蓝标 | 印刷 / 文档 / 浅色网页 |

---

## 2. 色彩

颜色值按 sRGB 给出。

| 名称 | HEX | RGB | 用途 |
|---|---|---|---|
| Orbit Blue | `#003DA5` | 0 / 61 / 165 | Default 背景基色；白底时的标志色 |
| Deep Navy | `#002B73` | 0 / 43 / 115 | 平面深色版底色、扁平回退、文档标题。**不是** Liquid Glass Dark 的背景色，原因见 5.2 |
| Icon White | `#FFFFFF` | 255 / 255 / 255 | Default 外观前景（A / 轨道 / 星） |
| Dark FG | `#F2F5FA` | 242 / 245 / 250 | 深色版前景，比纯白略压 |
| Ink | `#1A1A1A` | 26 / 26 / 26 | 文档正文，不用于 icon |

背景用 Icon Composer 内置的 `automatic-gradient`，基色填 Orbit Blue——同色相、上方略亮，比纯色有体积感，且深色/着色变体由系统同源推导。禁止用渐变地球、星空照片、彩虹描边当背景，也不要导入位图底或自己拼渐变。

---

## 3. 画布、安全区、最小尺寸

### 3.1 App Icon 画布

| 项目 | 规定 |
|---|---|
| 画布 | 1024 × 1024 px，正方形，**不预裁圆角** |
| 色彩空间 | Display P3 优先；否则 sRGB |
| 最终外形 | 系统自动蒙成 squircle，设计师不得自己切圆角 |
| 安全边距 | 主体（A + 轨道 + 星）放在中心 **76%** 区域内，四周至少留 **12%** |
| 轨道外端 | 轨道最右端、星星尖角距画布边缘 ≥ **10%** |
| A 的左右脚 | 两端距左右边 ≥ **16%**，避免被圆角吃掉 |

### 3.2 平面标志最小尺寸

| 场景 | 最小高度 | 说明 |
|---|---|---|
| 数字界面 | 24 px | 小于此尺寸只保留 A，去掉星 |
| 印刷 | 8 mm | 低于 8 mm 改用纯 A |
| Favicon | 32 × 32 | 可只留 A，轨道简化成细弧 |
| 通知 / Spotlight 小图 | 系统缩放 | 必须在 32 px 下仍能认出 A |

---

## 4. 对与错

### 4.1 必须做

- 提供未裁切的正方形分层稿，让系统套 squircle。
- 前景边缘实、清楚，不要羽化。高光和玻璃由系统画。
- 七种外观里保持同一套图形，只改颜色和透明度。
- 优先矢量（SVG）。文字若出现必须转曲。
- Icon Composer 里最多 4 个 group。
- 在 16 / 32 / 64 / 128 / 256 / 1024 六个尺度目视检查。

### 4.2 禁止做

- 把地球照片、星空、界面截图放进 icon。
- 自己画圆角、自己烘焙投影 / 镜面高光 / 玻璃反光。
- 细线、尖角过多、网格底纹、复杂渐变照片。
- 复制 Apple 硬件外形。
- 在图标里写 Watch / Play / New / For Mac 这类字。
- Clear / Tinted 外观换成另一套图形。
- 用旧 `.icns` 应付 macOS 26 的 Dark / Clear / Tinted。

---

## 5. macOS 26+ App Icon 分层方案

依据 Apple HIG：iOS / iPadOS / macOS / watchOS 图标由背景层 + 一层或多层前景组成，系统再施加 Liquid Glass（镜面高光、折射、半透明）。macOS 27 起更强调把玻璃做进各层，而不是盖一层厚雾。

### 5.1 推荐 3 个 Group（不超过 4）

| 顺序 | Group | 内容 | 制作要点 |
|---|---|---|---|
| 0 底 | Background | Orbit Blue 的 `automatic-gradient` | 铺满、不透明。用 Composer 内置渐变，不导位图。 |
| 1 | Letter A | 实心 A（两条子路径） | 前景填 `automatic`（在蓝底上解析为白），dark 显式 `#F2F5FA`。右笔画已按 1.1 节留好轨道间隙。 |
| 2 | Orbit | 轨道弧 | 实心不透明，靠自身投影与 A 分开。穿过 A，制造前后关系。 |
| 3 | Spark | 四角星 | 实心。可略提高玻璃折射，让它「亮」而不是画光晕。 |

层数原则：A 与轨道如果在矢量里已经布尔成一块，可以合成 Group 1，星星单独 Group 2。宁可层少、形清楚，也不要拆成 4 层碎玻璃。

各层一律 `translation-in-points: [0, 0]`、`scale: 1`。三个 SVG 已经在同一个 1024 画布里对齐，任何位移都说明几何出错，不要用位移去救。

### 5.2 七种外观的实测结果

用户可在「外观 → 图标与小组件样式」里切换。**这些变体的背景不是设计师指定的，是系统从背景基色推导的**——只能验收，不能声明。下表是用 `ictool` 从本仓库 `.icon` 导出 512 px 后实测的取样值（前景取亮度前 1% 像素的均值，背景取左中条带）：

| `--rendition` | 背景实测 | 前景实测 | 验收要点 |
|---|---|---|---|
| `Default` | `#1740AA` 附近，上方更亮 | `#FFFFFF` | 主外观，对标蓝底白标 |
| `Dark` | `#161616 → #1E1E1E` 近黑 | 近白 | 系统强制近黑，见下方说明 |
| `ClearLight` | 透明（导出为中灰） | `#FFFFFF` | 靠外形识别，星要留住 |
| `ClearDark` | 透明偏深 | 近白 | 检查深色壁纸上的对比 |
| `TintedLight` | 系统着色 | 近白 | 不要依赖品牌蓝存活 |
| `TintedDark` | 系统着色偏深 | 系统着色 | 与 Light 同一套路径 |
| `Mono` | 透明 | `#FFFFFF` | 单色剪影，菜单栏／模板用 |

**Dark 的背景无法指定。** 在 `icon.json` 顶层写 `fill-specializations` 的 dark 值（`solid` 与 `automatic-gradient` 两种写法都试过），macOS 与 iOS 平台的 Dark 渲染都仍是近黑 `#161616`——该键被 ictool 忽略。所以本项目不再往 `icon.json` 里写这条失效配置，Deep Navy `#002B73` 只用于平面深色色版（`logo_dark_1024.png` / `logo_dark.svg`）和 macOS 26 以下的扁平回退。想验证这一点，把 dark 值改回去再跑 `ictool --rendition Dark` 取样即可。

各层的 dark 前景 `#F2F5FA` 同样会被玻璃提亮到近白，实测差异不足 3/255，写它主要是为了在无玻璃的回退路径上保持一致。

核心要求：七种外观必须是同一套 A + 轨道 + 星，禁止换元素、加字、换构图。`build_icon.py` 每次运行都会把七种 rendition 各导一遍，任何一种渲染失败都会打印在 `renditions: n/7 ok` 那行。

---

## 6. 平台规格

一张 1024 分层母稿覆盖 iPhone / iPad / Mac。watchOS、tvOS、visionOS 若要上架再另出。

| 平台 | 画布 | 系统蒙版 | 风格 | 外观 |
|---|---|---|---|---|
| iOS / iPadOS / macOS | 1024² | 圆角矩形 | 分层玻璃 | 7 种 |
| watchOS | 1088² | 圆形 | 分层 | — |
| visionOS | 1024² | 圆形 | 分层 3D | — |
| tvOS | 800×480 | 圆角矩形 | 2–5 层视差 | — |

### 6.1 macOS 仍会用到的显示尺寸

系统会从母稿缩放。设计时必须保证下列尺寸可辨：

| pt | px @2x | 出现位置 |
|---|---|---|
| 16 | 32 | 列表、部分菜单、文件小图标 |
| 32 | 64 | Finder 小图标、标题栏 |
| 128 | 256 | Finder 中等 |
| 256 | 512 | Finder 大图标 |
| 512 | 1024 | Dock、启动台、App Store |

---

## 7. 制作流程

本仓库的图标**不走 Figma / Illustrator**：几何写在 `design/app-icon/build_icon.py`
里，三个 SVG、`icon.json`、平面色版和扁平回退 PNG 全是它生成的。日常改动只有两步：

1. 改 `build_icon.py` 顶部的几何参数。
2. `python3 design/app-icon/build_icon.py`，看 `renditions: 7/7 ok` 和 IoU 两行。

工程接线已经做好，**没有「再导入一次」这一步**——`.icon` 是原地更新的，重新构建即可：

| 位置 | 内容 |
|---|---|
| `project.pbxproj` 文件引用 | `AppIcon.icon`，类型 `folder.iconcomposer.icon` |
| Copy Resources 阶段 | 含 `AppIcon.icon` |
| Debug / Release 构建设置 | `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` |

重建后 Dock / Finder 常常还显示旧图标，常见有两种原因：

1. **`/Applications/Aureways.app` 是旧包。** Launch Services 按 bundle id 认图标，Applications 里 9 月 1 日那份没有 `CFBundleIconName`，Dock 就会一直是空白占位。`make open` 会把刚编的包同步过去。
2. **系统图标缓存。** `killall Dock` 即可刷新；Finder 里 `touch Aureways.app`。

想在 Icon Composer 里手调玻璃也可以：打开 `Aureways/AppIcon.icon`，改完覆盖保存。
`icon_json()` 输出的就是 Icon Composer 自己会写的那套键值，所以下次跑脚本不会把
GUI 的改动冲掉——只有**改了 GUI 里脚本没覆盖的项**时才需要把新值补回
`build_icon.py`，否则两边会打架。

从零起一套新图标时的完整流程（本项目已完成，留作参考）：

1. 按 1024 方画布画 3 层矢量，A、轨道、星分开导出 SVG，描边转轮廓。
2. 打开 Icon Composer（Xcode → Open Developer Tool → Icon Composer，或从 [Apple Design Resources](https://developer.apple.com/design/resources/) 下载）。
3. 新建文件，画布 1024。背景按第 2 节设 Orbit Blue 的 `automatic-gradient`。按 5.1 节导入并排列 Group。
4. 在 Style 面板逐个看 5.2 节那七种外观。只调颜色与玻璃强度，不改路径。
5. 分别在浅色壁纸、深色壁纸、彩色着色下检查 32 px 与 1024 px。
6. 保存 `AppIcon.icon`，拖进 Xcode 工程，Target → General → App Icon 填 `AppIcon`。
7. 若最低系统 < 26，Xcode 会额外生成旧式扁平图标。仍须目视确认 Sequoia 及更早系统上的效果。

非 Xcode 工程：用 `actool` 把 `.icon` 编成 `Assets.car`，`Info.plist` 的 `CFBundleIconName` 填文件名（不含扩展名）。`.icon` 实际是文件夹，访达默认隐藏扩展名。Group 超过 4 个会编不过。

---

## 8. 交付清单

### 8.1 必须交付

| 文件 | 格式 | 说明 |
|---|---|---|
| `Aureways/AppIcon.icon` | Icon Composer | 唯一工程源文件，含全部外观 |
| `design/app-icon/A.svg` / `Orbit.svg` / `Spark.svg` | SVG | 三层源文件，描边已转曲 |
| `design/app-icon/logo_default_1024.png` | PNG | 蓝底白标平面预览，未裁圆角 |
| `design/app-icon/logo_dark_1024.png` | PNG | Dark 预览 |
| `design/app-icon/logo_on_white.svg` | SVG | 白底蓝标，印刷 / 文档 |
| `design/app-icon/logo_on_dark.svg` | SVG | 透明底白标（若需网页） |

### 8.2 可选交付

- 圆角预览图（仅用于演示，不进工程）
- 32 / 64 / 128 像素抽查 PNG（`design/app-icon/preview_*.png`）
- 启动画面用「标志 + 简化地球」横版，与 icon 分开管理
- watchOS 圆形安全区版本（若做 Watch 应用）

### 8.3 验收标准

- `python3 design/app-icon/build_icon.py` 跑完必须是 `renditions: 7/7 ok`，且 IoU ≥ 0.97。
- 1024 下边缘无锯齿、无羽化脏边。
- 32 px 仍能看出是 A，轨道不糊成一条脏带。
- Default 在浅色与深色桌面上都够对比。
- Clear / Tinted 不丢星星、不与相邻系统图标撞形。
- 未预裁圆角；在 Icon Composer 预览里圆角由系统生成。
- 没有地球、没有照片、没有字。

---

## 9. 原图与 Icon 的分工

| 资产 | 用在哪 |
|---|---|
| 原图（标志 + 地球） | 官网头图、启动画面、宣传海报、壁纸。**不是 App Icon。** |
| 蓝底白标 / 分层 `.icon` | Dock、Launchpad、Finder、App Store、设置「关于」、通知。 |
| 白底蓝标 / 深色白标矢量 | 空白画布 `BrandMark`、文档页眉、PPT、打印物料、浅色网页。 |
| 单色剪影 | Clear / Tinted、菜单栏精简、模板水印。 |

---

## 10. 仓库位置

| 路径 | 角色 |
|---|---|
| `Aureways/AppIcon.icon/` | Xcode 26+ 工程图标（`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`） |
| `Aureways/Assets.xcassets/AppIcon.appiconset/` | 扁平回退 PNG（16–1024） |
| `Aureways/Assets.xcassets/BrandMark.imageset/` | 界面内平面标志（浅色蓝标 / 深色白标 SVG） |
| `Aureways/Assets.xcassets/AccentColor.colorset/` | 系统强调色，Orbit Blue / 深色提亮蓝 |
| `design/app-icon/` | 分层 SVG、色版预览、重建脚本 `build_icon.py` |
| `design/app-icon/reference/` | 三张 1408 参考稿，几何拟合的唯一依据 |

重建与验收：

```
python3 design/app-icon/build_icon.py           # 重建全部产物，并自检
python3 design/app-icon/build_icon.py --check   # 只自检
```

`design/app-icon/` 下所有 SVG 与 PNG 都是生成物。要改形状，改 `build_icon.py`
顶部的参数，不要直接编辑 SVG。

几何是解析式描述而非描摹：A 是四条直边加圆角，轨道是两段椭圆弧加两条收尖的三次
曲线，星是四条三次曲线。每层因此只有几条真曲线——折线会被 Liquid Glass 逐面打光，
呈现出锯齿状的假面。

`--check` 会把模型重新光栅化，与三张参考稿的多数投票做 IoU 比较（当前 **0.979**，
比三张参考稿彼此之间的一致度 0.93–0.96 还高），并写出 `_diag_overlay.png`：绿色为
吻合，红色为参考稿独有，黄色为模型独有。

脚本在装有 Xcode 时会自己调用 `ictool`：导出 `preview_composer_{default,dark}.png`
（1024 px，真实 Liquid Glass 渲染），再把 5.2 节那七种 rendition 各导一遍 256 px 做
存活检查，结果打印成 `renditions: 7/7 ok`。之后仍应用 Icon Composer 打开
`Aureways/AppIcon.icon`，在浅色 / 深色壁纸和 Tinted 下检查 32 px 与 1024 px。

端到端验证（改完图标后跑一遍）：

```
xcrun actool Aureways/Assets.xcassets Aureways/AppIcon.icon --compile /tmp/ic \
  --app-icon AppIcon --accent-color AccentColor --target-device mac \
  --minimum-deployment-target 26.0 --platform macosx \
  --output-partial-info-plist /tmp/ic/p.plist --notices --warnings
iconutil -c iconset /tmp/ic/AppIcon.icns -o /tmp/ic.iconset   # 目视 16/32/128 px
```

`actool` 无警告并产出 `AppIcon.icns` + `Assets.car` 就算通过。注意 `.icon` 与
`.appiconset` 同名不冲突：macOS 26+ 用前者，后者是 26 以下的回退，两个都留。

---

## 11. 参考

- [Apple HIG — App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/Xcode/creating-your-app-icon-using-icon-composer)
- [Apple Design Resources / Icon Composer](https://developer.apple.com/design/resources/)
- HIG 更新记录：2026-06-08 Refined guidance for Liquid Glass

本文档不替代 Apple 审核条款。上架前仍须用最新 Xcode 在 macOS 26 / 27 实机预览 5.2 节列出的七种外观。
