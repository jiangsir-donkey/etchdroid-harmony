# 把鸿蒙版合入官方仓库（EtchDroid/EtchDroid）—— 可行性评估与作战方案

> 目标：让移植版成为**官方仓库的一部分**，从而让"使用 EtchDroid 名称"从
> 商标风险变成天经地义。

## 一、先说结论（诚实版）

| 方案 | 上游负担 | 我的接受概率估计 | 结论 |
| --- | --- | --- | --- |
| A. 作为子目录合入官方仓库（`harmonyos/`） | 高：多一套工具链、他无法测试、CI 不覆盖 | **低** | 提，但别指望 |
| B. 官方 README 加一行链接到你的独立仓库 | 极低：一行 Markdown | **高** | **首选，先谈这个** |

**为什么 A 很难**：合入之后，上游拿不到任何好处 —— AppGallery 的发布还是你、
构建还是你、用户还是鸿蒙用户，但他要为一个**自己没有设备、没有工具链、
CI 也测不了**的平台长期负责。官方仓库现状是纯 Android：Gradle 只 include
`:app`，CI 跑的是 `assembleFossDebug` + Appium/QEMU。ArkTS 那部分在他的流水线里
是一块盲区。

**方案 B 其实已经能解决你的大部分问题**：被官方 README 明确链接＝官方承认你的
移植版存在、且默认接受你用它做鸿蒙版。这比你去要一封授权信**更有力**，因为它
公开、有时间戳、且由他亲自书写。

> 所以：**A 和 B 一起谈，但把 B 作为主推**。这会让你的接受概率从两成左右
> 上升到六七成，而且同样是"官方认可"。

---

## 二、第一步不是提 PR（重要）

上游 `CONTRIBUTING.md` 明确要求：

> **Discuss Big Changes:** For significant features, open an issue first to
> ensure it aligns with project goals.

同时上游对垃圾 issue **零容忍**，模板里写着 "permanent ban from the
organization"。所以：

**先开一个 Feature Request issue**（不是 PR），把 A/B 两个方案一起摆出来让他选。
这既符合 CONTRIBUTING，也把"被拒绝"的成本降到最低 —— 被拒的是一次讨论，
不是一整个 PR。

> ⚠️ 好消息：你的请求**不在**他的禁止清单里（Windows ISO / DMG / 内置 SD 卡 /
> 多重启动），所以不会触发封禁条款。但**务必**如实勾选那两个确认框。

---

## 三、可直接粘贴的 issue 内容

入口：`https://github.com/EtchDroid/EtchDroid/issues/new?template=feature_request.yml`

**标题**

```
[Feature]: Support for publishing an unofficial HarmonyOS (OpenHarmony) port
```

**Scope Acknowledgment（两个都勾选，如实）**

- ✅ I confirm my request is NOT about Windows ISOs, macOS/DMG, Internal SD cards, or Multi-boot support.
- ✅ I have searched existing issues to see if this has already been requested.

**Describe the feature**

```
I wrote an unofficial port of EtchDroid to HarmonyOS (OpenHarmony / HarmonyOS
NEXT) in pure ArkTS, and I would like to know how you would prefer to handle it.
The port reuses no Android code; it reimplements the same core value: a
hand-written USB Mass Storage (SCSI Bulk-Only Transport) stack that writes
ISO / IMG images straight to the raw block device, plus the same three-screen
flow (pick image -> pick drive -> confirm -> write with verification).

Concretely, I am offering two options and I will do whichever you prefer:

  Option A - host it in this repository as a subdirectory, e.g. harmonyos/.
             I have already verified that it lives there without touching
             anything Gradle-related: settings.gradle.kts only includes :app,
             so nothing in your build or CI changes. The port builds with
             hvigor/DevEco, not Gradle.

  Option B - keep it in my own repository and add a single line to this
             README pointing to it, clearly marked as an unofficial,
             community-maintained port.

I would genuinely prefer whichever you find less burdensome. Option B costs you
one Markdown line and makes the project relationship unambiguous, which also
settles the naming question - the port currently uses "EtchDroid" in its name
and icon, and I do not want to do that without your agreement.
```

**Why is this feature needed?**

```
There is no equivalent raw-image writer on HarmonyOS. Phone and tablet users on
that platform currently have no way to make a bootable Linux USB drive.

From your side, the value is reach, not code: the port brings EtchDroid to a
platform you do not ship on, at zero maintenance cost to you if we go with
Option B.
```

**Alternatives considered**

```
1. Publishing it as a fully separate project with a different name and a
   different icon, never mentioning EtchDroid in user-visible text. This works
   legally but throws away the attribution, which I think is worse for you
   than the alternatives above.
2. Sending you a request for a written trademark permission letter, which felt
   heavier than just asking here first.

The port is GPLv3, preserves your copyright notices, publishes its complete
corresponding source, and requests no INTERNET permission (no telemetry, no
ads). It currently builds and runs; I have tested it on a HarmonyOS emulator
(the write path needs a real USB-OTG device, which I will test before release).
```

---

## 四、如果他说"放进 `harmonyos/`"：PR 已经准备好了

我做过一次**真实试合入并编译验证**（在 `/tmp` 里，没动你的工程）：

