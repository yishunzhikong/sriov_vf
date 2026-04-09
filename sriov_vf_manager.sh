#!/bin/bash
set -e

CONFIG_DIR="/etc/sriov_vf"
BIN_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

CONFIG_FILE_NAME="config.yaml"
SCRIPT_FILE_NAME="sriov_vf.sh"
SERVICE_FILE_NAME="sriov_vf.service"

CONFIG_PATH="$CONFIG_DIR/$CONFIG_FILE_NAME"
SCRIPT_PATH="$BIN_DIR/$SCRIPT_FILE_NAME"
SERVICE_PATH="$SYSTEMD_DIR/$SERVICE_FILE_NAME"
SERVICE_NAME="$SERVICE_FILE_NAME"

INSTALL_ITEMS=(
    "$CONFIG_FILE_NAME|$CONFIG_DIR|$CONFIG_PATH|644"
    "$SCRIPT_FILE_NAME|$BIN_DIR|$SCRIPT_PATH|755"
    "$SERVICE_FILE_NAME|$SYSTEMD_DIR|$SERVICE_PATH|644"
)

PACKAGE_ITEMS=(
    "ethtool"
    "lshw"
)

# ========================
# 工具函数
# ========================
require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "请使用 root 运行"
        exit 1
    fi
}

pause() {
    read -p "按回车继续..."
}

header() {
    clear
    echo "=============================="
    echo "        SR-IOV 管理工具       "
    echo "=============================="
}

subheader() {
    header
    echo "---- $1 ----"
}

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

ensure_config_file() {
    if [ ! -f "$CONFIG_PATH" ]; then
        mkdir -p "$CONFIG_DIR"
        cat <<'EOF' > "$CONFIG_PATH"
vfs:
EOF
    fi
}

get_next_vf_id() {
    local ids=()
    local expected_id=0
    local current_id

    ensure_config_file
    mapfile -t ids < <(awk '/^[[:space:]]+id:/ {print $2}' "$CONFIG_PATH" | sort -n)

    for current_id in "${ids[@]}"; do
        [ "$current_id" = "$expected_id" ] || break
        expected_id=$((expected_id + 1))
    done

    echo "$expected_id"
}

