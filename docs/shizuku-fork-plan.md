# F-Droid 客户端「Shizuku 静默安装」改造 · 完整方案

> 目标：把 fdroidclient 改造成「即使系统包安装器被阉割，也能通过 Shizuku 正常安装 APK」的版本；
> 源码改动尽量小、与上游随时同步；GitHub Actions 自动同步上游 → 自动构建 → 自动发布 →
> 自带一个可自更新的软件源。
>
> **实现状态（已落地）**：仓库骨架、补丁集、CI 工作流与脚本均已提交到 `master`，并在本地完成
> 编译、签名与索引生成的验证。与下文方案的几处差异（均为简化）：
> - 源码补丁合并为 1 个：`patches/0001-shizuku-installer.patch`。
> - 自建源条目不在补丁里，改为构建时由 `scripts/inject-repo.sh` 注入（仓库地址与证书属于部署参数）。
> - 产物输出到 `build/dist/`（`build/` 已被上游 .gitignore 忽略，避免误提交）。
> - 新增依赖需要过 Gradle 依赖校验，补丁里加入 `<trust group="dev.rikka.shizuku"/>`。
> - 本地验证命令见 `README-SHIZUKU.md`。

> 基线：本仓库当前提交 `9dd8b2f94`（上游 master），版本 `2.0.3 (versionCode 2000053)`，
> Kotlin 2.4.21 / AGP 9.4.1 / Gradle 9.8.0 / compileSdk 37 / minSdk 24。

---

## 0. 结论先行（推荐路线）

| 决策点 | 选择 | 理由 |
| --- | --- | --- |
| 改动方式 | **补丁集（patch series）+ `git apply`**，源码改动不进 git 历史 | 上游 `master` 只有「新增文件」，git 层面几乎不可能冲突 |
| 改动规模 | 现有文件 **5 处共 ~28 行**，新增 2 个 Kotlin 文件（~330 行） | 钩子都落在唯一的安装汇聚点 |
| 安装机制 | **Shizuku UserService（shell uid）+ `cmd package install`**（先把 APK 暂存到 `/data/local/tmp`） | 不依赖隐藏 API、不依赖 Android 版本细节、代码量最小 |
| 包名 | `org.fdroid.fdroid.shizuku`（`full` flavor 后缀改为 `.fdroid.shizuku`） | 与官方 F-Droid 共存，避免签名冲突与仓库条目打架 |
| 版本号 | `versionCode = 当前时间戳/60`（上游 nightly 同款做法），`versionName = <上游>−shizuku` | 无状态、单调递增、不会回退 |
| 自更新源 | `fdroidserver` 生成 index-v2 → 推 `gh-pages` → 客户端 `default_repos.json` 预置该源并内置证书 | 一条命令生成合规索引（index-v2 + entry.json 签名） |
| 发布 | GitHub Release（APK、签名产物、更新说明）+ Pages（软件源） | 全免费、无额外账号 |

预期总改动：`app/build.gradle.kts` 1 行、`SessionInstallManager.kt` 1 行、`AppInstallManager.kt` 1 行、
`AndroidManifest.xml` 1 个 provider、`default_repos.json` 1 个条目，新增 `org/fdroid/install/shizuku/` 包与 CI 文件。

---

## 1. 现状梳理（决定「钩子」放哪）

当前安装主链路（全部在 `app/src/main/kotlin/org/fdroid/install/`）：

```
AppInstallManager.install()
  └─ startInstall()
       ├─ SessionInstallManager.requestPreapproval()   ← Android 14+ 预授权弹窗（国行 ROM 上已判定为 broken）
       └─ downloadAndInstall()
            ├─ 下载 APK 到 cacheDir（带进度）
            ├─ 状态置为 Installing
            ├─ if (isOldXiaomi) sessionInstallManager.installLegacy()
            └─ SessionInstallManager.install(sessionId, pkg, state, file)
                 └─ PackageInstaller.createSession → openWrite → commit(IntentSender)
```

关键事实：

1. **只有一个汇聚点**：所有安装（手动装、批量更新、自更新）都收敛到
   `AppInstallManager.downloadAndInstall()`（`AppInstallManager.kt:317` 附近）→
   `SessionInstallManager.install()`（`SessionInstallManager.kt:246`）。
2. **`requestPreapproval()` 是多余的一步**：有 Shizuku 时 shell 身份本身就有安装权，
   不需要 pre-approval，也不该弹窗（`SessionInstallManager.kt:120`）。
3. **2.0 已无 PrivilegedInstaller**：`Utils.kt:94` 只是给「从 privileged 扩展迁移」做了一次性判断，不影响安装。
4. **老小米分支会绕过 session**：`isOldXiaomi()` 为真时直接调 `installLegacy()`（发 `ACTION_INSTALL_PACKAGE`
   Intent）。我们的钩子必须放在它**前面**，否则 MIUI 设备用不上 Shizuku。
5. `default_repos.json` 是 assets 里的静态文件，首启时由 `RepoPreLoader` 写入数据库
   （字段：`name/address/mirrors/description/certificate/enabled`，`certificate` 是仓库签名证书的 **DER hex**）。
6. 应用自动更新默认 `OnlyWifi`（`SettingsConstants.kt:39`），仓库自动更新默认 `OnlyWifi` —— 自更新**不需要**改默认值。
7. `full` flavor 的 `applicationIdSuffix` 是 `.fdroid`（`app/build.gradle.kts:59`），即官方包名。

