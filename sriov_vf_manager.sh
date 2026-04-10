#!/bin/bash
set -e

# 安装目标目录
CONFIG_DIR="/etc/sriov_vf"
BIN_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

# 安装时涉及的文件名
CONFIG_FILE_NAME="config.ini"
SCRIPT_FILE_NAME="sriov_vf.sh"
SERVICE_FILE_NAME="sriov_vf.service"

# 安装后的完整路径
CONFIG_PATH="$CONFIG_DIR/$CONFIG_FILE_NAME"
SCRIPT_PATH="$BIN_DIR/$SCRIPT_FILE_NAME"
SERVICE_PATH="$SYSTEMD_DIR/$SERVICE_FILE_NAME"
SERVICE_NAME="$SERVICE_FILE_NAME"

# 安装清单：源文件名|目标目录|目标路径|权限
INSTALL_ITEMS=(
    "$CONFIG_FILE_NAME|$CONFIG_DIR|$CONFIG_PATH|644"
    "$SCRIPT_FILE_NAME|$BIN_DIR|$SCRIPT_PATH|755"
    "$SERVICE_FILE_NAME|$SYSTEMD_DIR|$SERVICE_PATH|644"
)

# 运行脚本依赖的软件包
PACKAGE_ITEMS=(
    "ethtool"
    "lshw"
    "linux-cpupower"
)

# 全局配置默认值
GLOBAL_CPU_GOVERNOR_DEFAULT="powersave"

# 结构化全局配置询问项：
# 提示文本|变量名|可选项列表|默认值|确认方式(0|no|yes)
GLOBAL_CONFIG_ITEMS=(
    "请选择 CPU governor，用于 cpupower 设置|cpu_governor|powersave/schedutil|powersave|0"
)

BACK_SIGNAL="__BACK__"

# 结构化网卡配置询问项：
# 提示文本|变量名|可选项列表|默认值|确认方式(0|no|yes)
VF_SELECT_CONFIG_ITEMS=(
    "请选择网卡|iface|__IFACE_OPTIONS__||0"
)

VF_COMMON_CONFIG_ITEMS=(
    "请输入 VF 数量（当前网卡最多可创建 __VF_LIMIT__ 个）|vf_count||8|0"
    "是否启用调优|tuned|true/false|true|0"
    "设置MAC第一位防止冲突|base_mac_hander||00|0"
    "请输入基础 MAC|base_mac||__BASE_MAC_DEFAULT__|0"
)

# ========================
# 工具函数
# ========================
# 要求以 root 运行，避免安装和 systemd 操作失败
require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "请使用 root 运行"
        exit 1
    fi
}

# 简单暂停，便于查看当前输出
pause() {
    read -p "按回车继续..."
}

# 主标题，同时负责清屏
header() {
    clear
    echo "=============================="
    echo "        SR-IOV 管理工具       "
    echo "=============================="
}

# 子页面标题：在主标题下显示当前功能名
subheader() {
    header
    echo "---- $1 ----"
}

# 使用 / 拼接数组，便于写入结构化可选项列表
join_by_slash() {
    local joined=""
    local item

    for item in "$@"; do
        if [ -z "$joined" ]; then
            joined="$item"
        else
            joined="$joined/$item"
        fi
    done

    printf '%s\n' "$joined"
}

# 检查并安装缺失依赖
install_packages() {
    local missing_packages=()
    local package_name

    for package_name in "${PACKAGE_ITEMS[@]}"; do
        if ! command -v "$package_name" >/dev/null 2>&1; then
            missing_packages+=("$package_name")
        fi
    done

    if [ ${#missing_packages[@]} -eq 0 ]; then
        echo "[*] 依赖软件已安装"
        return 0
    fi

    echo "[*] 正在安装依赖软件:"
    printf '    - %s\n' "${missing_packages[@]}"

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y "${missing_packages[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${missing_packages[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${missing_packages[@]}"
    else
        echo "[!] 未找到支持的包管理器，请手动安装以下软件:"
        printf '    - %s\n' "${missing_packages[@]}"
        return 1
    fi
}

# 根据用户输入决定是否卸载依赖
uninstall_packages() {
    local remove_choice

    read -r -p "是否同时卸载依赖软件 ${PACKAGE_ITEMS[*]}？[y/N]: " remove_choice
    subheader "卸载 SR-IOV 服务"
    case "$remove_choice" in
        y|Y|yes|YES)
            echo "[*] 正在卸载依赖软件:"
            printf '    - %s\n' "${PACKAGE_ITEMS[@]}"

            if command -v apt-get >/dev/null 2>&1; then
                apt-get remove -y "${PACKAGE_ITEMS[@]}"
            elif command -v dnf >/dev/null 2>&1; then
                dnf remove -y "${PACKAGE_ITEMS[@]}"
            elif command -v yum >/dev/null 2>&1; then
                yum remove -y "${PACKAGE_ITEMS[@]}"
            else
                echo "[!] 未找到支持的包管理器，请手动卸载以下软件:"
                printf '    - %s\n' "${PACKAGE_ITEMS[@]}"
                return 1
            fi
            ;;
        *)
            echo "[*] 保留依赖软件"
            ;;
    esac
}

# 首次使用时生成最小 ini 配置骨架
ensure_config_file() {
    if [ ! -f "$CONFIG_PATH" ]; then
        mkdir -p "$CONFIG_DIR"
        cat <<'EOF' > "$CONFIG_PATH"
; /etc/sriov_vf/config.ini
EOF
    fi
}

