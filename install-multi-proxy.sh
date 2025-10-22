#!/bin/bash
echo "=================================="
echo "   多网卡共享端口代理方案"
echo "=================================="
echo ""

# 1. 清理旧配置
echo "🧹 清理旧配置..."
systemctl stop 3proxy proxy-ip-monitor 2>/dev/null
systemctl disable 3proxy proxy-ip-monitor 2>/dev/null
pkill -9 3proxy 2>/dev/null
rm -rf /etc/3proxy /usr/local/3proxy /usr/bin/3proxy
rm -f /etc/systemd/system/3proxy.service /etc/systemd/system/proxy-ip-monitor.service
systemctl daemon-reload

# 2. 识别网卡
echo ""
echo "🔍 识别网卡配置..."

# 获取主网卡（默认路由）
MAIN_IFACE=$(ip route show default | awk '{print $5}' | head -1)
MAIN_IP=$(ip -4 addr show $MAIN_IFACE | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
echo "主网卡（管理用）: $MAIN_IFACE"
echo "  IP: $MAIN_IP"
echo ""

# 获取所有代理网卡（排除主网卡和lo）
PROXY_IFACES=($(ip -o link show | awk -F': ' '{print $2}' | grep -v "^lo$" | grep -v "^$MAIN_IFACE$"))

if [ ${#PROXY_IFACES[@]} -eq 0 ]; then
    echo "❌ 未找到代理网卡！"
    echo "当前网卡列表："
    ip -o link show | awk -F': ' '{print "  - " $2}'
    exit 1
fi

echo "代理网卡列表："
for iface in "${PROXY_IFACES[@]}"; do
    ip=$(ip -4 addr show $iface 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
    if [ -n "$ip" ]; then
        echo "  - $iface: $ip"
    else
        echo "  - $iface: 未分配IP（等待绑定）"
    fi
done
echo ""

# 3. 安装3proxy
echo "📦 安装3proxy..."
cd /tmp
if [ ! -f 3proxy.tar.gz ]; then
    wget https://github.com/3proxy/3proxy/archive/refs/tags/0.9.4.tar.gz -O 3proxy.tar.gz
fi
rm -rf 3proxy-0.9.4
tar -xzf 3proxy.tar.gz
cd 3proxy-0.9.4
make -f Makefile.Linux
mkdir -p /usr/local/3proxy/bin /etc/3proxy
cp bin/3proxy /usr/local/3proxy/bin/
ln -sf /usr/local/3proxy/bin/3proxy /usr/bin/3proxy

# 4. 创建动态配置生成脚本
echo ""
echo "⚙️  创建动态配置脚本..."
cat > /usr/local/bin/update-proxy-config.sh << 'EOF'
#!/bin/bash

# 获取主网卡
MAIN_IFACE=$(ip route show default | awk '{print $5}' | head -1)

# 获取所有代理网卡
PROXY_IFACES=($(ip -o link show | awk -F': ' '{print $2}' | grep -v "^lo$" | grep -v "^$MAIN_IFACE$"))

# 收集所有有IP的网卡
declare -A IFACE_IPS
for iface in "${PROXY_IFACES[@]}"; do
    ip=$(ip -4 addr show $iface 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
    if [ -n "$ip" ]; then
        IFACE_IPS[$iface]=$ip
    fi
done

if [ ${#IFACE_IPS[@]} -eq 0 ]; then
    echo "⚠️  所有代理网卡都没有IP，等待分配..."
    exit 0
fi

echo "✅ 检测到以下代理IP："
for iface in "${!IFACE_IPS[@]}"; do
    echo "  $iface: ${IFACE_IPS[$iface]}"
done

# 生成3proxy配置
cat > /etc/3proxy/3proxy.cfg << 'EOFCONF'
daemon
log /var/log/3proxy.log D
maxconn 1000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60

# 认证
auth strong
users user1:CL:pass123

# 所有网卡监听同一端口8001
EOFCONF

# 为每个有IP的网卡添加配置
for iface in "${!IFACE_IPS[@]}"; do
    ip=${IFACE_IPS[$iface]}
    cat >> /etc/3proxy/3proxy.cfg << EOFCONF

# 网卡: $iface
internal $ip
external $ip
socks -p8001
EOFCONF
done

echo ""
echo "✅ 配置已更新"
cat /etc/3proxy/3proxy.cfg
EOF

chmod +x /usr/local/bin/update-proxy-config.sh

# 5. 初始化配置
echo ""
echo "📝 初始化3proxy配置..."
/usr/local/bin/update-proxy-config.sh

# 6. 创建统一IP监控脚本
echo ""
echo "📡 创建IP变化监控脚本..."
cat > /usr/local/bin/monitor-ip-change.sh << 'EOF'
#!/bin/bash

# 获取主网卡
MAIN_IFACE=$(ip route show default | awk '{print $5}' | head -1)

# 获取所有代理网卡
PROXY_IFACES=($(ip -o link show | awk -F': ' '{print $2}' | grep -v "^lo$" | grep -v "^$MAIN_IFACE$"))

# 存储上次的IP状态
declare -A LAST_IPS

# 初始化上次IP状态
for iface in "${PROXY_IFACES[@]}"; do
    ip=$(ip -4 addr show $iface 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
    LAST_IPS[$iface]="$ip"
done

echo "开始监控代理网卡IP变化..."
echo "监控网卡: ${PROXY_IFACES[@]}"

while true; do
    config_changed=false
    
    for iface in "${PROXY_IFACES[@]}"; do
        current_ip=$(ip -4 addr show $iface 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
        last_ip="${LAST_IPS[$iface]}"
        
        if [ "$current_ip" != "$last_ip" ]; then
            config_changed=true
            
            if [ -z "$current_ip" ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] $iface: IP已移除 ($last_ip -> 无IP)"
            elif [ -z "$last_ip" ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] $iface: IP已绑定 (无IP -> $current_ip)"
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] $iface: IP已变化 ($last_ip -> $current_ip)"
            fi
            
            LAST_IPS[$iface]="$current_ip"
        fi
    done
    
    if [ "$config_changed" = true ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 检测到IP变化，等待网络稳定..."
        sleep 3
        
        # 更新配置
        /usr/local/bin/update-proxy-config.sh
        
        # 检查是否有任何网卡有IP
        has_ip=false
        for iface in "${PROXY_IFACES[@]}"; do
            ip=$(ip -4 addr show $iface 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
            if [ -n "$ip" ]; then
                has_ip=true
                break
            fi
        done
        
        if [ "$has_ip" = true ]; then
            # 重启3proxy
            systemctl restart 3proxy
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 代理服务已重启"
        else
            # 所有IP都被移除，停止服务
            systemctl stop 3proxy
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 代理服务已停止（所有网卡无IP）"
        fi
    fi
    
    sleep 5
done
EOF

chmod +x /usr/local/bin/monitor-ip-change.sh

# 7. 创建systemd服务
echo ""
echo "🔧 创建systemd服务..."
cat > /etc/systemd/system/3proxy.service << 'EOF'
[Unit]
Description=3proxy Multi-Interface SOCKS5 Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/proxy-ip-monitor.service << 'EOF'
[Unit]
Description=Multi-Interface IP Change Monitor
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/monitor-ip-change.sh
Restart=always
RestartSec=10s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 8. 配置防火墙
echo ""
echo "🔥 配置防火墙..."
for iface in "${PROXY_IFACES[@]}"; do
    iptables -I INPUT -i $iface -p tcp --dport 8001 -j ACCEPT 2>/dev/null
done

# 9. 启动服务
echo ""
echo "🚀 启动服务..."
systemctl daemon-reload
systemctl enable proxy-ip-monitor

# 检查是否有任何网卡有IP
has_ip=false
for iface in "${PROXY_IFACES[@]}"; do
    ip=$(ip -4 addr show $iface 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
    if [ -n "$ip" ]; then
        has_ip=true
        break
    fi
done

if [ "$has_ip" = true ]; then
    systemctl enable 3proxy
    systemctl start 3proxy
    sleep 2
fi

# 启动监控服务
systemctl start proxy-ip-monitor
sleep 2

# 10. 显示状态
echo ""
echo "=================================="
echo "   ✅ 安装完成！"
echo "=================================="
echo ""
echo "📊 服务状态："
echo ""
echo "IP监控服务："
systemctl status proxy-ip-monitor --no-pager | head -8
echo ""
echo "3proxy服务："
systemctl status 3proxy --no-pager 2>/dev/null | head -8 || echo "  等待IP绑定..."
echo ""
echo "🌐 网络配置："
echo "  管理网卡: $MAIN_IFACE ($MAIN_IP) - 仅SSH管理"
echo ""
echo "  代理网卡："
for iface in "${PROXY_IFACES[@]}"; do
    ip=$(ip -4 addr show $iface 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
    if [ -n "$ip" ]; then
        echo "    $iface: $ip ✅"
    else
        echo "    $iface: 未分配（等待绑定）"
    fi
done
echo ""
echo "📝 代理信息："
echo "  共享端口: 8001"
echo "  用户名: user1"
echo "  密码: pass123"
echo ""
echo "  连接方式（每个IP都监听8001端口）："
for iface in "${PROXY_IFACES[@]}"; do
    ip=$(ip -4 addr show $iface 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
    if [ -n "$ip" ]; then
        echo "    socks5://user1:pass123@${ip}:8001"
    fi
done
echo ""
echo "🧪 测试命令："
for iface in "${PROXY_IFACES[@]}"; do
    ip=$(ip -4 addr show $iface 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
    if [ -n "$ip" ]; then
        echo "  curl --socks5 user1:pass123@${ip}:8001 http://httpbin.org/ip"
    fi
done
echo ""
echo "💡 工作原理："
echo "  • 所有代理网卡共享端口 8001"
echo "  • 从哪个IP进入，就从哪个IP出去"
echo "  • 自动监控所有网卡的IP变化"
echo "  • 任何网卡IP变化时自动更新配置"
echo ""
echo "📡 查看监控日志（实时）："
echo "  journalctl -u proxy-ip-monitor -f"
echo ""
echo "🔧 手动更新配置："
echo "  /usr/local/bin/update-proxy-config.sh"
echo "  systemctl restart 3proxy"
echo ""
echo "📁 配置文件："
echo "  /etc/3proxy/3proxy.cfg"
echo "  /var/log/3proxy.log"
echo ""
