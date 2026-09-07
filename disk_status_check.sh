#!/usr/bin/env bash
# Linux disk/RAID health monitor for CentOS/RHEL and Debian/Ubuntu.

set -uo pipefail
export LC_ALL=C

VERSION="1.2.0"
DEFAULT_CONFIG_FILE="/etc/disk-status-check.conf"
CONFIG_FILE="${DISK_CHECK_CONFIG:-$DEFAULT_CONFIG_FILE}"

# These values may be overridden by the config file or environment.
WECOM_WEBHOOK_URL="${WECOM_WEBHOOK_URL:-}"
MONITOR_HOSTNAME="${MONITOR_HOSTNAME:-}"
STORCLI_RPM_URL="${STORCLI_RPM_URL:-https://tools.lcayun.cn/storcli/storcli-007.2310.0000.0000-1.noarch.rpm}"
STORCLI_DEB_URL="${STORCLI_DEB_URL:-https://tools.lcayun.cn/storcli/storcli_007.2705.0000.0000_all.deb}"
STORCLI_ZIP_URL="${STORCLI_ZIP_URL:-}"
SATA_TEMP_WARN="${SATA_TEMP_WARN:-60}"
NVME_TEMP_WARN="${NVME_TEMP_WARN:-70}"
NVME_PERCENT_USED_WARN="${NVME_PERCENT_USED_WARN:-100}"
NOTIFY_COOLDOWN="${NOTIFY_COOLDOWN:-3600}"
STATE_FILE="${STATE_FILE:-/var/tmp/disk-status-check.state}"
DEBUG_NOTIFY="${DEBUG_NOTIFY:-0}"

# Script update settings. auto uses the public IP country: CN=Gitee, others=GitHub.
UPDATE_SOURCE="${UPDATE_SOURCE:-auto}"
UPDATE_COUNTRY_CODE="${DISK_CHECK_COUNTRY_CODE:-${UPDATE_COUNTRY_CODE:-}}"
UPDATE_GITEE_URL="${UPDATE_GITEE_URL:-https://gitee.com/q992218196/disk-status-check/raw/main/disk_status_check.sh}"
UPDATE_GITHUB_URL="${UPDATE_GITHUB_URL:-https://raw.githubusercontent.com/q992218196/disk-status-check/main/disk_status_check.sh}"
UPDATE_TARGET="${UPDATE_TARGET:-/usr/local/sbin/disk-status-check}"

MODE="check"
NOTIFY=1

declare -a OK_MESSAGES=()
declare -a INFO_MESSAGES=()
declare -a WARN_MESSAGES=()
declare -a ERROR_MESSAGES=()
declare -A MEGARAID_VIRTUAL_DISKS=()

usage() {
    cat <<'EOF'
用法：
  disk_status_check.sh [--check] [--no-notify] [--debug] [--webhook URL]
  disk_status_check.sh --install
  disk_status_check.sh --check-update
  disk_status_check.sh --update

选项：
  --check          执行一次检测（默认）
  --install        安装 smartmontools、nvme-cli、pciutils；检测到
                   Broadcom/LSI MegaRAID 时再安装 storcli
  --check-update   检查是否有新版本，不修改文件
  --update         检查并更新 /usr/local/sbin/disk-status-check
  --webhook URL    本次运行使用的企业微信机器人 Webhook
  --no-notify      只输出结果，不推送企业微信
  --debug          每次检测都推送 Webhook，忽略告警冷却（调试用）
  --config FILE    指定配置文件（默认 /etc/disk-status-check.conf）
  -h, --help       显示帮助
  -V, --version    显示版本

退出码：0=正常，1=发现告警，2=执行或通知失败
EOF
}