# 去掉配置值两侧可能存在的引号
strip_config_quotes() {
    local value="$1"

    if [[ "$value" =~ ^\".*\"$ ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "$value" =~ ^\'.*\'$ ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s\n' "$value"
}

# 校验 MAC 地址格式
is_valid_mac() {
    [[ "$1" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]
}

# 校验 MAC 单个字节格式
is_valid_mac_octet() {
    [[ "$1" =~ ^[[:xdigit:]]{2}$ ]]
}

# 按约定规则生成默认基础 MAC
get_default_base_mac() {
    local vf_id="$1"
    local base_mac_hander="${2:-00}"

    printf '%s:66:%02X:00:00:00\n' "$base_mac_hander" "$((vf_id + 1))"
}

# 读取网卡可创建的最大 VF 数量
get_iface_total_vfs() {
    local iface="$1"
    local total_vfs_path="/sys/class/net/$iface/device/sriov_totalvfs"
    local total_vfs

    if [ ! -r "$total_vfs_path" ]; then
        return 1
    fi

    total_vfs="$(cat "$total_vfs_path")"
    if ! [[ "$total_vfs" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    printf '%s\n' "$total_vfs"
}

# 获取可用于 SR-IOV 的物理网卡，排除 lo、虚拟网卡和 VF
get_available_physical_ifaces() {
    local iface
    local sysfs_path
    local businfo_ifaces=()

    if ! command -v lshw >/dev/null 2>&1; then
        echo "[!] 未找到 lshw，请先执行安装功能安装依赖" >&2
        return 1
    fi

    mapfile -t businfo_ifaces < <(lshw -c network -businfo 2>/dev/null | awk 'NR > 1 {print $2}' | sed '/^$/d')

    while read -r iface; do
        [ -n "$iface" ] || continue
        [ "$iface" = "lo" ] && continue
        [ -e "/sys/class/net/$iface" ] || continue

        sysfs_path="$(readlink -f "/sys/class/net/$iface")"
        [[ "$sysfs_path" == *"/devices/virtual/net/"* ]] && continue
        [ -L "/sys/class/net/$iface/device/physfn" ] && continue

        if printf '%s\n' "${businfo_ifaces[@]}" | grep -Fxq "$iface"; then
            printf '%s\n' "$iface"
        fi
    done < <(printf '%s\n' "${businfo_ifaces[@]}")
}

# 确保配置文件中存在 [global] 段
ensure_global_section() {
    ensure_config_file

    if ! grep -Eq '^[[:space:]]*\[global\][[:space:]]*$' "$CONFIG_PATH"; then
        if [ -s "$CONFIG_PATH" ]; then
            printf '\n' >> "$CONFIG_PATH"
        fi
        printf '[global]\n' >> "$CONFIG_PATH"
    fi
}

# 读取 [global] 段中的指定 key
get_global_config_value() {
    local key="$1"

    ensure_config_file

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

# 根据确认方式确认当前输入
confirm_input_value() {
    local page_title="$1"
    local prompt_text="$2"
    local value="$3"
    local confirm_mode="$4"
    local confirm_input

    case "$confirm_mode" in
        0)
            return 0
            ;;
        no)
            read -r -p "确认“$prompt_text”的输入值为 \"$value\"，请输入 no: " confirm_input
            subheader "$page_title"
            [ "$confirm_input" = "no" ]
            ;;
        yes)
            read -r -p "确认“$prompt_text”的输入值为 \"$value\"，请输入 yes: " confirm_input
            subheader "$page_title"
            [ "$confirm_input" = "yes" ]
            ;;
        *)
            return 0
            ;;
    esac
}

# 生成统一的提问提示文案
build_prompt_label() {
    local prompt_text="$1"
    local options_text="$2"
    local default_value="$3"
    local label="$prompt_text"

    if [ -n "$options_text" ]; then
        label="$label（可选值: $options_text"
        if [ -n "$default_value" ]; then
            label="$label，默认值: $default_value"
        fi
        label="$label）"
    elif [ -n "$default_value" ]; then
        label="$label（默认值: $default_value）"
    fi

    printf '%s\n' "$label"
}

# 写入变量，兼容全局和局部变量名
set_prompt_value() {
    local var_name="$1"
    local var_value="$2"

    printf -v "$var_name" '%s' "$var_value"
}

# 处理单个结构化询问项
prompt_config_item() {
    local page_title="$1"
    local prompt_text="$2"
    local var_name="$3"
    local options_text="$4"
    local default_value="$5"
    local confirm_mode="$6"
    local prompt_label
    local input_value
    local selected_index
    local option_items=()
    local option_index

    while true; do
        prompt_label="$(build_prompt_label "$prompt_text" "$options_text" "$default_value")"

        if [ -n "$options_text" ]; then
            IFS='/' read -r -a option_items <<< "$options_text"
            echo "[*] 可选项："
            for option_index in "${!option_items[@]}"; do
                printf "%d) %s\n" "$((option_index + 1))" "${option_items[$option_index]}"
            done
            echo "b) 返回"
            read -r -p "$prompt_label，请输入序号: " input_value
        else
            echo "b) 返回"
            read -r -p "$prompt_label: " input_value
        fi
        subheader "$page_title"

        if [ "$input_value" = "b" ] || [ "$input_value" = "B" ]; then
            return 1
        fi

        if [ -z "$input_value" ] && [ -n "$default_value" ]; then
            input_value="$default_value"
        fi

        if [ -n "$options_text" ]; then
            if [[ "$input_value" =~ ^[0-9]+$ ]]; then
                if [ "$input_value" -lt 1 ] || [ "$input_value" -gt "${#option_items[@]}" ]; then
                    echo "序号超出范围"
                    continue
                fi
                selected_index=$((input_value - 1))
                input_value="${option_items[$selected_index]}"
            else
                selected_index=-1
                for option_index in "${!option_items[@]}"; do
                    if [ "$input_value" = "${option_items[$option_index]}" ]; then
                        selected_index="$option_index"
                        break
                    fi
                done
                if [ "$selected_index" -lt 0 ]; then
                    echo "无效输入，请输入序号"
                    continue
                fi
            fi
        fi

        case "$var_name" in
            cpu_governor)
                case "$input_value" in
                    powersave|schedutil)
                        ;;
                    *)
                        echo "[!] 无效输入，请输入 powersave 或 schedutil"
                        continue
                        ;;
                esac
                ;;
            iface)
                ;;
            vf_count)
                if ! [[ "$input_value" =~ ^[0-9]+$ ]] || [ "$input_value" -lt 1 ] || [ "$input_value" -gt "$vf_limit" ]; then
                    echo "VF 数量无效，请输入 1 到 $vf_limit 之间的整数"
                    continue
                fi
                ;;
            tuned)
                case "$input_value" in
                    yes|YES|true|TRUE)
                        input_value="true"
                        ;;
                    no|NO|false|FALSE)
                        input_value="false"
                        ;;
                    *)
                        echo "无效输入，请输入 true 或 false"
                        continue
                        ;;
                esac
                ;;
            base_mac)
                if ! is_valid_mac "$input_value"; then
                    echo "MAC 地址格式无效，请输入类似 00:66:01:00:00:00"
                    continue
                fi
                ;;
            base_mac_hander)
                if ! is_valid_mac_octet "$input_value"; then
                    echo "MAC 第一位格式无效，请输入两位十六进制，例如 00"
                    continue
                fi
                input_value="${input_value^^}"
                ;;
        esac

        if ! confirm_input_value "$page_title" "$prompt_text" "$input_value" "$confirm_mode"; then
            echo "[*] 已取消本次输入，请重新填写"
            continue
        fi

        set_prompt_value "$var_name" "$input_value"
        return 0
    done
}

