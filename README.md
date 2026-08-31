# QuotaWarmer

QuotaWarmer is a compact macOS menu bar app that manages your Claude Code and Codex CLI capacity — it keeps your own rolling quota windows in view and, when you ask it to, ready to use the moment they reset.

By default it only **monitors**: it watches live quota snapshots and shows each provider's window directly in the menu bar. Switch a tool to **Auto-warm** and it will also send a single minimal warm-up command through your own logged-in CLI the instant a fresh 5-hour window opens — then verify the window actually started.

<p align="center">
  <img src="docs/images/quota-warmer-menu.png" alt="QuotaWarmer menu bar popover" width="560">
</p>

---

## About This Fork

This fork exists because [upstream's](https://github.com/bcanozgur/quota-warmer) only tagged release, `v1.0.0`, ships a Claude OAuth refresh-token exchange that can silently invalidate Claude Code's own stored credential — it spends the CLI's single-use rotating refresh token without persisting the replacement it gets back. `main` had already removed that logic by the time this fork was cut, but no new release had been published, so there was no installable build without it. Building locally wasn't an option either: SwiftUI's `@State` compiles through a macro plugin (`libSwiftUIMacros.dylib`) that ships only with full Xcode, not Command Line Tools. This fork's releases are built from `main` via GitHub Actions instead — the diff against upstream `main` is version bumps only; every behavioral change below is a normal commit on top, same as any other fork's.

### What Changed

**No more recurring Keychain prompts.** Claude Code rewrites its own Keychain item on every OAuth token rotation (roughly every 8 hours), and a rewrite installs a fresh ACL — silently discarding any "Always Allow" grant you gave this app. That turned Keychain approval from a one-time cost into a recurring one, forever. `v1.6.0` adds a credential path that stores a token from `claude setup-token` in an item this app owns and controls: reads of an item you created yourself never prompt, and nothing else ever rewrites it.

**A calmer, native-looking panel.** The panel was rendered through a non-integral `scaleEffect`, which resamples already-rasterized text — the direct cause of the blur reported against it. Colors were a fixed light-mode hex palette that never followed system appearance, so dark mode rendered light-mode colors. `v1.2.0`–`v1.5.0` render the panel at 1:1 scale, resolve every color through AppKit's semantic palette (so dark mode works for free), narrow the icon rail to sit flush with the content instead of reading as a second pane, and color each quota bar by remaining headroom rather than always green — a bar that's fine stays neutral, so the one that needs attention actually stands out. The always-on menu-bar status dot is now silent while a tool is healthy, appearing only when something needs you.

**Backoff that respects a rate limit instead of hammering it.** When a credential or quota check fails, the app now backs off for real (up to 6 hours for a persistent 429) instead of retrying every 5 minutes forever — the old ceiling assumed a rate limit clears in about an hour; this endpoint has instead stayed blocked for 40+ hours at a stretch, and polling something that's visibly still blocked, once an hour, for two days straight helps no one.

### Screenshots

<!-- TODO: add before/after screenshots of the panel (light + dark) -->

### Verifying a Build

Every release DMG here is built by this repo's own `release-unsigned.yml` on GitHub's macOS runners, from the tagged commit — never hand-assembled. Compare the tag's `project.yml` against [upstream `main`](https://github.com/bcanozgur/quota-warmer/compare/main...WenjunLi2004:quota-warmer:main) to see that the only difference is the version string, and check the downloaded DMG's SHA-256 against the `.sha256` file published alongside it in the same release.

---

## 本 Fork 改了什么

这个 fork 存在的原因很直接:[上游仓库](https://github.com/bcanozgur/quota-warmer)唯一发布过的正式版本 `v1.0.0`,里面有一段 Claude OAuth 刷新令牌的换取逻辑——会拿 Claude Code 的一次性轮换 refresh token 去换新 token,却不把换回来的新 token 写回去,足以悄悄踩坏 Claude Code 自己存的登录凭据。作者在切这个 fork 时,`main` 分支其实已经把这段逻辑删掉了,但一直没有发布新版本,所以没有一个"不带这个 bug"的可安装版本。本地编译也走不通:SwiftUI 的 `@State` 现在靠一个宏插件(`libSwiftUIMacros.dylib`)编译,这个文件只随完整 Xcode 分发,Command Line Tools 里没有。于是这个 fork 改为直接从 `main` 走 GitHub Actions 构建——和上游 `main` 的差异只有版本号,下面列的每一项改动都是在此基础上正常提交的代码,和任何其他 fork 没有本质区别。

### 具体改了什么

**不再反复弹出钥匙串授权。** Claude Code 每次轮换 OAuth 令牌(大约每 8 小时一次)都会重写自己的钥匙串条目,而重写会装上全新的访问控制列表——把你之前点的"始终允许"连同旧条目一起悄悄丢弃。这让钥匙串授权从一次性成本变成了永久的周期性成本。`v1.6.0` 加了一条新的凭据路径:用 `claude setup-token` 生成一个长期令牌,存进这个 app 自己创建、自己拥有的钥匙串条目——读取自己创建的条目永远不会弹窗,也没有别的进程会去重写它。

**面板更安静、更像原生应用。** 之前面板是通过一个非整数倍的 `scaleEffect` 渲染的,这会把已经栅格化好的文字重新采样一遍,这正是"发糊"这个反馈的直接原因。配色是写死的浅色十六进制值,完全不跟随系统外观,导致深色模式下渲染出来还是浅色的颜色。`v1.2.0`–`v1.5.0` 把面板改成 1:1 渲染、全部颜色换成 AppKit 的系统语义色(深色模式因此白捡),把图标侧边栏收窄到和内容区贴合,不再像拼接的两块面板,配额进度条也不再永远是绿色,改成按剩余量分档着色——健康的窗口保持中性色,真正需要注意的那一条才会跳出来。菜单栏那个常驻的状态圆点,现在只在工具健康时保持安静,只有真需要你注意时才会出现。

**退避机制会真正尊重限流,而不是硬碰硬。** 以前凭据或配额检查失败后,app 会无限期地每 5 分钟重试一次;现在遇到持续性的 429 会真正退避(最长到 6 小时)——旧的 1 小时上限是按"限流大概一小时就能恢复"设计的,但实测这个接口曾连续限流超过 40 小时,对一个明显还在限流中的接口每小时敲一次、连敲两天,帮不上什么忙。

### 截图

<!-- TODO: 补充面板浅色/深色模式的前后对比截图 -->

### 如何验证一次构建

这里的每个 release DMG,都是这个仓库自己的 `release-unsigned.yml` 在 GitHub 的 macOS runner 上、从打了 tag 的那个 commit 编译出来的——不是手工攒出来的。可以对比该 tag 的 `project.yml` 和[上游 `main`](https://github.com/bcanozgur/quota-warmer/compare/main...WenjunLi2004:quota-warmer:main),会发现唯一的差异就是版本号;也可以核对下载的 DMG 的 SHA-256,和同一个 release 里发布的 `.sha256` 文件比对是否一致。

---

## Highlights

- **Three modes per tool**: **Off**, **Monitor only** (watch quota, never send anything — the default), or **Auto-warm** (claim fresh windows automatically).
- **Menu bar status at a glance**: provider glyph, mode/health dot, 5-hour countdown, and remaining quota percentage.
- **Claude Code and Codex CLI support**: each provider is monitored, refreshed, and warmed independently.
- **Live quota tracking**: reset decisions use fresh server quota snapshots; local logs are used only as display context.
- **Window claim receipt**: after a warm-up, QuotaWarmer re-checks quota to confirm the window actually opened — so "sent" never quietly means "missed."
- **Liveness watchdog**: if the app ever stops checking quota, the menu bar and popover say so instead of looking healthy.
- **Manual controls**: refresh quota or warm a provider directly from the popover.
- **Lightweight history**: recent quota checks, warm-ups, claim confirmations, update checks, and failures are visible without leaving the menu.
- **Notifications and update checks**: optional quota-window reminders plus in-app release availability.
- **Launch at login**: runs quietly as a menu bar utility.

## Is this allowed?

QuotaWarmer uses capacity you already pay for, through the official CLI you're already signed into. It never bypasses or raises your limits, never shares or uploads your credentials, and sends nothing at all for tools left on Monitor or Off. Providers may change their APIs at any time; if automated warm-up is ever disallowed, set a tool to Monitor and QuotaWarmer keeps tracking your quota.

## How It Works

Claude Code and Codex CLI use rolling quota windows. If a window starts only when you remember to open the CLI, part of the available time can be wasted.

QuotaWarmer keeps the app running in the menu bar and periodically checks quota state for monitored providers. For a tool set to Auto-warm, when a fresh reset is detected it runs a minimal warm-up command from an isolated temporary working directory:

```bash
claude --model haiku --effort low --no-session-persistence -p 'hi'
codex exec --model gpt-5.4-mini -c model_reasoning_effort="low" --skip-git-repo-check --ephemeral --ignore-rules 'hi'
```

If `gpt-5.4-mini` is unavailable for the signed-in Codex account, QuotaWarmer retries once with the configured default Codex model and low reasoning effort.

Local activity is scanned from:

```text
~/.claude/projects/*/*.jsonl
~/.codex/sessions/YYYY/MM/DD/*.jsonl
```

These logs help the UI show context, but stale local activity does not trigger automatic warm-ups.

## Requirements

| Dependency | Requirement |
| --- | --- |
| macOS | 14.0 Sonoma or later |
| Xcode | 16+ for local builds |
| Claude Code | Installed and available on your shell `PATH` |
| Codex CLI | Installed and available on your shell `PATH` |

QuotaWarmer shows setup guidance on first launch if a required CLI is missing.

## Install

### Homebrew (recommended)

```bash
brew install --cask bcanozgur/tap/quotawarmer
```

Update later with `brew upgrade --cask quotawarmer`.

### Manual download

1. Download the latest `QuotaWarmer-<version>-universal.dmg` from [Releases](https://github.com/bcanozgur/quota-warmer/releases).
2. Open the DMG and drag **QuotaWarmer.app** to **Applications**.
3. Launch **QuotaWarmer** from Applications.

### First launch (Gatekeeper)

QuotaWarmer is ad-hoc signed but **not Apple-notarized**, so macOS quarantines it on
download. Clear the quarantine once after installing:

```bash
xattr -dr com.apple.quarantine "/Applications/QuotaWarmer.app"
```

…or right-click **QuotaWarmer.app** in Applications and choose **Open** the first time.

## Build From Source

Install XcodeGen, generate the project, and open it in Xcode:

```bash
brew install xcodegen
git clone https://github.com/bcanozgur/quota-warmer.git
cd quota-warmer
xcodegen generate
open QuotaWarmer.xcodeproj
```

CLI build:

```bash
xcodebuild -project QuotaWarmer.xcodeproj -scheme QuotaWarmer build
```

Build a local Release app, replace any existing `/Applications/QuotaWarmer.app`, clear quarantine, and launch it:

```bash
scripts/local-package.command
```

## Project Structure

```text
Sources/QuotaWarmer/
  Models/       Shared app and quota types
  Services/     Quota checks, scheduling, notifications, updates, warm-up commands
  Views/        SwiftUI menu bar label, popover, provider, and settings screens
  Assets.xcassets/
project.yml     XcodeGen project definition
scripts/        Local install and packaging helpers
```

## Release Process

Releases are built by GitHub Actions from `vMAJOR.MINOR.PATCH` tags. The release workflow validates the tag against `project.yml`, builds the macOS app, signs and notarizes the DMG, uploads `latest.json`, and verifies release assets.

Required repository secrets:

| Secret | Purpose |
| --- | --- |
| `APPLE_CERTIFICATE` | Base64-encoded Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the `.p12` |
| `APPLE_SIGNING_IDENTITY` | Developer ID Application signing identity |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_PASSWORD` | App-specific password for notarization |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `KEYCHAIN_PASSWORD` | Temporary CI keychain password |

## License

MIT
