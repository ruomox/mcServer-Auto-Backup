#!/bin/bash
# WMServer backup script
# 优化版 v1.9

# ================= 配置区域 =================
SCREEN_NAME="WMServer"
SERVER_DIR="/home/WMServer"
BACKUP_DIR="/home/WMServer_backup"
BACKUP_LOG="$BACKUP_DIR/backup.log"
SESSION_LOCK="$SERVER_DIR/world/session.lock"
LEVEL_DAT="$SERVER_DIR/world/level.dat"
# 建议保留更多份数，例如 7 天
KEEP_COUNT=3
# 存储空间安全阈值
MIN_FREE_GB=20        # 至少保留 20GB 空闲
MIN_FREE_PERCENT=5    # 至少保留 10% 空闲
# save-all 监测配置
LOG_FILE="$SERVER_DIR/logs/latest.log"
SAVE_SUCCESS_MSG="Saved the game"
SAVE_TIMEOUT=300   # 最多等待 5 分钟（对 10k 地图很合理）
# 压缩级别，zstd 1-19，数字越大越慢但压缩率越高。3 是速度优先。
COMPRESS_LEVEL=3
# 压缩使用核心数，0 代表全核心
COMPRESS_THREADS=0
# --- 数据库配置 ---
# 数据库备份开关
ENABLE_DB_BACKUP=true   # true / false
# 备份数据库名称
MYSQL_DB="minecraft"
# MySQL 认证配置文件路径
MYSQL_AUTH_CNF="$BACKUP_DIR/mcdb.cnf"
# 数据库文件路径与命名
DB_BACKUP_DIR="$SERVER_DIR/.backup/db"
DB_DUMP_FILE="$DB_BACKUP_DIR/minecraft.sql"
# --- BlueMap 配置 ---
# 是否同步 BlueMap 网页渲染数据 (true/false)
# 设置为 true 则会把巨大的渲染数据同步到 latest_backup 目录
# 设置为 false 则 rsync 会跳过该目录，且不会删除目标目录中已存在的数据
ENABLE_BLUEMAP_RSYNC=true
# 压缩时是否排除 bluemap 
# 注意! 如果没有排除 bluemap 的同步将会打包进旧文件
TAR_EXCLUDE_BLUEMAP=true   # true / false
# BlueMap 周期性同步配置
BLUEMAP_SYNC_INTERVAL=7
BLUEMAP_COUNTER_FILE="$BACKUP_DIR/.bluemap_counter"
# ===========================================

NOW=$(date +"%Y%m%d_%H%M%S")
TARGET_TEMP="$BACKUP_DIR/latest_backup"
ARCHIVE_NAME="$NOW.tar.zst"
FINAL_ARCHIVE="$BACKUP_DIR/$ARCHIVE_NAME"

# 设置遇到错误立即退出 (更安全)
set -e

# --- 定义日志函数(暂未使用) ---
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# 确保备份目录存在
mkdir -p "$BACKUP_DIR"

# 将脚本的标准输出(1)和标准错误(2)都重定向到一个管道
# 管道的另一端是 tee 命令，它会把接收到的内容同时输出到屏幕和追加到日志文件
exec > >(tee -a "$BACKUP_LOG") 2>&1

echo "=== WMServer Backup start at $(date) ==="

# 清理所有未完成的临时压缩文件
TMP_PATTERN=".*.tar.zst.tmp"
if find "$BACKUP_DIR" -maxdepth 1 -type f -name "$TMP_PATTERN" | grep -q .; then
    echo "-> Found incomplete archives, cleaning up..."
    find "$BACKUP_DIR" -maxdepth 1 -type f -name "$TMP_PATTERN" -print -delete
fi

check_disk_space() {
    local target_dir="$1"

    local df_out
    df_out=$(df -P "$target_dir" | tail -1)

    local avail_kb
    local use_percent

    avail_kb=$(echo "$df_out" | awk '{print $4}')
    use_percent=$(echo "$df_out" | awk '{print $5}' | tr -d '%')

    local avail_gb=$((avail_kb / 1024 / 1024))
    local free_percent=$((100 - use_percent))

    echo "-> Disk space checking for $target_dir ..."
    echo "-> Available: ${avail_gb}GB (${free_percent}% free)"

    if [ "$avail_gb" -lt "$MIN_FREE_GB" ]; then
        echo "!! ERROR: Free disk space ${avail_gb}GB < ${MIN_FREE_GB}GB"
        return 1
    fi

    if [ "$free_percent" -lt "$MIN_FREE_PERCENT" ]; then
        echo "!! ERROR: Free disk percentage ${free_percent}% < ${MIN_FREE_PERCENT}%"
        return 1
    fi

    return 0
}

