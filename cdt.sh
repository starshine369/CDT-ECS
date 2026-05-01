#!/bin/bash

# ====================================================
# CDT Traffic Manager V2.1
# 命令名称: cdt
# 仓库地址: https://github.com/starshine369/CDT-ECS
# ====================================================

CONFIG_FILE="/etc/cdt.conf"
LOG_FILE="/var/log/cdt_shutdown.log"
BIN_FILE="/usr/local/bin/cdt"

# 1. 确保 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[31m[!] 请使用 root 权限运行此命令！\033[0m"
    exit 1
fi

set_conf() {
    if grep -q "^$1=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s/^$1=.*/$1=\"$2\"/" "$CONFIG_FILE"
    else
        echo "$1=\"$2\"" >> "$CONFIG_FILE"
    fi
}

# ==========================================
# Core 1: Background Monitor (Cron)
# ==========================================
if [ "$1" == "check" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then exit 0; fi
    source "$CONFIG_FILE"
    
    # 获取数据，严防空值
    VNSTAT_DATA=$(vnstat -i "$IFACE" --json 2>/dev/null)
    if [ -z "$VNSTAT_DATA" ]; then exit 0; fi

    if [ "$RESET_MODE" == "1" ]; then
        RX=$(echo "$VNSTAT_DATA" | jq -r '.interfaces[0].traffic.month[-1].rx // 0')
        TX=$(echo "$VNSTAT_DATA" | jq -r '.interfaces[0].traffic.month[-1].tx // 0')
    else
        RX=$(echo "$VNSTAT_DATA" | jq -r '.interfaces[0].traffic.total.rx // 0')
        TX=$(echo "$VNSTAT_DATA" | jq -r '.interfaces[0].traffic.total.tx // 0')
    fi

    # 兜底转换，确保是数字
    RX=${RX:-0}; TX=${TX:-0}

    if [ "$CALC_MODE" == "1" ]; then TOTAL=$(( RX + TX ))
    elif [ "$CALC_MODE" == "2" ]; then TOTAL=$(( RX > TX ? RX : TX ))
    elif [ "$CALC_MODE" == "3" ]; then TOTAL=$TX
    elif [ "$CALC_MODE" == "4" ]; then TOTAL=$RX
    fi

    LIMIT_BYTES=$(( LIMIT_GB * 1073741824 ))

    # 只有当总流量大于 0 且超标时才关机，防止初始化 bug 误杀
    if [ "$TOTAL" -gt 0 ] && [ "$TOTAL" -ge "$LIMIT_BYTES" ]; then
        
        # 关机前日志自洁 (上限 1MB)
        if [ -f "$LOG_FILE" ]; then
            CURRENT_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
            if [ "$CURRENT_SIZE" -gt 1048576 ]; then
                tail -n 100 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
            fi
        fi

        echo "$(date) - [ALERT] 流量超标！当前使用: $TOTAL Bytes, 限制: $LIMIT_BYTES Bytes. 执行紧急关机..." >> "$LOG_FILE"
        sync
        
        # 双重关机指令，防止某些系统环境缺失 shutdown
        /sbin/shutdown -h now || systemctl poweroff
    fi
    exit 0
fi

# ==========================================
# Core 2: Smart Installation & Init
# ==========================================
install_system() {
    # 防止代码裸贴崩溃
    if [[ ! -f "$0" || "$0" == "bash" || "$0" == "sh" || "$0" == "-bash" ]]; then
        echo -e "\033[31m[!] 错误：为保证完整性，请使用 wget 下载文件后执行！\033[0m"
        echo -e "指令：wget -O cdt.sh https://ghproxy.net/https://raw.githubusercontent.com/starshine369/CDT-ECS/main/cdt.sh && bash cdt.sh"
        exit 1
    fi

    clear
    echo "======================================================"
    echo "      [*] 正在部署 CDT 流量防爆闸 (GitHub 版 V2.1)..."
    echo "======================================================"
    
    # 智能依赖检测与安装
    MISSING_PKGS=""
    command -v vnstat >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS vnstat"
    command -v jq >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS jq"
    command -v curl >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS curl"
    
    if [ -n "$MISSING_PKGS" ]; then
        echo "[*] 检测到缺失依赖:$MISSING_PKGS，正在自动补全..."
        if [ -f /etc/debian_version ]; then
            apt-get update -y > /dev/null 2>&1
            apt-get install -y vnstat jq cron curl > /dev/null 2>&1
        elif [ -f /etc/redhat-release ]; then
            yum install -y epel-release > /dev/null 2>&1
            yum install -y vnstat jq cronie curl > /dev/null 2>&1
        else
            echo -e "\033[31m[!] 无法识别的操作系统包管理器，请手动安装:$MISSING_PKGS\033[0m"
            exit 1
        fi
    else
        echo "[+] 核心依赖已全部就绪，无需重复安装。"
    fi

    systemctl enable vnstat > /dev/null 2>&1
    systemctl start vnstat > /dev/null 2>&1

    # 智能获取主网卡
    DEFAULT_IFACE=$(ip route get 1.1.1.1 2>/dev/null | grep -Po '(?<=dev\s)\w+' | cut -f1 -d ' ' | head -n 1)
    if [ -z "$DEFAULT_IFACE" ]; then DEFAULT_IFACE="eth0"; fi
    
    read -p "[+] 请确认外网网卡名称 (默认: $DEFAULT_IFACE): " IFACE
    IFACE=${IFACE:-$DEFAULT_IFACE}

    # 强制初始化 vnstat 数据库
    vnstat -u -i "$IFACE" > /dev/null 2>&1

    read -p "[+] 请输入触发关机的流量上限 (单位: GB): " LIMIT_GB
    LIMIT_GB=${LIMIT_GB:-1000}

    echo "[*] 请选择流量统计方式:"
    echo "   [1] 入站 + 出站 (相加，默认)"
    echo "   [2] 入站和出站取最大值 (Max)"
    echo "   [3] 仅统计出站 (Out/TX)"
    echo "   [4] 仅统计入站 (In/RX)"
    read -p ">>> 请输入序号 (默认1): " CALC_MODE
    CALC_MODE=${CALC_MODE:-1}

    echo "[*] 请选择流量重置周期:"
    echo "   [1] 每月固定日期重置 (默认)"
    echo "   [2] 从不重置 (全局累计消耗)"
    read -p ">>> 请输入序号 (默认1): " RESET_MODE
    RESET_MODE=${RESET_MODE:-1}

    RESET_DAY=1
    if [ "$RESET_MODE" == "1" ]; then
        read -p "[+] 请输入每月结算日 (1-28, 默认1号): " RESET_DAY
        RESET_DAY=${RESET_DAY:-1}
        sed -i "s/^MonthRotate .*/MonthRotate $RESET_DAY/" /etc/vnstat.conf 2>/dev/null
        systemctl restart vnstat > /dev/null 2>&1
    fi

    # 创建配置
    cat << CFGEOF > "$CONFIG_FILE"
IFACE="$IFACE"
LIMIT_GB="$LIMIT_GB"
CALC_MODE="$CALC_MODE"
RESET_MODE="$RESET_MODE"
RESET_DAY="$RESET_DAY"
CFGEOF

    # 部署自身到环境变量
    cp "$0" "$BIN_FILE"
    chmod +x "$BIN_FILE"

    # 部署定时任务 (每5分钟自检)
    crontab -l 2>/dev/null | grep -v "$BIN_FILE check" | crontab -
    (crontab -l 2>/dev/null; echo "*/5 * * * * $BIN_FILE check") | crontab -

    echo ""
    echo -e "\033[32m[OK] CDT 防爆闸部署成功！\033[0m"
    echo "[INFO] 探针已启动。如果数据全为 0，请等待 3-5 分钟让系统收集流量。"
    echo "[INFO] 以后只需在终端输入命令: cdt 即可唤醒控制台"
    sleep 2
}

# ==========================================
# Core 3: CLI Dashboard
# ==========================================
show_dashboard() {
    source "$CONFIG_FILE"
    
    VNSTAT_DATA=$(vnstat -i "$IFACE" --json 2>/dev/null)
    
    if [ -z "$VNSTAT_DATA" ]; then
        RX=0; TX=0
    else
        if [ "$RESET_MODE" == "1" ]; then
            RX=$(echo "$VNSTAT_DATA" | jq -r '.interfaces[0].traffic.month[-1].rx // 0' 2>/dev/null)
            TX=$(echo "$VNSTAT_DATA" | jq -r '.interfaces[0].traffic.month[-1].tx // 0' 2>/dev/null)
            MODE_STR="本月周期 (每月 ${RESET_DAY} 号重置)"
        else
            RX=$(echo "$VNSTAT_DATA" | jq -r '.interfaces[0].traffic.total.rx // 0' 2>/dev/null)
            TX=$(echo "$VNSTAT_DATA" | jq -r '.interfaces[0].traffic.total.tx // 0' 2>/dev/null)
            MODE_STR="全局累计 (从不重置)"
        fi
    fi

    RX=${RX:-0}; TX=${TX:-0}

    if [ "$CALC_MODE" == "1" ]; then TOTAL=$(( RX + TX )); CALC_STR="入站 + 出站 (相加)"
    elif [ "$CALC_MODE" == "2" ]; then TOTAL=$(( RX > TX ? RX : TX )); CALC_STR="入出取大 (Max)"
    elif [ "$CALC_MODE" == "3" ]; then TOTAL=$TX; CALC_STR="仅计算出站 (TX)"
    elif [ "$CALC_MODE" == "4" ]; then TOTAL=$RX; CALC_STR="仅计算入站 (RX)"
    else TOTAL=0; CALC_STR="未知"
    fi

    USED_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL / 1073741824}")
    RX_GB=$(awk "BEGIN {printf \"%.2f\", $RX / 1073741824}")
    TX_GB=$(awk "BEGIN {printf \"%.2f\", $TX / 1073741824}")
    PERCENT=$(awk "BEGIN {printf \"%.1f\", ($USED_GB / $LIMIT_GB) * 100}")

    clear
    echo "======================================================"
    echo "              CDT 流量防爆控制台 V2.1"
    echo "======================================================"
    echo " [*] 监控网卡   : $IFACE"
    echo " [*] 统计周期   : $MODE_STR"
    echo " [*] 计费模式   : $CALC_STR"
    echo " [!] 关机阈值   : $LIMIT_GB GB"
    echo "------------------------------------------------------"
    echo " (RX) 累计入站   : $RX_GB GB"
    echo " (TX) 累计出站   : $TX_GB GB"
    echo " (=>) 计费总用量 : $USED_GB GB ($PERCENT%)"
    echo "======================================================"
    echo " [1] 修改 关机流量阈值"
    echo " [2] 修改 流量计费规则 (相加/取大/单向)"
    echo " [3] 修改 统计周期与结算日 (每月/全局)"
    echo " [4] 修改 监听网卡名称"
    echo " [88] 彻底 卸载防爆闸"
    echo " [0] 退出 面板"
    echo "======================================================"
    read -p ">>> 请输入选项: " OPTION

    case $OPTION in
        1)
            read -p "请输入新的关机流量上限 (GB): " NEW_LIMIT
            if [[ "$NEW_LIMIT" =~ ^[0-9]+$ ]]; then
                set_conf "LIMIT_GB" "$NEW_LIMIT"
                echo "[OK] 修改成功！"
            else
                echo "[!] 错误: 请输入纯数字！"
            fi
            sleep 1; show_dashboard ;;
        2)
            echo "1) 相加  2) 取大  3) 仅出站  4) 仅入站"
            read -p "请选择新计费模式 [1-4]: " NEW_CALC
            if [[ "$NEW_CALC" =~ ^[1-4]$ ]]; then
                set_conf "CALC_MODE" "$NEW_CALC"
                echo "[OK] 修改成功！"
            else
                echo "[!] 错误: 选择无效！"
            fi
            sleep 1; show_dashboard ;;
        3)
            echo "1) 每月固定日期重置  2) 全局累计 (从不重置)"
            read -p "请选择统计周期 [1-2]: " NEW_RMODE
            if [[ "$NEW_RMODE" == "1" ]]; then
                set_conf "RESET_MODE" "1"
                read -p "请输入每月结算日 (1-28): " NEW_RDAY
                if [[ "$NEW_RDAY" =~ ^[0-9]+$ ]] && [ "$NEW_RDAY" -ge 1 ] && [ "$NEW_RDAY" -le 28 ]; then
                    set_conf "RESET_DAY" "$NEW_RDAY"
                    sed -i "s/^MonthRotate .*/MonthRotate $NEW_RDAY/" /etc/vnstat.conf 2>/dev/null
                    systemctl restart vnstat > /dev/null 2>&1
                    echo "[OK] 统计周期已修改为每月 $NEW_RDAY 号重置！"
                else
                    echo "[!] 错误: 日期输入无效！"
                fi
            elif [[ "$NEW_RMODE" == "2" ]]; then
                set_conf "RESET_MODE" "2"
                echo "[OK] 统计周期已修改为全局累计！"
            else
                echo "[!] 错误: 选择无效！"
            fi
            sleep 1; show_dashboard ;;
        4)
            read -p "请输入新的外网网卡名称 (例如 eth0): " NEW_IFACE
            if [ -n "$NEW_IFACE" ]; then
                set_conf "IFACE" "$NEW_IFACE"
                echo "[OK] 网卡已修改！"
            fi
            sleep 1; show_dashboard ;;
        88)
            crontab -l 2>/dev/null | grep -v "$BIN_FILE check" | crontab -
            rm -f "$CONFIG_FILE" "$BIN_FILE" "$LOG_FILE"
            echo -e "\033[32m[OK] CDT 防爆闸已彻底卸载！服务器恢复无限制状态。\033[0m"
            exit 0 ;;
        0) exit 0 ;;
        *) show_dashboard ;;
    esac
}

# ==========================================
# Main Router
# ==========================================
if [ ! -f "$CONFIG_FILE" ]; then
    install_system
    show_dashboard
else
    show_dashboard
fi