# Read --config before loading configuration; command-line options are parsed
# again afterwards so they always win over config values.
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "--config" && $((i + 1)) -lt ${#args[@]} ]]; then
        CONFIG_FILE="${args[$((i + 1))]}"
    fi
done

if [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

while (($#)); do
    case "$1" in
        --check) MODE="check" ;;
        --install) MODE="install" ;;
        --check-update) MODE="check-update" ;;
        --update) MODE="update" ;;
        --no-notify) NOTIFY=0 ;;
        --debug) DEBUG_NOTIFY=1 ;;
        --webhook)
            [[ $# -ge 2 ]] || { echo "--webhook 缺少 URL" >&2; exit 2; }
            WECOM_WEBHOOK_URL="$2"
            shift
            ;;
        --config)
            [[ $# -ge 2 ]] || { echo "--config 缺少文件名" >&2; exit 2; }
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        -V|--version) echo "$VERSION"; exit 0 ;;
        *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

ok() { OK_MESSAGES+=("$*"); }
info() { INFO_MESSAGES+=("$*"); }
warn() { WARN_MESSAGES+=("$*"); }
error() { ERROR_MESSAGES+=("$*"); }
have() { command -v "$1" >/dev/null 2>&1; }
is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

display_hostname() {
    if [[ -n "${MONITOR_HOSTNAME:-}" ]]; then
        printf '%s\n' "$MONITOR_HOSTNAME"
    else
        hostname -f 2>/dev/null || hostname
    fi
}

detect_os() {
    OS_ID="unknown"
    OS_LIKE=""
    OS_NAME="unknown Linux"
    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_LIKE="${ID_LIKE:-}"
        OS_NAME="${PRETTY_NAME:-$OS_ID}"
    fi
}

raid_pci_lines() {
    if have lspci; then
        lspci -nn 2>/dev/null | grep -Ei 'RAID bus controller|MegaRAID|SAS.*(Broadcom|LSI)|Broadcom.*SAS|LSI.*SAS' || true
    fi
}

has_megaraid() {
    raid_pci_lines | grep -Eiq 'MegaRAID|Broadcom|LSI|1000:'
}

find_storcli() {
    local candidate
    for candidate in \
        "$(command -v storcli64 2>/dev/null || true)" \
        "$(command -v storcli 2>/dev/null || true)" \
        /opt/MegaRAID/storcli/storcli64 \
        /opt/MegaRAID/storcli/storcli \
        /usr/local/sbin/storcli64; do
        if [[ -n "$candidate" ]] && { [[ -x "$candidate" ]] || [[ "$(type -t "$candidate" 2>/dev/null)" == "function" ]]; }; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

download_file() {
    local url="$1" dest="$2"
    curl -fL --retry 2 --connect-timeout 10 --max-time 300 -o "$dest" "$url"
}

valid_country_code() {
    [[ "${1:-}" =~ ^[A-Z]{2}$ && "$1" != "XX" ]]
}

detect_update_country() {
    local body code

    if [[ -n "$UPDATE_COUNTRY_CODE" ]]; then
        code="${UPDATE_COUNTRY_CODE^^}"
        valid_country_code "$code" && { printf '%s\n' "$code"; return 0; }
        echo "无效的 UPDATE_COUNTRY_CODE：$UPDATE_COUNTRY_CODE" >&2
        return 1
    fi

    code="$(curl -fsSL --connect-timeout 4 --max-time 8 'https://ipapi.co/country/' 2>/dev/null |
        tr -d '[:space:]' | tr '[:lower:]' '[:upper:]' || true)"
    valid_country_code "$code" && { printf '%s\n' "$code"; return 0; }

    body="$(curl -fsSL --connect-timeout 4 --max-time 8 'https://www.cloudflare.com/cdn-cgi/trace' 2>/dev/null || true)"
    code="$(awk -F= '$1 == "loc" {gsub(/[[:space:]\r]/, "", $2); print toupper($2); exit}' <<<"$body")"
    valid_country_code "$code" && { printf '%s\n' "$code"; return 0; }

    body="$(curl -fsSL --connect-timeout 4 --max-time 8 'https://api.country.is/' 2>/dev/null || true)"
    code="$(sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([A-Za-z][A-Za-z]\)".*/\1/p' <<<"$body" |
        tr '[:lower:]' '[:upper:]')"
    valid_country_code "$code" && { printf '%s\n' "$code"; return 0; }
    return 1
}

select_update_urls() {
    local source="${UPDATE_SOURCE,,}" country=""
    UPDATE_URLS=()

    case "$source" in
        auto)
            country="$(detect_update_country || true)"
            if [[ "$country" == "CN" ]]; then
                echo "[信息] 公网 IP 归属地：CN，优先从 Gitee 检查更新"
                UPDATE_URLS=("$UPDATE_GITEE_URL" "$UPDATE_GITHUB_URL")
            elif valid_country_code "$country"; then
                echo "[信息] 公网 IP 归属地：$country，优先从 GitHub 检查更新"
                UPDATE_URLS=("$UPDATE_GITHUB_URL" "$UPDATE_GITEE_URL")
            else
                echo "[警告] 无法识别公网 IP 归属地，优先尝试 Gitee" >&2
                UPDATE_URLS=("$UPDATE_GITEE_URL" "$UPDATE_GITHUB_URL")
            fi
            ;;
        gitee) UPDATE_URLS=("$UPDATE_GITEE_URL" "$UPDATE_GITHUB_URL") ;;
        github) UPDATE_URLS=("$UPDATE_GITHUB_URL" "$UPDATE_GITEE_URL") ;;
        *)
            echo "无效的 UPDATE_SOURCE：$UPDATE_SOURCE（可选 auto、gitee、github）" >&2
            return 2
            ;;
    esac
}

extract_script_version() {
    awk -F'"' '/^VERSION="[0-9]/{print $2; exit}' "$1"
}