---

## 2. 总体架构

```
┌──────────────────────────── GitHub: aaa1115910/fdroidclient (fork) ────────────────────────────┐
│                                                                                               │
│  master  =  upstream(GitLab) master  +  仅新增文件：                                            │
│             patches/*.patch   .github/workflows/*   scripts/*   metadata/*   docs/*            │
│             （不含任何对上游源码的直接修改 → merge upstream 永远不冲突）                          │
│                                                                                               │
│  ┌──────────────┐   定时/手动     ┌──────────────────┐    push master    ┌──────────────────┐   │
│  │ sync-upstream│ ───────────────▶│ build-release     │ ────────────────▶ │ Release (APK)    │   │
│  │ (每日 merge)  │                 │ 1. git apply 补丁 │                   │ gh-pages (源)    │   │
│  └──────────────┘                 │ 2. 注入版本号     │                   └──────────────────┘   │
│                                   │ 3. 签名 & 构建    │                                          │
│                                   │ 4. fdroid update  │                                          │
│                                   └──────────────────┘                                          │
└───────────────────────────────────────────────────────────────────────────────────────────────┘
                                                    │
                        https://aaa1115910.github.io/fdroidclient/repo
                                                    │
                              ┌─────────────────────▼─────────────────────┐
                              │ 修改版 F-Droid (org.fdroid.fdroid.shizuku) │
                              │  · 预置自建源（内置证书指纹）               │
                              │  · 安装 APK → Shizuku → shell 静默安装      │
                              │  · 从自建源检查并自更新（同样走 Shizuku）   │
                              └───────────────────────────────────────────┘
```

---

## 3. 代码改造设计

### 3.1 改动清单

| # | 文件 | 改动 | 行数 |
| --- | --- | --- | --- |
| 1 | `app/build.gradle.kts` | `full` flavor：`applicationIdSuffix = ".fdroid"` → `".fdroid.shizuku"`；`dependencies` 加 2 行 Shizuku 依赖 | 3 |
| 2 | `app/src/main/AndroidManifest.xml` | `<application>` 内加 `ShizukuProvider`（4 行） | +5 |
| 3 | `.../install/SessionInstallManager.kt` | `requestPreapproval()` 首行：Shizuku 可用则直接 `PreApprovalResult.NotSupported` | 1 |
| 4 | `.../install/AppInstallManager.kt` | `downloadAndInstall()` 中、小米判断**之前**插入钩子：Shizuku 安装成功则直接返回 | 2 |
| 5 | `app/src/main/assets/default_repos.json` | 追加自建源条目（含证书 DER hex） | +8 |
| 6 | 新增 `.../install/shizuku/ShizukuInstaller.kt` | 权限申请、绑定 UserService、发起安装、结果映射 | ~140 |
| 7 | 新增 `.../install/shizuku/ShellInstallService.kt` | shell 身份执行 `cmd package install -S`，回传结果 | ~110 |
| 8 | 新增 `.../install/shizuku/ShizukuHook.kt` | 统一入口 `installWithShizukuOrNull(...)`，任何异常一律返回 null 回退 | ~60 |

> 所有对上游文件的修改都用 `// [SHIZUKU-PATCH]` 注释包起来，便于冲突时一眼定位。

### 3.2 为什么用「补丁集」而不是 rebase / merge 源码

| 方案 | 上游同步 | 冲突 | 评价 |
| --- | --- | --- | --- |
| fork 上直接改源码，定期 `git rebase upstream/master` | 要人盯着 | 每次上游动 `SessionInstallManager` 就冲突，且冲突上下文全是自己的改动 | 维护成本高 |
| fork 上直接改源码，`git merge` | 自动 | 同上，冲突更难解 | 不好 |
| **fork master 只放「新增文件」，源码改动做成 `patches/*.patch`，CI 里 `git apply --3way`** | `git merge upstream/master` 自动 | 几乎为零；补丁只在 **应用时**可能失败，失败即 CI 红，定位明确 | ✅ 推荐 |

配套约定：

- `master` 只允许出现「上游没有的文件」（`patches/`、`.github/`、`scripts/`、`metadata/`、`docs/`）。
  这样 `git merge upstream/master` 永远是干净的 merge commit，可无人值守。
- 补丁用 `git diff` 格式（不是 `format-patch`），CI 用 `git apply --3way`，冲突时留下 `.rej` 便于排查。
- 本地的 `dev/shizuku` 分支保留「已应用补丁」的完整代码，方便 IDE 调试；改完后重新 `git diff` 生成补丁。
- 补丁按关注点拆 3 个，冲突面最小：
  - `0001-build-application-id.patch`（包名）
  - `0002-shizuku-installer.patch`（安装实现 + 两个钩子 + manifest + 依赖）
  - `0003-default-repos.patch`（预置自建源）

生成补丁的日常流程：

```bash
git switch -c dev/shizuku origin/master
# ...改代码、调试验证...
git add -A && git commit -m "shizuku installer"
git diff origin/master..HEAD > ../patches/0002-shizuku-installer.patch   # 注意：以 master 为基线
# 回到 master，只提交 patches 目录
git switch master && cp ../patches/*.patch patches/ && git add patches && git commit -m "update patches"
```

### 3.3 Shizuku 安装实现

#### 3.3.1 方案对比

