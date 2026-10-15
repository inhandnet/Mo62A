# 贡献指南

[English](CONTRIBUTING.md)

## 分支与 PR

默认分支为 `master`，只接受 PR 合入。必须通过 `commit-message` 和
`validate-release` 检查，分支须基于最新 master，讨论须解决。包括管理员在内，
都不能直接推送、强推或删除 master。采用 rebase 合并，保留经过校验的提交信息。
不强制最低人工批准数量，维护者仍应在合并前审核内容。

不要提交本地编译产物、包含设备标识的照片、凭据或内部规划文件。

## Git commit message

`.github/commit-policy.yml` 定义约束，本地 hook 与 GitHub 必需检查共用
`scripts/commit_policy.py`。第一行使用最多 72 字符的英文 Conventional Commit
标题，空行后为 YAML 正文，且必须同时提供中英文说明：

```text
fix(image): include external drivers in offline images

Message:
  en: Include cryptodev when assembling an offline image.
  zh: 制作离线镜像时安装 cryptodev 驱动。
```

包含 `: ` 等 YAML 特殊字符时请加引号或使用 `>-`。允许类型为 `feat`、`fix`、
`docs`、`perf`、`refactor`、`test`、`build`、`ci`、`chore`、`revert`、`sync`。
冒号前的 `!` 表示不兼容变更，中英文说明均应写明迁移影响。禁止出现内部 IP 和域名。
PR 标题遵守同样的首行规范；PR 中每个提交均须合规，merge/fixup 提交需先 rebase 整理。

安装 Python 3 和 PyYAML（Ubuntu 可用 `sudo apt-get install python3-yaml`），再启用：

```bash
git config core.hooksPath .githooks
git config commit.template .github/commit-template.txt
python3 -B -m unittest discover -s tests -v
```

## 发布

只有 `weiyf1003` 可创建 TAG，TAG 创建后不允许修改或删除。合入 master 后，先通过
**Actions → Release image → Run workflow** 构建候选版本：只编译和验证，不发布。
通过后，在审核后的 master 提交上创建带注释的正式版本 TAG：

```bash
git fetch origin master --tags
git tag -a V1.1.1 origin/master -m "Mo62A V1.1.1"
git push origin V1.1.1
```

TAG 触发 GitHub 托管环境中的干净构建、镜像检查、校验和验证及草稿附件上传。
五项必需附件全部上传且服务器返回的摘要与本地一致后，Release 才公开。
失败不会公开新版本，可重跑失败作业；若须修改代码，应通过 PR 后使用新版本 TAG，
不能移动旧 TAG。本流程不需要长期发布令牌或自托管 runner。

V1.1.0 使用 `release-notes/` 中整理的首发说明。后续按相邻 TAG 之间的全部提交，
读取 `Message.en` / `Message.zh` 自动分类生成日志。每版附件包含截至该版本的
完整 `CHANGELOG.en.md`、`CHANGELOG.zh.md`，以及供网站使用的 `release.json`。
源码根目录不再维护累积日志，不自动写回 master，历史 Release 附件保持不变。
自动验证不代表已经完成实机启动或外设测试。详见 [RELEASES.md](RELEASES.md)。
