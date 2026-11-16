# F-Droid Shizuku 版

上游 [F-Droid](https://gitlab.com/fdroid/fdroidclient) 客户端 + **一个补丁**：安装 APK 时不再走
系统自带的软件包安装器，而是通过 [Shizuku](https://github.com/RikkaApps/Shizuku) 以 shell 身份
调用系统的包管理服务。

适用场景：系统安装器被裁剪、被「优化」掉，或者装非商店应用时各种弹窗/拦截的 ROM
（部分国产 ROM、Android TV 盒子等）。

- 包名：`org.fdroid.fdroid.shizuku`（可与官方 F-Droid 共存）
- 无 Shizuku 时：**行为与上游完全一致**（自动回落）
- 除了安装入口，其余功能（仓库、搜索、下载、通知、历史……）都是上游原样

## 仓库结构

`master` = 上游 master + 下面这些**新增**文件，源码改动全部在 `patches/` 里：

```
patches/
  0001-shizuku-installer.patch    包名 + 安装实现 + 两个钩子 + manifest + 依赖
scripts/
  apply-patches.sh                应用补丁（CI 与本地都用它）
  inject-version.sh               注入 versionCode/versionName（时间戳，单调）
  inject-repo.sh                  把自建源写进 default_repos.json
  build-apk.sh                    构建 + zipalign + apksigner + 产物断言
  publish-repo.sh                 fdroidserver 生成索引并推 gh-pages
  gen-keys.sh                     一次性生成签名密钥
.github/workflows/
  sync-upstream.yml               每天合并上游
  build-release.yml               打补丁 → 构建 → 签名 → Release → 更新源
docs/shizuku-fork-plan.md         完整方案与设计说明
```

这样做的原因：上游永远不可能和我们「新增的文件」冲突，所以 `git merge upstream/master` 可以
无人值守；万一上游重构了安装相关代码，问题只会表现为**打补丁失败**，CI 直接红，定位明确。

## 它是怎么工作的

1. `AppInstallManager.downloadAndInstall()` 下载完 APK 后，先尝试
   `ShizukuInstaller.install()`（一行钩子）。Shizuku 不可用就返回 `null`，继续走上游逻辑。
2. Shizuku 绑定一个运行在 shell uid 的 `ShellInstallService`（user service），App 把 APK 的
   文件描述符通过 binder 交给它。
3. 服务把 APK 落到 `/data/local/tmp`，执行
   `cmd package install -r -i org.fdroid.fdroid.shizuku <apk>` —— 和 `adb install` 同一机制，
   不弹任何安装界面。
4. 另外在 `SessionInstallManager.requestPreapproval()` 里加了一行：Shizuku 可用时跳过
   Android 14+ 的预授权弹窗（有 shell 权限时它本来就是多余的）。

## 一次性配置

### 1. 准备仓库

把本仓库 fork 到你自己的 GitHub 账号，然后本地克隆。

### 2. 生成签名密钥

```bash
bash scripts/gen-keys.sh
```

会在 `keys/`（已 gitignore）生成：

- `keys/app.jks` —— APK 签名密钥，**弄丢就只能换包名重来**
- `keys/repo.jks` —— 软件源索引签名密钥，**弄丢用户需要重新添加仓库**
- `keys/secrets.env` —— 上面两个的 base64/口令，以及 `REPO_URL`、`REPO_CERT_HEX`

请把 `keys/` 目录离线备份（密码管理器、加密 U 盘都行）。

### 3. 配置 GitHub Secrets / Variables

```bash
set -a; . keys/secrets.env; set +a
gh secret set SIGNING_KEYSTORE_BASE64 --body "$SIGNING_KEYSTORE_BASE64"
gh secret set SIGNING_STORE_PASSWORD  --body "$SIGNING_STORE_PASSWORD"
gh secret set SIGNING_KEY_ALIAS       --body "$SIGNING_KEY_ALIAS"
gh secret set SIGNING_KEY_PASSWORD    --body "$SIGNING_KEY_PASSWORD"
gh secret set REPO_KEYSTORE_BASE64    --body "$REPO_KEYSTORE_BASE64"
gh secret set REPO_STORE_PASSWORD     --body "$REPO_STORE_PASSWORD"
gh secret set REPO_KEY_ALIAS          --body "$REPO_KEY_ALIAS"
gh secret set REPO_KEY_PASSWORD       --body "$REPO_KEY_PASSWORD"
gh variable set REPO_URL              --body "$REPO_URL"
gh variable set REPO_CERT_HEX         --body "$REPO_CERT_HEX"
```

`REPO_URL` 默认是 `https://<你的用户名>.github.io/<仓库名>/repo`，想改就改（例如加 CDN 域名）。

### 4. 打开 Actions 与 Pages

- Settings → Actions → General：确认允许 Actions（fork 的定时任务默认是关的）。
- Settings → Pages → Source 选 **Deploy from a branch**，分支 `gh-pages`，目录 `/ (root)`。
  第一次发布后该分支才会出现。

### 5. 手动跑一次

```bash
gh workflow run build-release.yml
```

成功后：Releases 里有 APK，`gh-pages` 里有 `index-v2.json` / `entry.json` / APK。

### 6. 手机上装第一个

1. 手机装好 Shizuku，用无线调试或 root 启动它；
2. 安装 Release 里的 APK（可以用 adb：`adb install fdroid-shizuku-<vc>.apk`）；
3. 打开 App，随便点一个应用安装 —— 首次会弹 Shizuku 授权，允许即可；
4. 之后所有安装/更新都静默完成，包括这个客户端自己的更新。

## 日常维护

- **上游同步**：每天 03:17（北京时间）自动 `git merge upstream/master` 并触发构建。
- **版本号**：`versionCode` = 构建时的 Unix 时间戳/60（和上游 nightly 同款），永远递增；
  `versionName` = `<上游版本>-shizuku`。
- **自更新**：客户端默认「仅 Wi-Fi 自动更新仓库 + 自动更新应用」，所以在 Wi-Fi 下会自动发现
  新版本并静默装好，装完会自己重启。

### 补丁打不上时

上游改动碰到了钩子所在的位置。本地修复流程：

```bash
git switch -c dev/shizuku origin/master
bash scripts/apply-patches.sh          # 会失败并留下 .rej / 冲突标记
# 手动解决，保证编译通过
git add -A && git commit -m "rebase patches onto $(git rev-parse --short origin/master)"
git diff origin/master..HEAD -- app gradle > patches/0001-shizuku-installer.patch
git switch master && git add patches && git commit -m "update patches"
```

小提示：钩子都带 `[SHIZUKU-PATCH]` 注释，`grep -rn "SHIZUKU-PATCH" .` 能找到全部改动点。

### 升级 Shizuku 依赖

`app/build.gradle.kts` 里的两个依赖版本（当前 `13.1.5`）由补丁钉住；升级时改补丁即可，
或者直接在 `dev/shizuku` 分支里改完重新生成补丁。

## 排查

```bash
adb logcat -s ShizukuInstaller ShizukuShellInstall
```

- `Could not bind Shizuku user service`：Shizuku 没在运行，或权限被撤销。
- `cmd package install failed (exit=...)`：把日志里的完整输出贴出来，多半是该 ROM 的
  `cmd` 参数差异。
- 安装能成功但界面停在「安装中」：Shizuku 服务进程被杀，重试一次即可。

## 许可

与上游一致，GPL-3.0-or-later。本仓库不包含、也不分发 F-Droid 官方签名或官方软件源的任何密钥。