# 按结构化列表依次处理多个询问项
prompt_config_items() {
    local page_title="$1"
    local array_name="$2"
    local item_spec
    local prompt_text
    local var_name
    local options_text
    local default_value
    local confirm_mode

    declare -n item_specs_ref="$array_name"

    for item_spec in "${item_specs_ref[@]}"; do
        IFS='|' read -r prompt_text var_name options_text default_value confirm_mode <<< "$item_spec"
        if ! prompt_config_item "$page_title" "$prompt_text" "$var_name" "$options_text" "$default_value" "$confirm_mode"; then
            return 1
        fi
    done
}

# 将结构化询问项模板中的占位符替换成当前上下文值
build_prompt_items_from_template() {
    local template_array_name="$1"
    local output_array_name="$2"
    local item_spec
    local resolved_spec
    local prompt_text
    local var_name
    local options_text
    local default_value
    local confirm_mode
    local iface_options

    declare -n template_ref="$template_array_name"
    declare -n output_ref="$output_array_name"

    output_ref=()

    for item_spec in "${template_ref[@]}"; do
        IFS='|' read -r prompt_text var_name options_text default_value confirm_mode <<< "$item_spec"
        iface_options="$(join_by_slash "${ifaces[@]}")"

        prompt_text="${prompt_text//__IFACE_MAX__/${#ifaces[@]}}"
        prompt_text="${prompt_text//__VF_LIMIT__/$vf_limit}"
        prompt_text="${prompt_text//__VF_COUNT_DEFAULT__/$vf_count_default}"
        prompt_text="${prompt_text//__TUNED_DEFAULT__/$tuned_default}"
        prompt_text="${prompt_text//__BASE_MAC_DEFAULT__/$base_mac_default}"
        prompt_text="${prompt_text//__IFACE_OPTIONS__/$iface_options}"

        options_text="${options_text//__IFACE_MAX__/${#ifaces[@]}}"
        options_text="${options_text//__VF_LIMIT__/$vf_limit}"
        options_text="${options_text//__VF_COUNT_DEFAULT__/$vf_count_default}"
        options_text="${options_text//__TUNED_DEFAULT__/$tuned_default}"
        options_text="${options_text//__BASE_MAC_DEFAULT__/$base_mac_default}"
        options_text="${options_text//__IFACE_OPTIONS__/$iface_options}"

        default_value="${default_value//__IFACE_MAX__/${#ifaces[@]}}"
        default_value="${default_value//__VF_LIMIT__/$vf_limit}"
        default_value="${default_value//__VF_COUNT_DEFAULT__/$vf_count_default}"
        default_value="${default_value//__TUNED_DEFAULT__/$tuned_default}"
        default_value="${default_value//__BASE_MAC_DEFAULT__/$base_mac_default}"
        default_value="${default_value//__IFACE_OPTIONS__/$iface_options}"

        resolved_spec="$prompt_text|$var_name|$options_text|$default_value|$confirm_mode"
        output_ref+=("$resolved_spec")
    done
}

# 从结构化数组提取变量名列表
get_config_item_var_names() {
    local template_array_name="$1"
    local item_spec
    local prompt_text
    local var_name
    local options_text
    local default_value
    local confirm_mode

    declare -n template_ref="$template_array_name"

    for item_spec in "${template_ref[@]}"; do
        IFS='|' read -r prompt_text var_name options_text default_value confirm_mode <<< "$item_spec"
        printf '%s\n' "$var_name"
    done
}

