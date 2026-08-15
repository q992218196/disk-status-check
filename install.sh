#!/usr/bin/env bash
# Bootstrap installer for https://gitee.com/q992218196/disk-status-check

set -Eeuo pipefail

REPO="${DISK_CHECK_REPO:-https://gitee.com/q992218196/disk-status-check}"
REF="${DISK_CHECK_REF:-main}"
RAW_BASE="${DISK_CHECK_RAW_BASE:-${REPO}/raw/${REF}}"
INSTALL_PATH="${DISK_CHECK_INSTALL_PATH:-/usr/local/sbin/disk-status-check}"
CONFIG_PATH="${DISK_CHECK_CONFIG_PATH:-/etc/disk-status-check.conf}"
CRON_PATH="${DISK_CHECK_CRON_PATH:-/etc/cron.d/disk-status-check}"
STATE_PATH="${DISK_CHECK_STATE_PATH:-/var/tmp/disk-status-check.state}"

WEBHOOK=""
MONITOR_NAME=""
INSTALL_DEPS=1
RUN_CHECK=1
ENABLE_CRON=0
UNINSTALL=0

usage() {
    cat <<'EOF'
用法：curl -fsSL <install.sh地址> | sudo bash -s -- [选项]

选项：
  --webhook URL   写入企业微信机器人 Webhook
  --hostname NAME 写入 Webhook 显示名称（MONITOR_HOSTNAME）
  --cron          创建每 5 分钟运行一次的 cron 任务
  --no-deps       只安装脚本和配置，不安装系统依赖
  --no-check      安装完成后不执行首次检测
  --uninstall     卸载脚本和定时任务，保留配置及所有依赖
  --ref REF       从指定分支或标签安装（默认 main）
  -h, --help      显示帮助

也可使用环境变量 DISK_CHECK_RAW_BASE 指向自建镜像的 raw 目录。
EOF
}

while (($#)); do
    case "$1" in
        --webhook)
            [[ $# -ge 2 ]] || { echo "--webhook 缺少 URL" >&2; exit 2; }
            WEBHOOK="$2"
            shift
            ;;
        --hostname)
            [[ $# -ge 2 ]] || { echo "--hostname 缺少名称" >&2; exit 2; }
            MONITOR_NAME="$2"
            shift
            ;;
        --cron) ENABLE_CRON=1 ;;
        --no-deps) INSTALL_DEPS=0 ;;
        --no-check) RUN_CHECK=0 ;;
        --uninstall) UNINSTALL=1 ;;
        --ref)
            [[ $# -ge 2 ]] || { echo "--ref 缺少分支或标签" >&2; exit 2; }
            REF="$2"
            RAW_BASE="${REPO}/raw/${REF}"
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 运行，例如：curl -fsSL .../install.sh | sudo bash" >&2
    exit 2
fi

if ((UNINSTALL)); then
    echo "卸载 Disk Status Check"
    rm -f -- "$INSTALL_PATH" "$CRON_PATH" "$STATE_PATH"
    echo "已删除程序：$INSTALL_PATH"
    echo "已删除定时任务：$CRON_PATH"
    if [[ -e "$CONFIG_PATH" ]]; then
        echo "保留配置：$CONFIG_PATH"
    fi
    echo "已保留 smartmontools、nvme-cli、pciutils、curl 和 storcli 等依赖。"
    exit 0
fi

if [[ -n "$WEBHOOK" && ! "$WEBHOOK" =~ ^https://qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?key= ]]; then
    echo "--webhook 不是可识别的企业微信机器人地址" >&2
    exit 2
fi

tmp_dir="$(mktemp -d /tmp/disk-status-check-install.XXXXXX)"
trap 'rm -rf -- "$tmp_dir"' EXIT

download() {
    local url="$1" destination="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 2 --connect-timeout 10 --max-time 300 -o "$destination" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=300 -O "$destination" "$url"
    else
        echo "系统缺少 curl/wget，无法下载安装文件" >&2
        return 1
    fi
}

echo "[1/4] 从 $RAW_BASE 下载文件"
download "$RAW_BASE/disk_status_check.sh" "$tmp_dir/disk-status-check"
download "$RAW_BASE/disk-status-check.conf.example" "$tmp_dir/disk-status-check.conf.example"

if ! head -n 1 "$tmp_dir/disk-status-check" | grep -q '^#!/usr/bin/env bash'; then
    echo "下载内容不是预期的 Bash 脚本，请检查 RAW 地址" >&2
    exit 2
fi
bash -n "$tmp_dir/disk-status-check"

echo "[2/4] 安装到 $INSTALL_PATH"
install -D -m 0755 "$tmp_dir/disk-status-check" "$INSTALL_PATH"
if [[ ! -e "$CONFIG_PATH" ]]; then
    install -D -m 0600 "$tmp_dir/disk-status-check.conf.example" "$CONFIG_PATH"
    echo "已创建配置：$CONFIG_PATH"
else
    chmod 0600 "$CONFIG_PATH"
    echo "保留已有配置：$CONFIG_PATH"
fi

if [[ -n "$WEBHOOK" ]]; then
    sed -i '/^[[:space:]]*WECOM_WEBHOOK_URL=/d' "$CONFIG_PATH"
    printf 'WECOM_WEBHOOK_URL=%q\n' "$WEBHOOK" >> "$CONFIG_PATH"
    echo "已写入企业微信 Webhook"
fi

if [[ -n "$MONITOR_NAME" ]]; then
    sed -i '/^[[:space:]]*MONITOR_HOSTNAME=/d' "$CONFIG_PATH"
    printf 'MONITOR_HOSTNAME=%q\n' "$MONITOR_NAME" >> "$CONFIG_PATH"
    echo "已写入 Webhook 显示名称：$MONITOR_NAME"
fi

echo "[3/4] 安装检测依赖"
if ((INSTALL_DEPS)); then
    "$INSTALL_PATH" --install
else
    echo "已按 --no-deps 跳过"
fi

if ((ENABLE_CRON)); then
    printf '%s\n' \
        'SHELL=/bin/bash' \
        'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
        '*/5 * * * * root /usr/local/sbin/disk-status-check --check >>/var/log/disk-status-check.log 2>&1' \
        > "$CRON_PATH"
    chmod 0644 "$CRON_PATH"
    echo "已创建定时任务：$CRON_PATH"
fi

echo "[4/4] 首次检测"
if ((RUN_CHECK)); then
    set +e
    "$INSTALL_PATH" --check --no-notify
    check_rc=$?
    set -e
    if ((check_rc == 1)); then
        echo "安装完成，但首次检测发现警告/异常，请查看上方结果。"
    elif ((check_rc != 0)); then
        echo "首次检测执行失败（退出码 $check_rc）" >&2
        exit "$check_rc"
    fi
else
    echo "已按 --no-check 跳过"
fi

echo
echo "安装完成。"
echo "运行检测：sudo $INSTALL_PATH --check"
echo "编辑配置：sudo vi $CONFIG_PATH"
