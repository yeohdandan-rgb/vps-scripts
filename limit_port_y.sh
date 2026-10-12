#!/bin/bash

# 自动检测带有默认路由的网卡名称
INTERFACE=$(ip -4 route ls | grep default | awk '{print $5}' | head -1)
CONFIG_FILE="/etc/port_limit_config"

if [ -z "$INTERFACE" ]; then
    echo "⚠️ 无法自动检测到默认网卡，将默认使用 eth0"
    INTERFACE="eth0"
fi

clear_all() {
    tc qdisc del dev "$INTERFACE" root 2>/dev/null
    tc qdisc del dev "$INTERFACE" ingress 2>/dev/null
    tc qdisc del dev ifb0 root 2>/dev/null
    ip link set dev ifb0 down 2>/dev/null
}

init_env() {
    modprobe ifb numifbs=1 2>/dev/null
    ip link set dev ifb0 up 2>/dev/null
    tc qdisc add dev "$INTERFACE" ingress 2>/dev/null
    tc filter add dev "$INTERFACE" parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0 2>/dev/null
    tc filter add dev "$INTERFACE" parent ffff: protocol ipv6 u32 match u32 0 0 action mirred egress redirect dev ifb0 2>/dev/null
}

apply_rules() {
    if [ ! -f $CONFIG_FILE ] || [ ! -s $CONFIG_FILE ]; then
        return
    fi
    clear_all
    init_env

    local count=10
    while read -r line; do
        [[ -z "$line" ]] && continue
        port=$(echo "$line" | awk '{print $1}')
        mode=$(echo "$line" | awk '{print $2}')
        speed=$(echo "$line" | awk '{print $3}')

        count=$((count + 1))
        class_id="1:$count"

        # 模式 1(下载)
        if [ "$mode" == "1" ] || [ "$mode" == "3" ]; then
            tc qdisc replace dev "$INTERFACE" root handle 1: htb default 10
            tc class add dev "$INTERFACE" parent 1: classid "$class_id" htb rate "${speed}mbit" ceil "${speed}mbit"
            tc filter add dev "$INTERFACE" parent 1: protocol ip u32 match ip sport "$port" 0xffff flowid "$class_id"
            tc filter add dev "$INTERFACE" parent 1: protocol ipv6 u32 match ip6 sport "$port" 0xffff flowid "$class_id"
        fi

        # 模式 2(上传)
        if [ "$mode" == "2" ] || [ "$mode" == "3" ]; then
            tc qdisc replace dev ifb0 root handle 1: htb default 10
            tc class add dev ifb0 parent 1: classid "$class_id" htb rate "${speed}mbit" ceil "${speed}mbit"
            tc filter add dev ifb0 parent 1: protocol ip u32 match ip dport "$port" 0xffff flowid "$class_id"
            tc filter add dev ifb0 parent 1: protocol ipv6 u32 match ip6 dport "$port" 0xffff flowid "$class_id"
        fi
    done < $CONFIG_FILE
    echo ">>> 限速规则已在 $INTERFACE 上生效！"
}

show_config() {
    if [ ! -f $CONFIG_FILE ] || [ ! -s $CONFIG_FILE ]; then
        echo "暂无任何限速配置。"
    else
        echo "------------------------------------------------"
        printf "%-10s | %-15s | %-10s\n" "端口" "限速模式" "速率(Mbps)"
        echo "------------------------------------------------"
        while read -r line; do
            p=$(echo "$line" | awk '{print $1}')
            m=$(echo "$line" | awk '{print $2}')
            s=$(echo "$line" | awk '{print $3}')
            case $m in
                1) mode_name="用户下载限制" ;;
                2) mode_name="用户上传限制" ;;
                3) mode_name="双向同速限制" ;;
            esac
            printf "%-10s | %-15s | %-10s\n" "$p" "$mode_name" "$s"
        done < $CONFIG_FILE
        echo "------------------------------------------------"
    fi
}

show_stats() {
    echo "=================================="
    echo "    实时流量统计 (网卡: $INTERFACE)"
    echo "=================================="
    echo "--- [用户下载方向统计 (服务器出站)] ---"
    tc -s class show dev "$INTERFACE" | grep -A 1 "class htb"
    echo ""
    echo "--- [用户上传方向统计 (服务器入站)] ---"
    tc -s class show dev ifb0 2>/dev/null | grep -A 1 "class htb"
    echo "=================================="
    read -p "按回车键返回主菜单..."
}

while true; do
    echo ""
    echo "=================================="
    echo "    多端口限速管理工具 (终极版)"
    echo "    当前自动识别网卡: $INTERFACE"
    echo "=================================="
    echo "1. 添加/修改端口限速 (支持上下行独立设置)"
    echo "2. 暂停所有限速 (恢复全速)"
    echo "3. 恢复所有限速 (重新加载配置)"
    echo "4. 删除特定端口配置"
    echo "5. 查看当前限速配置列表"
    echo "6. 彻底清空所有配置"
    echo "7. 查看实时流量统计 (Dropped/Sent)"
    echo "0. 退出脚本"
    echo "=================================="
    read -p "请选择操作: " opt

    case $opt in
        1)
            echo "模式: 1.单向下行(下载) 2.单向上行(上传) 3.双向同速限制"
            read -p "模式(1/2/3): " m; read -p "端口: " p; read -p "速率(Mbps): " s
            if [ "$m" == "3" ]; then
                # 如果设置双向同速，清空该端口所有旧规则
                sed -i "/^$p /d" $CONFIG_FILE 2>/dev/null
            else
                # 如果设置单向，仅清理该方向的旧规则和可能冲突的双向规则，保留另一方向
                sed -i "/^$p $m /d" $CONFIG_FILE 2>/dev/null
                sed -i "/^$p 3 /d" $CONFIG_FILE 2>/dev/null
            fi
            echo "$p $m $s" >> $CONFIG_FILE
            apply_rules ;;
        2) clear_all ;;
        3) apply_rules ;;
        4) 
            read -p "删除端口: " p
            sed -i "/^$p /d" $CONFIG_FILE 2>/dev/null
            apply_rules ;;
        5) show_config ;;
        6) clear_all; rm -f $CONFIG_FILE ;;
        7) show_stats ;;
        0) break ;;
    esac
done
