# 合入官方仓库 —— 一键产出可提交的分支

把鸿蒙版作为 `harmonyos/` 子目录合入 `EtchDroid/EtchDroid`，产出 7 个原子提交，
符合上游 `CONTRIBUTING.md` / `AGENTS.md` 的 rebase-only + Conventional Commits
要求。

## 前置（**别跳过第一步**）

1. **先开 issue 谈**，不要直接提 PR。
   上游 `CONTRIBUTING.md`: *"For significant features, open an issue first."*
   可粘贴的 issue 全文见 `docs/upstream-contribution-plan.md` 第三节。
2. 需要联网 `git clone` 上游仓库（我这边网络是隔离的，没法替你 clone）。

## 用法

```bash
git clone https://github.com/EtchDroid/EtchDroid.git /tmp/EtchDroid
cd /home/donkey/桌面/etchdroid-harmony
./docs/merge-into-upstream/apply.sh /tmp/EtchDroid
```

脚本会**自检**：目标必须是真的上游克隆（有 `.git`、`app/`、`settings.gradle.kts`）、
工作区干净、且尚无 `harmonyos/`。任一不满足就直接退出，不会改坏东西。

## 它做了什么

| 步骤 | 动作 |
| --- | --- |
| 1 | 自检上游克隆 |
| 2 | 建分支 `harmonyos-port`（可用 `BRANCH=` 覆盖） |
| 3 | 把本移植版拷进 `harmonyos/`，**排除** `build/`、`dist/`、`entry/build/`、`docs/`、`LICENSE` |
| 4 | 用上游语境版覆盖 `harmonyos/README.md` 与 `harmonyos/NOTICE` |
| 5 | 把 `Index.ets` 的 `SOURCE_REPO_URL` 指向 `.../EtchDroid/tree/main/harmonyos` |
| 6 | 在上游根 `README.md` 的 `## Support the project` 之前插入「Other platforms」一节 |
| 7 | 打 7 个原子提交 |
| 8 | 校验：无未提交文件、无构建产物入库 |

## 产出的 7 个提交

```
docs(readme): mention the unofficial HarmonyOS port
chore(harmonyos): ship the upstream app icon with the HarmonyOS port
docs(harmonyos): document the port and its provenance
feat(harmonyos): add a Simplified Chinese localization
feat(harmonyos): add image writer UI, worker and background task
feat(harmonyos): implement SCSI bulk-only transport mass storage stack
chore(harmonyos): add hvigor project scaffolding
```

## 已端到端验证（实测，不是推测）

| 验证项 | 结果 |
| --- | --- |
| 脚本在干净的上游克隆上跑通 | ✅ 7 个提交，`git status` 无残余 |
| `harmonyos/` 下被跟踪的文件 | ✅ 50 个，全部是源码/文档/图标，零构建产物 |
| 合入后能否编译 | ✅ `BUILD SUCCESSFUL` + `verify-app success`，253 KB 已签名 HAP |
| 编译后 git 树是否被污染 | ✅ 仍然干净（嵌套 `.gitignore` 生效） |
| 合入版 HAP 在模拟器运行 | ✅ 启动正常，桌面图标与关于页均正确 |
| 是否动到 Android/Gradle | ✅ 没有（`settings.gradle.kts` 仍只 include `:app`） |

## 推送前你要改的两处

1. `harmonyos/README.md` 里的 `your-github-username`（两处）
2. `PR.md` 里的 `<issue-number>` 和 `<your-github-username>`

```bash
cd /tmp/EtchDroid
git push -u origin harmonyos-port
```

然后提 PR，正文从 `PR.md` 复制。

## 两个刻意的取舍

- **不带 `docs/`**：里面是你的华为上架清单、隐私政策、许可申请函和私人存档，
  对上游是噪音。留在你自己的仓库即可。
- **不带 `LICENSE`**：它与上游根目录的 `LICENSE` 逐字节相同，重复一份只会让
  reviewer 多问一句。`NOTICE` 要留 —— 它说明移植来源和范围。

## 如果上游说「不要放我仓库里」

别争辩，直接转方案 B：把 `README.section.md` 里的 `harmonyos/` 链接换成你的
独立仓库地址，请他在根 README 加那一节。一行 Markdown，接受概率高得多，
而且同样是公开的官方认可。
