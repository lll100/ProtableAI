# PortableAI 下游智能体连接

这里放的是连接配置、环境变量模板、启动脚本和当前机器上已批准的 Windows x64 CLI 副本。Claude Code 与 Codex 的版本、许可文件均保留在各自的 `package` 目录中；如果组织不允许复制 CLI，请删除对应 package，只保留配置模板。

当前副本：Claude Code 2.1.270、Codex 0.147.0、Node.js 便携运行时。两个启动器直接调用 F 盘路径，不依赖系统 PATH。

启动模型服务后，PortableAI 会提供三个本机入口：

| 用途 | 地址 | 协议 |
|---|---|---|
| OpenAI SDK / 普通脚本 | `http://127.0.0.1:11435/v1` | Chat Completions |
| Claude Code | `http://127.0.0.1:11436` | Anthropic Messages |
| Codex 类客户端 | `http://127.0.0.1:11436` | Responses / Chat |

默认本机密钥为 `portable-local`，可在 `config\config.json` 的 `agent_api_key` 中修改。适配器只监听 `127.0.0.1`，不会向局域网开放。

## Claude Code

双击 `claude-code\start-claude-code.bat` 即可调用 F 盘副本；如果组织不允许复制 CLI，删除 package 后再按批准方式安装并使用同一组环境变量。启动器会设置 `CLAUDE_CONFIG_DIR=agents\claude-code\home`，把这次便携运行与电脑用户目录下原有的 Claude 配置隔离，避免主机上的其他 Base URL 或令牌覆盖本地地址。PowerShell 手动配置如下：

```powershell
$env:CLAUDE_CONFIG_DIR = 'F:\PortableAI\agents\claude-code\home'
$env:ANTHROPIC_BASE_URL = 'http://127.0.0.1:11436'
$env:ANTHROPIC_API_KEY = 'portable-local'
$env:ANTHROPIC_AUTH_TOKEN = 'portable-local'
$env:CLAUDE_CODE_API_BASE_URL = 'http://127.0.0.1:11436'
$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
$env:ANTHROPIC_MODEL = 'claude-sonnet-4-5-20250929'
claude
```

适配器把 Anthropic Messages 请求转换为本地 llama.cpp 的 OpenAI Chat Completions 请求，并把结果转换回 Claude Code 需要的消息格式。

## Codex

双击 `codex\start-codex.bat` 即可调用 F 盘副本；如果组织不允许复制 CLI，删除 package 后再按批准方式安装。脚本将：

```text
CODEX_HOME=F:\PortableAI\agents\codex\home
OPENAI_API_KEY=portable-local
```

Codex 的 F 盘启动器把 `CODEX_HOME` 指向便携目录。`home\config.toml` 中的 `portableai` provider 使用 `wire_api = "responses"`、`base_url = "http://127.0.0.1:11436"`，并关闭 `supports_websockets`；当前网关是 PowerShell HTTP/SSE 服务，Codex 会走普通 HTTPS Responses 请求。适配器同时保留 `/v1/responses` 和 `/responses` 两种路径。

已在当前版本 Codex 0.147.0 上验证：

```powershell
F:\PortableAI\agents\codex\start-codex.bat exec --skip-git-repo-check --ephemeral "Return only PONG"
```

终端显示 `provider: portableai` 和 `PONG`，且 `logs\anthropic-gateway.log` 会出现 `POST /responses`。如果只看到 WebSocket 重试，说明 `home\config.toml` 没有被加载，先检查 `CODEX_HOME`。

## 排查

```powershell
powershell -ExecutionPolicy Bypass -File ..\tools\diagnose.ps1
Get-Content ..\logs\anthropic-gateway.log -Tail 50
```

请求没有离开本机时，客户端配置中的 Base URL 必须是 `127.0.0.1`，不要写外接硬盘盘符或局域网 IP。
