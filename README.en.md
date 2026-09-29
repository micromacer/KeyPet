<br />
<div align="center">
  <img src="docs/logo.png" alt="KeyPet Logo" width="200" height="200">

  <h3 align="center">KeyPet</h3>

  <p align="center">
    A lightweight, low-resource native macOS keyboard pet app
    <br />
    <br />
    <a href="README.md">简体中文</a>
    &middot;
    <a href="README.en.md">English</a>
    &middot;
    <a href="README.ja.md">日本語</a>
  </p>
</div>

## Introduction

KeyPet is a desktop pet app. Set up PNG/APNG character assets following the rules, and your pet will react to your keystrokes — it can even bounce upward with a springy motion.

Purpose-built for Apple silicon Macs, KeyPet is written in Swift 6 and uses Core Animation as its rendering and timing foundation, with an architecture that puts performance first. As a result, compared with other cross-platform desk-pet projects, KeyPet achieves the same smooth 60 FPS animation with lower resource usage.

KeyPet supports a rich set of animation triggers: actions can fire based on which side of the keyboard you press (left/right), and you can also assign dedicated action images to specific keys.

You can also flip the character horizontally, swap the left/right limb responses, add a real-time shadow, and adjust its size, opacity, and limb reset delay.

**⚠️ Note:** **KeyPet does not ship with any pet assets.** You need to design and create your own, or download pet assets from legitimate sources.

## System Requirements

- A Mac with Apple Silicon (arm64), running macOS 15.0 or later.

Intel Macs are not supported.

## Installation

1. Download the latest `.dmg` installer image from **Assets** on the **Releases** page.
2. Double-click the `.dmg` image and drag **KeyPet.app** into the **Applications** folder.

## First Run

Follow the prompts to enable **KeyPet** under **System Settings → Privacy & Security → Input Monitoring**. If KeyPet is not in the list, click the + button below the list to add it.

Once enabled, allow the system to reopen KeyPet, then choose the folder where your pet assets are stored. You can change this later from the menu.

## About Input Monitoring

Because KeyPet never takes keyboard focus in the foreground, the only way it can sense keyboard input is by globally monitoring keyboard events through the macOS Core Graphics API — which is why it needs Input Monitoring permission.

Rest assured: **KeyPet has no networking, analytics, or telemetry of any kind, and it never stores or transmits anything you type.** You are welcome to verify this in the source code at any time.

## Preparing Pet Assets

### Basic Requirements

- Static PNG (`.png`) or animated PNG (`.apng`) image files
- Image width and height must both be 2048 px or less
- A single file must be 64 MiB or less
- Animated files may contain at most 2000 frames

### Folder Layout

KeyPet distinguishes pets by the subfolders inside the asset root folder. See the file tree below:

```text
MyPets/
└── Swordsman43/
    ├── pet-idle.png
    ├── pet-left.png
    ├── pet-right.png
    └── pet-space.png
```

A subfolder's name is treated as the pet's name and shown in the menu, like `Swordsman43` here.

### File Naming Rules

#### Basics

Each file represents one character action, and its file name determines which key press triggers that action.

The file name format is:

```text
pet-<token>.png  or  pet-<token>.apng
```

Here, `pet-idle` is the character shown while idle and **must exist.** `pet-left` and `pet-right` are the left/right limb actions, triggered according to each key's left/right-hand assignment, or by the left/right arrow keys `←/→`, the volume down/up keys, and the previous/next track keys.

**We recommend that each pet include at least `pet-idle`, `pet-left`, and `pet-right`.**

#### Key Token Reference

**Letter keys**: the token is the corresponding lowercase letter — 26 in total (`a`, `b`, `c` … `x`, `y`, `z`).

**Number row and punctuation**:

