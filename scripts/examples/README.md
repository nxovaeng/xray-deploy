# 配置示例说明

本目录包含参考配置示例。所有配置均基于 `config-template.json` 模板。

## 推荐使用方式

直接使用根目录的 `config-template.json`：

```bash
# 1. 复制模板
cp config-template.json my-config.json

# 2. 编辑配置
vim my-config.json

# 3. 部署
sudo bash proxy-deploy.sh --config my-config.json
```

## 配置要点

### 必须配置的字段

- `domains.wildcard_base`: 通配符域名基础（如：`proxy.example.com`）
- `domains.subscription`: 订阅域名（如：`sub.example.com`）
- `domains.cdn_domain`: CDN域名（可选，用于CDN加速的协议）
- `email`: 证书申请邮箱

### 通配符证书配置

```json
{
  "certificates": {
    "wildcard": true,
    "dns_provider": "cloudflare",
    "dns_api_token": "YOUR_CLOUDFLARE_API_TOKEN"
  }
}
```

### WARP路由配置

```json
{
  "warp_outbound": {
    "enabled": true,
    "routing_mode": "selective",
    "block_bt": true,
    "license_key": "YOUR_WARP_PLUS_KEY"  // 可选
  }
}
```

### 订阅安全配置

```json
{
  "subscription": {
    "enabled": true,
    "nginx_port": 38080,
    "login_user": "admin",
    "login_password": "auto-generate"  // 或指定密码
  }
}
```

## DNS配置示例

### Cloudflare DNS记录

```
类型    名称                       值
A       proxy.example.com          YOUR_VPS_IP
A       *.proxy.example.com        YOUR_VPS_IP  (通配符)
A       sub.example.com            YOUR_VPS_IP
A       cdn.example.com            YOUR_VPS_IP  (可选)
```

### CDN加速设置

- `cdn.example.com`: 启用Cloudflare代理（橙色云朵）
- 其他域名: DNS only（灰色云朵）

## 更多信息

参考项目根目录的 `config-template.json` 获取完整配置说明和注释。