# 写入 [global] 段中的指定 key，不影响其他 section
set_global_config_value() {
    local key="$1"
    local value="$2"
    local tmp_file

    ensure_global_section
    tmp_file="$(mktemp)"

    awk -v target_key="$key" -v target_value="$value" '
        function print_kv() {
            print target_key "=" target_value
            updated = 1
        }
        /^[[:space:]]*\[global\][[:space:]]*$/ {
            in_global = 1
            print
            next
        }
        in_global && /^[[:space:]]*\[.*\][[:space:]]*$/ {
            if (!updated) {
                print_kv()
            }
            in_global = 0
            print
            next
        }
        in_global && $0 ~ "^[[:space:]]*" target_key "[[:space:]]*=" {
            if (!updated) {
                print_kv()
            }
            next
        }
        {
            print
        }
        END {
            if (in_global && !updated) {
                print_kv()
            }
        }
    ' "$CONFIG_PATH" > "$tmp_file"

    mv "$tmp_file" "$CONFIG_PATH"
}

# 读取指定 ini section 中的 key
get_ini_section_value() {
    local section_name="$1"
    local key="$2"

    ensure_config_file

    awk -F= -v target_section="$section_name" -v target_key="$key" '
        $0 ~ "^[[:space:]]*\\[" target_section "\\][[:space:]]*$" {
            in_section = 1
            next
        }
        in_section && /^[[:space:]]*\[.*\][[:space:]]*$/ {
            exit
        }
        in_section && $0 ~ "^[[:space:]]*" target_key "[[:space:]]*=" {
            value = $0
            sub(/^[^=]*=[[:space:]]*/, "", value)
            print value
            exit
        }
    ' "$CONFIG_PATH"
}

