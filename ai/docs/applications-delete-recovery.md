# /Applications 被误删软件恢复清单
# 事故: zcode.sh 的 rm -rf "/Applications/$(basename "$ZC_APP")" 在 $ZC_APP 为空时展开成 rm -rf /Applications/
# 发生时间: 2026-11-13 11:36~11:37 之间
# 恢复方式: ~/.Trash 为空(直接 rm, 非移废纸篓) + 无本地 Time Machine 快照 => 只能重装
# 现存 /Applications 仅 8 个: ClashX Meta, RustDesk, Safari, Scratch 3, SogouInputSwitchHelper, UnzipOne, WeChat, ZCode

## ── Tier 1: 铁证被删（进程/lsof 仍引用已 unlink 的文件）───────────────
| 软件 | 证据 | 恢复 |
|---|---|---|
| Google Chrome.app | ps 575/4801 仍引用 /Applications/Google Chrome.app; ~/Library/Application Support/Google/Chrome 完整残留 | brew install --cask google-chrome 或 官网 chrome-downloads 下 dmg |
| ChatGPT.app | lsof 仍引用 /Applications/ChatGPT.app | 官网 https://chatgpt.com/download 或 brew install --cask chatgpt |
| Beyond Compare.app | /usr/local/bin/bcomp 断裂链接 -> /Applications/Beyond Compare.app/Contents/MacOS/bcomp; App Support/Beyond Compare 完整(BCSessions.xml 10/24) | brew install --cask beyond-compare |
| Trae CN.app | ShipIt 日志 11:37:37 "Trae CN.app couldn't be removed: The file doesn't exist"; /usr/local/bin/trae-cn 断裂链接 | bash ide/trae/install-trae.sh (ai-hub 已集成) |
| ClashX Meta.app | 原进程 1710 仍引用, 文件已删 | ✅ 已恢复 |
| QuickTime.app | /Applications 与 /System/Applications 两处均无 | 软件更新 或 brew install --cask quicktime-player |

## ── Tier 2: LaunchServices 曾注册 + 现不存在（高置信）─────────────────
| 软件 | 说明 |
|---|---|
| Typora.app | App Support/abnerworks.Typora + Preferences/abnerworks.Typora.plist |
| Xmind.app | App Support/Xmind |
| wpsoffice.app | lsregister 含 LoginItems/wpslaunchhelper |
| BaiduNetdisk_mac.app | SavedState 完整残留(com.baidu.BaiduNetdisk-mac.savedState) |
| HexHub.app | Preferences/cn.hexhub.plist |
| NanoPhone.app | lsregister 注册过 |
| Mounty.app | Preferences/com.cu4uc.mounty.plist |
| Comate.app | App Support/Comate, Preferences |
| .Eclipse.app | lsregister 有 .Eclipse.app.bak-20261023 (10/23 备份) |

## ── Tier 3: 仅有 Preferences 残留（可能曾是 app, 也可能是 CLI）─────────
# 仅列你日常在用的, 逐个确认后恢复
Docker.app / VirtualBox / Genymotion / Nox AppPlayer / Parallels / CrossOver /
Windsurf / Antigravity / MarkText / draw.io / Motrix / VLC / DBeaver / JumpServer /
WindTerm / iTools-Pro / OmniDiskSweeper / DiskInventoryX / Podman Desktop /
Clash Verge Rev / Telegram / bilibili / Youku / Thunder / Skype / MakeMKV /
Chat2DB / MongoDB Compass / HBuilderX / Paros / ZAP / ShadowsocksX-NG / V2rayU /
OC-Gen-X / MarkText / utools / Obsidian / Sublime Text / ITerm2 / Android Studio /
DataGrip / PyCharm / IntelliJ / VSCode / Hermes / Kiro / Qoder IDE / 钉钉 / 腾讯会议 /
Aliworkbench / 夸克 / 阿里云灵码 / 通义千问 / 智谱清言 / CodeBuddy / 豆包浏览器 /
SenseTime共享盘 / OCAuxiliaryTools / Hackintool / 4uKey / YDSteward / WeType

## ── 未受影响（CLI/npm 形式, 仍在）─────────────────────────────────────
codex CLI (@openai/codex@0.167.2) / qoder CLI (@qoder-ai/qodercli@1.1.86) /
brew / opencode / dsh / codebuddy-code / 各 mcp-server 包 / Clash Verge Rev
(服务仍在跑: /Library/PrivilegedHelperTools/io.github.clash-verge-rev... 9:17 起)