# ============================================================
# 运行状态判定（三重保险）
# ============================================================

# 判断服务器状态
HAS_JAVA=false
HAS_SCREEN=false
WORLD_LOCKED=false
LEVEL_STATIC=false
BACKUP_MODE="UNKNOWN"

# 1) 判定 Java 进程是否存在（弱信号，只作保险）
if pgrep -f java >/dev/null 2>&1; then
    HAS_JAVA=true
fi

# 2) 判定 screen 是否存在（是否可控）
if screen -list | grep -q "[[:space:]]\+[0-9]\+\.${SCREEN_NAME}[[:space:]]"; then
    HAS_SCREEN=true
fi

# 3) 判定世界是否正在被使用（最强判据）
if [ -f "$SESSION_LOCK" ] \
   && fuser "$SESSION_LOCK" >/dev/null 2>&1; then
    WORLD_LOCKED=true
fi

# 4) 冷备份判断 level.dat 在最近 30 秒内没有变化
if [ -f "$LEVEL_DAT" ]; then
    if [ $(( $(date +%s) - $(stat -c %Y "$LEVEL_DAT") )) -gt 30 ]; then
        LEVEL_STATIC=true
    fi
fi

# ============================================================
# 决策逻辑（只在“完全确定”时才行动）
# ============================================================

if [ "$WORLD_LOCKED" = true ] \
   && [ "$HAS_SCREEN" = true ] \
   && [ "$HAS_JAVA" = true ]; then

    BACKUP_MODE="HOT"
    echo "-> Backup mode: HOT (world in use, screen controllable)"

elif [ "$WORLD_LOCKED" = false ] \
     && [ "$LEVEL_STATIC" = true ]; then

    BACKUP_MODE="COLD"
    echo "-> Backup mode: COLD (server offline)"

else
    echo "!! ERROR: Backup state is ambiguous."
    echo "!! HAS_JAVA=$HAS_JAVA HAS_SCREEN=$HAS_SCREEN"
    echo "!! WORLD_LOCKED=$WORLD_LOCKED LEVEL_STATIC=$LEVEL_STATIC"
    echo "!! Refusing to perform backup to avoid inconsistent snapshot."
    exit 1
fi

# 注册退出陷阱 (Trap)
# 无论脚本以何种方式退出（正常完成、出错中断、被信号杀死），
# 只要退出，就尝试执行这个恢复命令，确保服务器不会卡在 save-off 状态。

trap '
if [ "$BACKUP_MODE" = "HOT" ]; then
    screen -S "'"$SCREEN_NAME"'" -X stuff "save-on\n" 2>/dev/null
fi
' EXIT

# ============================================================
# 存储空间安全检查
# ============================================================
if ! check_disk_space "$BACKUP_DIR"; then
    echo "!! Backup aborted due to insufficient disk space."
    exit 1
fi

# ============================================================
# MySQL 认证文件初始化（首次运行安全）
# ============================================================
if [ "$ENABLE_DB_BACKUP" = "true" ]; then
    if [ ! -f "$MYSQL_AUTH_CNF" ]; then
        cat > "$MYSQL_AUTH_CNF" <<'EOF'
# MySQL client authentication config for WMServer backup
#
# !!! IMPORTANT !!!
# Please fill in the correct credentials before re-running the backup.
#
# Example:
#
# [client]
# user=backup_user
# password=backup_password
# host=localhost
#
# You may also add:
# port=3306
# socket=/var/lib/mysql/mysql.sock
#

[client]
user=
password=
host=localhost
EOF

        chmod 600 "$MYSQL_AUTH_CNF"

        cat <<EOF
!! MySQL auth config was not found.
!! A template has been created at:

   $MYSQL_AUTH_CNF

!! Please edit this file and fill in the correct
!! database username and password, then re-run
!! the backup script.
EOF

        exit 1
    fi
fi

