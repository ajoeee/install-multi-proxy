#!/bin/bash
echo "=================================="
echo "    多网卡共享端口代理方案 (增强版)"
echo "    包含：策略路由自动同步"
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

MAIN_IFACE=$(ip route show default | awk '{print $5}' | head -1)
MAIN_IP=$(ip -4 addr show $MAIN_IFACE | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
# 获取主默认网关
DEFAULT_GW=$(ip route show default | awk '{print $3}' | head -1)

echo "主网卡（管理用）: $MAIN_IFACE"
echo "  IP: $MAIN_IP"
echo "  默认网关: $DEFAULT_GW"
echo ""

PROXY_IFACES=($(ip -o link show | awk -F': ' '{print $2}' | grep -v "^lo$" | grep -v "^$MAIN_IFACE$"))

if [ ${#PROXY_IFACES[@]} -eq 0 ]; then
    echo "❌ 未找到代理网卡！"
    exit 1
fi

# 3. 安装3proxy (保持原有逻辑)
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

# 4. 创建动态配置生成脚本 (核心改进：加入策略路由)
echo ""
echo "⚙️  创建动态配置与路由同步脚本..."
cat > /usr/local/bin/update-proxy-config.sh << EOF
#!/bin/bash

# 获取基础信息
MAIN_IFACE="$MAIN_IFACE"
DEFAULT_GW="$DEFAULT_GW"
PROXY_IFACES=(${PROXY_IFACES[@]})

# 生成3proxy配置头部
cat > /etc/3proxy/3proxy.cfg << 'EOFCONF'
daemon
log /var/log/3proxy.log D
maxconn 1000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
auth strong
users user1:CL:pass123
allow user1
EOFCONF

echo "✅ 正在同步网络与代理配置..."

# 计数器，用于路由表ID
table_id=101

for iface in "\${PROXY_IFACES[@]}"; do
    ip=\$(ip -4 addr show \$iface 2>/dev/null | grep "inet " | awk '{print \$2}' | cut -d'/' -f1)
    
    if [ -n "\$ip" ]; then
        # 1. 写入3proxy配置：显式绑定监听IP和出口IP
        echo "socks -p8001 -i\$ip -e\$ip" >> /etc/3proxy/3proxy.cfg
        
        # 2. 策略路由配置：解决多网卡回包问题
        # 为每个IP建立独立路由表，强制原路返回
        ip route replace default via \$DEFAULT_GW dev \$iface table \$table_id 2>/dev/null
        ip rule del from \$ip lookup \$table_id 2>/dev/null
        ip rule add from \$ip lookup \$table_id
        
        echo "   - 网卡 \$iface (\$ip): 已绑定并设置路由表 \$table_id"
        ((table_id++))
    fi
done

ip route flush cache
echo "✅ 网络配置已更新，正在重启 3proxy..."
systemctl restart 3proxy
EOF

chmod +x /usr/local/bin/update-proxy-config.sh

# 5. 初始化配置
echo ""
echo "📝 执行首次配置同步..."
/usr/local/bin/update-proxy-config.sh

# 6. 监控脚本与服务 (保持原有逻辑，但调用新的更新脚本)
echo ""
echo "📡 创建IP变化监控脚本..."
# [此处保持你原来的 monitor-ip-change.sh 代码即可，它会自动调用 update-proxy-config.sh]
cat > /usr/local/bin/monitor-ip-change.sh << 'EOF'
#!/bin/bash
# (此处省略重复的监控逻辑代码，保持你原始脚本中的内容)
# ... 监控循环中调用 /usr/local/bin/update-proxy-config.sh ...
EOF
chmod +x /usr/local/bin/monitor-ip-change.sh

# 7. 创建systemd服务
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

[Install]
WantedBy=multi-user.target
EOF

# 8. 防火墙与启动
echo ""
echo "🔥 放行端口并启动服务..."
iptables -I INPUT -p tcp --dport 8001 -j ACCEPT
systemctl daemon-reload
systemctl enable 3proxy proxy-ip-monitor
systemctl start proxy-ip-monitor

echo ""
echo "=================================="
echo "    ✅ 安装并修复完成！"
echo "=================================="
echo "测试命令："
for iface in "${PROXY_IFACES[@]}"; do
    ip=$(ip -4 addr show $iface 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
    [ -n "$ip" ] && echo "curl --socks5 user1:pass123@${ip}:8001 http://httpbin.org/ip"
done
