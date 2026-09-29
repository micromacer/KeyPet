# KeyPet

一款轻量的 macOS 键盘桌宠，会根据你的按键做出动作。当前版本：**1.4.2**。

KeyPet 支持静态 PNG 和动态 PNG（APNG）素材、按键专用动作图片及素材自动重新加载。界面支持英语、日语、繁体中文和简体中文。应用在菜单栏运行，不显示 Dock 图标。

## 系统要求

- 搭载 Apple Silicon（arm64）的 Mac，运行 macOS 15.0 或更高版本。
- 自备宠物素材，应用不附带宠物图片。
- 允许“输入监控”权限，以启用键盘响应。

此构建不支持 Intel Mac、Windows 或 Linux。

## 安装

1. 打开 `KeyPet-1.4.2-arm64.dmg`，将 **KeyPet.app** 拖入 **Applications（应用程序）**。如果已安装 KeyPet，请先退出应用再替换。
2. 推出磁盘映像，从“应用程序”文件夹打开 KeyPet。
3. 按照提示，在 **系统设置 → 隐私与安全性 → 输入监控** 中启用 **KeyPet**。如果 macOS 要求重新打开应用，请按提示操作。
4. 选择存放宠物素材的文件夹。之后可通过菜单栏调整设置或退出应用。

