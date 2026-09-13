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

## [0.0.1] - 2026-09-13

### Added
- 项目启动（立项）。