version_is_newer() {
    local candidate="$1" current="$2" newest
    [[ "$candidate" != "$current" ]] || return 1
    newest="$(printf '%s\n%s\n' "$current" "$candidate" | sort -V | tail -n 1)"
    [[ "$newest" == "$candidate" ]]
}

cleanup_update_temp() {
    if [[ -n "${UPDATE_TMP_DIR:-}" && -d "$UPDATE_TMP_DIR" ]]; then
        rm -rf -- "$UPDATE_TMP_DIR"
    fi
    UPDATE_TMP_DIR=""
}

prepare_update_candidate() {
    local url remote_version
    have curl || { echo "缺少 curl，无法检查更新；请先运行 --install" >&2; return 2; }
    select_update_urls || return $?

    UPDATE_TMP_DIR="$(mktemp -d /tmp/disk-status-check-update.XXXXXX)" || return 2
    UPDATE_CANDIDATE="$UPDATE_TMP_DIR/disk-status-check"
    UPDATE_REMOTE_VERSION=""
    UPDATE_USED_URL=""

    for url in "${UPDATE_URLS[@]}"; do
        echo "[信息] 检查更新源：$url"
        if ! download_file "$url" "$UPDATE_CANDIDATE"; then
            echo "[警告] 更新源不可用，尝试备用源" >&2
            continue
        fi
        if ! head -n 1 "$UPDATE_CANDIDATE" | grep -q '^#!/usr/bin/env bash'; then
            echo "[警告] 下载内容不是预期的 Bash 脚本，尝试备用源" >&2
            continue
        fi
        if ! bash -n "$UPDATE_CANDIDATE"; then
            echo "[警告] 下载脚本语法检查失败，尝试备用源" >&2
            continue
        fi
        remote_version="$(extract_script_version "$UPDATE_CANDIDATE")"
        if [[ ! "$remote_version" =~ ^[0-9]+(\.[0-9]+){1,3}([-+][0-9A-Za-z.-]+)?$ ]]; then
            echo "[警告] 无法识别远端版本号，尝试备用源" >&2
            continue
        fi
        UPDATE_REMOTE_VERSION="$remote_version"
        UPDATE_USED_URL="$url"
        return 0
    done

    echo "Gitee 和 GitHub 更新源均不可用" >&2
    cleanup_update_temp
    return 2
}

check_update() {
    prepare_update_candidate || return $?
    if version_is_newer "$UPDATE_REMOTE_VERSION" "$VERSION"; then
        echo "发现新版本：$VERSION -> $UPDATE_REMOTE_VERSION"
        echo "执行更新：sudo $0 --update"
    elif [[ "$UPDATE_REMOTE_VERSION" == "$VERSION" ]]; then
        echo "当前已是最新版本：$VERSION"
    else
        echo "当前版本 $VERSION 高于远端版本 $UPDATE_REMOTE_VERSION，不执行降级"
    fi
    echo "更新源：$UPDATE_USED_URL"
    cleanup_update_temp
}