可下载的安装包采用 **本地临时签名（ad hoc），未经 Apple 公证**。macOS 可能阻止首次启动。仅在确认下载来源可信时，参照 Apple 的[打开身份不明开发者应用的说明](https://support.apple.com/en-us/102445)操作。替换本地签名的应用后，可能需要重新授予“输入监控”权限。

## 准备宠物素材

所选文件夹中的每个直接子文件夹代表一只宠物，子文件夹名会显示在菜单中：

```text
Pets/
└── MyPet/
    ├── pet-idle.png
    ├── pet-left.png
    ├── pet-right.png
    └── pet-space.png
```

### 文件命名规则

一个动作对应一个图片文件，文件名决定它响应哪个按键：

```text
pet-<动作名>.png  或  pet-<动作名>.apng
```

- 前缀 `pet-` 和扩展名不区分大小写。
- `<动作名>` 会先规范化为动作 token：转成小写，再去掉英文字母和数字以外的所有字符。例如 `pet-Space!.png` 会得到 `space`，`pet-F1.png` 会得到 `f1`；规范化为空的文件（如 `pet-!.png`）会被忽略。
- 注意规范化去掉的是字符而非语义：`pet-left-paw.png` 的 token 是 `leftpaw`，并不匹配左爪动作 `left`。
- 两个文件规范化出同一个 token（如 `pet-a.png` 与 `pet-A!.png`）即为冲突，两个文件都不会生效，菜单中会显示提示。
- 以 `.` 开头的隐藏文件不参与扫描；替换或增删素材后无需重启，KeyPet 会自动重新加载。

### 按键如何匹配动作

每次按下按键，KeyPet 按以下顺序挑选动作：

1. **按键专属 token**：如 `a`、`space`、`enter`。
2. **左右爪回退**：没有专属图片的按键，按左右手归属回退到 `left` 或 `right`。左右 Shift、Control、Option、Command 分别与同侧字母键保持一致，连续按同一个键不会交替；无归属的按键（Fn、小键盘 Clear 等）在左右爪之间交替。
3. **待机图**：连左右爪图片也缺失时，显示 `idle`。

方向键 ←、→ 的 token 正是 `left`、`right`，按下时直接显示对应的爪部动作。按键全部松开后停留片刻回到 `idle`；APNG 动作在显示期间循环播放，忽略文件自带的循环次数。

默认映射沿用角色朝向：键盘左侧（如 A、左 Shift）对应 `pet-right`，键盘右侧（如 P、右 Shift）对应 `pet-left`。菜单中的“交换左右响应”可反转这些回退动作，专属按键图片不受影响。

### 特殊 token

| token | 说明 |
| --- | --- |
| `idle` | 待机图，**必需**。 |
| `left` / `right` | 左右爪回退动作，可选；缺失时按 `idle` 处理。 |

### 按键 token 一览

**字母键**：token 即对应的小写字母，共 26 个（`a`、`b`、`c` … `x`、`y`、`z`）。

**数字行与标点**：

| 按键 | token |
| --- | --- |
| 1 | `1` |
| 2 | `2` |
| 3 | `3` |
| 4 | `4` |
| 5 | `5` |
| 6 | `6` |
| 7 | `7` |
| 8 | `8` |
| 9 | `9` |
| 0 | `0` |
| - | `minus` |
| = | `equals` |
| [ | `openbracket` |
| ] | `closebracket` |
| ; | `semicolon` |
| ' | `quote` |
| , | `comma` |
| . | `period` |
| / | `slash` |
| `` ` `` | `backquote` |
| \（反斜杠） | `backslash` |

**编辑键**：

| 按键 | token |
| --- | --- |
| Return | `enter` |
| Tab | `tab` |
| 空格 | `space` |
| 退格（Delete） | `backspace` |
| Esc | `escape` |
| Caps Lock | `capslock`（锁定瞬间记为一次完整的按下+松开） |

**修饰键**：

| 按键 | token |
| --- | --- |
| 左 Shift | `shift` |
| 右 Shift | `rightshift` |
| 左 Control | `control` |
| 右 Control | `rightcontrol` |
| 左 Option | `option` |
| 右 Option | `rightoption` |
| 左 Command | `command` |
| 右 Command | `rightcommand` |
| Fn / 地球键（键盘须向 macOS 上报） | `fn` |

Fn / 地球键支持 `pet-fn.png` 或 `pet-fn.apng` 专属素材；缺少时沿用未分类按键的左右交替规则。除系统修饰键事件外，KeyPet 还只读监听键盘上报的 Apple Fn 和 USB 地球键 HID 输入，支持单独按下、松开复位，并合并两条通道的按住状态，不改变系统原有功能。两条通道按原始输入时间配对去重，即使同一次点按的第二组事件延迟到达，也不会再次触发动作；连续点按仍各自响应。连接支持 HID Fn 的键盘后，其他键盘通过系统事件上报的 Fn 仍可使用。

外接键盘上用于切换灯光、蓝牙或功能层的 Fn，可能完全由键盘固件处理，不向 macOS 发送按键事件；这种 Fn 无法仅靠应用检测。可在键盘配置工具中选择向主机发送 Mac Globe / 地球键的功能，但它与键盘内部的 Fn 层切换不是同一种功能，是否能兼用取决于键盘固件。

**功能键**：F1–F20 对应 `f1`–`f20`（如 `pet-f5.png`）。

**导航与方向键**：

| 按键 | token |
| --- | --- |
| Help / Insert（PC 键盘） | `insert` |
| Home | `home` |
| End | `end` |
| Page Up | `pageup` |
| Page Down | `pagedown` |
| Forward Delete（⌦） | `delete` |
| ↑ | `up` |
| ↓ | `down` |
| ← | `left` |
| → | `right` |

**小键盘**：

| 按键 | token |
| --- | --- |
| 数字 0–9 | `numpad0`–`numpad9` |
| + | `numpadplus` |
| − | `numpadminus` |
| × | `numpadmultiply` |
| ÷ | `numpaddivide` |
| 小数点 | `numpaddecimal` |
| = | `numpadequals` |
| Enter | `numpadenter` |
| Clear | `numpadclear` |

**媒体键**：

| 按键 | token | 默认回退动作 |
| --- | --- | --- |
| 播放 / 暂停（同一个媒体键） | `playpause` | `pet-left` |
| 上一曲 | `previous` | `pet-left` |
| 下一曲 | `next` | `pet-right` |
| 音量 + | `volumeup` | `pet-right` |
| 音量 − | `volumedown` | `pet-left` |
| 静音 | `mute` | `pet-left` |

对应专属素材为 `pet-playpause.png`、`pet-previous.png`、`pet-next.png`、`pet-volumeup.png`、`pet-volumedown.png`、`pet-mute.png`，也支持 `.apng`。播放与暂停使用同一个 `playpause` token，因为系统发出的是同一种按键事件；KeyPet 不读取播放器状态。键盘将上一曲/下一曲上报为快退/快进事件时，也分别匹配 `previous` / `next`，包括长按重复和松开。

没有专属素材时，上一曲/下一曲、音量减/加分别使用固定的左/右动作，连续按同一个键不会交替；“交换左右响应”可以反转回退方向，专属素材不受影响。媒体键响应不拦截系统事件，原有播放、切歌、音量和静音功能继续工作。如果键盘设置为将顶行按键用作标准功能键，直接按下会匹配 `f7`、`f8`、`f9` 等功能键 token，按住 Fn 切换到媒体功能后才匹配媒体 token。

媒体键松开后按设定延迟回到待机；系统长按重复会保持动作。媒体键没有可查询的普通按键状态，因此漏收松开事件时，会在最近一次媒体事件停止至少 6 秒后的保护检查中释放动作。

**其他**：

| 按键 | token |
| --- | --- |
| ISO 键盘的 § 键（左 Shift 与 Z 之间） | `section` |

按键到 token 的映射以代码 [`PetKeyMapping.swift`](Sources/Input/PetKeyMapping.swift) 为准。

每张图片的宽、高均不能超过 2048 像素，单文件不能超过 64 MiB，动画最多支持 2000 帧。KeyPet 直接读取原位置的素材，不复制或修改原文件。请使用你有权使用的素材；第三方素材不适用本仓库的许可证。

拖动宠物可调整位置，右键点击宠物可打开菜单。开启鼠标穿透后，仍可通过菜单栏操作。菜单提供大小、不透明度、阴影、键盘响应、语言等设置。

## 隐私

KeyPet 仅根据按键状态选择动画，不读取或记录输入的文字，不发送网络请求，也不包含统计分析功能。Fn 去重所需的有限时间信息仅保留在内存中，停止监听时清空，不写入文件。偏好设置和所选素材文件夹的书签均保存在本地。

## 从源码构建

安装 Xcode 26 或更高版本（包含 Swift 6 和 Icon Composer 支持），并将其设为当前使用的开发工具目录。

```sh
xcodebuild -project KeyPet.xcodeproj -scheme KeyPet \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData build
```

构建产物位于 `build/DerivedData/Build/Products/Release/KeyPet.app`。项目使用系统框架和本地临时签名，本地构建无需外部依赖或签名账号。

Release 构建完成后，可打包 DMG：

```sh
bash BuildSupport/package-dmg.sh
```

脚本从已构建应用读取版本号，在 `dist/` 生成 `KeyPet-<版本号>-arm64.dmg` 和 `SHA256SUMS`，不修改版本号。DMG 包含应用、Applications 快捷方式、当前 README 和许可证；同名旧安装包会先备份到 `build/replaced-distributions/`。打包后会校验签名和磁盘映像完整性。

应用图标由 Xcode 直接编译 `Resources/KeyPet.icon`。该 Icon Composer 文件包包含图标配置和两个 SVG 图层，支持 macOS 26 的浅色、深色、透明和色调外观；较早的系统使用 Xcode 生成的兼容图标。菜单栏图标独立打包。

## 开源协议

版权所有 © 2026 Micromacer。项目采用 [MIT 许可证](LICENSE)授权。
