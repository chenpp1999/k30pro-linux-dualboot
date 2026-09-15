# 安全与风险声明

本项目的"安全"主要指标是**数据安全与设备可恢复性**，其次才是传统信息安全。

## 使用前必读

- 本项目处于实验阶段。执行任何写分区操作前，必须完整备份（boot、recovery、
  分区表 / GPT、Android 用户数据）。
- 永远保留一条可回滚路径，并事先验证过它有效。
- 只在通过门禁评审的里程碑上执行对应风险级别的操作，见
  [docs/charter.md](docs/charter.md) 与 [docs/test-plan.md](docs/test-plan.md)。

## 报告问题

如发现可能导致数据丢失、无法开机、启动循环等问题：

1. 不要公开披露可利用细节，先发私密报告或直接联系仓库所有者；
2. 附上设备型号、ROM 版本、复现步骤、consequence（后果）与现场日志；
3. 若涉及上游组件（postmarketOS / mainline / pmOS 生态），同时通知对应上游。

## 支持范围

仅支持 Xiaomi Redmi K30 Pro / POCO F2 Pro（`lmi`），且仅支持文档中列明的
ROM 与版本组合。其他环境不在支持范围内。

## 凭据与隐私

- **仓库不包含任何口令、口令哈希、SSH 私钥、WiFi PSK/SSID 或设备标识**
  （序列号、CPUID、设备证书）。构建脚本在构建时**随机生成** root 口令，或接受
  调用者传入的 `LMI_ROOT_PASSWORD`；引导镜像与 rootfs 里的凭据按设备生成，
  **不随仓库或 Release 分发**。
- 发布物（Release，以及计划中的一键安装包）只含**通用镜像**：不含任何 WiFi 网络、
  不含固定口令（口令在首次启动随机生成并显示在设备屏幕上），SSH 仅公钥登录，
  主机密钥与 machine-id 在首次启动生成。
- 提交前自查：`git grep -n -E '<serial>|<SSID>|password|psk|WPA'` 应无真实值；
  CI 的 `tools/ci/checks.sh` 亦检查文档链接与设备节点白名单。
- **若真实凭据曾出现在公开处**（issue、日志、截图、旧提交），按"已泄露"处理并立即轮换：
  改 root 口令与 WiFi 口令；删除公开过的 `authorized_keys`；必要时重建镜像。