is_valid_mac() {
    [[ "$1" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]
}

get_default_base_mac() {
    local vf_id="$1"
    printf '00:66:%02X:00:00:00\n' "$((vf_id + 1))"
}

get_available_physical_ifaces() {
    local iface
    local sysfs_path

    if ! command -v lshw >/dev/null 2>&1; then
        echo "[!] 未找到 lshw，请先执行安装功能安装依赖" >&2
        return 1
    fi

    while read -r iface; do
        [ -n "$iface" ] || continue
        [ "$iface" = "lo" ] && continue
        [ -e "/sys/class/net/$iface" ] || continue

        sysfs_path="$(readlink -f "/sys/class/net/$iface")"
        [[ "$sysfs_path" == *"/devices/virtual/net/"* ]] && continue
        [ -L "/sys/class/net/$iface/device/physfn" ] && continue

        if lshw -c network -businfo 2>/dev/null | awk 'NR > 1 {print $2}' | grep -Fxq "$iface"; then
            printf '%s\n' "$iface"
        fi
    done < <(lshw -c network -businfo 2>/dev/null | awk 'NR > 1 {print $2}' | sed '/^$/d')
}

# ========================
# 功能函数（独立函数，方便扩展）
# ========================
install_all() {
    require_root
    subheader "安装 SR-IOV 服务"
    echo "[+] 安装 SR-IOV 服务..."

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
    pause
}

uninstall_all() {
    require_root
    subheader "卸载 SR-IOV 服务"
    echo "[-] 卸载 SR-IOV 服务..."

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

status_service() {
    subheader "服务状态"
    echo "[*] SR-IOV 服务状态："
    systemctl status "$SERVICE_NAME" --no-pager || echo "服务未安装或未运行"
    pause
}

config_list() {
    local ifaces=()
    local selected_index
    local selected_choice

    subheader "查看网卡 VF 配置"

    if [ ! -f "$CONFIG_PATH" ]; then
        echo "配置文件不存在: $CONFIG_PATH"
        pause
        return 1
    fi

    mapfile -t ifaces < <(awk -F': ' '/^[[:space:]]+iface:/ {print $2}' "$CONFIG_PATH")

    if [ ${#ifaces[@]} -eq 0 ]; then
        echo "配置文件中没有网卡配置"
        pause
        return 0
    fi

    echo "[*] 配置列表："
    for selected_index in "${!ifaces[@]}"; do
        printf "%d) %s\n" "$((selected_index + 1))" "${ifaces[$selected_index]}"
    done
    echo "a) 查看全部"

    read -r -p "请输入要查看的序号: " selected_choice
    subheader "查看网卡 VF 配置"

    if [ "$selected_choice" = "a" ] || [ "$selected_choice" = "A" ]; then
        cat "$CONFIG_PATH"
        echo
        pause
        return 0
    fi

    if ! [[ "$selected_choice" =~ ^[0-9]+$ ]]; then
        echo "无效输入"
        pause
        return 1
    fi

    if [ "$selected_choice" -lt 1 ] || [ "$selected_choice" -gt "${#ifaces[@]}" ]; then
        echo "序号超出范围"
        pause
        return 1
    fi

    awk -v target="$selected_choice" '
        BEGIN {
            block_index = 0
            printing = 0
        }
        /^  - id:/ {
            block_index++
            printing = (block_index == target)
        }
        /^[^[:space:]]/ && !/^vfs:/ {
            printing = 0
        }
        printing {
            print
        }
    ' "$CONFIG_PATH"
    echo

    pause
}

config_add() {
    local next_id
    local default_base_mac
    local ifaces=()
    local iface_index
    local iface_choice
    local iface
    local max_vfs
    local vf_limit
    local vf_count
    local tuned_choice
    local tuned_value="true"
    local customize_mac_choice
    local base_mac
    local confirm_choice
    local tmp_file

    subheader "添加网卡 VF 配置"

    ensure_config_file

    next_id="$(get_next_vf_id)"
    default_base_mac="$(get_default_base_mac "$next_id")"

    mapfile -t ifaces < <(get_available_physical_ifaces)
    if [ ${#ifaces[@]} -eq 0 ]; then
        echo "未找到可配置的物理网卡"
        pause
        return 1
    fi

    echo "[*] 可选物理网卡："
    for iface_index in "${!ifaces[@]}"; do
        printf "%d) %s\n" "$((iface_index + 1))" "${ifaces[$iface_index]}"
    done

    read -r -p "请选择网卡序号: " iface_choice
    subheader "添加网卡 VF 配置"
    if ! [[ "$iface_choice" =~ ^[0-9]+$ ]]; then
        echo "无效输入"
        pause
        return 1
    fi

    if [ "$iface_choice" -lt 1 ] || [ "$iface_choice" -gt "${#ifaces[@]}" ]; then
        echo "序号超出范围"
        pause
        return 1
    fi

    iface="${ifaces[$((iface_choice - 1))]}"

    if [ ! -r "/sys/class/net/$iface/device/sriov_totalvfs" ]; then
        echo "网卡 $iface 不支持 SR-IOV 或无法读取 sriov_totalvfs"
        pause
        return 1
    fi

    max_vfs="$(cat "/sys/class/net/$iface/device/sriov_totalvfs")"
    if ! [[ "$max_vfs" =~ ^[0-9]+$ ]]; then
        echo "无法读取网卡 $iface 的 VF 上限"
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

    while true; do
        read -r -p "请输入 VF 数量 [1-$vf_limit]: " vf_count
        subheader "添加网卡 VF 配置"
        if [[ "$vf_count" =~ ^[0-9]+$ ]] && [ "$vf_count" -ge 1 ] && [ "$vf_count" -le "$vf_limit" ]; then
            break
        fi
        echo "VF 数量无效，请输入 1 到 $vf_limit 之间的整数"
    done

    read -r -p "是否启用调优？[Y/n]: " tuned_choice
    subheader "添加网卡 VF 配置"
    case "$tuned_choice" in
        n|N|no|NO)
            tuned_value="false"
            ;;
        *)
            tuned_value="true"
            ;;
    esac

    base_mac="$default_base_mac"
    read -r -p "是否自定义基础 MAC？[y/N]: " customize_mac_choice
    subheader "添加网卡 VF 配置"
    case "$customize_mac_choice" in
        y|Y|yes|YES)
            while true; do
                read -r -p "请输入基础 MAC: " base_mac
                subheader "添加网卡 VF 配置"
                if is_valid_mac "$base_mac"; then
                    break
                fi
                echo "MAC 地址格式无效，请输入类似 00:66:01:00:00:00"
            done
            ;;
        *)
            ;;
    esac

    echo "[*] 待写入配置："
    echo "    id: $next_id"
    echo "    iface: $iface"
    echo "    vf_count: $vf_count"
    echo "    tuned: $tuned_value"
    echo "    base_mac: $base_mac"
    read -r -p "确认写入配置？[y/N]: " confirm_choice
    subheader "添加网卡 VF 配置"

    case "$confirm_choice" in
        y|Y|yes|YES)
            tmp_file="$(mktemp)"
            cp "$CONFIG_PATH" "$tmp_file"
            cat <<EOF >> "$tmp_file"
  - id: $next_id
    iface: $iface
    vf_count: $vf_count
    tuned: $tuned_value
    base_mac: "$base_mac"
EOF
            mv "$tmp_file" "$CONFIG_PATH"
            echo "[+] 已添加网卡配置: $iface"
            ;;
        *)
            echo "[*] 已取消写入"
            ;;
    esac

    pause
}