# ============================================================
# --- 准备阶段 ---
# ============================================================
if [ "$BACKUP_MODE" = "HOT" ]; then
    if [ ! -f "$LOG_FILE" ]; then
        echo "Error: Log file not found at $LOG_FILE. Cannot monitor save status."
        exit 1
    fi
    echo "-> Notifying players and suspending server saves..."
    # 通知玩家
    screen -S "$SCREEN_NAME" -X stuff "say §e[Server] 服务器自动备份开始...\n"
    # 关闭自动保存
    screen -S "$SCREEN_NAME" -X stuff "save-off\n"
    sleep 2
    # 强制刷盘
    echo "-> Triggering save-all and waiting for completion..."
    # 在 save-all 之前记录日志行数
    LOG_START_LINE=$(wc -l < "$LOG_FILE")
    screen -S "$SCREEN_NAME" -X stuff "save-all flush\n"
    sleep 2
    # 【重要】探查服务器 latest.log 输出保存成功后进行下一步
    echo "-> Waiting for save-all completion (timeout: ${SAVE_TIMEOUT}s)..."

    # 使用 if ! timeout 结构来安全地捕获超时，而不触发 set -e
    if ! timeout "$SAVE_TIMEOUT" \
        awk '/'"$SAVE_SUCCESS_MSG"'/ { exit 0 }' \
        < <(tail -n +"$((LOG_START_LINE+1))" -F "$LOG_FILE"); then
        echo "!! ERROR: save-all timed out. Backup aborted."

        echo "-> Re-enabling server saves (safety)..."
        screen -S "$SCREEN_NAME" -X stuff "save-on\n"
        mkdir -p "$TARGET_TEMP"
        echo "FAILED save-all timeout $NOW" > "$TARGET_TEMP/.backup_status"

        exit 1
    fi

    echo "-> save-all completed."
    
fi # 结束 if BACKUP_MODE = HOT

# ============================================================
# --- 数据库备份阶段 ---
# ============================================================
if [ "$ENABLE_DB_BACKUP" = "true" ]; then
    echo "-> Dumping MySQL database: $MYSQL_DB ..."
    # 确保目标目录存在
    mkdir -p "$DB_BACKUP_DIR"
    # 使用 mysqldump 来备份数据库
    mysqldump \
      --defaults-file="$MYSQL_AUTH_CNF" \
      --single-transaction \
      --quick \
      --routines \
      --events \
      "$MYSQL_DB" > "$DB_DUMP_FILE"
fi

# ============================================================
# BlueMap 同步计数器逻辑（运行 N 次后启用一次）
# ============================================================

BLUEMAP_SYNC_THIS_RUN=false

mkdir -p "$(dirname "$BLUEMAP_COUNTER_FILE")"

if [ "$ENABLE_BLUEMAP_RSYNC" = "true" ]; then
    # 读取计数器（文件不存在或内容非法时视为 0）
    BLUEMAP_COUNT=$(cat "$BLUEMAP_COUNTER_FILE" 2>/dev/null || echo 0)

    # 防御性校验，确保是纯数字
    if ! [[ "$BLUEMAP_COUNT" =~ ^[0-9]+$ ]]; then
        BLUEMAP_COUNT=0
    fi

    # 递增
    BLUEMAP_COUNT=$((BLUEMAP_COUNT + 1))

    # 判断是否达到同步阈值
    if [ "$BLUEMAP_COUNT" -ge "$BLUEMAP_SYNC_INTERVAL" ]; then
        BLUEMAP_SYNC_THIS_RUN=true
        BLUEMAP_COUNT=0
        echo "-> BlueMap sync ENABLED for this run (interval reached)"
    else
        echo "-> BlueMap sync skipped ($BLUEMAP_COUNT / $BLUEMAP_SYNC_INTERVAL)"
    fi

    # 写回计数器
    echo "$BLUEMAP_COUNT" > "$BLUEMAP_COUNTER_FILE"
else
    # rsync 被禁用：强制清零计数器
    echo 0 > "$BLUEMAP_COUNTER_FILE"
    echo "-> BlueMap counter reseted."
fi
# ============================================================
# 复制阶段
# ============================================================
echo "-> Starting rsync data to latest..."
# 同步数据到 latest
mkdir -p "$TARGET_TEMP"
# 使用 || set +e ... 的结构是为了在 rsync 出现非致命错误（如文件在读取时消失）时也能继续，
# 但这里为了数据绝对安全，保持 strict 模式，如果 rsync 失败则整个备份失败。
# 构建动态 rsync 参数数组
RSYNC_ARGS=(
  -a
  --delete
  --exclude="logs"
  --exclude="cache"
  --exclude="crash-reports"
)
# 总开关开启 且本次 tick 命中周期 这两个条件同时满足时，才同步 BlueMap
if [ "$ENABLE_BLUEMAP_RSYNC" = "true" ] && [ "$BLUEMAP_SYNC_THIS_RUN" = "true" ]; then
    echo "-> BlueMap rsync is ENABLED. Syncing bluemap web data..."
    # 不加 exclude，正常同步
else
    echo "-> BlueMap rsync is DISABLED for this run. Skipping 'bluemap/' sync..."
    RSYNC_ARGS+=(--exclude="bluemap")