| 方案 | 代码量 | 依赖 | 风险 | 结论 |
| --- | --- | --- | --- | --- |
| A. `Shizuku.newProcess("pm install ...")` | ~30 行 | Shizuku 12.x | 新版 Shizuku 已不再提供该 API（以实际版本为准），且需把 APK 放 shell 可读路径 | 不可靠，仅作历史参考 |
| **B. UserService + `cmd package install -S`** | ~310 行 | Shizuku 13.x（`dev.rikka.shizuku:api` / `:provider`） | 依赖 `cmd package install` 在 ROM 上的行为 | ✅ 主选 |
| C. `ShizukuBinderWrapper` + 隐藏 API `IPackageInstaller` | ~400 行 + AIDL stub | 需维护 AOSP AIDL | 隐藏 API 随版本变化、跨 uid session 权限受限 | 备选，后续可选 |
| D. Dhizuku（DeviceOwner） | — | 需设备管理员，一次性绑定 | 场景不同（无法覆盖已激活设备） | 不适用 |

选 B 的核心理由：**不做隐藏 API 反射、不要求 APK 落到 shell 可读目录**。App 把 APK 的
`ParcelFileDescriptor` 通过 binder 传给 shell 进程，shell 进程用 `cmd package install -S <size>`
从 stdin 读入并提交会话 —— 这正是 `adb install` 的机制，且 shell 有 `INSTALL_PACKAGES`，
不会弹任何安装界面（正好绕开被阉割的安装器）。

#### 3.3.2 时序

```
F-Droid UI
   │ install(pkg, version)
   ▼
AppInstallManager.startInstall
   ├─ requestPreapproval ──[Shizuku 可用]──▶ NotSupported（跳过，不弹窗）
   ├─ 下载 APK → cacheDir（保留上游进度 UI）
   ├─ 状态 = Installing
   └─ [SHIZUKU 钩子] ShizukuInstaller.install(state, file)      ← 小米分支之前
          │
          │ ① Shizuku.pingBinder() / checkSelfPermission()
          │ ② 未授权 → Shizuku.requestPermission()（仅前台）+ 等待回调（90s 超时）
          │ ③ Shizuku.bindUserService() → IBinder
          ▼
     ShellInstallService（shell uid=2000，Shizuku 拉起）
          │ ④ 收到 ParcelFileDescriptor(apk) + size + installerPackage + userId
          │ ⑤ ProcessBuilder("cmd","package","install","-S",size,"-r","-i",pkg,"--user",uid)
          │ ⑥ 把 fd 内容 copy 到子进程 stdin，读 stdout/stderr，waitFor
          ▼
     系统 PackageInstaller（无 UI、无 pre-approval、无「未知来源」弹窗）
          │ exit 0 / stdout 含 "Success"
          ▼
     返回 InstallState.Installed → UI 更新、历史记录、通知
```

#### 3.3.3 代码骨架（新增，自包含）

`app/src/main/kotlin/org/fdroid/install/shizuku/ShizukuInstaller.kt`

```kotlin
package org.fdroid.install.shizuku

/**
 * [SHIZUKU-PATCH] 通过 Shizuku 静默安装 APK。
 * 任何一步失败（未安装/未授权/未运行/命令执行失败）都返回 null，
 * 调用方回退到上游原有安装逻辑，保证行为不变。
 */
class ShizukuInstaller private constructor(private val context: Context) {

  companion object {
    private const val REQUEST_CODE = 0x5A17
    private const val TIMEOUT_MS = 90_000L

    @Volatile private var instance: ShizukuInstaller? = null
    fun get(context: Context): ShizukuInstaller =
      instance ?: synchronized(this) {
        instance ?: ShizukuInstaller(context.applicationContext).also { instance = it }
      }

    /** Shizuku 在运行（binder 活着）且版本 >= 11 */
    fun isRunning(): Boolean = runCatching {
      Shizuku.pingBinder() && !Shizuku.isPreV11()
    }.getOrDefault(false)
  }

  /** 未授权时请求授权；只有 App 在前台才可能弹 Shizuku 的授权页 */
  private suspend fun ensurePermission(): Boolean {
    if (!isRunning()) return false
    if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) return true
    if (!context.isAppInForeground()) return false
    return withTimeoutOrNull(TIMEOUT_MS) {
      suspendCancellableCoroutine { cont ->
        val listener = Shizuku.OnRequestPermissionResultListener { _, result ->
          Shizuku.removeRequestPermissionResultListener(this)
          if (cont.isActive) cont.resume(result == PackageManager.PERMISSION_GRANTED)
        }
        Shizuku.addRequestPermissionResultListener(listener)
        cont.invokeOnCancellation { Shizuku.removeRequestPermissionResultListener(listener) }
        Shizuku.requestPermission(REQUEST_CODE)
      }
    } ?: false
  }

  private suspend fun bindService(): IBinder? = withTimeoutOrNull(15_000) {
    suspendCancellableCoroutine { cont ->
      val conn = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
          if (cont.isActive) cont.resume(service)
        }
        override fun onServiceDisconnected(name: ComponentName?) = Unit
      }
      val args = Shizuku.UserServiceArgs(
        ComponentName(context.packageName, ShellInstallService::class.java.name)
      ).daemon(false).processNameSuffix("install").debuggable(false).version(1)
      Shizuku.bindUserService(args, conn)
      cont.invokeOnCancellation { Shizuku.unbindUserService(args, conn, true) }
    }
  }

  /** 返回 null 表示「Shizuku 这条路走不通」，调用方回退上游逻辑 */
  suspend fun install(state: InstallState.Installing, apkFile: File): InstallState? {
    if (!ensurePermission()) return null
    val binder = bindService() ?: return null
    return try {
      val userId = context.user?.identifier ?: 0   // API 24+；work profile 也正确
      ParcelFileDescriptor.open(apkFile, ParcelFileDescriptor.MODE_READ_ONLY).use { pfd ->
        val result = ShellInstallService.install(
          binder = binder,
          apk = pfd,
          size = apkFile.length(),
          installerPackage = context.packageName,
          userId = userId,
        )
        if (result.success) {
          InstallState.Installed(
            name = state.name,
            versionName = state.versionName,
            currentVersionName = state.currentVersionName,
            lastUpdated = state.lastUpdated,
            iconModel = state.iconModel,
          )
        } else {
          InstallState.Error(result.message ?: "Shizuku install failed", state)
        }
      }
    } catch (e: Exception) {
      log.warn(e) { "Shizuku install failed, falling back" }
      null   // 回退系统安装器，而不是让安装直接失败
    }
  }
}
```