update_script() {
    local target_dir staged
    if [[ $EUID -ne 0 ]]; then
        echo "更新脚本必须使用 root，例如：sudo $0 --update" >&2
        return 2
    fi
    [[ "$UPDATE_TARGET" == /* ]] || {
        echo "UPDATE_TARGET 必须是绝对路径：$UPDATE_TARGET" >&2
        return 2
    }

    prepare_update_candidate || return $?
    if [[ "$UPDATE_REMOTE_VERSION" == "$VERSION" ]]; then
        echo "当前已是最新版本：$VERSION"
        cleanup_update_temp
        return 0
    fi
    if ! version_is_newer "$UPDATE_REMOTE_VERSION" "$VERSION"; then
        echo "当前版本 $VERSION 高于远端版本 $UPDATE_REMOTE_VERSION，拒绝降级"
        cleanup_update_temp
        return 0
    fi

    target_dir="$(dirname "$UPDATE_TARGET")"
    mkdir -p "$target_dir" || { cleanup_update_temp; return 2; }
    staged="$target_dir/.disk-status-check.new.$$"
    if ! install -m 0755 "$UPDATE_CANDIDATE" "$staged"; then
        cleanup_update_temp
        return 2
    fi
    if ! mv -f -- "$staged" "$UPDATE_TARGET"; then
        rm -f -- "$staged"
        cleanup_update_temp
        return 2
    fi

    echo "更新完成：$VERSION -> $UPDATE_REMOTE_VERSION"
    echo "安装位置：$UPDATE_TARGET"
    echo "更新源：$UPDATE_USED_URL"
    cleanup_update_temp
}

install_storcli_rpm() {
    local tmp_dir rpm_file
    tmp_dir="$(mktemp -d /tmp/disk-check-storcli.XXXXXX)" || return 1
    rpm_file="$tmp_dir/storcli.rpm"
    echo "下载 storcli：$STORCLI_RPM_URL"
    if ! download_file "$STORCLI_RPM_URL" "$rpm_file"; then
        rm -rf -- "$tmp_dir"
        return 1
    fi
    rpm -Uvh --replacepkgs "$rpm_file"
    local rc=$?
    rm -rf -- "$tmp_dir"
    return "$rc"
}

install_storcli_debian() {
    local tmp_dir package binary rc=0
    tmp_dir="$(mktemp -d /tmp/disk-check-storcli.XXXXXX)" || return 1

    if [[ -n "$STORCLI_DEB_URL" ]]; then
        package="$tmp_dir/storcli.deb"
        echo "下载 storcli DEB：$STORCLI_DEB_URL"
        download_file "$STORCLI_DEB_URL" "$package" && dpkg -i "$package" || rc=$?
    elif [[ -n "$STORCLI_ZIP_URL" ]]; then
        echo "下载 Broadcom Unified StorCLI：$STORCLI_ZIP_URL"
        apt-get install -y unzip || rc=$?
        if ((rc == 0)); then
            download_file "$STORCLI_ZIP_URL" "$tmp_dir/storcli.zip" || rc=$?
        fi
        if ((rc == 0)); then
            unzip -q "$tmp_dir/storcli.zip" -d "$tmp_dir/unpacked" || rc=$?
        fi
        if ((rc == 0)); then
            package="$(find "$tmp_dir/unpacked" -type f -iname 'storcli*.deb' -print -quit)"
            if [[ -z "$package" ]]; then
                echo "Unified ZIP 中没有找到 storcli*.deb" >&2
                rc=1
            else
                dpkg -i "$package" || rc=$?
            fi
        fi
    else
        # Broadcom's noarch RPM contains the userspace storcli64 binary.  On
        # Debian extract it instead of registering an RPM in dpkg's database.
        echo "未指定 DEB/ZIP，正在从 noarch RPM 提取 storcli64"
        apt-get install -y rpm2cpio cpio || rc=$?
        if ((rc == 0)); then
            download_file "$STORCLI_RPM_URL" "$tmp_dir/storcli.rpm" || rc=$?
        fi
        if ((rc == 0)); then
            mkdir -p "$tmp_dir/unpacked"
            (cd "$tmp_dir/unpacked" && rpm2cpio "$tmp_dir/storcli.rpm" | cpio -idm --quiet) || rc=$?
        fi
        if ((rc == 0)); then
            binary="$(find "$tmp_dir/unpacked" -type f \( -name storcli64 -o -name storcli \) -print -quit)"
            if [[ -z "$binary" ]]; then
                echo "RPM 中没有找到 storcli64" >&2
                rc=1
            else
                install -m 0755 "$binary" /usr/local/sbin/storcli64 || rc=$?
            fi
        fi
    fi

    rm -rf -- "$tmp_dir"
    return "$rc"
}

install_dependencies() {
    local family pm failed=0
    if [[ $EUID -ne 0 ]]; then
        echo "安装依赖必须使用 root（例如 sudo $0 --install）" >&2
        return 2
    fi

    detect_os
    family="$OS_ID $OS_LIKE"
    echo "系统：$OS_NAME"

    if [[ "$family" =~ (debian|ubuntu) ]]; then
        apt-get update || return 2
        DEBIAN_FRONTEND=noninteractive apt-get install -y smartmontools pciutils curl ca-certificates || return 2
        DEBIAN_FRONTEND=noninteractive apt-get install -y nvme-cli || {
            echo "警告：nvme-cli 安装失败；无 NVMe 设备时可忽略" >&2
            failed=1
        }
    elif [[ "$family" =~ (centos|rhel|fedora|rocky|almalinux) ]]; then
        if have dnf; then pm=dnf; elif have yum; then pm=yum; else
            echo "找不到 dnf/yum" >&2
            return 2
        fi
        "$pm" install -y smartmontools pciutils curl ca-certificates || return 2
        "$pm" install -y nvme-cli || {
            echo "警告：nvme-cli 安装失败；无 NVMe 设备时可忽略" >&2
            failed=1
        }
    else
        echo "暂不支持自动安装：$OS_NAME" >&2
        return 2
    fi

    if has_megaraid; then
        echo "检测到 Broadcom/LSI RAID 控制器。"
        if find_storcli >/dev/null; then
            echo "storcli 已安装：$(find_storcli)"
        elif [[ "$family" =~ (debian|ubuntu) ]]; then
            install_storcli_debian || {
                echo "storcli 安装失败" >&2
                failed=1
            }
        else
            install_storcli_rpm || {
                echo "storcli 安装失败" >&2
                failed=1
            }
        fi
    else
        echo "未检测到 Broadcom/LSI MegaRAID，不安装 storcli。"
    fi

    if ((failed)); then return 2; fi
    echo "依赖安装完成。可执行：$0 --check"
    return 0
}

check_software_raid() {
    local mdstat status_lines
    if [[ ! -r /proc/mdstat ]]; then
        info "软件 RAID：/proc/mdstat 不可读"
        return
    fi
    mdstat="$(< /proc/mdstat)"
    if ! grep -Eq '^md[0-9_]+' <<<"$mdstat"; then
        info "软件 RAID：未发现 md 阵列"
        return
    fi

    while IFS= read -r status_lines; do
        [[ -n "$status_lines" ]] && info "软件 RAID：$status_lines"
    done < <(grep -E '^md[0-9_]+' <<<"$mdstat" || true)

    if grep -Eq '\[[U_]*_[U_]*\]' <<<"$mdstat"; then
        error "软件 RAID 存在掉盘：成员状态包含下划线"
    elif grep -Eiq '^md.*inactive' <<<"$mdstat"; then
        error "软件 RAID 处于 inactive 状态"
    else
        ok "软件 RAID 成员状态正常"
    fi

    if grep -Eiq 'recovery|resync|reshape|check[[:space:]]*=' <<<"$mdstat"; then
        local progress
        progress="$(grep -Ei 'recovery|resync|reshape|check[[:space:]]*=' <<<"$mdstat" | sed -E 's/^[[:space:]]+//' | head -n 1)"
        warn "软件 RAID 正在执行后台任务：$progress"
    fi
}

check_storcli() {
    local cli output rc controllers pci controller_output vd_output vd_detail_output pd_output
    pci="$(raid_pci_lines)"
    if [[ -z "$pci" ]]; then
        info "硬件 RAID：未发现 PCI RAID 控制器"
        return
    fi
    while IFS= read -r line; do info "RAID 控制器：$line"; done <<<"$pci"

    if ! has_megaraid; then
        warn "发现非 Broadcom/LSI RAID 控制器，当前脚本无法读取其后端物理盘状态"
        return
    fi
    if ! cli="$(find_storcli)"; then
        error "检测到 MegaRAID，但 storcli 未安装；请先运行 --install"
        return
    fi

    output="$("$cli" show nolog 2>&1)"
    rc=$?
    if ((rc != 0)); then
        error "storcli 执行失败（rc=$rc）：$(tail -n 1 <<<"$output")"
        return
    fi
    controllers="$(awk -F= '/Number of Controllers/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' <<<"$output")"
    if ! is_uint "$controllers"; then
        controllers="$(awk '$1 ~ /^[0-9]+$/ {n++} END {print n+0}' <<<"$output")"
    fi
    if ((controllers == 0)); then
        error "PCI 上存在 MegaRAID，但 storcli 未识别到控制器"
        return
    fi
    info "storcli：$cli，共识别 $controllers 个控制器"

    local c state row bad_count os_drive
    for ((c = 0; c < controllers; c++)); do
        controller_output="$("$cli" /c$c show nolog 2>&1)"
        rc=$?
        if ((rc != 0)) || grep -Eiq 'Status[[:space:]]*=[[:space:]]*(Failure|Failed)' <<<"$controller_output"; then
            error "RAID /c$c 查询失败"
            continue
        fi
        if grep -Eiq '(Controller Status|Health)[[:space:]]*=[[:space:]]*(Degraded|Failed|Critical|Offline|Not Optimal)' <<<"$controller_output"; then
            error "RAID /c$c 控制器状态异常"
        else
            ok "RAID /c$c 控制器可访问"
        fi

        vd_output="$("$cli" /c$c/vall show nolog 2>&1)"
        rc=$?
        if ((rc != 0)); then
            error "RAID /c$c 虚拟盘查询失败"
        else
            bad_count=0
            while IFS= read -r row; do
                [[ -z "$row" ]] && continue
                state="$(awk '{print $3}' <<<"$row")"
                info "RAID 虚拟盘：$row"
                if [[ "$state" != "Optl" && "$state" != "Optimal" ]]; then
                    error "RAID 虚拟盘异常：$(awk '{print $1 " 状态=" $3}' <<<"$row")"
                    ((bad_count += 1))
                fi
            done < <(awk '$1 ~ /^[0-9]+\/[0-9]+$/ {print}' <<<"$vd_output")
            ((bad_count == 0)) && ok "RAID /c$c 所有虚拟盘均为 Optimal"
        fi

        # StorCLI can expose the Linux block-device name for each virtual
        # drive. Remember it so the OS disk pass does not treat the virtual
        # disk as a directly attached SMART-capable physical disk.
        vd_detail_output="$("$cli" /c$c/vall show all nolog 2>&1)"
        if (($? == 0)); then
            while IFS= read -r os_drive; do
                [[ "$os_drive" == /dev/* ]] || continue
                MEGARAID_VIRTUAL_DISKS["$os_drive"]=1
                info "MegaRAID 虚拟盘映射：$os_drive"
            done < <(awk -F= '/^[[:space:]]*OS Drive Name[[:space:]]*=/ {
                sub(/^[^=]*=[[:space:]]*/, "", $0)
                sub(/[[:space:]]+$/, "", $0)
                print $0
            }' <<<"$vd_detail_output")
        fi

        pd_output="$("$cli" /c$c/eall/sall show nolog 2>&1)"
        rc=$?
        if ((rc != 0)); then
            error "RAID /c$c 物理盘查询失败"
        else
            bad_count=0
            while IFS= read -r row; do
                [[ -z "$row" ]] && continue
                state="$(awk '{print $3}' <<<"$row")"
                info "RAID 物理盘：$row"
                case "$state" in
                    Onln|UGood|GHS|DHS|JBOD) ;;
                    Rbld|Cpybck|Shld)
                        warn "RAID 物理盘正在后台处理：$(awk '{print $1 " 状态=" $3}' <<<"$row")"
                        ((bad_count += 1))
                        ;;
                    *)
                        error "RAID 物理盘异常：$(awk '{print $1 " 状态=" $3}' <<<"$row")"
                        ((bad_count += 1))
                        ;;
                esac
            done < <(awk '$1 ~ /^[0-9]+:[0-9]+$/ {print}' <<<"$pd_output")
            ((bad_count == 0)) && ok "RAID /c$c 所有物理盘状态正常"
        fi

        if grep -Eiq '(BBU|Battery|CacheVault).*(Failed|Degraded|Critical|Missing|Not Optimal)' <<<"$controller_output"; then
            error "RAID /c$c 缓存保护单元（BBU/CacheVault）异常"
        fi
    done
}