fi

# 根据 DB 备份开关决定是否同步数据库 dump
if [ "$ENABLE_DB_BACKUP" != "true" ]; then
    RSYNC_ARGS+=(--exclude=".backup/db")
    echo "-> Database rsync is DISABLED. Skipping '.backup/db' sync..."
fi

# 使用数组扩展 "${RSYNC_ARGS[@]}" 来传递参数
rsync "${RSYNC_ARGS[@]}" "$SERVER_DIR/" "$TARGET_TEMP/"

# --- 恢复阶段 (仅热备份模式需要) ---
if [ "$BACKUP_MODE" = "HOT" ]; then
    # 数据快照完成后，立即恢复服务器保存功能
    echo "-> Re-enabling server saves..."
    screen -S "$SCREEN_NAME" -X stuff "save-on\n"
    echo "OK $NOW" > "$TARGET_TEMP/.backup_status"
else
    echo "OK $NOW (COLD)" > "$TARGET_TEMP/.backup_status"
fi # 结束 if BACKUP_MODE = HOT

# --- 压缩阶段 ---
TAR_EXCLUDES=()
# tar 是否排除 BlueMap（与 rsync 无关）
if [ "$TAR_EXCLUDE_BLUEMAP" = "true" ]; then
    TAR_EXCLUDES+=(--exclude="bluemap")
    echo "-> BlueMap archive is DISABLED."
else
    echo "-> BlueMap archive is ENABLED"
fi

# 数据库是否进入压缩包，必须与 DB 同步保持一致
if [ "$ENABLE_DB_BACKUP" != "true" ]; then
    TAR_EXCLUDES+=(--exclude=".backup/db")
    echo "-> Database archive is DISABLED."
else
    echo "-> Database archive is ENABLED."
fi

# 自动判断 cpu 核心数，避免超过最大值
CPU_CORES=$(nproc)
if [ "$COMPRESS_THREADS" -gt 0 ] && [ "$COMPRESS_THREADS" -gt "$CPU_CORES" ]; then
    echo "-> Compression threads $COMPRESS_THREADS exceeds CPU cores ($CPU_CORES), fallback to auto (-T0)"
    COMPRESS_THREADS=0
else
    if [ "$COMPRESS_THREADS" -eq 0 ]; then
        echo "-> Compression threads: auto (zstd decides, CPU cores = $CPU_CORES)"
    else
        echo "-> Compression threads: $COMPRESS_THREADS"
    fi
fi

# 压缩使用核心构建
ZSTD_THREADS_ARG="-T$COMPRESS_THREADS"
# 压缩临时文件构建
ARCHIVE_TMP="$BACKUP_DIR/.${ARCHIVE_NAME}.tmp"

echo "-> Compressing latest using zstd..."
# 切换到备份目录进行操作，以便 tar 包内路径整洁
pushd "$BACKUP_DIR" > /dev/null
# 压缩 latest 目录
if tar -I "zstd $ZSTD_THREADS_ARG -$COMPRESS_LEVEL" \
	"${TAR_EXCLUDES[@]}" \
	-cf "$ARCHIVE_TMP" -C "$TARGET_TEMP" .; then
    mv -f "$ARCHIVE_TMP" "$FINAL_ARCHIVE"
    echo "-> Compression successful!"
    # latest 目录作为增量基线，不删除
else
    echo "Error: Compression failed!"
    # 恢复自动保存 (以防万一上面没执行)并退出
    if [ "$BACKUP_MODE" = "HOT" ]; then
        screen -S "$SCREEN_NAME" -X stuff "save-on\n"
    fi
    exit 1
fi
popd > /dev/null

# --- 清理阶段 ---
# 只保留最新 N 个备份文件
echo "-> Cleaning up old backups (keeping latest $KEEP_COUNT)..."
cd "$BACKUP_DIR"
# 使用 find 替代 ls -t，处理文件名更安全 (虽然你的命名格式用 ls 也没问题)
# 这里继续沿用你原来的 ls -t 方法，因为它简单且适用于此场景
ls -t *.tar.zst 2>/dev/null | tail -n +$((KEEP_COUNT+1)) | while read f; do rm -f "$f"; done

# --- 完成 ---
# 通知玩家
if [ "$BACKUP_MODE" = "HOT" ]; then
    screen -S "$SCREEN_NAME" -X stuff "say §e[Server] 服务器自动备份完成！\n"
fi
echo "-> Backup mode: $BACKUP_MODE"
echo "=== WMServer Backup finished successfully at $(date) ==="
ls -lh "$FINAL_ARCHIVE"