`.../shizuku/ShellInstallService.kt`（运行在 shell uid 的 UserService）

```kotlin
package org.fdroid.install.shizuku

/**
 * [SHIZUKU-PATCH] 由 Shizuku 以 shell 身份拉起。
 * 只做一件事：把 App 传来的 APK fd 喂给 `cmd package install -S`。
 */
class ShellInstallService : IShizukuService.Stub() {

  companion object {
    const val DESCRIPTOR = "org.fdroid.install.shizuku.IShellInstall"
    const val TRANSACTION_INSTALL = 0x00FD_0001   // 远高于 IShizukuService 自身事务号，避免冲突

    /** App 侧调用；同步阻塞，调用方放在 IO 线程/协程里 */
    fun install(binder: IBinder, apk: ParcelFileDescriptor, size: Long,
                installerPackage: String, userId: Int): Result {
      val data = Parcel.obtain()
      val reply = Parcel.obtain()
      return try {
        data.writeInterfaceToken(DESCRIPTOR)
        data.writeFileDescriptor(apk.fileDescriptor)
        data.writeLong(size)
        data.writeString(installerPackage)
        data.writeInt(userId)
        binder.transact(TRANSACTION_INSTALL, data, reply, 0)
        reply.readException()
        Result(reply.readInt() == 1, reply.readString())
      } finally {
        data.recycle(); reply.recycle()
      }
    }
  }

  override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
    if (code != TRANSACTION_INSTALL) return super.onTransact(code, data, reply, flags)
    data.enforceInterface(DESCRIPTOR)
    val fd = data.readFileDescriptor() ?: return fail(reply, "no fd")
    val size = data.readLong()
    val installer = data.readString().orEmpty()
    val userId = data.readInt()

    val cmd = mutableListOf(
      "cmd", "package", "install", "-S", size.toString(), "-r", "-i", installer,
    ).apply { if (userId >= 0) addAll(listOf("--user", userId.toString())) }

    val process = ProcessBuilder(cmd).start()
    // 必须先并行读输出，避免子进程缓冲区写满导致死锁
    val stdout = thread { process.inputStream.bufferedReader().readText() }
    val stderr = thread { process.errorStream.bufferedReader().readText() }
    FileInputStream(fd.fileDescriptor).use { it.copyTo(process.outputStream) }
    process.outputStream.close()
    val exit = process.waitFor()
    val out = stdout.join().trim()
    val err = stderr.join().trim()
    val ok = exit == 0 && out.contains("Success", ignoreCase = true)
    // 兼容个别 ROM：失败时再试一次「落 /data/local/tmp 再 install <path>」
    return finish(reply, ok, if (ok) null else "exit=$exit out=$out err=$err")
  }
}
```

> 细节提醒：
> - `cmd package install` 若某些 ROM 不支持 `-S`，服务内改为：把 fd 写到
>   `/data/local/tmp/fdroid-install.apk`（shell 可写），再 `cmd package install -r <path>`，最后删除。
> - 多用户：传 `--user <当前用户>`；部分 ROM 需要 `--user 0`，作为兜底参数。
> - 单 APK 即可：F-Droid 索引里一个版本只有一个 APK，不存在 split 安装需求。

#### 3.3.4 两个钩子（只改这些）

`SessionInstallManager.kt`，`requestPreapproval()` 第一行：

```kotlin
  ): PreApprovalResult {
    // [SHIZUKU-PATCH] 有 Shizuku 时无需 pre-approval，避免多余的 session 与弹窗
    if (ShizukuInstaller.isRunning()) return PreApprovalResult.NotSupported
    return if (!context.isAppInForeground()) {
```

`AppInstallManager.kt`，`downloadAndInstall()` 中 `newState` 之后、小米判断之前：

```kotlin
    // [SHIZUKU-PATCH] 优先用 Shizuku 静默安装；不可用时返回 null，回退上游逻辑
    ShizukuInstaller.get(context).install(newState, file)?.let { return it }
```

（`install()` 内部任何异常都吞掉并返回 null，所以这里的回退是安全的，不会把可恢复的失败变成安装失败。）

#### 3.3.5 权限与降级行为

