# 测试计划（骨架）

原则：**能非破坏验证的，绝不先做破坏性验证；能在测试机做的，绝不在主力机做。**

## T0 — 静态检查（每次提交，CI）

由 `tools/ci/checks.sh` 执行（CI job「Guard rails」），实现状态：

- `shellcheck` 全部 shell 脚本（含 `tools/m0/init`；`-e SC2187` 因 busybox shebang）
- Markdown **本地**链接检查（相对链接必须存在；外链不检查）
- 禁止硬编码设备节点：仅白名单文件允许（`tools/m0/init`、`tools/m1/m1-init.sh`
  的 `misc` 兜底节点，已注释说明）；`/dev/block/by-name/*` 为稳定符号链接，允许
- 破坏性脚本（含 `dd ... of=`）必须提供 `--dry-run`；ramboot init 豁免
  （其唯一写入是设计内的 BCB 清除，ADR-0001）

## T1 — 非破坏验证（主力机可执行）

| 编号 | 项目 | 通过标准 |
|---|---|---|
| T1-01 | `fastboot boot` 启动 Linux（阶段 A） | 显示、触屏、SSH 可用；未写任何分区 |
| T1-02 | 读取并归档分区表 / GPT / boot / recovery 备份 | 哈希校验通过 |
| T1-03 | BCB 行为试验：写 boot-recovery 进 TWRP | ✅ 2026-09-14 完成：ABL **不**清 BCB、Linux init 清除；且 recovery 引导要求镜像自带 `recovery_dtbo`（v6 缺 → fastboot；v7 修复）。见 `acceptance/m2-2026-09-14.md` |
| T1-04 | 正常重启回归 | 100 次重启全部回到 Android（可分批） |
| T1-05 | 方式 B 部署门禁（预检） | 无 attestation / SHA-256 缺失或不匹配时 `to-linux` 拒绝写入；`--dry-run` 不写任何分区。自动化：`tools/tests/m2-switch-test.sh`（CI 运行，含 BCB 写/清校验、`--force`、尺寸检查） |

## T2 — 受控破坏性验证（测试机优先）

> M2 v0.1 实现完成（2026-09-14）：命令与验收步骤见 `docs/m2-runbook.md`；
> 下表 T2-02/03/04 与 TWRP 恢复演练待实机执行并归档。

| 编号 | 项目 | 通过标准 |
|---|---|---|
| T2-01 | 阶段 B 安装（super 空闲空间 + recovery） | 30 次重启稳定；TWRP 可恢复 |
| T2-02 | 双向切换 | 各 20 次无失败。**2026-09-14 实机：5 轮零失败后由负责人决定提前结束（时间成本）；标准修订待定**（见 `acceptance/m2-2026-09-14.md`） |
| T2-03 | Linux 未清 BCB 时断电 | 重启能回到 Android 或自愈 |
| T2-04 | 切换命令执行中断电 | 重启回 Android |
| T2-05 | M3 扩容 dry-run | 输出与预期分区表一致 |
| T2-06 | M3 扩容实做 + 回滚 | 回滚后数据完好、镜像一致 |
| T2-07 | 全量备份恢复演练 | TWRP 全量恢复后系统与数据可用 |

## T3 — 发布回归（每个 Release）

- T1 全量
- T2 在至少一台已完成安装的设备上抽样（T2-01/02/04/07）
- 验收记录归档到 `docs/acceptance/`

## 验收记录模板

```
日期 / 设备 / ROM / 内核 / 操作人
前置条件：
执行步骤：
结果（含日志 / 截图哈希）：
结论：PASS / FAIL
遗留问题：
```

## 异常场景清单

- 切换中断电 / 拔线
- Linux 内核 panic、initramfs 卡死
- BCB 残留导致 fastboot 循环（方式 B 救援：`fastboot erase misc`，见 m0-runbook §5）
- Android 侧 root 丢失（Magisk 被覆盖）
- recovery 分区被系统 OTA 恢复成官方镜像
- 存储写满导致 boot 镜像复制不完整（写入前必须校验空间与哈希）
