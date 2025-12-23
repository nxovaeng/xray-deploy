# Multi-Protocol Proxy Deployment Script

一键部署多协议代理服务器，支持 **XHTTP、gRPC** 协议，基于 **Xray 2025 官方推荐**。

## 📋 系统要求

- **操作系统**: Debian 10+ / Ubuntu 18.04+
- **架构**: x86_64 / aarch64
- **内存**: 最低 512MB（推荐 1GB+）
- **权限**: Root 权限

## 🚀 快速开始

### 1. 下载脚本

```bash
chmod +x proxy-deploy.sh modules/*.sh
```

### 2. 编辑配置文件

复制模板并修改：

```bash
cp config-template.json my-config.json
nano my-config.json
```

**关键配置项**：

```json
{
  "domains": {
    "wildcard_base": "proxy.example.com",
    "cdn_domain": "cdn.example.com",
    "subscription": "sub.example.com"
  },
  "protocols": {
    "grpc": { "enabled": true },          // 推荐：CDN 兼容性最佳
    "xhttp": { "enabled": false }         // 可选：HTTP/3 支持
  }
}
```

### 3. 运行部署

```bash
sudo ./proxy-deploy.sh --config my-config.json
```

## 🛠️ 管理命令

### 服务管理

```bash
# 查看状态
systemctl status xray
systemctl status haproxy

# 重启服务
systemctl restart xray
systemctl restart haproxy

# 查看日志
journalctl -u xray -f
journalctl -u haproxy -f
```

### 证书管理

```bash
# 手动续期
~/.acme.sh/acme.sh --renew-all --force

# 查看证书信息
~/.acme.sh/acme.sh --list

# 证书位置
ls /etc/xray/cert/
```

### HAProxy 统计页面

访问 `http://VPS_IP:8404/stats` 查看：
- 后端服务器状态
- 连接数统计
- 流量监控

默认用户名：`admin`  
密码：部署时生成（见部署输出）

## 📊 CDN 优化建议

### Cloudflare 设置

1. **gRPC 协议**（最稳定）:
   - DNS: Proxied（橙色云）
   - Network > gRPC: ✅ 开启
   - SSL/TLS: Full (strict)

2. **XHTTP 协议**（HTTP/3）:
   - DNS: Proxied（橙色云）
   - Network > HTTP/3: ✅ 开启
   - SSL/TLS: Full (strict)

## ❓ 故障排查

### 1. 证书申请失败

```bash
# 检查 DNS 解析
dig +short grpc.yourdomain.com

# 手动验证端口
curl -I http://VPS_IP:80

# 查看 acme.sh 日志
~/.acme.sh/acme.sh --issue -d domain.com --standalone --debug
```

### 2. Xray 启动失败

```bash
# 验证配置
/usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json

# 查看详细日志
journalctl -u xray -n 100 --no-pager
```

### 3. HAProxy 无法连接

```bash
# 测试 HAProxy 配置
haproxy -c -f /etc/haproxy/haproxy.cfg

# 检查端口占用
ss -tlnp | grep 443
```

### 4. gRPC CDN 断流

配置 `initial_windows_size: 65536` 防止 Cloudflare GOAWAY 断流。

如仍出现问题：
```bash
# 检查 Xray 配置
grep "initial_windows_size" /usr/local/etc/xray/config.json
# 应显示 65536 或更大值
```

## 🔐 安全建议

1. **定期更新**：
   ```bash
   bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
   ```
2. **禁止 root 登录**：
   ```bash
   sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
   systemctl restart sshd
   ```

## 📚 参考资料

- [Xray 官方文档](https://xtls.github.io)
- [Reality 协议说明](https://github.com/XTLS/REALITY)
- [gRPC Transport](https://xtls.github.io/config/transports/grpc.html)
- [Cloudflare gRPC 支持](https://developers.cloudflare.com/fundamentals/reference/protocols/#grpc)

## 📝 许可证

MIT License

## 🙏 致谢

- [Xray-core](https://github.com/XTLS/Xray-core)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
- [wgcf](https://github.com/ViRb3/wgcf)

---

**免责声明**: 本工具仅用于学习交流，请遵守当地法律法规。使用本工具所产生的一切后果由使用者自行承担。