| 场景 | 行为 |
| --- | --- |
| Shizuku 未安装 | 钩子返回 null → 完全走上游逻辑（系统安装器） |
| Shizuku 已装但没运行 | 同上；不会打扰用户 |
| Shizuku 运行、未授权、App 在前台 | 弹 Shizuku 授权页，等待结果；授权后继续本次安装 |
| 同上但 App 在后台（批量更新） | 不弹窗，直接回退系统安装器（失败则 UI 显示错误） |
| 授权后命令失败（ROM 差异） | 返回 `InstallState.Error`，UI 展示 stderr 摘要，便于反馈 |
| 系统安装器被阉割且无 Shizuku | 与上游一样失败 —— 用户需先装 Shizuku |

> 建议后续版本在设置页加一个「安装方式：自动 / 仅 Shizuku / 仅系统」开关；
> MVP 不做 UI，以减少与上游的差异（自动探测已够用）。

### 3.4 包名与签名

- **包名**：`org.fdroid.fdroid.shizuku`。做法是只改 `full` flavor 的后缀（1 行），
  所以 `debug` 构建变 `org.fdroid.fdroid.shizuku.debug`，可与正式版共存。
- 为什么不复用 `org.fdroid.fdroid`：
  1. 与官方版签名不同，互相覆盖会安装失败，用户必须先卸载官方版；
  2. 官方仓库里已有同名 package，两个仓库条目会打架（签名校验、版本比较都不清晰）；
  3. 独立包名后，自建源里只有我们这一个 app，逻辑最干净。
- **签名**：自建 keystore（RSA 4096 / 10000 天），只放 GitHub Secrets，本地和备份离线保存。
  一旦丢失，所有用户只能卸载重装。

### 3.5 版本号策略

上游 `versionCode` 是「语义化编码」（2.0.3 → 2000053），不适合我们（同一上游版本可能构建多次）。

- `versionCode = $(date +%s) / 60`（与上游 nightly flavor 完全相同的思路）
  - 单调、无状态、无需在仓库里存计数器；重复构建同一分钟的概率可忽略（重跑会覆盖同一个 release 名，反而更好）。
  - 备选：`10_000_000 + GITHUB_RUN_NUMBER`（更可读，但仓库迁移/重建会重置）。
- `versionName = <上游 versionName> + "-shizuku"`，例如 `2.0.3-shizuku`。
- CI 用 `sed` 只替换 `defaultConfig` 里那两行（`grep -m1`），**不写进补丁**，
  这样上游改版本号不会让补丁失效；若格式变了，`sed` 后校验失败直接红。

```bash
VC_BASE=$(grep -m1 -oP 'versionCode = \K[0-9]+' app/build.gradle.kts)
VN_BASE=$(grep -m1 -oP 'versionName = "\K[^"]+' app/build.gradle.kts)
VC=$(( $(date +%s) / 60 )); VN="${VN_BASE}-shizuku"
sed -i "s/versionCode = $VC_BASE/versionCode = $VC/; s/versionName = \"$VN_BASE\"/versionName = \"$VN\"/" app/build.gradle.kts
grep -q "versionCode = $VC" app/build.gradle.kts || { echo "version injection failed"; exit 1; }
```

### 3.6 预置自建源

`app/src/main/assets/default_repos.json` 追加一条（保留官方源，用户仍能装普通应用）：

```json
{
  "name": "F-Droid Shizuku",
  "address": "https://aaa1115910.github.io/fdroidclient/repo",
  "description": "本仓库仅包含修改版 F-Droid 客户端（通过 Shizuku 静默安装），用于自更新。",
  "certificate": "<仓库签名证书 DER 的十六进制>",
  "enabled": true
}
```

`certificate` 必须是**仓库 index 签名证书**的 DER hex（和官方条目里那串 `3082...` 同格式），
生成方式见 §7。预置证书后，客户端首次连接即做指纹固定，不会 TOFU。

> 用户如果已经装过我们的旧版本：assets 只在首启写入，之后靠数据库里的仓库记录走，不受影响。

---

## 4. 仓库与分支模型

| 分支 | 内容 | 谁写 |
| --- | --- | --- |
| `master`（默认） | 上游 master + 仅新增文件（`patches/`、`.github/`、`scripts/`、`metadata/`、`docs/`） | 人 / 同步机器人 |
| `dev/shizuku` | 已应用补丁的完整代码，用于本地 IDE 调试与生成补丁 | 人（本地，可选推送） |

规则：

1. **禁止**在 `master` 上直接改上游源码（否则 merge 开始冲突）。
2. 上游同步 `git merge upstream/master`，因为我们的文件都是新增的，合并不会冲突。
3. 补丁更新走 PR，PR 里必须跑一遍 `scripts/apply-patches.sh` + `./gradlew assembleFullDefaultRelease`（CI 会在 push 后验证）。

目录：

```
.github/workflows/
  sync-upstream.yml
  build-release.yml
patches/
  0001-build-application-id.patch
  0002-shizuku-installer.patch
  0003-default-repos.patch
scripts/
  apply-patches.sh
  inject-version.sh
  build-apk.sh          # 构建 + zipalign + apksigner + 校验
  publish-repo.sh       # fdroidserver 生成索引并推 gh-pages
metadata/
  org.fdroid.fdroid.shizuku.yml
docs/
  shizuku-fork-plan.md
```

