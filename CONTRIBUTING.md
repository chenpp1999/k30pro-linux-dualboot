# 贡献指南

## 流程

1. 先开 Issue 描述问题/需求（使用模板）。
2. 从 `main` 切分支：`feat/xxx`、`fix/xxx`、`docs/xxx`。
3. 提交遵循 [Conventional Commits](https://www.conventionalcommits.org/)：
   `feat(switch): add BCB clear in initramfs`
4. 开 PR，填写模板，CI 通过后由维护者 Squash 合并。
5. `main` 分支受保护，禁止直接推送。

## 硬性规则（安全相关）

- 任何写分区/引导的操作必须先提供 `--dry-run`、备份与回滚路径，否则不予合并。
- 禁止在脚本中硬编码设备节点；必须参数化或探测（白名单例外需注释说明）。
- 新功能必须补充或更新测试计划用例，并在测试机验证后才可标注"主力机可用"。
- 文档中的危险操作必须加显著警告。

## 风格

- Shell：POSIX sh 优先，`shellcheck` 零警告；错误必须显式处理。
- 文档：中文为主，代码/注释/提交信息英文。
- 提交原子化：一个 PR 只做一件事。

## 语言与沟通

- Issue/PR 可用中文或英文。
- 讨论技术方案时优先引用 ADR 与风险台账编号（如 R1、T1-03）。

## 开发者证书（DCO）

签名提交（`git commit -s`）表示你同意 [DCO](https://developercertificate.org/)。
