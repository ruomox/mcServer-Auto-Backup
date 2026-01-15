# mcServer-Auto-Backup

🌍 English | [简体中文](./README.zh-CN.md)

---

## Overview

**mcServer-Auto-Backup** is a safety-first automated backup script for Minecraft servers.

It is designed for long-running production servers and focuses on **data consistency**, **failure safety**, and **predictable restore points**.

---

## Key Features

- **Safe Hot Backup**
  - Automatically suspends saves (`save-off`)
  - Forces disk flush (`save-all flush`)
  - Confirms completion via `latest.log`
  - Always restores `save-on`, even on failure

- **Reliable Cold Backup**
  - Detects offline servers
  - Verifies world inactivity before backing up

- **Strict State Validation**
  - Java process detection
  - Screen session detection
  - World lock file detection (`session.lock`)
  - Refuses to run if state is ambiguous

- **Disk Safety Guards**
  - Minimum free space (GB)
  - Minimum free space percentage

- **High-Performance Compression**
  - Zstandard (`zstd`)
  - Multi-threaded
  - Configurable compression level

- **Optional Components**
  - MySQL database backup
  - Periodic BlueMap data sync

---

## Core Design: `latest_backup`

This script **always maintains a `latest_backup/` directory**:

- `latest_backup` is a **fully usable snapshot**
- Compression (`.tar.zst`) is built **from `latest_backup`**
- In case of compression failure, `latest_backup` is still valid
- Acts as:
  - Incremental baseline
  - Fast restore source
  - Safety fallback

> Archives are disposable.  
> **`latest_backup` is the real guarantee.**

---

## Notes

- `backup_example.sh` is a **template only**
- Copy it and rename before use