`scripts/apply-patches.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
for p in patches/*.patch; do
  echo "==> applying $p"
  git apply --3way --whitespace=nowarn "$p"
done
```

失败时 `git apply` 会留下 `.rej` 并以非 0 退出，CI 直接红，附带 `.rej` 内容。

---

## 5. GitHub Actions

### 5.1 `.github/workflows/sync-upstream.yml`

```yaml
name: sync-upstream
on:
  schedule: [{ cron: "0 19 * * *" }]      # 每日 03:00 (Asia/Shanghai)
  workflow_dispatch:
concurrency: { group: sync-upstream, cancel-in-progress: false }
permissions: { contents: write, issues: write }

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { ref: master, fetch-depth: 0 }
      - name: Merge upstream
        id: merge
        run: |
          git config user.name  "fdroid-shizuku-bot"
          git config user.email "bot@users.noreply.github.com"
          git remote add upstream https://gitlab.com/fdroid/fdroidclient.git || true
          git fetch --no-tags upstream master
          if git merge-base --is-ancestor FETCH_HEAD HEAD; then
            echo "changed=false" >> "$GITHUB_OUTPUT"; exit 0
          fi
          git merge --no-edit FETCH_HEAD
          echo "changed=true" >> "$GITHUB_OUTPUT"
          echo "sha=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"
      - name: Push
        if: steps.merge.outputs.changed == 'true'
        run: git push origin master
      - name: Report conflict
        if: failure()
        uses: actions/github-script@v7
        with:
          script: |
            await github.rest.issues.create({
              owner: context.repo.owner, repo: context.repo.repo,
              title: `上游同步冲突 ${new Date().toISOString().slice(0,10)}`,
              body: '自动 merge 失败，请本地执行 `git fetch upstream && git merge upstream/master` 解决后推送。',
              labels: ['sync-conflict']
            })
```

> 注意：fork 仓库的 schedule 默认不启用，需要在仓库 Settings → Actions 里确认允许；
> 第一次也可以手动 `workflow_dispatch`。

### 5.2 `.github/workflows/build-release.yml`

```yaml
name: build-release
on:
  push: { branches: [master] }
  workflow_dispatch:
concurrency: { group: build-release, cancel-in-progress: false }
permissions:
  contents: write          # Release + 推 gh-pages
  pages: write

jobs:
  build:
    runs-on: ubuntu-latest
    env:
      ANDROID_HOME: /usr/local/lib/android/sdk
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }          # git apply --3way 需要完整历史

      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: '21' }

      - uses: gradle/actions/setup-gradle@v4

      - name: Install Android SDK 组件
        run: |
          yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null
          "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
            "platforms;android-37" "build-tools;37.0.0" "platform-tools"

      - name: Apply patches
        run: bash scripts/apply-patches.sh

      - name: Inject version
        id: ver
        run: bash scripts/inject-version.sh >> "$GITHUB_OUTPUT"

      - name: Build
        run: |
          ./gradlew --no-daemon -Dorg.gradle.jvmargs=-Xmx4g \
            assembleFullDefaultRelease

      - name: Sign
        env:
          KS_B64: ${{ secrets.SIGNING_KEYSTORE_BASE64 }}
          KS_PASS: ${{ secrets.SIGNING_STORE_PASSWORD }}
          KEY_ALIAS: ${{ secrets.SIGNING_KEY_ALIAS }}
          KEY_PASS: ${{ secrets.SIGNING_KEY_PASSWORD }}
        run: |
          echo "$KS_B64" | base64 -d > "$RUNNER_TEMP/app.jks"
          UNSIGNED=$(find app/build/outputs/apk/fullDefault/release -name '*.apk' | head -1)
          "$ANDROID_HOME/build-tools/37.0.0/zipalign" -p -f 4 "$UNSIGNED" aligned.apk
          "$ANDROID_HOME/build-tools/37.0.0/apksigner" sign \
            --ks "$RUNNER_TEMP/app.jks" --ks-pass "pass:$KS_PASS" \
            --ks-key-alias "$KEY_ALIAS" --key-pass "pass:$KEY_PASS" \
            --out fdroid-shizuku-${{ steps.ver.outputs.version_code }}.apk aligned.apk
          "$ANDROID_HOME/build-tools/37.0.0/apksigner" verify --print-certs fdroid-shizuku-*.apk
          "$ANDROID_HOME/build-tools/37.0.0/aapt2" dump badging fdroid-shizuku-*.apk | head -3

      - name: Release
        env: { GH_TOKEN: "${{ secrets.GITHUB_TOKEN }}" }
        run: |
          gh release create "${{ steps.ver.outputs.tag }}" fdroid-shizuku-*.apk \
            --title "${{ steps.ver.outputs.version_name }}" \
            --notes-file "${{ steps.ver.outputs.notes }}"

      - name: Publish F-Droid repo
        env:
          REPO_KS_B64: ${{ secrets.REPO_KEYSTORE_BASE64 }}
          REPO_KS_PASS: ${{ secrets.REPO_STORE_PASSWORD }}
          REPO_KEY_ALIAS: ${{ secrets.REPO_KEY_ALIAS }}
          REPO_KEY_PASS: ${{ secrets.REPO_KEY_PASSWORD }}
          TAG: ${{ steps.ver.outputs.tag }}
        run: bash scripts/publish-repo.sh
```

要点：

