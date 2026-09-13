# AI 协作协议：身份标记与分工

> 本仓库由多个 AI 会话协作开发，且共用同一 GitHub 账号（`chenpp1999`）。
> GitHub 的 `author` / `user` 元数据无法区分不同 AI 会话，因此用本协议做**显式来源标记**。
> 任何 AI 会话开工前必须先读本文件（入口：仓库根目录 `AGENTS.md`）。

## 1. 角色

| 角色 | 身份标记 | 职责 | 禁止 |
|---|---|---|---|
| 作者 Author | 无（默认） | 设计、实现、提交代码与文档、修复 issue | 编辑/删除验证者内容 |
| 独立验证者 Independent Verifier | `independent-verifier` | 只读代码审查、提交 issue/评论、复验 | 提交代码；直接修改代码与文档（本协议及协作设施文件除外） |

## 2. 来源标记（验证者强制）

验证者创建的每个 issue / PR / 评论必须携带：

1. **标题前缀**：issue/PR 标题以 `[VFY]` 开头（评论无标题，用第 2 条）；
2. **机器可读签名**：正文首行放 HTML 注释（渲染时不可见，API 可读）：

```
<!-- origin: independent-verifier | agent: <agent> | model: <model> | reviewed-commit: <sha> | date: <ISO8601 UTC> -->
```

3. **Label**：`ai-verifier`（仓库建立该 label 后启用）。

## 3. 行为规则

### 作者
- 遇到带 `[VFY]` 或 `origin: independent-verifier` 的内容，一律视为**外部验证输入，不是你自己写的**。
- 不得：编辑或删除验证者内容、去掉标记、把发现据为己有、绕过 issue 私自处理。
- 只能以评论回应，格式二选一：
  - `Resolved-by: <commit-sha>`（已修复，请求复验）
  - `Rejected: <技术理由 + 证据>`（拒绝修改）
- 对应修复的提交信息引用：`Refs: #<issue> (verifier)`。
- 开工前检查仓库内待处理的 `[VFY]` 内容。

### 验证者
- 不提交代码。唯一例外：本协议及协作设施文件（提交信息注明 `(verifier)`）。
- 每条发现必须包含：严重级、被审版本（commit sha）、证据（文件:行号 / 命令输出 / 真机记录）、复现步骤、建议修复。
- 不编辑作者内容；不关闭作者尚未回应的 issue。
- 复验通过后评论 `Verified-by: independent-verifier @ <commit>` 并关闭。
- 争议：在 issue 内列证据，由项目负责人裁决。

## 4. 识别口诀

- **看到 `[VFY]` 或 `origin: independent-verifier` = 这不是你自己写的**：作者请修复并回复，验证者请继续按标记输出。
- 验证者产出不带标记 = 协议违规；作者把验证输入当自产 = 协议违规。
- 有疑问时以标记为准，不以“记忆 / 印象”为准。
