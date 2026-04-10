#!/bin/bash
#
# SR-IOV 自动化配置脚本
# 从 ini 配置读取全局参数和多网卡 VF 配置，依次完成创建、MAC 设置和调优

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG_PATH="/etc/sriov_vf/config.ini"
LOCAL_CONFIG_PATH="$SCRIPT_DIR/config.ini"
CONFIG_PATH="${SRIOV_VF_CONFIG:-$DEFAULT_CONFIG_PATH}"

if [ ! -f "$CONFIG_PATH" ] && [ -f "$LOCAL_CONFIG_PATH" ]; then
    CONFIG_PATH="$LOCAL_CONFIG_PATH"
fi

DEFAULT_CPU_GOVERNOR="powersave"
DEFAULT_RING_TX="4096"
DEFAULT_RING_RX="4096"
DEFAULT_PF_COMBINED="4"
DEFAULT_VF_COMBINED="2"

# 去掉字符串首尾空白，兼容 ini 中带空格的写法。
trim() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

# 去掉配置值两侧可能存在的单双引号。
strip_quotes() {
    local value

    value="$(trim "$1")"
    if [[ "$value" =~ ^\".*\"$ ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "$value" =~ ^\'.*\'$ ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s\n' "$value"
}

# 输出普通执行日志，便于 systemd journal 查看处理进度。
log_info() {
    echo "[INFO] $*"
}

# 输出告警日志。单块网卡失败时尽量只跳过当前块，不影响整体退出。
log_warn() {
    echo "[WARN] $*" >&2
}

# 确保配置文件存在，否则直接失败退出。
require_config_file() {
    if [ ! -f "$CONFIG_PATH" ]; then
        echo "[ERROR] 配置文件不存在: $CONFIG_PATH" >&2
        exit 1
    fi
}

# 读取 [global] 段中的指定 key。
get_global_value() {
    local key="$1"

    awk -F= -v target_key="$key" '
        /^[[:space:]]*\[global\][[:space:]]*$/ {
            in_global = 1
            next
        }
        in_global && /^[[:space:]]*\[.*\][[:space:]]*$/ {
            exit
        }
        in_global && $0 ~ "^[[:space:]]*" target_key "[[:space:]]*=" {
            value = $0
            sub(/^[^=]*=[[:space:]]*/, "", value)
            print value
            exit
        }
    ' "$CONFIG_PATH"
}

# 解析所有 [vf.N] 段，输出为 TAB 分隔字段，供主循环逐条处理。
load_vf_configs() {
    awk '
        function flush_section() {
            if (!in_vf) {
                return
            }
            print vf_id "\t" iface "\t" vf_count "\t" tuned "\t" base_mac
        }
        function reset_section() {
            in_vf = 0
            vf_id = ""
            iface = ""
            vf_count = ""
            tuned = ""
            base_mac = ""
        }
        BEGIN {
            reset_section()
        }
        /^[[:space:]]*\[.*\][[:space:]]*$/ {
            if (in_vf) {
                flush_section()
            }
            reset_section()

            if ($0 ~ /^[[:space:]]*\[vf\.[0-9]+\][[:space:]]*$/) {
                in_vf = 1
                vf_id = $0
                gsub(/^[[:space:]]*\[vf\./, "", vf_id)
                gsub(/\][[:space:]]*$/, "", vf_id)
            }
            next
        }
        !in_vf {
            next
        }
        {
            if ($0 ~ /^[[:space:]]*iface[[:space:]]*=/) {
                iface = $0
                sub(/^[[:space:]]*iface[[:space:]]*=[[:space:]]*/, "", iface)
            } else if ($0 ~ /^[[:space:]]*vf_count[[:space:]]*=/) {
                vf_count = $0
                sub(/^[[:space:]]*vf_count[[:space:]]*=[[:space:]]*/, "", vf_count)
            } else if ($0 ~ /^[[:space:]]*tuned[[:space:]]*=/) {
                tuned = $0
                sub(/^[[:space:]]*tuned[[:space:]]*=[[:space:]]*/, "", tuned)
            } else if ($0 ~ /^[[:space:]]*base_mac[[:space:]]*=/) {
                base_mac = $0
                sub(/^[[:space:]]*base_mac[[:space:]]*=[[:space:]]*/, "", base_mac)
            }
        }
        END {
            if (in_vf) {
                flush_section()
            }
        }
    ' "$CONFIG_PATH"
}

# 根据基础 MAC 为指定 VF 序号生成最终 MAC，保持原脚本的递增规则。
mac_with_suffix() {
    local base_mac="$1"
    local vf_index="$2"
    local mac_suffix

    mac_suffix="$(printf '%02x' $((vf_index + 1)))"
    printf '%s:%s\n' "${base_mac%:*}" "$mac_suffix"
}

# 写入 sriov_numvfs；若当前已有 VF，先清零再按目标值重建，避免重复执行时报错。
set_sriov_numvfs() {
    local iface="$1"
    local vf_count="$2"
    local sriov_numvfs_path="/sys/class/net/$iface/device/sriov_numvfs"
    local current_vfs

    if [ ! -w "$sriov_numvfs_path" ]; then
        log_warn "网卡 $iface 无法写入 sriov_numvfs，跳过"
        return 1
    fi

    current_vfs="$(cat "$sriov_numvfs_path")"
    if [ "$current_vfs" = "$vf_count" ]; then
        return 0
    fi

    if [ "$current_vfs" -ne 0 ]; then
        echo 0 > "$sriov_numvfs_path"
    fi
    echo "$vf_count" > "$sriov_numvfs_path"
}

# 等待 VF 网卡节点出现，保持和原脚本一致的重试节奏。
wait_for_vf_device() {
    local vf_dev="$1"
    local attempt

    for attempt in {1..8}; do
        if ip link show "$vf_dev" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.2
    done

    return 1
}

# 针对单块网卡执行完整 SR-IOV 配置流程，环节顺序与原始脚本保持一致。
configure_single_iface() {
    local vf_id="$1"
    local iface="$2"
    local vf_count="$3"
    local tuned="$4"
    local base_mac="$5"
    local vf_index
    local vf_dev
    local new_mac

    if [ ! -d "/sys/class/net/$iface" ]; then
        log_warn "配置 [vf.$vf_id] 的网卡 $iface 不存在，跳过"
        return 0
    fi

    if [ ! -r "/sys/class/net/$iface/device/sriov_totalvfs" ]; then
        log_warn "网卡 $iface 不支持 SR-IOV 或无法读取 sriov_totalvfs，跳过"
        return 0
    fi

    log_info "开始配置 [vf.$vf_id] 网卡 $iface，VF 数量: $vf_count，调优: $tuned"

    ### 2. 创建指定数量的 VF
    set_sriov_numvfs "$iface" "$vf_count" || return 0

    ### 3. 为 VF 设置 MAC 地址，增加等待确保 VF 已生成
    for ((vf_index = 0; vf_index < vf_count; vf_index++)); do
        vf_dev="${iface}v${vf_index}"
        if wait_for_vf_device "$vf_dev"; then
            new_mac="$(mac_with_suffix "$base_mac" "$vf_index")"
            ip link set "$iface" vf "$vf_index" mac "$new_mac"
        else
            log_warn "VF $vf_dev 未生成，跳过 MAC 设置"
        fi
    done

    ### 4. 启动物理口和 VF
    ip link set "$iface" up
    for ((vf_index = 0; vf_index < vf_count; vf_index++)); do
        ip link set "${iface}v${vf_index}" up || true
    done

    if [ "$tuned" = "true" ]; then
        ### 5. 调整 ring buffer 大小
        ethtool -G "$iface" tx "$DEFAULT_RING_TX" rx "$DEFAULT_RING_RX" || true
        for ((vf_index = 0; vf_index < vf_count; vf_index++)); do
            ethtool -G "${iface}v${vf_index}" tx "$DEFAULT_RING_TX" rx "$DEFAULT_RING_RX" || true
        done

        ### 6. 调整队列数量
        ethtool -L "$iface" combined "$DEFAULT_PF_COMBINED" || true
        for ((vf_index = 0; vf_index < vf_count; vf_index++)); do
            ethtool -L "${iface}v${vf_index}" combined "$DEFAULT_VF_COMBINED" || true
        done
    fi

    ### 7. 可选：开启混杂模式（抓包或桥接才需要）
    # ip link set "$iface" promisc on

    log_info "[vf.$vf_id] 网卡 $iface 配置完成"
}

# 主流程：先处理全局配置，再按 ini 中的 [vf.N] 顺序依次配置网卡。
main() {
    local cpu_governor
    local vf_records=()
    local record
    local vf_id
    local iface
    local vf_count
    local tuned
    local base_mac

    require_config_file

    ### 1. 设置 CPU 调度器模式
    cpu_governor="$(strip_quotes "$(get_global_value "cpu_governor")")"
    cpu_governor="${cpu_governor:-$DEFAULT_CPU_GOVERNOR}"
    cpupower -c all frequency-set -g "$cpu_governor" || true
    log_info "CPU governor 已设置为 $cpu_governor"

    mapfile -t vf_records < <(load_vf_configs)
    if [ ${#vf_records[@]} -eq 0 ]; then
        log_warn "配置文件中没有 [vf.N] 配置，未执行网卡配置"
        exit 0
    fi

    for record in "${vf_records[@]}"; do
        IFS=$'\t' read -r vf_id iface vf_count tuned base_mac <<< "$record"

        iface="$(strip_quotes "$iface")"
        vf_count="$(strip_quotes "$vf_count")"
        tuned="$(strip_quotes "$tuned")"
        base_mac="$(strip_quotes "$base_mac")"

        if [ -z "$iface" ] || [ -z "$vf_count" ] || [ -z "$base_mac" ]; then
            log_warn "[vf.$vf_id] 配置不完整，跳过"
            continue
        fi

        if ! [[ "$vf_count" =~ ^[0-9]+$ ]] || [ "$vf_count" -lt 1 ]; then
            log_warn "[vf.$vf_id] 的 vf_count 无效: $vf_count，跳过"
            continue
        fi

        case "${tuned,,}" in
            true|yes)
                tuned="true"
                ;;
            false|no|"")
                tuned="false"
                ;;
            *)
                log_warn "[vf.$vf_id] 的 tuned 无效: $tuned，按 false 处理"
                tuned="false"
                ;;
        esac

        configure_single_iface "$vf_id" "$iface" "$vf_count" "$tuned" "$base_mac"
    done

    log_info "SR-IOV 配置完成"
    exit 0
}

main "$@"
