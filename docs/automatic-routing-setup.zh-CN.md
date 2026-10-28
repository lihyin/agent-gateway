# 自动路由：配置与真机验收

目标：一个中继服务多个独立配对，手机自动更新推送地址，Muse 不再配置
`RELAY_ROUTE`，也不需要每天复制消息。手机仍负责 Gmail 授权和信息披露审批。

## 1. 确认发布完成

在 GitHub Actions 的 **Production delivery** 检查以下步骤全部成功：

1. verify：Node、Flutter 和 Docker 检查。
2. Check relay transport secrets before deployment：staging 和 production 配置名称齐全。
3. staging、production 部署和健康/配对通道验证。
4. Codemagic `ios-release` 构建、签名及 TestFlight 后处理完成。

生产地址：`https://agent-gateway-relay-production.agentbrain.workers.dev`。
打开其 `/health` 应返回正确 release SHA 和 `environment: production`。
`sourceAccessEnabled: false` 是正确结果：中继本身不能访问 Gmail。
只有健康检查成功不能证明推送或 Gmail 已可用。

## 2. 一次性服务配置

已有配置只需核对；不要为了本次发布重复创建账号、密钥或 OAuth 客户端。
不要把密钥、推送令牌、配对码或私人状态文件发到聊天里。

### GitHub production environment

位置：仓库 Settings → Environments → production。

| 类型     | 名称                  | 用途                                                         |
| -------- | --------------------- | ------------------------------------------------------------ |
| Secret   | CLOUDFLARE_API_TOKEN  | 部署 Worker                                                  |
| Secret   | CM_API_TOKEN          | 启动和检查 Codemagic 构建                                    |
| Variable | CLOUDFLARE_ACCOUNT_ID | Cloudflare 账号 ID                                           |
| Variable | CM_APP_ID             | Codemagic 应用 ID                                            |
| Variable | RELAY_URL             | 上述 production HTTPS origin，不带结尾斜杠                   |
| Variable | STAGING_RELAY_URL     | `https://agent-gateway-relay-staging.agentbrain.workers.dev` |

### Cloudflare 两个 Worker

位置：Workers & Pages → 对应 Worker → Settings → Variables and Secrets。
分别检查 staging 和 production；这里的六项使用 Secret 类型。

| 名称              | 配置                                                                                  |
| ----------------- | ------------------------------------------------------------------------------------- |
| RELAY_ROUTING_KEY | 32 个安全随机字节的无填充 base64url，共 43 个字符；两环境分别生成，已有值不要随意轮换 |
| APNS_KEY_ID       | Apple APNs signing key ID                                                             |
| APNS_TEAM_ID      | 拥有该 App 的 Apple Developer Team ID                                                 |
| APNS_PRIVATE_KEY  | 对应 `.p8` 文件全文，保留 PEM 头尾及换行                                              |
| APNS_TOPIC        | `com.agentbrain.agentgateway`                                                         |
| APNS_ENVIRONMENT  | TestFlight 使用 `production`                                                          |

`RELAY_ORIGIN` 由发布流程根据环境设置。`CHANNELS`、`PAIRINGS`、
`PAIRINGS_REGISTRY` 及其迁移由仓库 Wrangler 配置管理，无需手工建数据库。
`PAIRING_CONFIG` 已不再使用；不要为每个用户配置它。

若需要生成一个尚不存在的路由密钥，在自己的本地终端运行下列命令，并将输出
直接存入相应 Worker Secret，不提交到 Git：

```sh
node -e "console.log(require('node:crypto').randomBytes(32).toString('base64url'))"
```

