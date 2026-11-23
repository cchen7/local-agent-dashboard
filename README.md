# Agent Dashboard

[English](README.en.md) · [下载 macOS 版](https://github.com/cchen7/local-agent-dashboard/releases/latest)

Agent Dashboard 把散落在不同编程助手里的本地会话放到同一个 Mac 窗口里。忘了上周在哪个项目讨论过一个报错？可以直接搜当时的中文或英文，点开命中消息读上下文，再看这个项目花了多少 Token。

## 安装和第一次索引

需要 **macOS 27 或更高版本、Apple silicon 芯片**。界面支持简体中文和英文。

1. 从 [0.1.0 发布页](https://github.com/cchen7/local-agent-dashboard/releases/tag/v0.1.0) 下载 `AgentDashboard-0.1.0-macOS-arm64.dmg`。打开磁盘映像，把 **AgentDashboard** 拖到 **Applications（应用程序）**，再从应用程序启动。发行版使用 Developer ID 签名并经过 Apple 公证。
2. 在首次设置里选择要索引的来源，然后点 **开始索引**。0.1.0 支持 Claude Code、Codex（CLI 和桌面应用）以及 GitHub Copilot CLI 的本地会话。
3. 如果会话在自定义目录，到 **设置 → 来源** 添加其根目录并授予访问权限，再启动索引。只登记目录不会自动扫描。远端环境需要先将记录同步到 Mac；应用不会连接远端服务。

## 找到会话，读懂用量

- **会话**：按 `⌘F` 搜索。如 `agent:codex in:7d "migration"` 只查最近七天的 Codex 记录。点结果跳到对应消息，用 `⌘G` / `⇧⌘G` 前后切换命中。常用查询可以保存为智能分组。
- **项目**：从工作目录查看相关会话、主题和最近进展；需要细节时回到原始转录。
- **Token 用量**：按时段查看各助手的用量和吞吐量，合计包含缓存读写。费用是按公开 API 价表计算的估算，不是订阅账单；无法定价的调用仍保留用量。菜单栏也能查看用量和搜索。

## 隐私和数据范围

应用不会联网或调用模型。它只读访问来源，把可搜索的索引保存在自己的沙箱中。默认的显示脱敏只遮盖界面中的常见凭据，不会改写来源或已经存储的原文；可在隐私设置里配置索引脱敏和工作目录排除规则。

0.1.0 不索引云端会话或 Grok Build，不提供会话导出。Claude Code 的本地记录可以正常使用；由于缺少同一时段、包含缓存分项的独立统计，历史用量的这项对账仍待补验。支持的数据边界见[发行范围](docs/RELEASE-SCOPE.md)。

## 从源码构建

在 Apple silicon Mac 上安装 Xcode 27 及对应 macOS SDK。仓库包含 Swift 包依赖锁文件。首次解析依赖可能需要网络；应用运行时不需要网络。

```sh
xcodebuild -project AgentDashboard.xcodeproj -scheme AgentDashboard \
  -configuration Release -destination 'platform=macOS,arch=arm64' build
swift test --package-path Packages/AgentDashKit
```

[开发与测试约定](AGENTS.md) · [产品规格](docs/SPEC.md) · [会话格式和计量规则](docs/FORMATS.md) · [MIT 许可](LICENSE) · [第三方许可](App/Resources/THIRD-PARTY-NOTICES.txt)
