# yy

BitBetter（Bitwarden 自授权补丁）在无 Docker 沙箱中的完整运行验证。

## 内容

- **BitBetter/** — BitBetter 源码（已打补丁：net8.0 降级 + `X509Certificate2`），作为普通目录嵌入本仓库（非子模块，克隆即用）。含 `dist/` 无 Docker 启动/初始化脚本和 `dist/initdb/` DB 初始化工具。
- **appsettings.json / appsettings.SelfHosted.json** — 沙箱运行配置（`GlobalSettings` 大写 key + sqlite + dataProtection 目录）
- **memory/** — 排障记录

## 验证结果

在受限沙箱（无 `CAP_SYS_ADMIN`，Docker 无法跑容器）中用 **crane + dotnet** 运行 Bitwarden Identity + API：

- Identity `openid-configuration` / `jwks` → HTTP 200
- API `/alive`、`/config`、`/sync`、`/devices`、`/plans`、`/version` → HTTP 200
- 密码认证 `/connect/token` → HTTP 200 + JWT（完整 token 流程跑通）
- **完整用户生命周期**：注册（send-verification-email → register/finish）→ 登录 → API 认证访问（`/accounts/profile` 返回完整资料）全部 HTTP 200

## 无 Docker 运行方法

前提：已用 `BitBetter/dist/rebuild-in-sandbox.sh` 生成 `dist/bitbetter-{api,identity}-<ver>.tar`，并解包到 `/tmp/fs-api/app` 和 `/tmp/fs-identity/app`；安装 `/opt/dotnet10`（.NET 10 运行时）。

一键初始化（建 DB + 插测试用户 + 启动 Identity/API）：

```bash
cd BitBetter/dist
./init-sandbox.sh
```

或手动：

```bash
# 1. 建 DB schema + 插入测试用户（test@example.com / password123）
cd BitBetter/dist/initdb
/opt/dotnet10/dotnet build -c Release
cp bin/Release/net10.0/initdb.dll /tmp/fs-identity/app/initdb.dll
cd /tmp/fs-identity/app
/opt/dotnet10/dotnet initdb.dll

# 2. 启动服务（需在含 appsettings.json 的目录，设 selfHosted=true）
cd /root/.openclaw/workspace
export globalSettings__selfHosted=true
nohup /opt/dotnet10/dotnet /tmp/fs-identity/app/Identity.dll --urls "http://0.0.0.0:5001" &
nohup /opt/dotnet10/dotnet /tmp/fs-api/app/Api.dll --urls "http://0.0.0.0:5000" &
```

登录验证：

```bash
curl -s -X POST http://127.0.0.1:5001/connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Bitwarden-Client-Version: 2026.8.0" \
  -d "grant_type=password&client_id=web&username=test@example.com&password=password123&scope=api offline_access&deviceType=9&deviceIdentifier=11111111-2222-3333-4444-555555555555&deviceName=TestBrowser"
```

## 在真实 Docker 主机上加载镜像

```bash
cd BitBetter/dist
./load-images.sh
```

然后按脚本提示修改 `bwdata` 的 docker-compose.override.yml 使用 `bitbetter/*` 镜像。