# 只解析 [vf.N] 段，输出：
# index TAB section TAB start_line TAB end_line TAB id TAB iface TAB vf_count TAB tuned TAB base_mac
get_vf_records() {
    awk '
        function flush_section() {
            if (!in_vf) {
                return
            }
            print section_index "\t" section_name "\t" section_start "\t" section_end "\t" vf_id "\t" iface "\t" vf_count "\t" tuned "\t" base_mac
        }
        function reset_section() {
            in_vf = 0
            section_name = ""
            section_start = 0
            section_end = 0
            vf_id = ""
            iface = ""
            vf_count = ""
            tuned = ""
            base_mac = ""
        }
        BEGIN {
            section_index = 0
            reset_section()
        }
        /^[[:space:]]*\[.*\][[:space:]]*$/ {
            if (in_vf) {
                section_end = NR - 1
                flush_section()
            }
            reset_section()

            if ($0 ~ /^[[:space:]]*\[vf\.[0-9]+\][[:space:]]*$/) {
                in_vf = 1
                section_index++
                section_name = $0
                gsub(/^[[:space:]]*\[/, "", section_name)
                gsub(/\][[:space:]]*$/, "", section_name)
                section_start = NR
                section_end = NR
                vf_id = section_name
                sub(/^vf\./, "", vf_id)
            }
            next
        }
        !in_vf {
            next
        }
        {
            section_end = NR

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

# 获取当前可用的最小 VF id，尽量复用空缺编号
get_next_vf_id() {
    local ids=()
    local expected_id=0
    local current_id
    local record_index
    local record_section
    local record_start
    local record_end
    local record_id
    local record_iface
    local record_vf_count
    local record_tuned
    local record_base_mac

    ensure_config_file

    while IFS=$'\t' read -r record_index record_section record_start record_end record_id record_iface record_vf_count record_tuned record_base_mac; do
        [ -n "$record_id" ] || continue
        ids+=("$record_id")
    done < <(get_vf_records)

    if [ ${#ids[@]} -eq 0 ]; then
        echo "0"
        return 0
    fi

    mapfile -t ids < <(printf '%s\n' "${ids[@]}" | sort -n)

    for current_id in "${ids[@]}"; do
        [ "$current_id" = "$expected_id" ] || break
        expected_id=$((expected_id + 1))
    done

    echo "$expected_id"
}

# 按固定格式构造单条 VF ini 配置块
build_vf_block() {
    local vf_id="$1"
    local item_var_name

    printf '[vf.%s]\n' "$vf_id"
    printf 'iface=%s\n' "$iface"

    while IFS= read -r item_var_name; do
        [ -n "$item_var_name" ] || continue
        printf '%s=%s\n' "$item_var_name" "${!item_var_name}"
    done < <(get_config_item_var_names "VF_COMMON_CONFIG_ITEMS")
}

# 在配置文件末尾追加一条 VF 配置
append_vf_block() {
    local vf_id="$1"

    ensure_config_file

    if [ -s "$CONFIG_PATH" ]; then
        printf '\n' >> "$CONFIG_PATH"
    fi

    build_vf_block "$vf_id" >> "$CONFIG_PATH"
    printf '\n' >> "$CONFIG_PATH"
}

# 清空所有 [vf.N] 网卡配置段，保留其他 section 不变
clear_vf_blocks() {
    local tmp_file

    ensure_config_file
    tmp_file="$(mktemp)"

    awk '
        /^[[:space:]]*\[vf\.[0-9]+\][[:space:]]*$/ {
            skip = 1
            next
        }
        /^[[:space:]]*\[.*\][[:space:]]*$/ {
            skip = 0
        }
        !skip {
            print
        }
    ' "$CONFIG_PATH" > "$tmp_file"

    mv "$tmp_file" "$CONFIG_PATH"
}

# 配置文件变更后重载服务，使新配置立即生效
reload_managed_service() {
    require_root

    systemctl daemon-reload

    if ! systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${SERVICE_NAME}[[:space:]]"; then
        echo "[*] 服务 $SERVICE_NAME 尚未安装，已跳过重载"
        return 0
    fi

    echo "[*] 正在重新加载服务: $SERVICE_NAME"
    if ! systemctl restart "$SERVICE_NAME"; then
        echo "[!] 服务重载失败，请执行 systemctl status $SERVICE_NAME 查看详情"
        return 1
    fi

    echo "[+] 服务已重新加载"
}

# ========================
# 功能函数（独立函数，方便扩展）
# ========================
# 安装配置、脚本和 systemd 服务
install_all() {
    require_root
    subheader "安装 SR-IOV 服务"
    echo "[+] 安装 SR-IOV 服务..."

    # 安装过程中的路径、清单遍历和覆盖检查变量
    local script_dir
    local item
    local src_name
    local dst_dir
    local dst_path
    local file_mode
    local src_path
    local overwrite_choice
    local existing_files=()
    local created_dirs=()
    local seen_dirs=()
    local dir_exists
    local cpu_governor

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    install_packages

    for item in "${INSTALL_ITEMS[@]}"; do
        IFS='|' read -r src_name dst_dir dst_path file_mode <<< "$item"
        src_path="$script_dir/$src_name"

        if [ ! -f "$src_path" ]; then
            echo "[!] 安装文件不完整，请确认以下文件存在："
            echo "    - $src_path"
            pause
            return 1
        fi

        [ -e "$dst_path" ] && existing_files+=("$dst_path")

        dir_exists=0
        for created_dir in "${seen_dirs[@]}"; do
            if [ "$created_dir" = "$dst_dir" ]; then
                dir_exists=1
                break
            fi
        done
        if [ "$dir_exists" -eq 0 ]; then
            seen_dirs+=("$dst_dir")
            created_dirs+=("$dst_dir")
        fi
    done

    if [ ${#existing_files[@]} -gt 0 ]; then
        subheader "安装 SR-IOV 服务"
        echo "[!] 发现以下同名文件已存在："
        printf '    - %s\n' "${existing_files[@]}"
        read -r -p "是否覆盖这些文件？[y/N]: " overwrite_choice
        subheader "安装 SR-IOV 服务"
        case "$overwrite_choice" in
            y|Y|yes|YES)
                echo "[*] 将覆盖已存在文件"
                ;;
            *)
                echo "[*] 已取消安装"
                pause
                return 0
                ;;
        esac
    fi

    for dst_dir in "${created_dirs[@]}"; do
        mkdir -p "$dst_dir"
    done

    for item in "${INSTALL_ITEMS[@]}"; do
        IFS='|' read -r src_name dst_dir dst_path file_mode <<< "$item"
        src_path="$script_dir/$src_name"
        install -m "$file_mode" "$src_path" "$dst_path"
    done

    cpu_governor="$GLOBAL_CPU_GOVERNOR_DEFAULT"
    prompt_config_items "安装 SR-IOV 服务" "GLOBAL_CONFIG_ITEMS"
    set_global_config_value "cpu_governor" "$cpu_governor"

    systemctl daemon-reload

    if systemctl is-enabled "$SERVICE_NAME" 2>/dev/null | grep -qx "masked"; then
        echo "[*] 检测到 $SERVICE_NAME 已被 masked，正在解除屏蔽..."
        systemctl unmask "$SERVICE_NAME"
    fi

    systemctl enable "$SERVICE_NAME"

    echo "[+] 安装完成"
    echo "    配置文件: $CONFIG_PATH"
    echo "    执行脚本: $SCRIPT_PATH"
    echo "    服务文件: $SERVICE_PATH"
    echo "    已设置开机自启: $SERVICE_NAME"
    echo "    CPU governor: $cpu_governor"
    pause
}

# 停止并卸载服务，同时删除安装产物
uninstall_all() {
    require_root
    subheader "卸载 SR-IOV 服务"
    echo "[-] 卸载 SR-IOV 服务..."

    # removed_files 用于最后汇总实际删除的文件
    local item
    local src_name
    local dst_dir
    local dst_path
    local file_mode
    local removed_files=()

    if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${SERVICE_NAME}[[:space:]]"; then
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            echo "[*] 正在停止服务: $SERVICE_NAME"
            systemctl stop "$SERVICE_NAME"
        else
            echo "[*] 服务未运行: $SERVICE_NAME"
        fi

        if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
            echo "[*] 正在取消开机自启: $SERVICE_NAME"
            systemctl disable "$SERVICE_NAME"
        fi
    else
        echo "[*] 服务未安装: $SERVICE_NAME"
    fi

    for item in "${INSTALL_ITEMS[@]}"; do
        IFS='|' read -r src_name dst_dir dst_path file_mode <<< "$item"
        if [ -e "$dst_path" ]; then
            rm -f "$dst_path"
            removed_files+=("$dst_path")
        fi
    done

    systemctl daemon-reload

    echo "[+] 卸载完成"
    if [ ${#removed_files[@]} -gt 0 ]; then
        echo "    已删除文件:"
        printf '    - %s\n' "${removed_files[@]}"
    else
        echo "    未发现可删除的安装文件"
    fi

    uninstall_packages

    pause
}

# 查看当前 systemd 服务状态
status_service() {
    subheader "服务状态"
    echo "[*] SR-IOV 服务状态："
    systemctl status "$SERVICE_NAME" --no-pager || echo "服务未安装或未运行"
    pause
}

# 查看已保存的 VF 配置，可单条查看或查看全部
config_list() {
    local records=()
    local selected_index
    local selected_choice
    local record_index
    local record_section
    local record_start
    local record_end
    local record_id
    local record_iface
    local record_vf_count
    local record_tuned
    local record_base_mac

    subheader "查看网卡 VF 配置"

    if [ ! -f "$CONFIG_PATH" ]; then
        echo "配置文件不存在: $CONFIG_PATH"
        pause
        return 1
    fi

    mapfile -t records < <(get_vf_records)

    if [ ${#records[@]} -eq 0 ]; then
        echo "配置文件中没有网卡配置"
        pause
        return 0
    fi

    echo "[*] 配置列表："
    for selected_index in "${!records[@]}"; do
        IFS=$'\t' read -r record_index record_section record_start record_end record_id record_iface record_vf_count record_tuned record_base_mac <<< "${records[$selected_index]}"
        printf "%d) %s\n" "$((selected_index + 1))" "$(strip_config_quotes "$record_iface")"
    done
    echo "a) 查看全部"
    echo "b) 返回"

    read -r -p "请输入要查看的序号: " selected_choice
    subheader "查看网卡 VF 配置"

    if [ "$selected_choice" = "a" ] || [ "$selected_choice" = "A" ]; then
        cat "$CONFIG_PATH"
        echo
        pause
        return 0
    fi

    if [ "$selected_choice" = "b" ] || [ "$selected_choice" = "B" ]; then
        return 0
    fi

    if ! [[ "$selected_choice" =~ ^[0-9]+$ ]]; then
        echo "无效输入"
        pause
        return 1
    fi

    if [ "$selected_choice" -lt 1 ] || [ "$selected_choice" -gt "${#records[@]}" ]; then
        echo "序号超出范围"
        pause
        return 1
    fi

    IFS=$'\t' read -r record_index record_section record_start record_end record_id record_iface record_vf_count record_tuned record_base_mac <<< "${records[$((selected_choice - 1))]}"
    sed -n "${record_start},${record_end}p" "$CONFIG_PATH"
    echo

    pause
}

# 新增一条 VF 配置
config_add() {
    # next_id/default_base_mac 负责生成新配置的默认标识和 MAC
    local next_id
    local default_base_mac
    local config_items=()

    # 网卡选择相关变量
    local ifaces=()
    local iface_index
    local iface

    # VF 数量校验相关变量
    local max_vfs
    local vf_limit
    local vf_count
    local vf_count_default="1"

    # 用户输入的调优、MAC 和确认选项
    local tuned="true"
    local tuned_default="true"
    local base_mac_hander="00"
    local base_mac_hander_default="00"
    local base_mac
    local base_mac_default

    subheader "添加网卡 VF 配置"

    ensure_config_file

    next_id="$(get_next_vf_id)"
    mapfile -t ifaces < <(get_available_physical_ifaces)
    if [ ${#ifaces[@]} -eq 0 ]; then
        echo "未找到可配置的物理网卡"
        pause
        return 1
    fi

    build_prompt_items_from_template "VF_SELECT_CONFIG_ITEMS" "config_items"
    if ! prompt_config_items "添加网卡 VF 配置" "config_items"; then
        return 0
    fi

    if ! max_vfs="$(get_iface_total_vfs "$iface")"; then
        echo "网卡 $iface 不支持 SR-IOV 或无法读取 sriov_totalvfs"
        pause
        return 1
    fi

    vf_limit="$max_vfs"
    if [ "$vf_limit" -gt 256 ]; then
        vf_limit=256
    fi

    if [ "$vf_limit" -lt 1 ]; then
        echo "网卡 $iface 的 VF 上限不可用"
        pause
        return 1
    fi

    echo "[*] 网卡 $iface 最多可创建 $max_vfs 个 VF"
    [ "$vf_limit" != "$max_vfs" ] && echo "[*] 当前工具允许填写的最大值为 $vf_limit"

    if ! prompt_config_item "添加网卡 VF 配置" "请输入 VF 数量（当前网卡最多可创建 $vf_limit 个）" "vf_count" "" "$vf_count_default" "0"; then
        return 0
    fi
    if ! prompt_config_item "添加网卡 VF 配置" "是否启用调优" "tuned" "true/false" "$tuned_default" "0"; then
        return 0
    fi
    if ! prompt_config_item "添加网卡 VF 配置" "设置MAC第一位防止冲突" "base_mac_hander" "" "$base_mac_hander_default" "0"; then
        return 0
    fi

    default_base_mac="$(get_default_base_mac "$next_id" "$base_mac_hander")"
    base_mac="$default_base_mac"
    base_mac_default="$default_base_mac"
    if ! prompt_config_item "添加网卡 VF 配置" "请输入基础 MAC" "base_mac" "" "$base_mac_default" "0"; then
        return 0
    fi

    echo "[*] 待写入配置："
    echo "    id: $next_id"
    echo "    iface: $iface"
    echo "    vf_count: $vf_count"
    echo "    tuned: $tuned"
    echo "    base_mac: $base_mac"
    append_vf_block "$next_id"
    reload_managed_service
    echo "[+] 已添加网卡配置: $iface"

    pause
}

# 删除单条 VF 配置，或清空全部配置
config_del() {
    local records=()
    local selected_index
    local selected_choice
    local selected_iface
    local confirm_choice
    local record_index
    local record_section
    local record_start
    local record_end
    local record_id
    local record_iface
    local record_vf_count
    local record_tuned
    local record_base_mac
    local tmp_file
    local total_lines

    subheader "删除网卡 VF 配置"

    if [ ! -f "$CONFIG_PATH" ]; then
        echo "配置文件不存在: $CONFIG_PATH"
        pause
        return 1
    fi

    mapfile -t records < <(get_vf_records)

    if [ ${#records[@]} -eq 0 ]; then
        echo "配置文件中没有可删除的网卡配置"
        pause
        return 0
    fi

    echo "[*] 当前网卡配置："
    for selected_index in "${!records[@]}"; do
        IFS=$'\t' read -r record_index record_section record_start record_end record_id record_iface record_vf_count record_tuned record_base_mac <<< "${records[$selected_index]}"
        printf "%d) %s\n" "$((selected_index + 1))" "$(strip_config_quotes "$record_iface")"
    done
    echo "a) 删除全部"
    echo "b) 返回"

    read -r -p "请输入要删除的序号: " selected_choice
    subheader "删除网卡 VF 配置"

    if [ "$selected_choice" = "a" ] || [ "$selected_choice" = "A" ]; then
        read -r -p "将删除全部网卡配置，确认请输入 yes: " confirm_choice
        subheader "删除网卡 VF 配置"
        if [ "$confirm_choice" != "yes" ]; then
            echo "[*] 已取消删除"
            pause
            return 0
        fi

        clear_vf_blocks
        reload_managed_service
        echo "[-] 已删除全部网卡配置"
        pause
        return 0
    fi

    if [ "$selected_choice" = "b" ] || [ "$selected_choice" = "B" ]; then
        return 0
    fi

    if ! [[ "$selected_choice" =~ ^[0-9]+$ ]]; then
        echo "无效输入"
        pause
        return 1
    fi

    if [ "$selected_choice" -lt 1 ] || [ "$selected_choice" -gt "${#records[@]}" ]; then
        echo "序号超出范围"
        pause
        return 1
    fi

    selected_index=$((selected_choice - 1))
    IFS=$'\t' read -r record_index record_section record_start record_end record_id record_iface record_vf_count record_tuned record_base_mac <<< "${records[$selected_index]}"
    selected_iface="$(strip_config_quotes "$record_iface")"
    tmp_file="$(mktemp)"
    total_lines="$(wc -l < "$CONFIG_PATH")"

    if [ "$record_start" -gt 1 ]; then
        sed -n "1,$((record_start - 1))p" "$CONFIG_PATH" > "$tmp_file"
    else
        : > "$tmp_file"
    fi

    if [ "$record_end" -lt "$total_lines" ]; then
        sed -n "$((record_end + 1)),\$p" "$CONFIG_PATH" >> "$tmp_file"
    fi

    mv "$tmp_file" "$CONFIG_PATH"

    reload_managed_service
    echo "[-] 已删除网卡配置: $selected_iface"
    pause
}

# 修改已有 VF 配置，并覆盖原有配置段
config_set() {
    local records=()
    local selected_index
    local selected_choice
    local selected_id
    local selected_iface
    local block_start
    local block_end
    local config_items=()

    # 新配置输入相关变量
    local default_base_mac
    local available_ifaces=()
    local ifaces=()
    local iface_index
    local iface
    local max_vfs
    local vf_limit
    local vf_count
    local vf_count_default
    local tuned="true"
    local tuned_default
    local base_mac_hander="00"
    local base_mac_hander_default="00"
    local base_mac
    local base_mac_default
    local tmp_file
    local record_index
    local record_section
    local record_start
    local record_end
    local record_id
    local record_iface
    local record_vf_count
    local record_tuned
    local record_base_mac
    local total_lines
    local item_var_name
    local current_item_value

    subheader "修改网卡 VF 配置"

    ensure_config_file
    mapfile -t records < <(get_vf_records)

    if [ ${#records[@]} -eq 0 ]; then
        echo "配置文件中没有可修改的网卡配置"
        pause
        return 0
    fi

    echo "[*] 当前网卡配置："
    for selected_index in "${!records[@]}"; do
        IFS=$'\t' read -r record_index record_section record_start record_end record_id record_iface record_vf_count record_tuned record_base_mac <<< "${records[$selected_index]}"
        printf "%d) %s\n" "$((selected_index + 1))" "$(strip_config_quotes "$record_iface")"
    done
    echo "b) 返回"

    read -r -p "请输入要修改的序号: " selected_choice
    subheader "修改网卡 VF 配置"
    if [ "$selected_choice" = "b" ] || [ "$selected_choice" = "B" ]; then
        return 0
    fi
    if ! [[ "$selected_choice" =~ ^[0-9]+$ ]]; then
        echo "无效输入"
        pause
        return 1
    fi

    if [ "$selected_choice" -lt 1 ] || [ "$selected_choice" -gt "${#records[@]}" ]; then
        echo "序号超出范围"
        pause
        return 1
    fi

    selected_index=$((selected_choice - 1))
    IFS=$'\t' read -r record_index record_section record_start record_end record_id record_iface record_vf_count record_tuned record_base_mac <<< "${records[$selected_index]}"
    selected_id="$(strip_config_quotes "$record_id")"
    selected_iface="$(strip_config_quotes "$record_iface")"
    default_base_mac="$(get_default_base_mac "$selected_id" "$base_mac_hander")"
    record_vf_count="${record_vf_count:-1}"
    record_tuned="${record_tuned:-true}"
    record_base_mac="${record_base_mac:-$default_base_mac}"

    mapfile -t available_ifaces < <(get_available_physical_ifaces)
    if [ ${#available_ifaces[@]} -eq 0 ]; then
        echo "未找到可配置的物理网卡"
        pause
        return 1
    fi

    ifaces=("${available_ifaces[@]}")
    build_prompt_items_from_template "VF_SELECT_CONFIG_ITEMS" "config_items"
    if ! prompt_config_items "修改网卡 VF 配置" "config_items"; then
        return 0
    fi

    if ! max_vfs="$(get_iface_total_vfs "$iface")"; then
        echo "网卡 $iface 不支持 SR-IOV 或无法读取 sriov_totalvfs"
        pause
        return 1
    fi

    vf_limit="$max_vfs"
    if [ "$vf_limit" -gt 256 ]; then
        vf_limit=256
    fi

    if [ "$vf_limit" -lt 1 ]; then
        echo "网卡 $iface 的 VF 上限不可用"
        pause
        return 1
    fi

    echo "[*] 网卡 $iface 最多可创建 $max_vfs 个 VF"
    [ "$vf_limit" != "$max_vfs" ] && echo "[*] 当前工具允许填写的最大值为 $vf_limit"

    while IFS= read -r item_var_name; do
        [ -n "$item_var_name" ] || continue
        current_item_value="$(get_ini_section_value "$record_section" "$item_var_name")"
        if [ -n "$current_item_value" ]; then
            set_prompt_value "$item_var_name" "$current_item_value"
        fi
    done < <(get_config_item_var_names "VF_COMMON_CONFIG_ITEMS")

    vf_count_default="$record_vf_count"
    tuned_default="$record_tuned"
    base_mac_hander_default="${base_mac_hander:-00}"

    if ! prompt_config_item "修改网卡 VF 配置" "请输入 VF 数量（当前网卡最多可创建 $vf_limit 个）" "vf_count" "" "$vf_count_default" "0"; then
        return 0
    fi
    if ! prompt_config_item "修改网卡 VF 配置" "是否启用调优" "tuned" "true/false" "$tuned_default" "0"; then
        return 0
    fi
    if ! prompt_config_item "修改网卡 VF 配置" "设置MAC第一位防止冲突" "base_mac_hander" "" "$base_mac_hander_default" "0"; then
        return 0
    fi

    default_base_mac="$(get_default_base_mac "$selected_id" "$base_mac_hander")"
    base_mac="$default_base_mac"
    base_mac_default="${record_base_mac:-$default_base_mac}"
    if ! prompt_config_item "修改网卡 VF 配置" "请输入基础 MAC" "base_mac" "" "$base_mac_default" "0"; then
        return 0
    fi

    echo "[*] 待写入配置："
    echo "    id: $selected_id"
    echo "    iface: $iface"
    echo "    vf_count: $vf_count"
    echo "    tuned: $tuned"
    echo "    base_mac: $base_mac"
    block_start="$record_start"
    block_end="$record_end"

    if [ -z "$block_start" ]; then
        echo "[!] 未找到要修改的配置块"
        pause
        return 1
    fi

    total_lines="$(wc -l < "$CONFIG_PATH")"
    tmp_file="$(mktemp)"

    if [ "$block_start" -gt 1 ]; then
        sed -n "1,$((block_start - 1))p" "$CONFIG_PATH" > "$tmp_file"
    else
        : > "$tmp_file"
    fi

    build_vf_block "$selected_id" >> "$tmp_file"
    printf '\n' >> "$tmp_file"

    if [ "$block_end" -lt "$total_lines" ]; then
        sed -n "$((block_end + 1)),\$p" "$CONFIG_PATH" >> "$tmp_file"
    fi

    mv "$tmp_file" "$CONFIG_PATH"
    reload_managed_service
    echo "[*] 已更新网卡配置: $selected_iface -> $iface"

    pause
}

# 显示菜单帮助
show_help() {
    subheader "帮助"
    echo "帮助信息："
    echo "选择对应数字操作 SR-IOV 服务"
    echo "安装、卸载、查看服务状态、配置增删改查"
    pause
}

# ========================
# 配置菜单
# ========================
# 二级菜单：配置增删改查
config_menu() {
    while true; do
        header
        echo "---- 配置管理 ----"
        echo "1) 查看网卡 VF 配置"
        echo "2) 添加网卡 VF 配置"
        echo "3) 删除网卡 VF 配置"
        echo "4) 修改网卡 VF 配置"
        echo "b) 返回主菜单"
        read -p "请选择: " choice

        case $choice in
            1) config_list ;;
            2) config_add ;;
            3) config_del ;;
            4) config_set ;;
            b|B) break ;;
            *) echo "无效输入"; pause ;;
        esac
    done
}

# ========================
# 主菜单
# ========================
# 程序主入口菜单
main_menu() {
    while true; do
        header
        echo "1) 安装网卡 SR-IOV 服务"
        echo "2) 卸载网卡 SR-IOV 服务"
        echo "3) 配置管理"
        echo "4) 服务状态"
        echo "h) 帮助"
        echo "q) 退出"
        read -p "请选择: " choice

        case $choice in
            1) install_all ;;
            2) uninstall_all ;;
            3) config_menu ;;
            4) status_service ;;
            h|H) show_help ;;
            q|Q) exit 0 ;;
            *) echo "无效输入"; pause ;;
        esac
    done
}

# ========================
# 入口
# ========================
main_menu