smart_attribute_raw() {
    local text="$1" id="$2"
    awk -v wanted="$id" '$1 == wanted {print $NF; exit}' <<<"$text"
}

check_smart_disk() {
    local dev="$1" output rc health attr value temp bad=0
    output="$(smartctl -H -A "$dev" 2>&1)"
    rc=$?
    health="$(grep -Ei 'SMART overall-health.*:|SMART Health Status:' <<<"$output" | tail -n 1 || true)"

    if grep -Eiq 'DELL or MegaRaid controller|try adding.*-d[[:space:]]+megaraid' <<<"$output"; then
        info "$dev 是 MegaRAID 虚拟盘，普通 SMART 不适用（物理盘状态由 storcli 检查）"
        return
    elif grep -Eiq '(FAILED|BAD|FAILING)' <<<"$health" || ((rc & 8)); then
        error "$dev SMART 健康检查失败：${health:-smartctl rc=$rc}"
        bad=1
    elif grep -Eiq '(PASSED|OK)' <<<"$health"; then
        ok "$dev SMART 健康状态正常"
    elif grep -Eiq 'unsupported|unknown usb bridge|scsi error unsupported' <<<"$output"; then
        info "$dev 不支持直接读取 SMART（可能是 RAID 虚拟盘或 USB 桥接盘）"
        return
    elif ((rc & 1 || rc & 2)); then
        warn "$dev 无法完整读取 SMART：$(tail -n 1 <<<"$output")"
        return
    else
        warn "$dev 未返回可识别的 SMART 健康状态"
    fi

    for attr in 5 187 197 198; do
        value="$(smart_attribute_raw "$output" "$attr")"
        if is_uint "$value" && ((value > 0)); then
            error "$dev SMART 属性 $attr 的原始值为 $value"
            bad=1
        fi
    done

    temp="$(awk '$1 == 190 || $1 == 194 {print $10; exit}' <<<"$output")"
    if is_uint "$temp"; then
        info "$dev 温度 ${temp}°C"
        if ((temp >= SATA_TEMP_WARN)); then
            warn "$dev 温度过高：${temp}°C（阈值 ${SATA_TEMP_WARN}°C）"
        fi
    fi
    ((bad == 0)) || true
}

