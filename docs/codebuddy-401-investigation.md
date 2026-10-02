# CodeBuddy 401 复核记录

日期：2026-10-02（Asia/Shanghai）

## 结论

本次复核确认，国际站当前登录态的失败触发因素是应用硬编码的
`User-Agent: ... Chrome/153.0.0.0 ...`。只将此头替换为当前已登录
Chrome 实际发送的 `Chrome/154.0.0.0`，普通 URLSession 就能返回
HTTP 200、业务 code 0，现有 CodeBuddyParser 能正常解析额度快照。

先前会话将问题归因于“服务端只放行 Chrome TLS/HTTP2 指纹”，证据不足；
本次普通 URLSession 与系统 curl 均成功，排除了“必须换浏览器 TLS 栈”这一判断。
没有服务端实现或日志，不能据此确认内部是会话绑定 User-Agent、特定版本策略，
还是其他针对该请求头的校验。

## 方法与凭证保护

- 使用 catchup 读取指定 ZCode 会话，复核其诊断假设。
- 用内置 Chrome 网络诊断能力，在已登录的国际站页面发起同源只读资源查询。
- 浏览器与应用导入的 Cookie 集合在规范化后的 SHA-256 摘要上完全一致；
  无需输出任何 Cookie 值来确认。
- Chrome 请求使用 HTTP/2，无 Service Worker 响应，直接返回正常 JSON。
- Keycloak Cookie 因路径不匹配没有发送；session 和 session_2 各一份。
- 临时 Swift 探针复用仓库 CookieImporter、Client、Models 与 Parser。
- 所有 Cookie 仅保存在内存；curl 配置经标准输入传入，凭证不出现在参数或文件中。
- 所有查询只发送到原登录站点。网络响应只输出状态、业务 code 和解析是否成功。
- 每轮诊断进程设置 60 秒上限，单个请求设置 12–15 秒超时。

## 对照结果（国际站）

| 变体 | HTTP 状态 | 业务响应与额度解析 |
| --- | ---: | --- |
| 应用当前 CodeBuddyClient 原请求 | 401 | 失败 |
| Chrome 同源请求 | 200 | 正常 JSON |
| URLSession 使用 Chrome 实际请求头 | 200 | code 0，解析成功 |
| 系统 curl 使用同一 Cookie、正文、实际请求头 | 200 | 正常 JSON |
| curl-impersonate 使用同一 Cookie、正文、实际请求头 | 200 | 正常 JSON |
| 成功请求改回导入器 Cookie 顺序 | 200 | code 0，解析成功 |
| 成功请求去掉 Origin | 200 | code 0，解析成功 |
| 成功请求去掉显式 Accept-Encoding | 200 | code 0，解析成功 |
| 成功请求只将 User-Agent 改回 Chrome/153 | 401 | 失败 |
| 成功请求只将 sec-ch-ua 改回应用值 | 200 | code 0，解析成功 |
| 成功请求同时将 UA 和 hints 版本改为 153 | 401 | 失败 |
| 应用原请求仅把 User-Agent 换为实际 Chrome/154 | 200 | code 0，解析成功 |
| 应用原请求仅替换 sec-ch-ua | 401 | 失败 |
| 应用原请求仅删除三项 sec-ch-ua 头 | 401 | 失败 |
| 应用原请求仅补 Origin 或 Priority | 401 | 失败 |

系统 curl 与 curl-impersonate 对照固定同一个 Chrome 实际访问的服务器 IP，
并禁用 curl 代理，二者都使用 HTTP/2。普通 URLSession 本身的成功已足以
证明无需模拟 Chrome TLS 指纹。

## 修复建议

1. 当前最小修复：在 CodeBuddyClient 的 User-Agent 中使用已验证的 Chrome/154。
2. 长期方案：从 Cookie 所属 Chrome 安装版本构造对应的 User-Agent，避免版本写死；
   同步维护 client hints，处理安装路径、版本读取失败与浏览器升级。
3. 当前无需引入 curl-impersonate、Rosetta、Python 或依赖 Chrome 调试端口。
4. 401 文案现在一律声称会话过期。未来可改为登录态校验失败，避免把请求契约问题
   一律解释为 Cookie 失效；服务端 401 不能单独证明实际过期。
5. Cookie 按名称去重和固定选择首个 profile 是另两个潜在兼容问题，
   本次登录态没有发现它们造成差异，不能将其列为本次根因。

本次为调查，没有修改应用源码、测试或安装产物；以上是可执行的修复建议。

## 验证边界

- 国际站完成真实登录态与单变量请求对照；未证明所有版本或账户均同样表现。
- 国内站补充请求被自动审批拒绝，理由为额外站点的 Cookie 传输未获明确授权；
  没有发送该请求，不能将国际站实测结论直接标为国内站已验证。
- 运行原有 swift test 探针时，沙箱禁止写默认编译缓存，构建未开始。
  随后使用可写的临时 module cache 编译独立探针，完成上述真实请求验证。
  本次没有产品代码改动，没有声称完成 SwiftPM 全量测试或安装后界面验证。

## 备用传输方案资料

若将来出现新的传输层限制，可再做同请求、同凭证、同出口对照。
维护分支 lexiforest/curl-impersonate 的 v2.2.3 发布提供原生 arm64 macOS 资产，
旧分支只有 Intel 预编译的描述不能代表当前选择；但本次不需要引入该依赖。

- [维护分支发布](https://github.com/lexiforest/curl-impersonate/releases/tag/v2.2.3)
- [安装文档](https://curl-impersonate.readthedocs.io/en/latest/install.html)
- [CodeBuddy 官方环境变量文档](https://www.codebuddy.ai/docs/cli/env-vars)：
  模型 API key 与平台 AUTH_TOKEN 用途不同，不能直接推断个人资源接口接受它们。
