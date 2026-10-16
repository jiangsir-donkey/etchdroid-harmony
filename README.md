# EtchDroid for HarmonyOS

把 [EtchDroid](https://github.com/EtchDroid/EtchDroid)（Android，Kotlin + Compose）
移植到鸿蒙（OpenHarmony / HarmonyOS NEXT）的纯 ArkTS 版本。

用手机通过 USB-OTG 给 U 盘 / SD 卡写入 **ISO / IMG / DMG 镜像**，做成 Linux、
Windows 或树莓派启动盘。核心链路是 **手写的 USB Mass Storage（SCSI Bulk-Only
Transport）协议栈**，直接对着裸块设备写入，不依赖内核挂载 —— 这也是 EtchDroid
的价值所在，移植后完全保留。

- 包名：`eu.depau.etchdroid.harmony`
- 版本：对齐上游 `2.1`（versionName `2.1.0`）
- 语言：100% ArkTS，无原生 C++、无三方 so
- 界面：内置英文 + 简体中文（跟随系统语言）
- 状态：`./build.sh all` 可编译出 **已签名并验签通过** 的 HAP
- 许可：GNU GPLv3（继承上游），详见 `LICENSE` 与 `NOTICE`

---

## 1. 构建

### 前置

- HarmonyOS Command Line Tools（本机为 `26.0.0.621`，SDK API 26）
  默认路径 `~/downloads/commandline-tools-linux-x64-*/command-line-tools`，
  可用环境变量覆盖：`HOS_CLI=/path/to/command-line-tools`
- `java`（签名工具依赖）、`python3`

### 命令

```bash
cd etchdroid-harmony
HVIGOR_USER_HOME=/tmp/etchdroid-hvigor-home ./build.sh all
```

| 子命令 | 作用 |
| --- | --- |
| `hap`  | 用 hvigor 产出未签名 HAP |
| `sign` | 用 SDK 自带 OpenHarmony 测试证书签名并 `verify-app` 验签 |
| `all`  | `hap` + `sign`（默认） |
| `clean`| 清理构建产物与 `/tmp` 镜像 |

产物：

```
entry/build/default/outputs/default/entry-default-unsigned.hap   # 未签名
dist/etchdroid-signed.hap                                        # 已签名（用于安装）
```

### 两个必须知道的坑

1. **`HVIGOR_USER_HOME` 必须设置。** 否则 hvigor 会尝试写 `~/.hvigor` 并从 npm
   拉取 wrapper，在受限环境里会直接失败。本机已把 pnpm 缓存预置到
   `/tmp/etchdroid-hvigor-home/wrapper`。
2. **工程路径不能含非 ASCII 字符。** 本工程目录是 `桌面`，hvigor 会报错，
   所以 `build.sh` 会先把源码 `tar` 镜像到 ASCII 路径
   `/tmp/etchdroid-harmony-hap/etchdroid-harmony` 再构建，产物再拷回 `dist/`。
   想换镜像目录用 `ETCHDROID_MIRROR=/some/ascii/dir`。

### 安装

```bash
hdc install dist/etchdroid-signed.hap
```

> 测试证书签名，仅用于真机调试安装（需设备打开调试/信任）。上架需换成正式
> 签名证书与 profile。

### 模拟器

鸿蒙模拟器（2in1 / PC 形态）**没有 USB 主机服务**：`usbManager.getDevices()`
不会报错，而是直接返回空列表。App 会正常启动，首页显示「USB is not available
on this device」提示，选完镜像后停在设备列表弹层 —— 这是预期行为，不是崩溃。

要真正写入 U 盘，必须用支持 USB-OTG 的真机（手机 / 平板）。

---

## 2. 三页 UI 与流程

| 页面 | 文件 | 对应上游 |
| --- | --- | --- |
| 首页 | `pages/Index.ets` | `ui/MainActivity.kt` |
| 确认页 | `pages/Confirm.ets` | `ui/ConfirmOperationActivity.kt` |
| 进度页 | `pages/Progress.ets` | `ui/ProgressActivity.kt` |

流程：**选镜像 → 选 U 盘 → 确认并授权 USB 访问 → 写入 → 全量校验**。

- 首页：系统文件选择器挑镜像（按后缀过滤）；若只有 1 个可写驱动器则自动选择；
  检测到 Windows ISO 会弹提示；内置「支持范围」与「设置」底部弹层
  （主题 / 动态取色 / 关于）。
- 确认页：镜像卡片 + 目标设备卡片；`usbManager.requestRight` 申请 USB 权限；
  「平放手机」防误触提醒；开始写入。
- 进度页：百分比 / 速度 / 已写字节、来源→目标、可跳过校验；成功页
  （支持项目 / Star / 已写入其它镜像）、致命错误页（提 issue / 重试 / 重新开始）。
  还会处理「写入中 U 盘掉线」的重连轮询。

---

## 3. Android → HarmonyOS 映射

| Android / Kotlin | HarmonyOS / ArkTS | 说明 |
| --- | --- | --- |
| `libaums`（USB Mass Storage 库） | `massstorage/` 手写 SCSI BOT 栈 | `Scsi` 组包/解析、`BulkOnlyTransport` CBW/CSW、`ScsiBlockDevice`、`BlockDevice{Input,Output}Stream` |
| `UsbManager`（Java） | `@ohos.usbManager` | host 模式，`getDevices` / `requestRight` / `bulkTransfer` / `usbControlTransfer` |
| 协程 + `Channel` 预读 | `utils/AsyncQueue.ets` | 有界 promise FIFO，读侧预取；写侧用 promise 链 + 在途计数限流 |
| `WakeLock` | `backgroundTaskManager` DATA_TRANSFER 长时任务 | `service/Notifications.ets` 申请/释放 |
| `BroadcastReceiver` + `Intent` 广播进度 | `service/JobStore.ets` 单例 | 进程内共享最新 `JobStatus`；比上游更好：中途进入页面也能看到真实进度 |
| `SharedPreferences` | `@ohos.data.preferences` | `AppSettings.ets`（`getPreferencesSync`） |
| `Intent` 跳转 | `router.replaceUrl` / `getUIContext().getRouter()` | |
| `NotificationCompat` 进度通知 | `@ohos.notificationManager` | 文本型通知 + `WantAgent` 回跳 |
| `ContentResolver` 打开 uri | `@ohos.file.picker` + `@ohos.file.fs` | `DocumentViewPicker` 选镜像；`ImageSource` 用 `openSync/read/lseek` 做可 seek 读 |
| Compose UI | ArkUI 声明式 | 主题在 `ui/Theme.ets` |
| `EtchDroidException.getUiMessage(Context)` | 异常携带 `uiMessageRes` + `uiMessageParams` | 通过 `utils/Resources.ets` 的 `stringByName()` 延迟解析 |
| 资源 `strings.xml`（134 条） | `resources/base/element/string.json`（144 条） | 多出的 10 条是鸿蒙侧新增文案（后台运行原因、通知开关、USB 不可用提示等） |
| `values-zh-rCN/strings.xml`（133 条） | `resources/zh_CN/element/string.json`（144 条） | 中文译文与上游官方中文逐条对齐；`zh_CN` 与 `base` 的 key 集合完全一致，随系统语言自动切换 |

### 关键参数（保持与上游一致）

```
BUFFER_BLOCKS = 4096          # 一次 I/O 的块数
QUEUE_SIZE    = 2             # 在途写请求上限
IO_TIMEOUT    = 10s           # 单次 I/O watchdog
进度刷新      = 1s
校验静默超时  = 11s           # 超时判定任务已死（LAST_NOTIFICATION_TIMEOUT）
重连静默      = 3s            # 掉线后探测重新插入的等待
断点续写回退  = 回退 BUFFER_BLOCKS*2 个块重写（上次失败可能写坏尾部块）
```

---

## 4. 已知限制与差异

- **单线程异步**：ArkTS 没有真线程，全部 I/O 走异步；不阻塞 UI，但没有上游那种
  「后台线程池」概念。
- **`bulkTransfer` 单次 ≤ 200 KB 限制**：鸿蒙侧对单次 bulk 传输有长度上限，
  因此所有 bulk 传输按 `MAX_TRANSFER_CHUNK = 64 KiB` 分片（`BulkOnlyTransport`）。
  逻辑上等价，只是多了一层切分。
- **保留 2 TB 上限**：块数按 32 位处理，512 B/块时 2^32 块 = 2 TB 封顶；
  超出会抛 `UsbDriveTooLargeException`（`ScsiBlockDevice.MAX_SUPPORTED_BLOCKS`）。
- **通知为文本型**：系统 live-view 通知内容类型仅系统代理可用，因此进度用文本
  通知呈现，而不是上游那种带进度条的系统通知。
- **已移除的平台绑定功能**：Sentry 上报、遥测、Google Play 评价/更新插件全部
  去掉（鸿蒙没有对应生态，也避免隐私问题）。
- **USB 热插拔靠轮询**：`utils/DeviceWatcher.ets` 每 1.5 s 轮询并按设备 key 去重。
  未用 `commonEventManager`，因为 USB 设备插拔事件是系统级事件，普通应用订阅受限。
- **校验失败「重试」仍保留**：与上游行为一致（校验失败后可重试）。
- **无 USB 主机服务时会优雅降级**：枚举失败不再让首页崩溃，而是标记
  `usbAvailable = false` 并提示用户（模拟器就属于这种情况）。

---

## 5. 目录结构

```
etchdroid-harmony/
├── build.sh                     # 构建/签名脚本（含 /tmp ASCII 镜像逻辑）
├── LICENSE                      # GNU GPLv3（与上游一致）
├── NOTICE                       # 上游版权 + 本移植版本的修改声明
├── docs/                        # 上架合规材料
│   ├── appgallery-release.md    # 华为应用市场上架清单与风险点
│   ├── upstream-permission-request.md        # 申请渠道说明 + 函件模板
│   ├── upstream-permission-request-ready.md  # 可直接复制发送的版本（含无回复应对）
│   ├── upstream-contribution-plan.md         # 合入官方仓库的评估、issue/PR 文案
│   ├── permission-evidence/     # 授权证据存档（上架时的补充材料）
│   ├── merge-into-upstream/     # 一键合入官方仓库（apply.sh + 上游版 README/NOTICE）
│   └── privacy-policy.md        # 隐私政策（需替换占位并发布到公网）
├── design/                      # 图标留档（发行图标就是上游原始图标，未改动）
│   ├── upstream-icon-192.png    # 与上游 ic_launcher.png 逐字节一致（即发行图标）
│   ├── upstream-icon.svg        # 上游矢量图标（可追溯）
│   └── make_icon.py             # 可选备用：如需改名，用它生成带角标的差异化图标
├── build-profile.json5
├── AppScope/                    # 应用级配置与资源
├── entry/src/main/
│   ├── module.json5             # 权限：ohos.permission.KEEP_BACKGROUND_RUNNING
│   ├── resources/
│   │   ├── base/element/string.json      # 英文文案 144 条
│   │   ├── base/element/color.json
│   │   ├── base/profile/main_pages.json
│   │   ├── base/media/startIcon.png      # 上游原始图标
│   │   └── zh_CN/element/string.json     # 中文文案 144 条（对齐上游官方中文）
│   └── ets/
│       ├── entryability/EntryAbility.ets   # 初始化上下文/设置/JobStore/深色模式
│       ├── pages/{Index,Confirm,Progress}.ets
│       ├── service/WorkerService.ets       # 写入主流程（对齐上游 WorkerService.kt，792 行）
│       ├── service/{JobStore,Notifications,ImageSource}.ets
│       ├── massstorage/                    # SCSI BOT + 块设备（替代 libaums）
│       ├── utils/{AsyncQueue,Watchdog,DeviceWatcher,Resources,Format,Logger,AppContext,ErrorText}.ets
│       ├── exceptions/Exceptions.ets
│       ├── JobStatus.ets
│       ├── AppSettings.ets
│       └── ui/Theme.ets
└── dist/etchdroid-signed.hap    # 构建产物
```

---

## 6. 移植时踩到的 ArkTS 坑（供后续参考）

1. `BusinessError` 是纯类型，不能 `instanceof`，只能按 `error.code` 判断。
2. `arkts-limited-throw` 规则：`throw` 只能抛 `Error` 子类，统一用 `throw toError(e)`。
3. 自定义 struct 名不能与内置冲突（`Progress` → 改名 `ProgressPage`）。
4. **只有从入口页可达的 `.ets` 才会被类型检查**，孤立文件里的错误可能一直不报。
5. `NotificationRequest` 里字段名必须是 `notificationSlotType`（不是 `slotType`）。
6. 深色模式判断用 `getConfigurationSync().colorMode`，成员是
   `resourceManager.ColorMode.DARK/LIGHT`（不是 `ConfigurationConstant.ColorMode.*`）。
7. `router.*` 与 `promptAction.showToast` 已废弃，改用
   `this.getUIContext().getRouter()` / `.getPromptAction()`。
8. `@Builder` 方法 **不能接收函数类型参数**，需要拆成独立的 builder。
9. `getStringByNameSync(name, ...args)` 是变参，端口化的 `strings.xml` 用 `%s` 占位符。
10. **native 异常对象不能做字符串转换**：`String(err)` / `${err}` 会抛
    `TypeError: Cannot convert a illegal value to a String`。因为这是在 catch 里
    抛的，会直接逃出 catch 把整个 Ability 带崩。统一走
    `utils/ErrorText.ets` 的 `errorText()`，只读 `code` / `message` / `name` 原始字段。
11. `usbManager.getDevices()` 在**没有 USB 主机服务**时返回 `undefined` 而不是抛异常，
    直接 `for...of` 会崩。必须先判空（`scanMassStorageDevices()` 已处理），并且
    `device.configs` / `config.interfaces` 也要防 undefined。

---

## 7. 未验证项 / 后续可做

- **已在鸿蒙模拟器上验证**：App 可正常启动、渲染首页，选镜像 → 文件选择器 →
  设备弹层全流程无崩溃（模拟器无 USB 主机服务，写入路径无法在模拟器上验证）。
- **真机待回归**：编译与签名已验证，但「真正插上 U 盘写入」的端到端行为需要真机。
  建议真机测试：小镜像写入 → 校验通过；中途拔盘 → 重连续写；Windows ISO → 首页提示；
  校验失败 → 「重试」路径。
- 剩余 2 条编译告警（`BulkOnlyTransport.ets:169`、`BlockDeviceInputStream.ets:256`
  的 `may throw exceptions`），都是已被调用方包裹的 USB 调用，属提示性告警。
- 图标沿用**上游原始图标**：`AppScope/.../app_icon.png` 与
  `entry/.../startIcon.png` 与上游 `mipmap-xxxhdpi/ic_launcher.png` 逐字节一致
  （原图留档于 `design/upstream-icon-192.png`，矢量图 `design/upstream-icon.svg`）。
- **已支持中文**：`entry/src/main/resources/zh_CN/element/string.json`（144 条，
  译法对齐上游官方 `values-zh-rCN/strings.xml`）+ `AppScope/.../zh_CN/element/string.json`
  （`app_name`）。基础语言在 `resources/base`，两套 key 完全一致。

## 8. 上架与许可（重要）

本工程是 EtchDroid（GPLv3）的移植版本，属于 GPL 意义上的**修改版本**，因此：

- 必须以 **GPLv3** 分发，保留上游版权声明，并提供**对应源代码**（`LICENSE`、`NOTICE`）；
- **不能**抹掉署名、不能只发二进制、不能闭源；

### 名称与图标（当前采用「EtchDroid 鸿蒙版」，属有风险方案）

GPLv3 只授权代码，**不授予商标权**。`EtchDroid` 这个项目名与上游图标默认不在
授权范围内，叫「EtchDroid 鸿蒙版」会让用户与审核认为这是**官方**的鸿蒙版本。
当前采取的降险措施：

- 名称加「鸿蒙版」后缀；
- 图标**直接沿用上游原始图标**（不做任何改动）——本文档前几版曾叠加「鸿蒙」角标
  做差异化工件，现按需求改为原图，因此"外观可区分"这一层缓冲**不再存在**：
  除非拿到上游书面许可或已被官方仓库合入，否则更接近"看起来像官方版"；
- 因此上架前**务必先发许可申请**（`docs/upstream-permission-request-ready.md`），
  回复存档进 `docs/permission-evidence/`，作为市场审核补充材料；
- App 内「关于」页固定展示：非官方移植、与上游开发者无关联、未获背书；
- App 内提供本移植版本自己的 GPLv3 源码链接；
- 应用描述中标注「非官方移植，基于 GPLv3 开源项目 EtchDroid」。

**最有效的一步是拿到上游作者书面许可**：可直接复制发送的版本见
`docs/upstream-permission-request-ready.md`（渠道必须是 GitHub Discussions，
上游禁止发空白 Issue）；拿到回复后存进 `docs/permission-evidence/`，
作为审核补充材料一起提交。
拿不到许可时，改用不含 `EtchDroid` 的独立名称（如「鸿蒙写盘器」）＋自绘图标，
可基本消除商标风险。

包名 `eu.depau.etchdroid.harmony` 沿用了上游作者的反向域名。包名用户看不到、
也不是商标标识，但建议上架前改为自有域名（如 `com.<你的域名>.etchdroidharmony`）。

完整的个人开发者上架清单（软著、APP 备案、隐私政策、名称与图标、审核材料、
风险等级）见 **`docs/appgallery-release.md`**。

## 参考

- 上游源码：`../etchdroid-main/`（Kotlin，`app/src/main/java/eu/depau/etchdroid/`）
- 同类移植参考：`../ppsspp-harmony/`（签名流程与工程骨架参考）
