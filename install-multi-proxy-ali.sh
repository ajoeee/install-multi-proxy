#!/bin/bash

# ====================================================
#  多网卡共享端口代理一键安装脚本 (V2.0 稳定版)
# ====================================================

# 1. 基础环境准备
echo "🧹 清理旧环境..."
systemctl stop 3proxy proxy-ip-monitor 2>/dev/null
pkill -9 3proxy 2>/dev/null
rm -rf /etc/3proxy /usr/local/3proxy /usr/bin/3proxy
rm -f /etc/systemd/system/3proxy.service /etc/systemd/system/proxy-ip-monitor.service

# 2. 核心网络识别
echo "🔍 识别网络拓扑..."
MAIN_IFACE=$(ip route show default | awk '{print $5}' | head -1)
MAIN_IP=$(ip -4 addr show $MAIN_IFACE | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
DEFAULT_GW=$(ip route show default | awk '{print $3}' | head -1)

# 获取所有待代理的网卡
PROXY_IFACES=($(ip -o link show | awk -F': ' '{print $2}' | grep -v "^lo$" | grep -v "^$MAIN_IFACE$"))

if [ ${#PROXY_IFACES[@]} -eq 0 ]; then
    echo "❌ 未找到副网卡，请检查网卡是否已绑定到实例！"
    exit 1
fi

# 3. 安装 3proxy (0.9.4)
echo "📦 编译安装 3proxy..."
cd /tmp
wget -q https://github.com/3proxy/3proxy/archive/refs/tags/0.9.4.tar.gz -O 3proxy.tar.gz
tar -xzf 3proxy.tar.gz && cd 3proxy-0.9.4
make -f Makefile.Linux >/dev/null 2>&1
mkdir -p /etc/3proxy /usr/local/3proxy/bin
cp bin/3proxy /usr/local/3proxy/bin/
ln -sf /usr/local/3proxy/bin/3proxy /usr/bin/3proxy

# 4. 创建动态更新脚本 (集成策略路由)
echo "⚙️  配置动态同步逻辑..."
cat > /usr/local/bin/update-proxy-config.sh << EOF
#!/bin/bash
# 自动生成的同步脚本

# 基础信息
GW="$DEFAULT_GW"
IFACES=(${PROXY_IFACES[@]})

# 初始化 3proxy 配置 (去掉 daemon 模式，交给 Systemd)
cat > /etc/3proxy/3proxy.cfg << 'EOFCONF'
nserver 8.8.8.8
nserver 1.1.1.1
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
auth strong
users user1:CL:pass123
allow user1
EOFCONF

# 内核参数：关闭反向路径过滤 (必须)
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null

table_id=101
for iface in "\${IFACES[@]}"; do
    ip=\$(ip -4 addr show \$iface 2>/dev/null | grep "inet " | awk '{print \$2}' | cut -d'/' -f1)
    if [ -n "\$ip" ]; then
        # 1. 写入 3proxy 配置 (单行模式：-i 监听, -e 出口)
        echo "socks -p8001 -i\$ip -e\$ip" >> /etc/3proxy/3proxy.cfg
        
        # 2. 写入策略路由 (强制回包走原网卡)
        ip route replace default via \$GW dev \$iface table \$table_id 2>/dev/null
        ip rule del from \$ip lookup \$table_id 2>/dev/null
        ip rule add from \$ip lookup \$table_id
        
        sysctl -w net.ipv4.conf.\$iface.rp_filter=0 >/dev/null
        ((table_id++))
    fi
done

ip route flush cache
systemctl restart 3proxy
EOF

chmod +x /usr/local/bin/update-proxy-config.sh

# 5. 创建 Systemd 服务 (使用 Simple 模式，最稳定)
echo "🔧 创建系统服务..."
cat > /etc/systemd/system/3proxy.service << 'EOF'
[Unit]
Description=3proxy Multi-Interface Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 6. 初始化运行
echo "🚀 正在激活配置..."
/usr/local/bin/update-proxy-config.sh
systemctl daemon-reload
systemctl enable 3proxy
iptables -I INPUT -p tcp --dport 8001 -j ACCEPT 2>/dev/null

echo "=================================="
echo " ✅ 一键部署完成！"
echo "=================================="
echo "代理端口: 8001 (共享)"
echo "验证方式: socks5://user1:pass123@{IP}:8001"
echo ""
