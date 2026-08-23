# yy

BitBetter（Bitwarden 自授权补丁）在无 Docker 沙箱中的完整运行验证。

## 内容

- **BitBetter** — 子模块（`jakeswenson/BitBetter`），已打补丁（net8.0 降级 + X509Certificate2），含 `dist/` 无 Docker 启动脚本
- **appsettings.json / appsettings.SelfHosted.json** — 沙箱运行配置（`GlobalSettings` 大写 key + sqlite + dataProtection 目录）
- **memory/** — 排障记录

## 验证结果

在受限沙箱（无 `CAP_SYS_ADMIN`，Docker 无法跑容器）中用 **crane + dotnet** 运行 Bitwarden Identity + API：

- Identity `openid-configuration` / `jwks` → HTTP 200
- API `/alive`、`/config` → HTTP 200
- 密码认证 `/connect/token` → HTTP 200 + JWT（完整 token 流程跑通）

## 克隆后初始化子模块

```bash
git clone https://github.com/zzzhoo1/yy.git
cd yy
git submodule update --init
```
