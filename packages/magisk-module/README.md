# Magisk 模块：K30 Pro Dualboot Switch（M2 v0.1）

Android → Linux 的一键切换入口：在 Magisk 应用里按模块的 **Action** 按钮
（需 Magisk 27+），即执行 `recovery-swap.sh to-linux` 并自动重启进入 Linux。

- 机制：ADR-0001（`recovery` 分区 + `misc` BCB 一次性引导）。
- `boot` 分区永不被修改；Linux 侧任意重启回 Android（M1b init 清 BCB）。
- 本模块**不包含**切换逻辑本身，只是调用已部署的
  `recovery-swap.sh`（默认 Termux home）与已通过方式 A 验证的镜像。

## 依赖

| 项 | 默认值 | 覆盖环境变量 |
|---|---|---|
| 切换脚本 | `/data/data/com.termux/files/home/recovery-swap.sh` | `LMI_SWITCH_SCRIPT` |
| Linux 镜像 | `/data/local/lmi-dualboot/boot-m1b-v6.img` | `LMI_SWITCH_IMG` |
| 跳过门禁（救援/测试） | 关 | `LMI_SWITCH_FORCE=1` |

镜像必须已生成 attestation（`recovery-swap.sh attest-ramboot`，见
`docs/m0-runbook.md` §4），否则 `to-linux` 会按部署门禁拒绝写入。

## 打包与安装

模块目录内容需位于 zip 根（`module.prop`、`action.sh` 在 zip 顶层）：

```sh
cd packages/magisk-module
zip -r ../lmi-dualboot-switch-v0.1.zip .
# 然后在 Magisk 应用里“从本地安装”该 zip，重启后生效
```

## 卸载 / 回滚

- Magisk 里直接移除模块即可（本模块不写任何分区）。
- 若切换后想回 TWRP：`recovery-swap.sh restore-twrp`（见 `docs/m2-runbook.md`）。

## 状态

v0.1 骨架，随 M2 实机验收一起验证；接口（环境变量与默认路径）已冻结，
实现可能随验收反馈调整。详见 `docs/m2-runbook.md` 与 issue #15。