config_del() {
    local ifaces=()
    local selected_index
    local selected_choice
    local selected_iface
    local confirm_choice
    local tmp_file

    subheader "删除网卡 VF 配置"

    if [ ! -f "$CONFIG_PATH" ]; then
        echo "配置文件不存在: $CONFIG_PATH"
        pause
        return 1
    fi

    mapfile -t ifaces < <(awk -F': ' '/^[[:space:]]+iface:/ {print $2}' "$CONFIG_PATH")

    if [ ${#ifaces[@]} -eq 0 ]; then
        echo "配置文件中没有可删除的网卡配置"
        pause
        return 0
    fi

    echo "[*] 当前网卡配置："
    for selected_index in "${!ifaces[@]}"; do
        printf "%d) %s\n" "$((selected_index + 1))" "${ifaces[$selected_index]}"
    done
    echo "a) 删除全部"

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

        cat <<'EOF' > "$CONFIG_PATH"
vfs:
EOF
        echo "[-] 已删除全部网卡配置"
        pause
        return 0
    fi

    if ! [[ "$selected_choice" =~ ^[0-9]+$ ]]; then
        echo "无效输入"
        pause
        return 1
    fi

    if [ "$selected_choice" -lt 1 ] || [ "$selected_choice" -gt "${#ifaces[@]}" ]; then
        echo "序号超出范围"
        pause
        return 1
    fi

    selected_index=$((selected_choice - 1))
    selected_iface="${ifaces[$selected_index]}"
    tmp_file="$(mktemp)"

    awk -v target="$selected_choice" '
        BEGIN {
            block_index = 0
            in_block = 0
            skip_block = 0
        }
        /^  - id:/ {
            block_index++
            in_block = 1
            skip_block = (block_index == target)
        }
        {
            if (!skip_block) {
                print
            }
        }
        in_block && /^[^[:space:]]/ {
            in_block = 0
            skip_block = 0
        }
    ' "$CONFIG_PATH" > "$tmp_file"

    mv "$tmp_file" "$CONFIG_PATH"

    echo "[-] 已删除网卡配置: $selected_iface"
    pause
}

config_set() {
    local ifaces=()
    local ids=()
    local selected_index
    local selected_choice
    local selected_id
    local selected_iface
    local start_lines=()
    local end_lines=()
    local current_line
    local block_start
    local next_block_start
    local default_base_mac
    local available_ifaces=()
    local iface_index
    local iface_choice
    local iface
    local max_vfs
    local vf_limit
    local vf_count
    local tuned_choice
    local tuned_value="true"
    local customize_mac_choice
    local base_mac
    local confirm_choice
    local tmp_file

    subheader "修改网卡 VF 配置"

    ensure_config_file

    mapfile -t ifaces < <(awk -F': ' '/^[[:space:]]+iface:/ {print $2}' "$CONFIG_PATH")
    mapfile -t ids < <(awk '/^[[:space:]]+id:/ {print $2}' "$CONFIG_PATH")

    if [ ${#ifaces[@]} -eq 0 ]; then
        echo "配置文件中没有可修改的网卡配置"
        pause
        return 0
    fi

    echo "[*] 当前网卡配置："
    for selected_index in "${!ifaces[@]}"; do
        printf "%d) %s\n" "$((selected_index + 1))" "${ifaces[$selected_index]}"
    done

    read -r -p "请输入要修改的序号: " selected_choice
    subheader "修改网卡 VF 配置"
    if ! [[ "$selected_choice" =~ ^[0-9]+$ ]]; then
        echo "无效输入"
        pause
        return 1
    fi

    if [ "$selected_choice" -lt 1 ] || [ "$selected_choice" -gt "${#ifaces[@]}" ]; then
        echo "序号超出范围"
        pause
        return 1
    fi

    selected_index=$((selected_choice - 1))
    selected_id="${ids[$selected_index]}"
    selected_iface="${ifaces[$selected_index]}"
    default_base_mac="$(get_default_base_mac "$selected_id")"

    mapfile -t available_ifaces < <(get_available_physical_ifaces)
    if [ ${#available_ifaces[@]} -eq 0 ]; then
        echo "未找到可配置的物理网卡"
        pause
        return 1
    fi

    echo "[*] 可选物理网卡："
    for iface_index in "${!available_ifaces[@]}"; do
        printf "%d) %s\n" "$((iface_index + 1))" "${available_ifaces[$iface_index]}"
    done

    read -r -p "请选择网卡序号: " iface_choice
    subheader "修改网卡 VF 配置"
    if ! [[ "$iface_choice" =~ ^[0-9]+$ ]]; then
        echo "无效输入"
        pause
        return 1
    fi

    if [ "$iface_choice" -lt 1 ] || [ "$iface_choice" -gt "${#available_ifaces[@]}" ]; then
        echo "序号超出范围"
        pause
        return 1
    fi

    iface="${available_ifaces[$((iface_choice - 1))]}"

    if [ ! -r "/sys/class/net/$iface/device/sriov_totalvfs" ]; then
        echo "网卡 $iface 不支持 SR-IOV 或无法读取 sriov_totalvfs"
        pause
        return 1
    fi

    max_vfs="$(cat "/sys/class/net/$iface/device/sriov_totalvfs")"
    if ! [[ "$max_vfs" =~ ^[0-9]+$ ]]; then
        echo "无法读取网卡 $iface 的 VF 上限"
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

    while true; do
        read -r -p "请输入 VF 数量 [1-$vf_limit]: " vf_count
        subheader "修改网卡 VF 配置"
        if [[ "$vf_count" =~ ^[0-9]+$ ]] && [ "$vf_count" -ge 1 ] && [ "$vf_count" -le "$vf_limit" ]; then
            break
        fi
        echo "VF 数量无效，请输入 1 到 $vf_limit 之间的整数"
    done

    read -r -p "是否启用调优？[Y/n]: " tuned_choice
    subheader "修改网卡 VF 配置"
    case "$tuned_choice" in
        n|N|no|NO)
            tuned_value="false"
            ;;
        *)
            tuned_value="true"
            ;;
    esac

    base_mac="$default_base_mac"
    read -r -p "是否自定义基础 MAC？[y/N]: " customize_mac_choice
    subheader "修改网卡 VF 配置"
    case "$customize_mac_choice" in
        y|Y|yes|YES)
            while true; do
                read -r -p "请输入基础 MAC: " base_mac
                subheader "修改网卡 VF 配置"
                if is_valid_mac "$base_mac"; then
                    break
                fi
                echo "MAC 地址格式无效，请输入类似 00:66:01:00:00:00"
            done
            ;;
        *)
            ;;
    esac

    echo "[*] 待写入配置："
    echo "    id: $selected_id"
    echo "    iface: $iface"
    echo "    vf_count: $vf_count"
    echo "    tuned: $tuned_value"
    echo "    base_mac: $base_mac"
    read -r -p "确认写入配置？[y/N]: " confirm_choice
    subheader "修改网卡 VF 配置"

    case "$confirm_choice" in
        y|Y|yes|YES)
            mapfile -t start_lines < <(grep -n '^  - id:' "$CONFIG_PATH" | cut -d: -f1)
            block_start="${start_lines[$selected_index]}"
            next_block_start=""

            if [ $((selected_index + 1)) -lt "${#start_lines[@]}" ]; then
                next_block_start="${start_lines[$((selected_index + 1))]}"
            fi

            if [ -z "$block_start" ]; then
                echo "[!] 未找到要修改的配置块"
                pause
                return 1
            fi

            if [ -n "$next_block_start" ]; then
                current_line=$((next_block_start - 1))
            else
                current_line="$(wc -l < "$CONFIG_PATH")"
            fi

            tmp_file="$(mktemp)"

            if [ "$block_start" -gt 1 ]; then
                sed -n "1,$((block_start - 1))p" "$CONFIG_PATH" > "$tmp_file"
            else
                : > "$tmp_file"
            fi

            cat <<EOF >> "$tmp_file"
  - id: $selected_id
    iface: $iface
    vf_count: $vf_count
    tuned: $tuned_value
    base_mac: "$base_mac"
EOF

            if [ "$current_line" -lt "$(wc -l < "$CONFIG_PATH")" ]; then
                sed -n "$((current_line + 1)),\$p" "$CONFIG_PATH" >> "$tmp_file"
            fi

            mv "$tmp_file" "$CONFIG_PATH"
            echo "[*] 已更新网卡配置: $selected_iface -> $iface"
            ;;
        *)
            echo "[*] 已取消写入"
            ;;
    esac

    pause
}

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