APNs key、Team、App ID 必须属于同一开发者配置。Apple App ID 需启用 Push
Notifications；签名 provisioning profile 也必须包含该能力。
参考：[Apple APNs token 配置](https://developer.apple.com/help/account/capabilities/communicate-with-apns-using-authentication-tokens/)。

### Codemagic 和 Google

Codemagic 应用连接 `lihyin/agent-gateway`，使用 `relay-architecture` 分支和根目录
`codemagic.yaml`。`production_mobile` 环境组中核对：

1. `APP_STORE_ID`：App Store Connect 应用的数字 ID。
2. `GOOGLE_IOS_CLIENT_ID`：Google Cloud 中针对 `com.agentbrain.agentgateway`
   创建的 **iOS** OAuth 客户端 ID。它是公共标识，不是 client secret。
3. `agent-gateway-asc` 集成及该 bundle ID 对应的 App Store distribution profile。

Google Cloud 启用 Gmail API；在 OAuth consent 配置中加入你用于测试的 Gmail 账号。
App 仅请求 `gmail.readonly`。如果现有版本能正常登录 Gmail，通常无需修改 Google
配置。完整步骤见 [Gmail setup](gmail-setup.md)。

App Store Connect → 对应 App → TestFlight：确认构建已处理、必要的出口合规信息
已完成，并将构建分配给自己的内部测试组。自动分配和手工分配选择一种即可。
参考：[Apple 内部测试者](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/)。

## 3. 安装匹配的 iPhone 版本

1. 在 TestFlight 更新 Agent Gateway，不要只更新中继。
2. 打开 App，核对显示的 release SHA 与本次 Actions 发布一致。
3. 点击连接 Gmail，使用测试账号完成系统浏览器登录和授权。
4. 在 iPhone Settings 中允许 Agent Gateway 通知。

暂时只验证自己的设备和账号；不需要添加真实用户。

## 4. 更新 Muse 客户端并配对

把 App 的 **Pair with Muse** 生成的完整 setup message 发给你的可信 Muse 会话。
该消息包含客户端安装说明和一次性 `AGW1` 行，勿发到公开群聊。

Muse 的现有运行环境需要 Node 22+、该仓库最新客户端及出站 WebSocket 能力。
首次克隆时指定正确分支：

```sh
git clone --branch relay-architecture https://github.com/lihyin/agent-gateway.git
cd agent-gateway
npm ci
npm run build --workspace agent-adapter
```

已有 checkout 则停止正在使用状态文件的 CLI/MCP 进程，再更新
`relay-architecture` 分支、安装依赖并重新 build。保留原有私有
`GATEWAY_AGENT_STATE`；它包含代理私钥，不能上传或贴到聊天中。

Muse 运行时仅需两个环境变量：

| 名称                | 值                                          |
| ------------------- | ------------------------------------------- |
| GATEWAY_AGENT_STATE | Muse 环境内私有、排除备份的状态文件绝对路径 |
| RELAY_URL           | production 中继 origin                      |

删除旧客户端配置中的 `RELAY_ROUTE`；新客户端不使用它。不同用户必须使用不同的
私有代理状态文件，不能共享身份。Windows PowerShell 的设置方式为
`$env:RELAY_URL = 'https://agent-gateway-relay-production.agentbrain.workers.dev'`；
Linux/macOS 使用 `export RELAY_URL='https://agent-gateway-relay-production.agentbrain.workers.dev'`。
状态路径用同样方式设置。

运行 `node agent-adapter/dist/src/cli.js pair`，在标准输入粘贴 App 生成的 `AGW1`
行，回手机确认并完成本机认证。配对码 30 分钟内有效，只能尝试一次。
配对成功后开启 App 的 **Relay notifications**，确认并允许 iOS 通知。
公共配对记录及推送目标会自动注册，不需要操作 Cloudflare 或复制路由。

若使用 stdio MCP，配对后以相同环境变量启动：

```sh
node agent-adapter/dist/src/mcp-server.js
```

CLI 和 MCP 不能同时占用同一个状态文件。Muse 的原生自定义工具接口如果无法安装
客户端或维持出站连接，必须先解决这一运行环境限制；不能仅靠聊天文字替代客户端。

## 5. 第一条真机测试

先在自己的测试邮箱准备一封主题含唯一标记的普通邮件，例如
`AGW-AUTO-ROUTE-TEST-20261027`，不要使用私人邮件内容。
在 Muse 中发送：

> 用 Agent Gateway 查询最近 7 天主题包含 AGW-AUTO-ROUTE-TEST-20261027 的邮件，
> 最多 1 封，只需要 id、date、subject。用途是验证自动路由。等待我在 iPhone
> 上同意访问并审批披露；不要直接连接 Gmail。

预期顺序：

1. Muse 创建请求并维持出站连接，显示等待手机审批。
2. iPhone 收到不含主题或邮件内容的通用通知。
3. 点击通知打开 App；未同意访问前不能获取 Gmail 数据。
4. 同意访问后看到筛选过的预览。
5. 点击 Allow once 后，Muse 才能获得已验证的结果。

一次请求最多 5 分钟；过期后不要审批旧请求，应明确发起一次新测试。

## 6. 继续验收

| 测试                     | 预期                                                   |
| ------------------------ | ------------------------------------------------------ |
| 拒绝一次新请求           | Muse 得到拒绝结果，没有邮件内容                        |
| App 退出再打开           | 自动恢复注册，原配对保留，不复制路由                   |
| 超过 24 小时再次查询     | 不需要刷新或粘贴任何消息                               |
| 网络断开后重试相同请求   | 在原有效期内复用请求，不重复获取 Gmail                 |
| 关闭 Relay notifications | 在线撤销目标成功后，新请求不能投递                     |
| 再次开启通知             | 自动注册，无需重新配对或修改 Muse 环境变量             |
| Unpair agent             | 在线撤销成功后，旧代理请求被拒绝；重新配对生成新 epoch |

每个配对每分钟最多 10 次投递尝试，重试也计入；遇到限流先等下一分钟。
关闭通知/解绑需要联网，失败时 App 保留原状态并报错，恢复网络后重试。
iOS 不保证后台运行；若系统更换 token，可能需要打开一次 App 才能更新，但不是
每天更新。真实 APNs、通知点击、Face ID 和 Muse 执行必须用真机完成。

## 7. 失败时从哪里查

- **缺少 Worker secret**：发布的预检步骤会列出缺失的名称，分别补齐两环境。
- **Gmail 登录失败**：核对 iOS client ID、bundle ID、Google 测试用户，以及 App
  构建时的 `GOOGLE_IOS_CLIENT_ID`。
- **没有通知**：先确认 Relay notifications 开启、iOS 权限、production APNs 环境、
  `.p8`/Team/Topic 一致，再打开 App 重试。健康接口成功不代表 APNs 已可用。
- **TestFlight 后处理失败**：检查 App Store Connect 中该构建的具体提示及 Codemagic
  Publishing 日志；不要把问题误判为手机代码失败，也不要重复改动所有密钥。
- **Muse 报配对/路由错误**：确认最新客户端、相同 production origin 和正确状态文件；
  旧版本客户端必须更新。

记录 release SHA、TestFlight build number、测试时间及成功/失败即可，不记录私人
邮件内容、密钥、配对码、推送 token 或认证 proof。
