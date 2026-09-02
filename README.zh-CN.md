# QuotaWarmer

[English](README.md) | **简体中文**

一个小巧的 macOS 菜单栏应用,帮你把 Claude Code 和 Codex CLI 的 5 小时配额窗口一直"焐热"——它盯着你的滚动配额窗口,窗口一开就自动接手续上,不用你自己记着去用一下才能触发。

<p align="center">
  <img src="docs/images/panel-overview-light.png" alt="QuotaWarmer 总览面板,浅色" width="360">
  <img src="docs/images/panel-overview-dark.png" alt="QuotaWarmer 总览面板,深色" width="360">
</p>
<p align="center">
  <img src="docs/images/menu-bar.png" alt="QuotaWarmer 菜单栏显示" height="20">
</p>

默认只**监控**:实时看配额、在菜单栏显示每个工具的窗口状态。把某个工具切到 **Auto-warm**,它就会在窗口一开的瞬间,通过你本机已登录的 CLI 发一条最小化的预热命令,然后再确认一遍窗口是不是真的开了。

## 关于这个仓库

这是 [bcanozgur/quota-warmer](https://github.com/bcanozgur/quota-warmer) 的个人 fork。保留它的原因是上游唯一发布过的正式版本带一个凭据相关的 bug(见下方[鸣谢](#鸣谢)),我需要一个不带这个 bug 的版本用在自己每天的自动化上——一台 Mac 早上 7 点自动醒来,把两个工具都预热好,然后全天自动续窗口,不用我插手。在这个基础上,我把面板重做成跟随系统浅色/深色外观(而不是写死的十六进制颜色)、修掉了反复弹出的钥匙串授权框,还让自动续窗口这件事在配额查询接口被限流时也能扛得住——查下来发现这个接口真的会一连限流好几个小时,之前一限流,整个自动续期就跟着停摆。

## 亮点

- **每个工具三档模式**:**Off**(关闭)、**Monitor only**(只看不发,默认档)、**Auto-warm**(自动抢开新窗口)。
- **菜单栏一眼看懂状态**:工具图标、时钟式倒计时、剩余配额百分比——健康时安安静静,只有真需要注意时才会亮起彩色角标。
- **同时支持 Claude Code 和 Codex CLI**:两个工具各自独立监控、刷新、预热。
- **抗限流的自动续期**:实时配额查不到时,会退而求其次去看本地 CLI 的真实活动记录来判断要不要续窗口——配额查询接口被限流,不再连累这个 app 真正该干的事。
- **开窗回执**:预热之后会再查一次配额,确认窗口真的开了,不会出现"命令发了但其实没生效"这种情况自己却不知道。
- **健康监测**:如果 app 哪天真的停止检查配额了,菜单栏和面板会明说,而不是继续装作一切正常。
- **手动控制**:面板里可以直接手动刷新配额或手动预热某个工具。
- **轻量历史记录**:最近的配额检查、预热、开窗确认、失败记录,不用离开菜单栏就能看。
- **早晨预热**:可以设定一个时间让 Mac 自动唤醒并抢开当天第一个窗口,合不合盖都不影响。
- **开机自启**:安静地作为菜单栏工具运行,没有 Dock 图标。

## 这样用合规吗?

QuotaWarmer 用的是你本来就付费买下的额度,走的是你已经登录的官方 CLI。它不会绕过或提高你的限额,不会分享或上传你的凭据,Monitor 或 Off 状态下什么都不会发送。服务商随时可能调整接口规则;如果自动预热哪天不被允许了,把工具切到 Monitor,QuotaWarmer 还是能继续帮你看着配额。

## 工作原理

Claude Code 和 Codex CLI 用的是滚动配额窗口。如果窗口只能靠你自己想起来去用一下才会开始计时,那有一部分可用时间就白白浪费掉了。

QuotaWarmer 安安静静地跑在菜单栏,定期检查被监控工具的配额状态。设成 Auto-warm 的工具,一旦检测到新窗口——不管是通过实时配额读数,还是(在配额接口查不到的情况下)通过"最近本地完全没有活动记录"这个信号——就会在一个隔离的临时工作目录里跑一条最小化的预热命令:

```bash
claude --model haiku --effort low --no-session-persistence -p 'hi'
codex exec --model gpt-5.4-mini -c model_reasoning_effort="low" --skip-git-repo-check --ephemeral --ignore-rules 'hi'
```

本地活动读取自:

```text
~/.claude/projects/*/*.jsonl
~/.codex/sessions/YYYY/MM/DD/*.jsonl
```

这些日志一方面给界面提供上下文,另一方面——因为它们反映的是真实使用情况而不是一次网络请求——在实时接口失灵的时候,能撑住自动续期的判断。

## 环境要求

| 依赖 | 要求 |
| --- | --- |
| macOS | 14.0 Sonoma 或更高 |
| Xcode | 16+(仅本地编译需要,见下文) |
| Claude Code | 已安装,且在 shell 的 `PATH` 里能找到 |
| Codex CLI | 已安装,且在 shell 的 `PATH` 里能找到 |

## 安装

### 下载 Release

1. 从本仓库的 [Releases](https://github.com/WenjunLi2004/quota-warmer/releases) 下载最新的 `QuotaWarmer-<version>-universal.dmg`。
2. 打开 DMG,把 **QuotaWarmer.app** 拖进 **Applications**。
3. 清除 Gatekeeper 隔离属性(DMG 是 ad-hoc 签名,未经 Apple 公证):
   ```bash
   xattr -dr com.apple.quarantine "/Applications/QuotaWarmer.app"
   ```
   ……或者第一次打开时右键点 **QuotaWarmer.app** 选择"打开"。
4. 从 Applications 里启动它。

### 从源码构建

SwiftUI 的 `@State` 现在靠一个宏插件编译,这个插件只随完整 Xcode 分发,单装 Command Line Tools 编译不出来。

```bash
brew install xcodegen
git clone https://github.com/WenjunLi2004/quota-warmer.git
cd quota-warmer
xcodegen generate
open QuotaWarmer.xcodeproj
```

或者用命令行直接编译:

```bash
xcodebuild -project QuotaWarmer.xcodeproj -scheme QuotaWarmer build
```

### 如何验证一次 Release

这里的每个 DMG 都是这个仓库自己的 `release-unsigned.yml`,在 GitHub 的 macOS runner 上、从打了 tag 的那个具体 commit 编译出来的——不是手工攒的。想核实某个 release 对应哪一份看得见的源码:把那个 tag 的 `project.yml` 和[上游 `main`](https://github.com/bcanozgur/quota-warmer/compare/main...WenjunLi2004:quota-warmer:main) 对比一下,应该只有版本号不一样;再核对下载的 DMG 的 SHA-256 和同一个 release 里发布的 `.sha256` 文件是否一致。

## 两个值得知道的取舍

**配额百分比偶尔会弹出钥匙串授权框。** 要拿到实时百分比,唯一办法是读 Claude Code 自己存的凭据;而 macOS 的"始终允许"授权,扛不过 Claude Code 每次轮换 OAuth 令牌(大约每 8 小时一次)对这个条目的重写——所以弹窗大概率会按这个周期反复出现。QuotaWarmer 会在两次轮换之间把令牌镜像到自己的钥匙串条目里,专门用来减少弹窗频率,但没法完全消除。如果弹窗比看到实时百分比更让你烦,把这个工具切成 **Monitor** 或 **Off** 就行——自动续期本身直接调用 CLI,完全不需要这一步。

**`claude setup-token` 生成的长期令牌在这里用不了。** 之前试过这条路,想法是"app 自己拥有的钥匙串条目不需要重新授权"——这个逻辑没错,但 Anthropic 的用量查询接口(`/api/oauth/usage`)会直接拒绝这种类型的令牌,报 429,和普通的限流长得一模一样。表面上看就像接口被打爆了,实际上只是凭据类型不对,等多久都没用。如果配额百分比连续好几个刷新周期都显示不出来、也没有限流提示自己消失,先查这个——解法是换回 Claude Code 正常的 OAuth 凭据,不是多等一会儿。

另外:如果实时配额查询是因为真正短暂的原因掉线了(网络抖动、真实的临时限流),自动续期不会干等它恢复——会退而求其次去看本地 CLI 活动记录来判断窗口要不要续(见[工作原理](#工作原理)),所以单是百分比显示不出来,不会连累这个 app 真正该干的事。

## 项目结构

```text
Sources/QuotaWarmer/
  Models/       共享的 app 与配额类型
  Services/     配额检查、调度、通知、更新检查、预热命令
  Views/        SwiftUI 菜单栏标签、面板、工具详情、设置界面
  Assets.xcassets/
project.yml     XcodeGen 项目定义
scripts/        本地安装与打包脚本
```

## 鸣谢

这个项目 fork 自 [bcanozgur/quota-warmer](https://github.com/bcanozgur/quota-warmer)——核心设计(菜单栏这个思路、配额面板、预热机制)全部是原作者的工作。保留这个 fork 的原因是:上游唯一发布过的正式版本(`v1.0.0`)里,有一段 Claude OAuth 刷新令牌的换取逻辑,会消耗掉 CLI 那个一次性轮换的 refresh token 却不把换回来的新令牌写回去,足以悄悄踩坏 Claude Code 自己存的登录凭据——切这个 fork 时,`main` 分支其实已经删掉了这段逻辑,但一直没有发布新版本,而本地编译又离不开完整 Xcode(见上文)。从那个起点 commit 之后的所有改动——面板重做、钥匙串弹窗修复、抗限流的自动续期后备逻辑——都是在这个 fork 里写的,不代表对上游项目质量的任何评价,持续维护的原始项目还是应该去上游看。

## 许可证

MIT