check_nvme_controller() {
    local dev="$1" output rc critical temp spare threshold used media
    output="$(nvme smart-log "$dev" 2>&1)"
    rc=$?
    if ((rc != 0)); then
        error "$dev NVMe SMART 读取失败：$(tail -n 1 <<<"$output")"
        return
    fi

    critical="$(awk -F: '/^[[:space:]]*critical_warning[[:space:]]*:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' <<<"$output")"
    temp="$(awk -F: '/^[[:space:]]*temperature[[:space:]]*:/ {gsub(/^[[:space:]]*/, "", $2); print $2; exit}' <<<"$output" | awk '{print $1}')"
    spare="$(awk -F: '/^[[:space:]]*available_spare[[:space:]]*:/ {gsub(/[^0-9]/, "", $2); print $2; exit}' <<<"$output")"
    threshold="$(awk -F: '/^[[:space:]]*available_spare_threshold[[:space:]]*:/ {gsub(/[^0-9]/, "", $2); print $2; exit}' <<<"$output")"
    used="$(awk -F: '/^[[:space:]]*percentage_used[[:space:]]*:/ {gsub(/[^0-9]/, "", $2); print $2; exit}' <<<"$output")"
    media="$(awk -F: '/^[[:space:]]*media_errors[[:space:]]*:/ {gsub(/[,.[:space:]]/, "", $2); print $2; exit}' <<<"$output")"

    if [[ "$critical" =~ ^(0|0x0+)$ ]]; then
        ok "$dev NVMe critical_warning=0"
    else
        error "$dev NVMe critical_warning=${critical:-未知}"
    fi

    if is_uint "$temp"; then
        ((temp > 200)) && temp=$((temp - 273))
        info "$dev 温度 ${temp}°C"
        ((temp >= NVME_TEMP_WARN)) && warn "$dev 温度过高：${temp}°C（阈值 ${NVME_TEMP_WARN}°C）"
    fi
    if is_uint "$spare" && is_uint "$threshold"; then
        info "$dev 可用备用空间 ${spare}%（阈值 ${threshold}%）"
        ((spare < threshold)) && error "$dev NVMe 可用备用空间低于阈值"
    fi
    if is_uint "$used"; then
        info "$dev 寿命已使用 ${used}%"
        ((used >= NVME_PERCENT_USED_WARN)) && warn "$dev NVMe 估算寿命已用 ${used}%"
    fi
    if is_uint "$media"; then
        ((media > 0)) && error "$dev NVMe media_errors=$media" || ok "$dev NVMe 无介质错误"
    fi
}