- 构建完成后用 `apksigner verify` + `aapt2 dump badging` 做**产物断言**（包名、versionCode），
  防止某次补丁/注入出错发布出错误包。
- 失败即停，不会发布半个版本。
- `gh-pages` 推送用内置 `GITHUB_TOKEN`（`contents: write`）足够。

### 5.3 Secrets 清单

| Secret | 说明 |
| --- | --- |
| `SIGNING_KEYSTORE_BASE64` | App 签名 keystore（base64），**永久不变** |
| `SIGNING_STORE_PASSWORD` / `SIGNING_KEY_ALIAS` / `SIGNING_KEY_PASSWORD` | App 密钥口令 |
| `REPO_KEYSTORE_BASE64` | fdroidserver 仓库索引签名 keystore（base64） |
| `REPO_STORE_PASSWORD` / `REPO_KEY_ALIAS` / `REPO_KEY_PASSWORD` | 仓库密钥口令 |

---

## 6. 自建软件源（自更新用）

### 6.1 用 fdroidserver 生成索引

```bash
pipx install fdroidserver        # 或 pip install fdroidserver==2.x
mkdir -p fd/metadata && cd fd
base64 -d <<< "$REPO_KEYSTORE_BASE64" > keystore.jks

cat > config.yml <<EOF
repo_url: https://aaa1115910.github.io/fdroidclient/repo
repo_name: F-Droid Shizuku
repo_description: 修改版 F-Droid（Shizuku 静默安装）自更新源
repo_keyalias: $REPO_KEY_ALIAS
keystore: ./keystore.jks
keystorepass: $REPO_STORE_PASSWORD
keypass: $REPO_KEY_PASSWORD
make_current_version_link: false
archive_older: 3
EOF

cat > metadata/org.fdroid.fdroid.shizuku.yml <<EOF
Name: F-Droid (Shizuku)
Summary: F-Droid 客户端，通过 Shizuku 安装 APK
Description: 基于上游 F-Droid 客户端，增加通过 Shizuku 静默安装/更新 APK 的能力。
License: GPL-3.0-or-later
SourceCode: https://github.com/aaa1115910/fdroidclient
IssueTracker: https://github.com/aaa1115910/fdroidclient/issues
Categories: [System]
Binaries: https://github.com/aaa1115910/fdroidclient/releases/download/$TAG/fdroid-shizuku-$VC.apk
EOF

fdroid update --use-date-from-apk
```

生成结果（`fd/repo/`）：

```
index-v2.json        # 新客户端读这个（含 sha256）
entry.json           # 对 index-v2.json 的签名信封
index-v1.jar/.json   # 兼容旧客户端，保留无害
org.fdroid.fdroid.shizuku_<vc>.apk
icons/…
```

### 6.2 发布到 Pages

`scripts/publish-repo.sh` 做两件事：

```bash
git worktree add --orphan -b gh-pages-site gh-pages || git worktree add gh-pages
git -C gh-pages rm -rq . 2>/dev/null || true
cp -r fd/repo/. gh-pages/
cp fd/repo/index-v2.json fd/repo/entry.json gh-pages/
touch gh-pages/.nojekyll
git -C gh-pages add -A && git -C gh-pages commit -m "repo $TAG"
git -C gh-pages push origin gh-pages --force
```

仓库 Settings → Pages → Source: `gh-pages` / root。最终源地址：
`https://aaa1115910.github.io/fdroidclient/repo`。

> 想更稳：再加 Cloudflare Pages 或对象存储做**镜像**，把镜像地址写进仓库元数据的 `mirrors`
> （fdroidserver 支持），客户端会自动选可用源。国内直连 github.io 偶发不稳，这一步值得做。

### 6.3 自更新闭环

1. 客户端首启：`default_repos.json` 写入自建源（含证书指纹）→ 拉 `index-v2.json`。
2. 默认每 Wi-Fi 自动更新仓库索引（`RepoUpdateValues.OnlyWifi`），并检查应用更新
   （`AppUpdateValues.OnlyWifi`）。
3. 发现 `org.fdroid.fdroid.shizuku` 有新 `versionCode` → 更新列表出现 → 自动/手动更新
   → 下载新 APK → **同一 Shizuku 钩子**静默安装 → 系统替换自身 → `SelfUpdateReceiver` 重新拉起。
4. 全程无需系统安装器，无需「未知来源」授权。

---

## 7. 密钥管理（一次性）

三类密钥，全部离线备份：

```bash
# 1) App 签名密钥（务必永久保存）
keytool -genkeypair -v -keystore fdroid-shizuku-app.jks -alias app \
  -keyalg RSA -keysize 4096 -validity 10000 -storetype PKCS12 \
  -dname "CN=F-Droid Shizuku, O=personal"
base64 -w0 fdroid-shizuku-app.jks   # → SIGNING_KEYSTORE_BASE64

# 2) 仓库索引签名密钥
mkdir -p fd && cd fd
cat > config.yml <<'EOF'
repo_url: https://aaa1115910.github.io/fdroidclient/repo
repo_name: F-Droid Shizuku
repo_keyalias: repo
keystore: ./keystore.jks
keystorepass: <强口令>
keypass: <强口令>
EOF
fdroid update --create-key          # 生成 keystore.jks + 密钥
base64 -w0 keystore.jks             # → REPO_KEYSTORE_BASE64

# 3) 取证书 DER hex（填进 default_repos.json 的 certificate）
keytool -exportcert -keystore keystore.jks -alias repo -rfc \
  | openssl x509 -outform DER | xxd -p -c 100000
```