| Key           | token          |
| ------------- | -------------- |
| 1             | `1`            |
| 2             | `2`            |
| 3             | `3`            |
| 4             | `4`            |
| 5             | `5`            |
| 6             | `6`            |
| 7             | `7`            |
| 8             | `8`            |
| 9             | `9`            |
| 0             | `0`            |
| -             | `minus`        |
| =             | `equals`       |
| [             | `openbracket`  |
| ]             | `closebracket` |
| ;             | `semicolon`    |
| '             | `quote`        |
| ,             | `comma`        |
| .             | `period`       |
| /             | `slash`        |
| `` ` ``       | `backquote`    |
| \ (backslash) | `backslash`    |

**Editing keys**:

| Key               | token       |
| ----------------- | ----------- |
| Return            | `enter`     |
| Tab               | `tab`       |
| Space             | `space`     |
| Backspace (Delete) | `backspace` |
| Esc               | `escape`    |
| Caps Lock         | `capslock`  |

**Modifier keys**:

| Key           | token          |
| ------------- | -------------- |
| Left Shift    | `shift`        |
| Right Shift   | `rightshift`   |
| Left Control  | `control`      |
| Right Control | `rightcontrol` |
| Left Option   | `option`       |
| Right Option  | `rightoption`  |
| Left Command  | `command`      |
| Right Command | `rightcommand` |
| Fn            | `fn`           |

**Function keys**: F1–F12 map to `f1`–`f12`.

**Navigation and arrow keys**:

| Key                 | token      |
| ------------------- | ---------- |
| Home                | `home`     |
| End                 | `end`      |
| Page Up             | `pageup`   |
| Page Down           | `pagedown` |
| Forward Delete (⌦)  | `delete`   |
| ↑                   | `up`       |
| ↓                   | `down`     |
| ←                   | `left`     |
| →                   | `right`    |

**Numeric keypad**:

| Key           | token               |
| ------------- | ------------------- |
| Digits 0–9    | `numpad0`–`numpad9` |
| +             | `numpadplus`        |
| −             | `numpadminus`       |
| ×             | `numpadmultiply`    |
| ÷             | `numpaddivide`      |
| Decimal point | `numpaddecimal`     |
| =             | `numpadequals`      |
| Enter         | `numpadenter`       |
| Clear         | `numpadclear`       |

**Media keys**:

| Key                              | token        |
| -------------------------------- | ------------ |
| Play / Pause (a single media key) | `playpause`  |
| Previous track                   | `previous`   |
| Next track                       | `next`       |
| Volume +                         | `volumeup`   |
| Volume −                         | `volumedown` |
| Mute                             | `mute`       |

See the code [`PetKeyMapping.swift`](Sources/Input/PetKeyMapping.swift) for the exact token matching rules.

#### Action Matching Order

On every key press, KeyPet picks an action in the following order:

1. **Key-specific token**: such as `1`, `a`, `space`, `enter`, etc.
2. **Left/right limb**: keys without a dedicated image trigger `left` or `right` based on their side assignment.
3. **Idle image**: if there are no `left` or `right` assets, `idle` is shown.

#### Asset Loading

At launch, KeyPet reads every subfolder inside the asset root folder. KeyPet also detects and reloads assets automatically, so there is no need to restart the app after replacing, adding, or removing assets.

If a pet is not recognized properly, choose **Pets - Rescan** from the menu.

#### Example Pet

You can download the example pet asset files [here](demo).

## Building from Source

Install Xcode 26 or later (which includes Swift 6 and Icon Composer support), and set it as the active developer directory. Release builds have been verified with Xcode 27.0.

```sh
xcodebuild -project KeyPet.xcodeproj -scheme KeyPet \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData build
```

The build product is located at `build/DerivedData/Build/Products/Release/KeyPet.app`.

## FAQ

1. **The app won't launch when double-clicked after installation:** scroll down in **System Settings → Privacy & Security**, then click the **Open Anyway** button.
2. **Double-clicking after installation shows “damaged and can’t be opened”:** first try right-clicking the KeyPet app icon and choosing **Open** from the menu. If that doesn't work, run the following command in Terminal: `sudo xattr -r -d com.apple.quarantine /Applications/KeyPet.app`.
3. **The Fn key doesn't trigger the character's animations:** on some external keyboards, the Fn key is handled entirely by the keyboard's own firmware and never sends a key event to macOS, so the app cannot detect it. However, with the default system settings, holding Fn + a function key still correctly triggers the animations for F1, F2, and other function keys.

## License

KeyPet is open source under the [MIT License](LICENSE).

Copyright (c) 2026 Micromacer
