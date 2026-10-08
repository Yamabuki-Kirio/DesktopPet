# 53 - PetLife 接入 Git 并上传到 GitHub（公开仓库）操作指南

> 本文是给**人工执行**的操作手册。仓库本地文件（`.gitignore` / `.gitattributes` / `README.md`）已准备好，
> 但**所有 git 命令都没有被执行**，需要你自己按下面的顺序敲。
>
> 目标：把 `DesktopPet\petlife\` 作为一个 **Public** 仓库上传到 GitHub。

---

## 0. 结论速览

| 项目 | 结论 |
| --- | --- |
| 仓库根目录 | `C:\Users\Administrator\WorkBuddy\DesktopPet\petlife`（**不是** 上一层的 `DesktopPet`） |
| 预计提交内容 | **655 个文件，约 15.6 MB** |
| 被排除的内容 | 约 **3.6 GB** 构建产物 / APK / 运行时（详见 §3） |
| 机密 | `server/.env`、`server/*.db` 已被排除，**不会**上传 |
| GitHub 仓库名 | 建议 `petlife`（可改） |
| 可见性 | Public（公开） |

**注意：绝对不要在 `DesktopPet\` 目录里执行 `git init`。**
那一层放着 18 个 APK（每个约 180 MB）和 `Ace Attorney` 等无关内容，一旦作为仓库根，公开后无法收回。

---

## 1. 先建立心智模型：Git 的四个区域

```
工作区                 暂存区                本地仓库              远程仓库
(你的文件夹)           (index)              (.git)                (GitHub)
   │                     │                    │                     │
   │  git add -A         │                    │                     │
   ├────────────────────>│                    │                     │
   │                     │  git commit -m     │                     │
   │                     ├───────────────────>│                     │
   │                     │                    │   git push          │
   │                     │                    ├────────────────────>│
   │                     │                    │                     │
   │<────────────────────┴────────────────────┴─────────────────────┤
   │                        git pull / git clone                    │
```

- **工作区**：你平时编辑的 `petlife\` 文件夹。
- **暂存区**：`git add` 之后，准备写入「下一次提交」的改动清单。
- **本地仓库**：`petlife\.git\`，保存全部历史。**本机独有**，与 GitHub 无关。
- **远程仓库**：GitHub 上的那一份。`git push` 才把本地历史传上去。

关键认知：**`commit` 是本地操作，`push` 才是「上传到 GitHub」**。
所以即使推送失败或认证没配好，你的提交也不会丢，重新 `git push` 即可。

---

## 2. 已经为你准备好的三个文件

| 文件 | 作用 |
| --- | --- |
| `petlife\.gitignore` | **最关键**。声明哪些文件永不入库（构建产物、缓存、密钥、日志）。已重写，覆盖 `build_incr*`、`*.apk`、`server/.env` 等原先漏掉的规则。 |
| `petlife\.gitattributes` | 统一换行符策略（仓库内 LF），并把 `*.png/*.dll/*.exe/...` 标记为二进制，避免 Windows↔其他系统的换行符噪音。 |
| `petlife\README.md` | 公开仓库首页。原项目根目录**没有** README，这是新建的草稿，建议你按需修改。 |

此外，Flutter 脚手架自带的三个忽略文件也会生效（无需改动）：

| 文件 | 覆盖内容 |
| --- | --- |
| `android\.gitignore` | `gradlew`、`.gradle`、`local.properties`、`key.properties`、`*.jks`、`*.keystore` |
| `windows\.gitignore` | `flutter/ephemeral/`、`x64/`、`x86/`、VS 用户文件 |
| `server\.gitignore` | `.env`、`.python/`、`__pycache__/`、`*.db`、`.pytest_cache/` |

---

## 3. 会提交什么 / 不会提交什么（已实测验证）

下表是用 `git ls-files --exclude-standard` 在**不建立仓库**的情况下实测出来的结果。

### 会提交（655 文件 / 15.63 MB）

| 顶层条目 | 文件数 | 说明 |
| --- | ---: | --- |
| `lib/` | 226 | Flutter 源码 |
| `server/` | 113 | Python 后端源码（不含 `.env`、`.python/`、`*.db`） |
| `test/` | 99 | 测试 |
| `docs/` | 97 | 交付文档与证据 |
| `android/` | 82 | Android 工程（不含 `.gradle`、`local.properties`） |
| `windows/` | 18 | Windows 工程（不含 `ephemeral`） |
| `snapshots/` | 3 | 源码快照 zip（按你的选择保留） |
| `tools/` | 4 | 辅助脚本 |
| `.workbuddy/` | 4 | AI 工作记忆（按你的选择保留） |
| `assets/` | 2 | 托盘图标 |
| 根配置 | 7 | `pubspec.yaml`、**`pubspec.lock`**、`analysis_options.yaml`、`.metadata`、`.gitignore`、`.gitattributes`、`README.md` |

> 关于 `pubspec.lock`：原 `.gitignore` 忽略它，已**修正为提交**。
> 这是 Flutter 官方对 `project_type: app` 的建议——锁定可复现的依赖版本。

### 不会提交（约 3.6 GB）

| 被排除项 | 体积 | 命中规则 |
| --- | ---: | --- |
| `build/` | 2,235 MB | `/build/` |
| 17 个 `build_incr*` / `build_region_*` / `build_win_*` | 约 830 MB | `/build_*/` |
| 根目录 17 个 `*.apk` | 约 3,070 MB | `/*.apk` |
| `windows\flutter\ephemeral\` | 262 MB | `windows/.gitignore` |
| `.dart_tool\` | 311 MB | `.dart_tool/` |
| `server\.python\` | 130 MB | `server/.python/` |
| `petlife_win_regress_20260929_3\` | 59 MB | `/petlife_win_regress_*/` |
| `petlife-REGION-COORD-20261006.zip` | 14 MB | `/*.zip` |
| `.idea\`、`*.iml`、`android\.gradle\`、`android\local.properties` | — | 编辑器/Android |
| **`server\.env`**（机密） | — | `server/.env` |
| `server\petlife_server_dev.db` | — | `server/*.db` |
| `__pycache__/`、`.pytest_cache/` | — | Python |

---

## 4. 一次性配置（每台机器只做一次）

先打开终端。**推荐方式**：在资源管理器里进入
`C:\Users\Administrator\WorkBuddy\DesktopPet\petlife`，在地址栏输入 `powershell` 回车，
或右键空白处 →「在终端中打开」/「Open Git Bash here」。

配置提交者身份（会写进每一次提交记录，用你 GitHub 的用户名和邮箱）：

```
git config --global user.name 你的GitHub用户名
```

```
git config --global user.email 你的邮箱@example.com
```

> 若名字**含空格**，需要加引号：`git config --global user.name "Zhang San"`。
> 若引号在你的终端里会被吞掉，就换一个不含空格的名字。

让中文文件名正常显示（否则 `git status` 里会看到 `\346\226\207` 之类的乱码转义）：

```
git config --global core.quotepath false
```

检查是否配置成功：

```
git config --global --list
```

---

## 5. 步骤一：初始化本地仓库

**先确认当前目录正确**（必须能看到 `pubspec.yaml` 和 `lib`）：

```
cd C:\Users\Administrator\WorkBuddy\DesktopPet\petlife
```

```
pwd
```

`pwd` 应输出 `C:\Users\Administrator\WorkBuddy\DesktopPet\petlife`。
**如果输出的路径是 `...\DesktopPet`（没有 `\petlife`），立即停下**，回到 §0 的警告。

初始化仓库（`-b main` 直接把默认分支命名为 `main`，与 GitHub 默认一致）：

```
git init -b main
```

把文件加入暂存区：

```
git add -A
```

**这一步之后务必核对**（这是最关键的一次检查）：

```
git status
```

期望看到类似：

```
Changes to be committed:
        新文件:   <655 个文件>
```

**判定标准：**
- ✅ 文件数在 **600~700** 之间 → 正常，继续。
- ❌ 出现 `build_incrC2/`、`build/`、`*.apk`、`server/.env`、`.dart_tool/` 中的任何一项 → **停止**，说明 `.gitignore` 没生效；
- ❌ 文件数是几万 → 同上，**停止**。

> 若确实进错了文件，用 `git reset` 撤回暂存区，修正 `.gitignore` 后重新 `git add -A`。

确认无误后提交：

```
git commit -m "Initial commit: PetLife (Flutter desktop/mobile + server)"
```

> 提交信息**故意用英文 ASCII**，避免中文在 Windows 终端里被转成乱码。
> 若引号被终端吞掉导致命令不完整，可把消息改成单个词，例如 `git commit -m init`。

查看提交结果：

```
git log --oneline
```

---

## 6. 步骤二：在 GitHub 上建仓库

用浏览器登录 GitHub → 右上角 **+** → **New repository**：

| 字段 | 填什么 |
| --- | --- |
| Repository name | `petlife` |
| Description | 可选，例如 `Cross-platform desktop pet with screen-time tracking` |
| Visibility | **Public**（你已选择公开） |
| Add a README file | **不要勾选** |
| Add .gitignore | **不要选** |
| Choose a license | **不要选** |

> **为什么都不要勾？** 勾了任何一项，GitHub 会替你生成一个「初始提交」，
> 你的本地仓库和它就没有共同历史，`git push` 会被拒绝（`rejected — fetch first`），
> 需要额外做 `git pull --rebase` 才能合并，白绕一圈。
> 空仓库推送最顺。

点 **Create repository**。跳转后的页面会显示一段命令提示，忽略它，用下面 §7 的命令。

---

## 7. 步骤三：连接远程仓库并推送

把 `USERNAME` 换成你的 GitHub 用户名（注意：**不要带尖括号 `< >`**，终端会当成重定向符号）：

```
git remote add origin https://github.com/USERNAME/petlife.git
```

核对远程地址：

```
git remote -v
```

推送（`-u` 记住分支关联，以后只需 `git push`）：

```
git push -u origin main
```

### 首次推送的认证

Git for Windows 自带 **Git Credential Manager**，通常会自动弹出窗口，
点「Sign in with your browser」→ 浏览器里登录并授权即可，凭据会被 Windows 凭据管理器保存，
**以后不用再登录**。

如果没有弹窗、或提示认证失败：

1. 打开 https://github.com/settings/tokens → **Generate new token (classic)**；
2. 勾选 `repo` 权限，生成后**复制一次**（页面关掉就看不见了）；
3. 再次执行 `git push -u origin main`；
4. 用户名填 GitHub 用户名，**密码栏粘贴那个 Token**（不是账号密码）。

> 若账号开了双重验证（2FA），**必须**用 Token，账号密码一定失败。

---

## 8. 步骤四：核对上传结果

本地检查：

```
git status
```

期望输出 `nothing to commit, working tree clean`（若显示 `Untracked files` 里有构建目录，说明 `.gitignore` 需要补规则，但已被排除的内容不会因为这条提示而被上传）。

```
git log --oneline
```

```
git remote -v
```

浏览器检查（**重点**）：
1. 打开 `https://github.com/USERNAME/petlife`；
2. 首页文件列表里**不应**出现 `build_incrC2`、`build`、`*.apk`、`.dart_tool`；
3. 仓库右上角的 **Code** 按钮旁应显示约 `655 Files`；
4. 访问 `https://github.com/USERNAME/petlife/settings` → 底部 **Danger Zone** 确认可见性为 Public；
5. **务必访问 `https://github.com/USERNAME/petlife/tree/main/server`**，确认里面**没有** `.env`（只有 `.env.example`）。

---

## 9. 日常怎么用（以后每次改代码）

```bash
git status                     # 我改了什么
git add -A                     # 全部加入暂存区
git commit -m "说明这次改了什么"  # 生成一次提交
git push                       # 推送到 GitHub
```

查看历史：

```
git log --oneline --graph --all
```

查看某个文件的改动：

```
git diff
```

新建功能分支（推荐：改大功能时用，改完再合并回 main）：

```
git switch -c feature/wheel-c3
```

切回主分支：

```
git switch main
```

合并分支：

```
git merge feature/wheel-c3
```

从 GitHub 拉取别人/别处的改动：

```
git pull
```

撤销「工作区尚未 add」的某个文件改动：

```
git restore 路径\到\文件.dart
```

> ⚠️ `git restore` 会**丢弃**未提交的修改，且无法找回。用之前先想清楚。

---

## 10. 公开仓库的风险提示（请务必阅读）

你选择了 **Public（公开）**，意味着**任何人都能永久查看、下载、复制这份代码**。
上传前请确认以下几点：

1. **`docs\` 目录（97 个文件）会公开。** 里面是内部交付说明与测试证据，
   可能包含**本机绝对路径**（如 `C:\Users\Administrator\...`）、内部设计取舍记录、
   以及尚未发布的功能计划。如果这些不想公开，有两个选择：
   - 把仓库改成 **Private**（Settings → Danger Zone → Change visibility）；
   - 或在 `.gitignore` 里加一行 `docs/`（并在提交前执行 `git rm -r --cached docs`）。
2. **`.workbuddy/memory/`（4 个文件）是 AI 协作工作日志**，同样会公开。
   如不愿公开，在 `.gitignore` 里加 `.workbuddy/`。
3. **`snapshots/*.zip`（3 个，约 5 MB）是源码快照**，会让仓库体积随时间增长。
4. **`server/.env` 已被排除**，已实测确认不会上传；但**不要**用 `git add -f` 强行添加它。
5. **一旦推送，即使之后删除文件，它仍可能存在于提交历史中**，
   别人可以通过历史记录找回。彻底清除需要重写历史（`git filter-repo`），比较麻烦。
   所以：**确认无误再 push**。
6. 本项目**当前没有 LICENSE**。公开但无许可证 = 别人没有合法使用权，
   建议补一个（如 MIT）。你可以在 GitHub 建仓时补，也可以之后手动加 `LICENSE` 文件。

---

## 11. 常见问题排查

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| `git status` 列出几万个文件 | `.gitignore` 没生效，或目录选错 | 确认在 `petlife` 目录；确认 `.gitignore` 存在 |
| 已被忽略的文件还是被提交了 | 它在此前已被追踪，`.gitignore` 只对未追踪文件生效 | `git rm -r --cached 路径` 后再提交 |
| `push` 报 `rejected — fetch first` | GitHub 上有你本地没有的提交（建仓时勾了 README） | `git pull --rebase origin main` 后再 `git push` |
| `push` 报 `403` / 认证失败 | 用了账号密码，或 Token 权限不足 | 改用 Token（勾 `repo`）或让浏览器授权弹窗重来 |
| `remote origin already exists` | 之前加过 | `git remote set-url origin 新地址` |
| 文件名显示成 `\346\226\207` | `core.quotepath` 未关 | `git config --global core.quotepath false` |
| 所有文件都显示被修改（但你没改） | 换行符问题 | `git config --global core.autocrlf true` |
| 想改成私有 | — | GitHub 仓库 Settings → Danger Zone → Change visibility |
| 提交后发现漏了文件 | — | `git add -A` → `git commit -m "补充"` → `git push` |

---

## 12. 如果你想换一种做法

以下调整我都可以代做，说一声即可：

- **换仓库根**：把 `petlife` 和 `server` 拆成两个仓库（Flutter 端 / 后端各一个）。
- **换可见性**：改为 Private 并把 `docs/`、`.workbuddy/` 排除。
- **补 `LICENSE`**：加一份 MIT / Apache-2.0。
- **补 CI**：加 `.github/workflows/` 跑 `flutter analyze` + `flutter test`。
- **去掉快照**：把 `snapshots/` 排除，改用 GitHub Releases 存放构建产物。

---

## 附：命令速查（从头到尾一次性照抄）

```
cd C:\Users\Administrator\WorkBuddy\DesktopPet\petlife
```

```
git config --global user.name 你的GitHub用户名
```

```
git config --global user.email 你的邮箱@example.com
```

```
git config --global core.quotepath false
```

```
git init -b main
```

```
git add -A
```

```
git status
```

```
git commit -m "Initial commit: PetLife (Flutter desktop/mobile + server)"
```

```
git remote add origin https://github.com/USERNAME/petlife.git
```

```
git push -u origin main
```

```
git log --oneline
```

> 粘进终端后、按回车之前，**先看一眼命令有没有被折成两行**。