| 验证项 | 结果 |
| --- | --- |
| 放进 `EtchDroid/harmonyos/` 后能否编译 | ✅ `BUILD SUCCESSFUL` + `verify-app success`，产出 253 KB 已签名 HAP |
| 与上游文件是否冲突 | ✅ 顶层无同名目录，54 个文件全在 `harmonyos/` 下，零冲突 |
| 嵌套 `.gitignore` 是否仍生效 | ✅ `build/`、`dist/`、`entry/build/` 全部被正确忽略 |
| 是否会把构建产物/签名材料提交上去 | ✅ 无（已用 `git check-ignore -v` 逐条确认） |
| 是否影响上游 Gradle 构建 | ✅ 不影响（`settings.gradle.kts` 只 include `:app`） |

### 提交前要做的三件事

1. **删掉只对你个人有意义的文件**（不要塞进上游 PR）：
   - `harmonyos/docs/permission-evidence/` —— 你的私人存档
   - `harmonyos/docs/appgallery-release.md` —— 你的华为上架清单
   - `harmonyos/LICENSE` —— 与上游根目录 `LICENSE` 逐字节相同，保留一份即可
   （`NOTICE` 要留，那是 GPLv3 §5 要求的修改声明）
2. **`harmonyos/README.md` 顶部改成**：作者是你、非官方、不接受上游维护者支持。
3. **`SOURCE_REPO_URL`（`Index.ets:41`）**：若合入成功，指向
   `https://github.com/EtchDroid/EtchDroid/tree/main/harmonyos`。

### 分支与提交（遵守上游 CONTRIBUTING / AGENTS.md）

上游要求 **rebase-only、无 merge commit、原子提交、Conventional Commits**。
所以整块代码要拆成原子提交，而不是一个巨型 commit。

**首选做法：直接用现成脚本**（`docs/merge-into-upstream/apply.sh`），它已经按上述
要求完成全部工作，产出的 7 个提交是：

```
chore(harmonyos): add hvigor project scaffolding
feat(harmonyos): implement SCSI bulk-only transport mass storage stack
feat(harmonyos): add image writer UI, worker and background task
feat(harmonyos): add a Simplified Chinese localization
docs(harmonyos): document the port and its provenance
chore(harmonyos): ship the upstream app icon with the HarmonyOS port
docs(readme): mention the unofficial HarmonyOS port
```

```bash
git clone https://github.com/EtchDroid/EtchDroid.git /tmp/EtchDroid
cd /path/to/etchdroid-harmony/docs/merge-into-upstream
./apply.sh /tmp/EtchDroid          # 详细说明见同目录 README.md
cd /tmp/EtchDroid && git push -u origin harmonyos-port
```

**手工做法**（脚本不适用时）：按上面的顺序 `git add` 对应路径再逐个 `git commit`，
一次提交只做一件事；`README.md` 的改动单独一个 commit。

### 需要给上游 `README.md` 加的那行

在 "### Supported disk image types" 之后新增一节：

```markdown
### Other platforms

- **HarmonyOS / OpenHarmony:** an unofficial, community-maintained port written
  in ArkTS lives in [`harmonyos/`](harmonyos/). It is not built or tested by
  this repository's CI, and it is supported by its author, not by the EtchDroid
  maintainers.
```

若走方案 B，`[`harmonyos/`](harmonyos/)` 换成你的仓库地址，其余措辞不变。

### PR 描述模板

```markdown
Follow-up to #<issue-number>.

Adds the unofficial HarmonyOS port discussed there, as a self-contained
`harmonyos/` subdirectory.

**What this does not touch**
- No Gradle files: `settings.gradle.kts` still only includes `:app`.
- No Android sources, no resources, no CI workflows.
- No existing files except a short README section.

**Verification**
- [x] `cd harmonyos && ./build.sh all` completes with `BUILD SUCCESSFUL` and a
      HAP that passes `verify-app`.
- [x] `git status` in a trial merge shows no build output or signing material
      being tracked (nested `.gitignore` verified with `git check-ignore`).
- [x] App launches and the full pick-image -> pick-drive flow renders on a
      HarmonyOS emulator (API 21).
- [ ] Writing to a real USB drive on physical hardware - **not yet verified**,
      the emulator has no USB host service. I will confirm before anyone calls
      this releasable.

**Maintenance**
The port is maintained by me (@<your-github>). It has no effect on your build,
your releases, or your CI. If you would rather not carry a second toolchain in
this repository, say so and I will take option B instead - a README link to my
own repository - without any further discussion.
```

---

## 五、如果他说"不"（大概率结局之一）

不要争辩。直接回一句「明白，那我走独立仓库 + README 链接」然后**立刻执行**
`docs/upstream-permission-request-ready.md` 里的流程。你已经准备好的独立仓库
方案（见 README 第 8 节）可以无缝接上。

注意：**他拒绝"合入"不等于拒绝你使用名称**。这两件事要分开谈 —— 如果 A 被拒，
把话题收窄到"只要一封许可信"，成功率会更高。

---

## 六、现实提醒

- 上游是**个人维护的小项目**，回复可能很慢（几周），也可能不回复。别卡在这里
  不上架；可以先按独立仓库方案推进，把合入当作**长期优化**。
- 这套操作**需要联网**（clone 上游、提 issue、开 PR），我这边网络是隔离的，
  只能帮你把内容准备到"复制粘贴即可"的程度。
- 本文档是操作方案，不构成法律意见。
