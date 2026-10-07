# github-release-upload

给 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 用的 **Skill**：
把构建产物（exe / zip / msi / apk）上传到 **GitHub Release**，**不需要 `gh` CLI**，
并且在 `uploads.github.com` 不稳定的网络下也能成功。

配套 skill：[`dsh-skill-github-publish`](https://github.com/IKTNF/dsh-skill-github-publish) 负责建仓库和推源码；
本 skill 负责 tag 之后的一切——建/修 Release、传附件、修状态、验证。

## 它解决什么

普通的 `curl` 上传在这些情况下会静默失败或传上去一个坏的：

| 症状 | 天真做法 | 本 Skill |
|---|---|---|
| `uploads.github.com` 解析到死 IP | 直接超时 | 逐个 TCP 探测候选 IP，用 20 字节探针确认拿到 `201` 再传真实文件 |
| `schannel ... 0x80092013` | TLS 握手失败 | 加 `--ssl-no-revoke`（CRL 服务器不可达时不再校验吊销） |
| 100 MB+ 传一半 `Connection was reset` | 反复失败 | 12 次重试，循环切换 不限速 / `--limit-rate 4M` / `2M` / `1M`——降速换成功率 |
| 响应丢了但其实传成功了 | 重复上传 | 每次重试前重新查资产列表，已存在就跳过 |
| tag 被删了重推 → Release 变成 draft | 访客看不到附件 | `PATCH {"draft": false}` 重新发布 |
| PS 5.1 按 GBK 读脚本导致中文乱码 | 解析报错 | 脚本保持纯 ASCII，中文发布说明走 UTF-8 JSON 文件 |
| 打了网站边缘 IP | 返回 `301` | 按状态码区分 201/301/403/000 各自处理 |

## 安装

Skill 目录本身就是仓库，克隆到 DSH 的 user skill 根目录即可
（`$DSH_HOME` 默认 `~/.dsh`）：

```powershell
# 确认你的 DSH_HOME
echo $env:DSH_HOME

git clone https://github.com/IKTNF/dsh-skill-github-release-upload.git "$env:DSH_HOME\skills\github-release-upload"
```

装完即生效——DSH 会监视 `<dshHome>/skills`，新目录一出现就自动进入模型可见的 skill 目录，**不需要重启**。

验证：

```powershell
Test-Path "$env:DSH_HOME\skills\github-release-upload\SKILL.md"   # 应为 True
```

更新：

```powershell
git -C "$env:DSH_HOME\skills\github-release-upload" pull
```

## 用法

### 1. 让 Agent 用它

直接说需求，Agent 会根据 `SKILL.md` 的 description 自动加载：

> 把 dist 里的 exe 传到 GitHub Release v1.2.3 上

### 2. 手动调用脚本

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\upload-release.ps1 `
  -Owner <owner> -Repo <repo> -Tag v1.2.3 `
  -Files "dist\App-1.2.3-setup.exe","dist\App-1.2.3-portable.exe" `
  -NotesJson "$env:TEMP\release.json"     # 可选，UTF-8 JSON（含中文时必须用）
```

只验证状态、不写任何东西的干跑：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\upload-release.ps1 `
  -Owner <owner> -Repo <repo> -Tag v1.2.3 -Files .\App.exe -DryRun
```

参数：`-Owner -Repo -Tag -Files`（必填），`-NotesJson -UploadIps -MaxAttempts -TokenFile`，
开关 `-DryRun -SkipProbe -KeepToken`。
`-Files` 支持逗号或空格分隔（`powershell -File` 不绑定数组）。
令牌缓存文件默认写到 `%TEMP%\dsh-gh-token.txt`，退出时删除，除非传了 `-KeepToken`。

## 目录结构

```
github-release-upload/
├─ SKILL.md                     主指令：recon → token → 建/修 Release → 上传 → 验证 → 清理
├─ scripts/
│  └─ upload-release.ps1        参数化实现（纯 ASCII，兼容 PS 5.1）
├─ references/
│  └─ network-notes.md          原始诊断记录：IP 扫描表、确切报错原文、编码陷阱
├─ README.md
└─ LICENSE
```

## 前提条件

- `git`（用来取已缓存的 GitHub 凭据）与 Windows 自带的 `curl.exe`
- **Git Credential Manager 里已缓存 GitHub 凭据**（用过一次 `git push` 到 GitHub 就会有）：
  ```powershell
  cmdkey /list | Select-String github
  ```
- 目标仓库与 tag **必须已经存在**——本 skill 不负责推代码，那是 `github-publish` 的事

脚本**不会**打印、回显或提交令牌；只在内存和 `%TEMP%` 缓存文件里用过即弃。

## 已知边界

- 面向 **Windows + PowerShell**；API 调用部分跨平台，但脚本本身是 PS。
- 默认候选 IP 列表是写成参数的（`-UploadIps`），网络环境变了要自己更新。
- 只做 **Release 附件**，不处理 GitHub Packages / Actions artifacts。
- 网络不稳时大文件可能需要几分钟（降速重试的代价）。

## License

MIT
