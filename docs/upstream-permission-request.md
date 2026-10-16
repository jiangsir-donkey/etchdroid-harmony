# 向上游作者申请名称 / 图标使用许可（函件模板）

> 用途：本移植版以「EtchDroid 鸿蒙版」上架时，GPLv3 只授权**代码**，
> 不授权**名称与商标**。拿到上游作者的书面回复，是把这个方案从「有风险」
> 变成「可解释」的最有效一步。回复截图可作为华为应用市场的审核补充材料。

## 一、先确认你要对方同意什么

至少覆盖下面三点，回复里逐条对应最好：

1. 允许在鸿蒙（HarmonyOS）移植版中**继续使用名称 `EtchDroid`**（可带
   「鸿蒙版 / for HarmonyOS」等限定后缀）；
2. 允许**在移植版中使用上游的原始图标**（当前发行版对图标未做任何改动）；
3. 双方确认此移植版为**非官方版本**，上游不对其质量、行为、数据安全负责，
   且**不构成背书**。

## 二、首选渠道：GitHub Discussions（**不是** Issue）

已核对上游仓库配置 `.github/ISSUE_TEMPLATE/config.yml`：

- `blank_issues_enabled: false` —— **发不了空白 Issue**，只有 bug_report /
  feature_request 两个模板，许可申请会被归错类或者被直接关掉；
- 上游把"一般性提问"明确指向 **Discussions**。

所以正确入口是：

1. 打开 `https://github.com/EtchDroid/EtchDroid/discussions`（需要 GitHub 账号；
   没有就注册一个，用户名建议与 Gitee 一致，方便对方核验你是真人）；
2. `New discussion` → 选 **General**（Q&A 也行）；
3. 标题：`Permission to use the "EtchDroid" name and icon in an unofficial HarmonyOS port`；
4. 正文用第三节（英文）或第四节（中文）的模板；
5. 发送后**立刻记下讨论链接**——这就是你的证据，截图存进 `docs/`。

补充：

- 上游仓库里**没有公开邮箱**（已全仓库检索确认，只有 libaums 原作者邮箱），
  不要盲发邮件。
- 若确实想走邮件：Google Play 商店页的「开发者联系方式」和 F-Droid 应用页
  列出的邮箱是官方登记的开发者联系渠道，属于正当用途，但需要你联网自行查证。
- 公开帖里只写必要信息；需要留联系方式时写"可通过 GitHub 私信联系"即可。

## 三、英文模板（发 Issue / 邮件用）

```
Subject: Permission to use the "EtchDroid" name and icon in an unofficial HarmonyOS port

Hi depau,

I am an independent developer. I have written an unofficial port of EtchDroid
to HarmonyOS (OpenHarmony / HarmonyOS NEXT) in pure ArkTS, because there is no
equivalent app on that platform. The port keeps the same core value as upstream:
a hand-written USB Mass Storage (SCSI Bulk-Only Transport) stack that writes
ISO / IMG / DMG images straight to the raw block device.

GPLv3 lets me redistribute modified code, but it does not grant any trademark
rights. Before publishing, I would like to ask you for explicit permission on
three points:

1. May I keep the name "EtchDroid" for this port, with a qualifier suffix such
   as "EtchDroid 鸿蒙版 / EtchDroid for HarmonyOS"?
2. May I use the upstream app icon as it is? The current build ships your icon
   unmodified, so side by side with the Android app the two icons are identical
   - I would rather ask than quietly keep it.
3. Do you agree that this port is unofficial, is not affiliated with or
   endorsed by you, and that you take no responsibility for it?

For transparency, here is what I am already doing:

  - The project is licensed under GPLv3 and the full corresponding source code
    is published at: <填写你的公开仓库地址>
  - Upstream copyright notices are preserved (see NOTICE).
  - The in-app "About" screen states, in both the UI and the store listing, that
    this is an unofficial port, not affiliated with nor endorsed by you.
  - No telemetry, no ads, no network permission (INTERNET is not requested).

If you prefer, I am happy to rename the app and replace the icon with an
original one instead - just say so. I would of course also accept a "no" and
still publish under a different name.

Thank you for EtchDroid - it is a genuinely useful piece of software.

Best regards,
<你的名字 / GitHub 或 Gitee 用户名>
<联系邮箱>
```

## 四、中文模板（对方用中文回复时，或国内渠道用）

```
主题：申请在鸿蒙移植版中继续使用 “EtchDroid” 名称与图标

depau 你好，

我是独立开发者。因为鸿蒙（HarmonyOS NEXT）上没有同类工具，我用纯 ArkTS 把
EtchDroid 移植到了鸿蒙，保留了上游的核心能力：手写 USB Mass Storage
（SCSI Bulk-Only Transport）协议栈，直接把 ISO / IMG / DMG 镜像写入裸块设备。

GPLv3 授权的是代码，不包含商标。上架前想就以下三点征求你的明确许可：

1. 移植版可否继续使用 “EtchDroid” 名称（后缀限定，如「EtchDroid 鸿蒙版」）？
2. 可否使用上游的原始图标（当前发行版未对图标做任何修改，与官方图标完全一致）？
3. 你确认该移植版为非官方版本，与你无隶属关系、未获你背书，你不对其负责？

目前已做到的信息披露：

  - 项目以 GPLv3 分发，完整对应源代码公开在：<填写你的公开仓库地址>
  - 保留上游版权声明（见 NOTICE）。
  - App 内「关于」页与应用商店描述均标注：非官方移植，与上游开发者无关联、未获背书。
  - 无遥测、无广告，未申请网络权限（INTERNET）。

如果你更希望我不要沿用名称或图标，我也可以改用自绘图标与独立名称后上架，
请直接告诉我即可。无论结果如何，都感谢 EtchDroid 这个优秀的项目。

顺祝安好，
<你的名字>
<联系邮箱>
```

## 五、拿到回复之后

- **同意**：把回复原文 + 截图 + permalink 存进 `docs/permission-evidence/`
  （按该目录的 `README.md` 填 `RECORD.md`）；提交应用市场时在「审核备注」
  说明「已获上游作者许可，见附件」。
- **拒绝 / 无回复**：按 `README.md` 第 8 节走 B 方案 —— 换成不含 `EtchDroid`
  的独立名称 + 差异化图标（可直接运行 `python3 design/make_icon.py` 生成带
  「鸿蒙」角标的图标，改完记得重新构建并同步 NOTICE），此时商标风险基本清零，
  GPLv3 合规不受影响。
- **无论哪种结果**：GPLv3 的源码公开、版权声明保留、修改声明这三件事都必须继续做。

## 六、风险提醒

- 这封信**只是模板**，不构成法律意见。出资询律师的口径是：
  「个人开发者、非商用为主、愿意按要求改名」通常比商业公司更容易获得宽容。
- 不要在没有回复的情况下，在商店描述里写「已获作者授权」——这属于虚假陈述，
  比商标本身的问题更严重。
- 不要删除 App 内的「非官方」声明；它是你善意（good faith）最直接的证据。
