# mcServer-Auto-Backup

🌍 简体中文 | [English](./README.md)

---

## 项目简介

**mcServer-Auto-Backup** 是一个以**数据安全优先**为设计目标的 Minecraft 服务器自动备份脚本。

它面向长期运行的生产服务器，核心关注点只有三件事：

**一致性 · 可恢复性 · 可预期行为**

---

## 核心功能

- **安全热备份**
  - 自动 `save-off`
  - 强制 `save-all flush`
  - 通过 `latest.log` 确认保存完成
  - 无论成功或失败，都会恢复 `save-on`

- **可靠冷备份**
  - 自动识别服务器离线状态
  - 确保世界静止后才执行备份

- **严格状态判定**
  - Java 进程检测
  - Screen 会话检测
  - 世界锁文件检测（`session.lock`）
  - 状态不明确时直接拒绝备份

- **磁盘安全保护**
  - 最小可用空间（GB）
  - 最小可用空间百分比

- **高效压缩**
  - 使用 Zstandard（zstd）
  - 支持多核并行
  - 可调压缩级别

- **可选功能**
  - MySQL 数据库备份
  - BlueMap 周期性同步

---

## 核心设计：`latest_backup`

本脚本**始终维护一个 `latest_backup/` 目录**：

- `latest_backup` 是一个**完整、可直接使用的快照**
- 压缩包（`.tar.zst`）始终由它构建
- 即使压缩失败，`latest_backup` 仍然可用
- 作用包括：
  - 增量基线
  - 快速恢复源
  - 安全兜底

> 历史压缩包可以删除，  
> **`latest_backup` 才是最终保障。**

---

## 说明

- `backup_example.sh` 仅作为配置模板
- 实际使用请复制并重命名
