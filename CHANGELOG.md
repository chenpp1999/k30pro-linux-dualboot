# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与
[语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added
- Phase 0 立项文档：立项书、可行性研究、系统架构、风险台账、测试计划、ADR-0001。
- 项目仓库与 README。
- M0 构建链 `tools/m0/`：上游产物获取与校验、initramfs 构建、boot 镜像组装、
  ramboot init（含 BCB 清除与自检报告）、eventdump 触摸检测工具。
- M0 操作手册 `docs/m0-runbook.md`（方式 A：fastboot boot 零写入；
  方式 B：recovery-swap 无宿主部署）。
- `tools/m1/recovery-swap.sh`：recovery 分区切换部署工具（备份/写入/回滚）。
- `recovery-swap.sh attest-ramboot`：方式 A RAM 启动通过后的 attestation
  （issue #1 部署门禁）；`to-linux` 新增 `--dry-run` / `--force` 选项。
- `tools/m0/init`：USB 网络 gadget 优先 NCM、RNDIS 回退（issue #2）。
- `.gitattributes`：构建输入与 shell 脚本强制 LF（issue #3）。
- `tools/m0/display.c`：`m0-display` 最小 KMS 接管工具（无 fbdev 内核下设置
  DSI 模式 + 色条 + 背光，常驻持有 DRM master；issue #4）；init 后台拉起。
- `docs/acceptance/m0-2026-09-13.md`：M0 方式 A 真机验收记录与证据
  （A1–A5 全过；完整 UI 推迟 M1）。

### Changed
- `recovery-swap.sh to-linux` 默认启用部署预检：SHA-256 清单 + attestation +
  `ANDROID!` 头 + 分区大小，任一缺失/不符即拒绝写入（issue #1）。
- M0 门禁收紧：方式 B 写入前，同一镜像必须已通过方式 A 实机启动并生成
  attestation（charter §6、runbook §2 A8）。
- README：M0 状态更新为方式 A 实机验收 A1–A5 全过（2026-09-13）。
- runbook §1 产物哈希更新（2026-09-13 终轮：NCM + LF + display 接管）；§2/§3
  注明退出方式 A 用 `reboot -f`（普通 `reboot` 对 PID1=busybox sh 无效）。

### Fixed
- M0 黑屏根因：内核无 fbdev（`CONFIG_FB=n`）且无用户态 KMS 接管，且
  `bl_power=4` 且 msm 在最后 DRM 客户端退出时熄屏；以 `m0-display` 解决
  （issue #4）。触摸验证设备修正为 `fts_ts` → `/dev/input/event3`。
- M0 启动失败根因：`tools/m0/init` 为 CRLF → busybox shebang 失效 →
  init 退出 127 → kernel panic（issue #3；方式 B 失败链条见 issue #1）。
- runbook §3 补充 Windows 宿主 fastboot 驱动/接口 GUID 注意事项与
  `AdbWriteEndpointSync failed` 恢复方法（2026-09-13 真机救援实测）。
- runbook §5 重写为 BCB 救援流程（`fastboot erase misc` + 二级救援）；
  `misc` 列为唯一 erase 例外；删除"方式 B 后无法进 Android 理论不可能"的错误假设。
- architecture 失败模式表补充"内核未启动 → BCB 残留 → fastboot 循环"；
  明确 T1-03 完成前不得假设 bootloader 会自动清 BCB。
- test-plan 新增 T1-05（部署门禁预检）与 T1-03 备注；risk R3 更新为已触发
  （2026-09-13 真机实测）。
- initramfs 补全动态链接器 `ld-linux-aarch64.so.1`（此前 dropbear 无法执行）。
- ramboot init 挂载 `/dev/pts`（SSH/telnet 需要 PTY）。
- ramboot init 关键步骤改用 `/bin/busybox` 绝对路径，并增加 misc 分区兜底
  路径，保证 BCB 一定被清除。
- recovery-swap 写入后校验 `ANDROID!` 头，防止不完整写入。

## [0.0.1] - 2026-09-13

### Added
- 项目启动（立项）。
