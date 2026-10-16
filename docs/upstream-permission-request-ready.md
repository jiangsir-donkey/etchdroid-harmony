# 许可申请 —— 可直接复制发送版

> 用法：打开 `https://github.com/EtchDroid/EtchDroid/discussions` →
> `New discussion` → 分类选 **General** → 标题和正文照下面复制。
> 发送前把 `<...>` 里的三处补上（只需 30 秒）。

## 你要补的三处

| 占位 | 填什么 | 现在知不知道 |
| --- | --- | --- |
| `<你的邮箱>` | 一个你常用的邮箱（**不要**用 git 里那个 `...@user.noreply.gitee.com`，那是免回复地址，收不到信） | ❓ 需你填 |
| `<你的公开仓库地址>` | 移植版源码的公开仓库。**必须先建好仓库并推上去**，否则 GPLv3 义务未满足、链接也是死链 | ❓ 需你建 |
| GitHub 用户名 | 建议与 Gitee 一致，方便对方核验 | 推断为 `ditney`，请确认 |

建议仓库名：`etchdroid-harmony`，即 `https://gitee.com/ditney/etchdroid-harmony`
（Gitee 支持 GitHub 账号互通，对方也能打开）。

---

## 标题（直接复制）

```
Permission to use the "EtchDroid" name and icon in an unofficial HarmonyOS port
```

---

## 正文 · 英文版（**推荐用这个**，上游作者是意大利人，英文回复概率更高）

```
Hi depau,

I am 蒋先生 (GitHub/Gitee: ditney), an independent developer. I have written an
unofficial port of EtchDroid to HarmonyOS (OpenHarmony / HarmonyOS NEXT) in pure
ArkTS, because there is no equivalent tool on that platform. The port keeps the
same core value as upstream: a hand-written USB Mass Storage (SCSI Bulk-Only
Transport) stack that writes ISO / IMG / DMG images straight to the raw block
device.

GPLv3 lets me redistribute modified code, but it does not grant trademark
rights, so before publishing I would like to ask for your explicit permission on
three points:

1. May I keep the name "EtchDroid" for this port, with a qualifier suffix such
   as "EtchDroid 鸿蒙版 / EtchDroid for HarmonyOS"?
2. May I use the upstream app icon as it is? The current build ships your icon
   unmodified, so next to the Android app the two icons are identical. If you
   would rather I change it, I can add a badge or draw a new one - just say
   which you prefer.
3. Do you agree that this port is unofficial, is not affiliated with or endorsed
   by you, and that you take no responsibility for it?

For transparency, here is what I am already doing:

  - The project is licensed under GPLv3, and the complete corresponding source
    code is published at: <你的公开仓库地址>
  - Upstream copyright notices are preserved (see NOTICE in the repository).
  - The in-app "About" screen displays, in the UI itself, that this is an
    unofficial port, not affiliated with nor endorsed by you.
  - No telemetry, no ads, no network permission (INTERNET is not requested).
  - The icon currently IS your file, byte for byte - which is exactly why I am
    asking before publishing.

If you prefer that I do not use the name or the icon, I will happily publish
under a different name with an original icon instead - just say so, and I will
comply. A "no" is a perfectly acceptable answer.

Thank you for EtchDroid - it is a genuinely useful piece of software, and the
reason I spent the effort porting it.

Best regards,
蒋先生
<你的邮箱>
GitHub: <你的 GitHub 用户名>
```

---

## 正文 · 中文版（备选）

```
depau 你好，

我是蒋先生（GitHub/Gitee：ditney），独立开发者。因为鸿蒙（HarmonyOS NEXT）上
没有同类工具，我用纯 ArkTS 把 EtchDroid 移植到了鸿蒙，保留了上游的核心能力：
手写 USB Mass Storage（SCSI Bulk-Only Transport）协议栈，直接把 ISO / IMG /
DMG 镜像写入裸块设备。

GPLv3 授权的是代码，不包含商标。上架前想就以下三点征求你的明确许可：

1. 移植版可否继续使用 "EtchDroid" 名称（带限定后缀，如「EtchDroid 鸿蒙版」）？
2. 可否使用上游的原始图标（当前发行版未对图标做任何修改，与官方图标完全一致）？
   如果你希望我改掉，我可以加角标或另绘一枚，请告诉我倾向哪种。
3. 你确认该移植版为非官方版本，与你无隶属关系、未获你背书，你不对其负责？

目前已做到的信息披露：

  - 项目以 GPLv3 分发，完整对应源代码公开在：<你的公开仓库地址>
  - 保留上游版权声明（见仓库内 NOTICE）。
  - App 内「关于」页明确标注：非官方移植，与上游开发者无关联、未获背书。
  - 无遥测、无广告，未申请网络权限（INTERNET）。
  - 图标目前就是你的原始文件（逐字节相同），所以需要在发行前先征得同意。

如果你更希望我不要沿用名称或图标，我会改用自绘图标与独立名称后上架，请直接
告诉我即可。拒绝也是完全可以接受的答复。

顺祝安好，
蒋先生
<你的邮箱>
```

---

## 发送后立刻做的事

1. **存证据**：讨论页 URL + 整页截图（含时间戳），存到
   `docs/permission-evidence/` 下，命名如 `2026-10-16-discussions-post.png`。
2. **开个提醒**：给自己设个 14 天后的提醒。
3. **别在这一步先上架**：拿到答复再提交，或在提交时如实说明"申请已发出，尚未回复"。

## 对方回复后的处理

| 回复 | 动作 |
| --- | --- |
| **明确同意** | 把回复截图 + 链接存进 `docs/permission-evidence/`，在其中写明"已获授权"；提交应用市场时在「审核备注」写"已获上游作者许可，见附件"，并把截图作为补充材料上传 |
| **有条件同意**（如"可以，但要说清是非官方"） | 逐条落实条件后，把往来记录一并存档，并在审核备注里说明条件已满足 |
| **拒绝** / 明确反对用名 | 走 B 方案：改名 + 差异化图标（`python3 design/make_icon.py` 可直接生成带角标版本，改完记得重新构建并同步 NOTICE），商标风险清零 |
| **14 天无回复** | 在同一个 discussion 里礼貌顶一次（`Just a gentle bump - any thoughts on the above?`）；再等 14 天仍无回复，按"未授权"处理，即走 B 方案，或先按现状上架但**绝不**在商店描述里声称"已获授权" |

## 三个别踩的坑

- **不要在无回复时就写"已获作者授权"** —— 这是虚假陈述，性质比商标本身严重得多。
- **不要删 App 内的非官方声明** —— 它是你善意（good faith）最直接的证据。
- **不要只发私信** —— 公开帖子有时间戳、可归档，证明力远强于私信截图。

## 提醒

本文档是操作模板，不构成法律意见。真到争议阶段，请咨询律师；个人开发者、
非商用、愿意按要求改名这三点，通常会让对方更倾向于给许可而非追究。