把 3 个 `.jks`、口令、以及证书 hex 存进密码管理器/离线介质。

---

## 8. 落地步骤（按顺序）

- [ ] **P0 仓库骨架**：建 `patches/ scripts/ metadata/ docs/`、`.github/workflows/`，写 `apply-patches.sh`、`inject-version.sh`。
- [ ] **P1 密钥**：生成 App 与仓库 keystore，写入 Secrets；把证书 hex 记下来。
- [ ] **P2 真机 spike（不写代码先验证命令）**：
      `adb shell cmd package install -S $(stat -c%s app.apk) -r -i test.pkg < app.apk`
      在目标机型确认 `Success`，并确认无 UI。再验证 Shizuku 传 fd 可行（可用最简 UserService demo）。
- [ ] **P3 写补丁**：包名 1 行 → Shizuku 包 3 个文件 + 2 个钩子 + manifest → 本地 `assembleFullDefaultRelease` 跑通，
      真机验证「装新应用 / 更新已有应用 / 更新自身 / 关闭 Shizuku 自动回退」。
- [ ] **P4 生成补丁**：`git diff origin/master..dev/shizuku` 拆成 3 个 `.patch` 提交到 `master`。
- [ ] **P5 CI**：跑通 `build-release`（先 `workflow_dispatch`），确认 Release 里 APK 的包名/版本/签名正确。
- [ ] **P6 源**：`publish-repo.sh` 推 gh-pages；用官方 F-Droid 客户端「添加仓库」验证索引合法（这一步能提前发现签名问题）。
- [ ] **P7 预置源补丁**：把源地址+证书 hex 写进 `default_repos.json`，重新构建发布第一个版本。
- [ ] **P8 自更新验证**：装 P3 版本 → 改点东西发新版 → 客户端内自动更新 → 确认走 Shizuku 且无需交互。
- [ ] **P9 定时同步**：开 `sync-upstream`，观察第一次上游合并 + 构建。

---

## 9. 验证矩阵

| 维度 | 用例 |
| --- | --- |
| Android 版本 | 8.0 / 10 / 12 / 14 / 16（至少覆盖 12、14、16） |
| ROM | 原生 / HyperOS(MIUI) / ColorOS / 类原生 TV 盒子（安装器被删） |
| Shizuku 状态 | 未安装 / 已装未运行 / 运行未授权 / 已授权 |
| 安装类型 | 新装 / 覆盖更新 / 降级（应失败并提示） / 安装自身 / 批量更新 |
| 前台后台 | App 前台点安装（可弹授权）/ 后台自动更新（不弹窗） |
| 断网/取消 | 下载取消、安装中取消、Shizuku 中途被杀 |
| 源 | 首次拉取索引、指纹不匹配（应拒绝）、索引更新、APK 下载校验 |

---

## 10. 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| 上游重构 `AppInstallManager`/`SessionInstallManager`，补丁打不上 | CI 红，暂停发布 | 钩子只有 3 行，定位快；`git apply --3way` + `.rej`；预留 30 分钟修复窗口 |
| `cmd package install -S` 在某 ROM 上不支持/行为异常 | 该机型安装失败 | 服务内二级兜底：写 `/data/local/tmp` 再 `install <path>`；错误原文回传 UI |
| 跨进程传 APK fd 被 SELinux 拦 | 安装失败 | 兜底：binder 分块传字节（512KB/次，服务端拼成临时文件）；属 spike 阶段必须验证项 |
| 自更新时进程被杀，状态丢失 | 更新后 App 重启 | 预期行为；下次启动 `InstalledAppsCache` 刷新即可 |
| GitHub Pages 国内访问不稳 | 更新慢/失败 | 加云厂商镜像并写入 `mirrors`；或换自定义域名+CDN |
| versionCode 回退 | 无法更新 | 时间戳方案天然单调；发布前断言 `apksigner`/`aapt2` 输出的 versionCode 大于上一个 release |
| 签名密钥丢失 | 只能换包名重来 | 离线双备份；Secrets 之外再存一份加密副本 |
| 上游许可/商标 | 合规 | 仓库公开（GPLv3 要求）；App 名改为「F-Droid (Shizuku)」避免冒充官方 |
| fork 的 schedule 被禁用 | 不同步 | 首次手动 dispatch；README 里写明开启步骤 |

---

## 11. 工作量估算

| 阶段 | 内容 | 预估 |
| --- | --- | --- |
| P0–P2 | 骨架、密钥、真机命令验证 | 0.5 天 |
| P3 | Shizuku 安装实现 + 真机调试 | 1–1.5 天 |
| P4–P5 | 补丁化 + CI 构建发布 | 0.5 天 |
| P6–P8 | 自建源 + 预置 + 自更新闭环 | 0.5 天 |
| 合计 | | **2.5–3 天**（首次），之后每次上游同步 ≈ 0 人工 |

后续可选增强（不影响最小改动原则）：

1. 设置页加「安装方式」开关与 Shizuku 授权状态显示（+~120 行，集中在 1 个 composable）。
2. 用隐藏 API `IPackageInstaller` 取代 shell 命令，获得 session 级进度与更精确的错误码。
3. CI 里对补丁应用做「上游新提交触碰了哪些钩子文件」的预警评论。