check_os_visible_disks() {
    local -a disks=() nvme_controllers=()
    local dev name ctrl seen=" "
    if ! have lsblk; then
        error "缺少 lsblk，无法枚举系统磁盘"
        return
    fi
    mapfile -t disks < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2 == "disk" {print "/dev/" $1}')
    if ((${#disks[@]} == 0)); then
        error "lsblk 未发现任何磁盘"
        return
    fi
    info "系统可见磁盘：${disks[*]}"

    for dev in "${disks[@]}"; do
        name="${dev#/dev/}"
        if [[ "$name" =~ ^(nvme[0-9]+) ]]; then
            ctrl="/dev/${BASH_REMATCH[1]}"
            if [[ "$seen" != *" $ctrl "* ]]; then
                nvme_controllers+=("$ctrl")
                seen+="$ctrl "
            fi
        elif [[ "${MEGARAID_VIRTUAL_DISKS[$dev]:-}" == "1" ]]; then
            info "$dev 是 MegaRAID 虚拟盘，跳过普通 SMART（物理盘状态由 storcli 检查）"
        elif have smartctl; then
            check_smart_disk "$dev"
        else
            error "缺少 smartctl，无法检查 $dev；请运行 --install"
        fi
    done

    for ctrl in "${nvme_controllers[@]}"; do
        if have nvme; then
            check_nvme_controller "$ctrl"
        elif have smartctl; then
            warn "缺少 nvme-cli，使用 smartctl 兼容模式检查 $ctrl"
            check_smart_disk "$ctrl"
        else
            error "缺少 nvme-cli 和 smartctl，无法检查 $ctrl"
        fi
    done
}

json_escape() {
    local text="$1"
    text=${text//\\/\\\\}
    text=${text//\"/\\\"}
    text=${text//$'\r'/}
    text=${text//$'\n'/\\n}
    printf '%s' "$text"
}

send_wecom() {
    local content="$1" escaped response
    escaped="$(json_escape "$content")"
    response="$(curl -sS --connect-timeout 8 --max-time 15 \
        -H 'Content-Type: application/json' \
        --data-binary "{\"msgtype\":\"markdown\",\"markdown\":{\"content\":\"$escaped\"}}" \
        "$WECOM_WEBHOOK_URL" 2>&1)" || {
        echo "企业微信推送失败：$response" >&2
        return 1
    }
    if ! grep -Eq '"errcode"[[:space:]]*:[[:space:]]*0' <<<"$response"; then
        echo "企业微信返回失败：$response" >&2
        return 1
    fi
}

build_alert_text() {
    local title="$1" message line
    message="### $title"$'\n'
    message+="> 主机：$(display_hostname)"$'\n'
    message+="> 时间：$(date '+%F %T %z')"$'\n'
    message+="> 系统：$OS_NAME"$'\n\n'
    for line in "${ERROR_MESSAGES[@]}"; do message+="- <font color=\"warning\">严重：$line</font>"$'\n'; done
    for line in "${WARN_MESSAGES[@]}"; do message+="- <font color=\"comment\">警告：$line</font>"$'\n'; done
    if ((${#ERROR_MESSAGES[@]} == 0 && ${#WARN_MESSAGES[@]} == 0)); then
        message+="- <font color=\"info\">正常：所有已检测项目均正常</font>"$'\n'
    fi
    printf '%s' "${message:0:3800}"
}

notify_if_needed() {
    local now hash old_hash="" old_time=0 old_status="ok" current status content debug_title state_should_write=0
    NOTIFY_FAILED=0
    status="ok"
    current=""
    if ((${#ERROR_MESSAGES[@]} > 0 || ${#WARN_MESSAGES[@]} > 0)); then
        status="alert"
        if ((${#ERROR_MESSAGES[@]} > 0)); then
            current+="$(printf 'ERROR:%s\n' "${ERROR_MESSAGES[@]}")"
        fi
        if ((${#WARN_MESSAGES[@]} > 0)); then
            current+="$(printf 'WARN:%s\n' "${WARN_MESSAGES[@]}")"
        fi
    fi
    hash="$(printf '%s' "$current" | sha256sum | awk '{print $1}')"
    now="$(date +%s)"

    if [[ -r "$STATE_FILE" ]]; then
        IFS='|' read -r old_hash old_time old_status < "$STATE_FILE" || true
        is_uint "$old_time" || old_time=0
    fi

    if ((NOTIFY == 0)); then
        info "企业微信通知已禁用"
    elif [[ -z "$WECOM_WEBHOOK_URL" ]]; then
        if ((DEBUG_NOTIFY)); then
            warn "DEBUG 模式已启用，但未配置企业微信 Webhook"
        else
            info "未配置企业微信 Webhook，本次不推送"
        fi
    elif ((DEBUG_NOTIFY)); then
        if [[ "$status" == "alert" ]]; then
            debug_title="磁盘监控 DEBUG（存在告警）"
        else
            debug_title="磁盘监控 DEBUG（状态正常）"
        fi
        content="$(build_alert_text "$debug_title")"
        if send_wecom "$content"; then
            info "DEBUG 模式：已强制推送企业微信"
        else
            NOTIFY_FAILED=1
        fi
    elif [[ "$status" == "alert" ]]; then
        if [[ "$hash" != "$old_hash" ]] || ((now - old_time >= NOTIFY_COOLDOWN)); then
            content="$(build_alert_text "磁盘监控告警")"
            if send_wecom "$content"; then
                state_should_write=1
            else
                NOTIFY_FAILED=1
            fi
        else
            info "告警未变化且仍在冷却期内，不重复推送"
        fi
    else
        info "检测结果无警告/异常，不推送企业微信"
        # Record a recovery once so the same alert will notify immediately
        # if it appears again. Repeated healthy checks do not refresh state.
        [[ "$old_status" != "ok" ]] && state_should_write=1
    fi

    # Debug pushes do not alter production alert-deduplication state. Most
    # importantly, a suppressed alert must retain the last successful send
    # time; otherwise a frequent cron job creates a sliding cooldown forever.
    if ((state_should_write)) && [[ -n "$STATE_FILE" && -n "$WECOM_WEBHOOK_URL" &&
          $NOTIFY -eq 1 && $DEBUG_NOTIFY -eq 0 && $NOTIFY_FAILED -eq 0 ]]; then
        umask 077
        printf '%s|%s|%s\n' "$hash" "$now" "$status" > "$STATE_FILE" 2>/dev/null || true
    fi
}

print_report() {
    local line
    echo "============================================================"
    echo "磁盘健康检测  v$VERSION"
    echo "主机：$(hostname -f 2>/dev/null || hostname)"
    echo "时间：$(date '+%F %T %z')"
    echo "系统：$OS_NAME"
    echo "============================================================"
    for line in "${INFO_MESSAGES[@]}"; do echo "[信息] $line"; done
    for line in "${OK_MESSAGES[@]}"; do echo "[正常] $line"; done
    for line in "${WARN_MESSAGES[@]}"; do echo "[警告] $line"; done
    for line in "${ERROR_MESSAGES[@]}"; do echo "[异常] $line"; done
    echo "------------------------------------------------------------"
    echo "汇总：正常 ${#OK_MESSAGES[@]}，警告 ${#WARN_MESSAGES[@]}，异常 ${#ERROR_MESSAGES[@]}"
}

main_check() {
    if [[ $EUID -ne 0 ]]; then
        warn "当前不是 root，部分 SMART/RAID 信息可能无法读取"
    fi
    detect_os
    check_storcli
    check_software_raid
    check_os_visible_disks
    notify_if_needed
    print_report

    if ((NOTIFY_FAILED)); then return 2; fi
    if ((${#WARN_MESSAGES[@]} > 0 || ${#ERROR_MESSAGES[@]} > 0)); then return 1; fi
    return 0
}

case "$MODE" in
    install) install_dependencies ;;
    check-update) check_update ;;
    update) update_script ;;
    *) main_check ;;
esac

