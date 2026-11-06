# PortableAI 部署与推理学习手册

这套项目的目标是：运行时、模型和脚本在移动硬盘上，借用当前电脑的 CPU/GPU 完成本地推理。

## 1. 一次请求经过什么流程

```text
start.bat
  -> PowerShell start.ps1
  -> 读取 config/config.json
  -> 找到 models/*.gguf
  -> 检查内存、CPU、显卡
  -> 选择 runtime/cuda、runtime/vulkan 或 runtime/cpu
  -> 启动 llama-server.exe
  -> llama-server 加载 GGUF 权重
  -> 监听 http://127.0.0.1:11435
  -> 浏览器或 /v1/chat/completions 发送消息
  -> tokenizer 把文字转成 token
  -> 模型根据上下文预测下一个 token
  -> 采样并把 token 解码回文字
```

“模型”和“推理运行时”是两件事。`Qwen3-4B-Q4_K_M.gguf` 是权重文件，决定模型能力；`llama-server.exe`、`ggml-vulkan.dll` 等是运行时，决定如何在 CPU/GPU 上执行这些权重。同一个 GGUF 可以更换后端。

## 2. 目录怎么分工

- `models`：模型权重和校验文件。
- `runtime/cpu`：最兼容的 CPU 后端。
- `runtime/vulkan`：通用 GPU 后端，需要主机有 Vulkan 驱动。
- `runtime/cuda`：NVIDIA 后端。当前已放入 CUDA 核心，缺少 cudart 时会自动回退 Vulkan。
- `config/config.json`：模型名、端口、上下文长度和推理选项。
- `start.ps1`：启动编排器，负责检测环境和启动服务器。
- `logs/startup.log`：启动阶段进度日志，离线机器排障时首先看它。
- `logs/server-error.log`：模型加载和后端错误日志。
- `documents/inbox`：待处理文档。
- `documents/extracted`：提取出的纯文本。
- `tools/ask.ps1`：向本地 API 发送一个问题。
- `tools/ask-file.ps1`：读取文本文件后发送给模型。

## 3. 配置参数的含义

```json
{
  "model": "Qwen3-4B-Q4_K_M.gguf",
  "context": 8192,
  "max_tokens": 2048,
  "temperature": 0.2,
  "port": 11435,
  "prefer_gpu": true,
  "threads": 0,
  "gpu_layers": -1,
  "reasoning": "off"
}
```

- `context` 是一次请求能看到的上下文上限。增大它会增加 KV cache 的内存占用。
- `max_tokens` 是单次最多生成多少 token，不等于中文字符数。
- `prefer_gpu` 为 `false` 时可以强制走 CPU，适合验证 CPU 兼容性。
- `threads: 0` 表示由脚本自动取逻辑线程数，当前脚本最多使用 8 个线程。
- `gpu_layers: -1` 表示尽可能把模型层放到 GPU；显存不足时需要降低它或改用 CPU。
- `reasoning: off` 适合摘要、翻译和简单代码；改为 `on` 会让 Qwen3 为复杂问题保留思考预算。

## 4. 启动和验证

```powershell
cd F:\PortableAI
.\start.bat
.\healthcheck.ps1
.\stop.ps1
```

健康检查只说明 HTTP 服务可访问，不说明答案一定正确。要确认模型真正加载，查看：

```powershell
Get-Content .\logs\server-error.log -Tail 30
Get-Content .\logs\server.pid
Get-Process -Id (Get-Content .\logs\server.pid)
```

## 5. 直接调用本地推理 API

```powershell
$body = @{
  model = 'Qwen3-4B-Q4_K_M.gguf'
  messages = @(@{ role = 'user'; content = '请用一句话解释什么是本地推理。' })
  max_tokens = 128
  stream = $false
  chat_template_kwargs = @{ enable_thinking = $false }
} | ConvertTo-Json -Depth 8
$bytes = [Text.Encoding]::UTF8.GetBytes($body)
$r = Invoke-RestMethod http://127.0.0.1:11435/v1/chat/completions -Method Post -ContentType 'application/json' -Body $bytes
$r.choices[0].message.content
```

这里最关键的是 `127.0.0.1`、端口、模型名和 UTF-8 字节。Windows PowerShell 5.1 直接发送字符串时可能破坏中文，所以脚本显式转换为 UTF-8 字节。

## 6. 常见故障的定位顺序

1. **网页打不开**：运行 `healthcheck.ps1`；再运行 `Test-NetConnection 127.0.0.1 -Port 11435`。
2. **提示模型不存在**：检查 `config/config.json` 的模型名是否和 `models` 下文件名完全一致。
3. **进程启动后马上消失**：查看 `logs/server-error.log`，重点找 `error`、`failed`、`cannot load`、`out of memory`。
4. **内存或显存不足**：先把 `context` 降到 4096，确认使用 4B 模型，再关闭 GPU 或换更小模型。
5. **回答为空或只有思考过程**：保持 `reasoning: off`，或在 API 中传 `enable_thinking: false`。
6. **中文乱码**：读文件时显式使用 UTF-8；API 请求使用 UTF-8 字节；不要用系统默认编码覆盖文件。
7. **换电脑后路径失效**：脚本使用 `$PSScriptRoot` 计算路径，所以盘符变成 G: 通常没有问题；不要把 F: 写进配置。

## 7. 建议的学习实验

- 把 `prefer_gpu` 改成 `false`，重启，比较 CPU 与 Vulkan 的速度。
- 把 `context` 从 8192 改成 4096，观察内存和长文档效果。
- 把 `reasoning` 改成 `on`，比较简单问题的响应长度。
- 用 `documents/inbox` 放一个 TXT 或 DOCX，运行 `extract-documents.ps1`，再用 `ask-file.ps1` 分析。
- 用 `nvidia-smi` 观察模型加载前后的显存变化。

每次只改一个参数，先记录启动后端、首 token 延迟、生成速度和内存占用，这样才能知道参数的真实影响。

## 8. 保密边界

本地推理表示请求不发送到云端，但主机内存、分页文件、浏览器缓存和 Office 临时文件仍可能出现明文。只在获授权的电脑上处理敏感资料，结束后停止服务并安全弹出硬盘。

## 9. 浏览器窗口和后端服务是两个生命周期

`start.ps1` 同时启动后端并打开浏览器；`stop.ps1` 只负责停止 `llama-server.exe`，不会关闭浏览器标签页。浏览器页面可以继续显示已经加载的 HTML，但发送新问题时会因为 11435 端口没有服务而失败。

判断服务是否真的停止，以 `healthcheck.ps1` 和端口为准：

```powershell
.\healthcheck.ps1
Get-NetTCPConnection -LocalPort 11435 -State Listen
```

为了避免双击 `.ps1` 只打开脚本文件，项目现在提供 `stop.bat`。双击它会执行停止、清理旧 PID 文件，并报告是否仍有进程占用端口。
## 10. 离线电脑启动慢或窗口消失

新版启动脚本把启动分成 8 个阶段，并把每一步写入 `logs/startup.log`。它会等待模型真正返回 `/health = ok`，最长等待时间由 `config/config.json` 的 `startup_timeout_sec` 控制，默认 180 秒。

如果 Vulkan 或 CUDA 进程启动后立即退出，脚本会把后端错误打印到窗口，并在 `auto_cpu_fallback` 为 `true` 时自动尝试 CPU。离线电脑首次从外接硬盘加载模型可能很慢，看到“等待模型加载”时不要重复点击启动。

如果窗口仍然消失，使用 `start-debug.bat`，它会保留 PowerShell 窗口；也可以直接打开 `logs/startup.log` 和 `logs/service_error.log`。新版还会根据可见内存自动降低 context、batch 和 ubatch：约 6 GB 及以下会进入低内存模式，避免模型加载时因批处理缓存过大而立即退出。

如果日志中出现退出码 `0xC0000135`（对应有时显示为 `-1073741515`），通常是 Windows C++/UCRT 运行库缺失；检查 `runtime\cpu`、`runtime\vulkan` 和 `runtime\cuda` 下是否有 `vcruntime140.dll`、`vcruntime140_1.dll`、`msvcp140.dll`、`ucrtbase.dll`。`tools\diagnose.ps1` 会直接报告缺少的 DLL。退出码 `0xC000007B` 则通常表示运行时 DLL 位数不匹配。

## 11. 控制台与下游智能体

启动后打开 `http://127.0.0.1:11434`。控制台由 PowerShell `HttpListener` 提供，不需要 Node、Python 或联网：

- “总览”读取 `/api/status`、`/api/metrics` 和启动日志，显示健康状态、后端、进程内存、模型大小和生成吞吐。
- “参数配置”通过 `/api/config` 写回 `config/config.json`，可以保存后手动重启，也可以保存并重启。
- “日志诊断”读取 `startup.log`、`service_error.log` 和各后端错误日志。错误日志不会上传。
- “下游连接”展示 OpenAI、Claude Code、Codex 的本机地址和密钥提示。

`tools/anthropic-gateway.ps1` 在 `11436` 提供 `/v1/messages`、`/v1/responses` 和 `/v1/chat/completions`。它把请求转换到 `llama-server` 的 `11435/v1`，只接受 `config/config.json` 中的 `agent_api_key`，并且只绑定 `127.0.0.1`。`agents/README.md` 说明了如何把已获批准的 Claude Code 或 Codex CLI 指向这些地址；F 盘中同时放置了已批准的 Windows x64 CLI 副本、便携 Node.js 运行时和启动配置。

## 12. Claude Code 与 Codex 的实际请求链路

两个 CLI 都不是直接调用 `llama-server`，而是先经过 11436 适配器：

```text
Claude Code -> /v1/messages  -> 11436 gateway -> /v1/chat/completions -> 11435 llama-server
Codex       -> /responses     -> 11436 gateway -> /v1/chat/completions -> 11435 llama-server
```

Claude Code 启动器设置 `CLAUDE_CONFIG_DIR=agents/claude-code/home`，避免读取电脑用户目录中已有的云端 Base URL；它还从 `config/config.json` 读取当前 `agent_api_key` 和 `anthropic_port`。Codex 启动器设置 `CODEX_HOME=agents/codex/home`，其中 `config.toml` 定义 `portableai` provider、Responses wire format 和 `supports_websockets=false`，这样离线网关不会被 Codex 的 WebSocket 预热阻塞。两个启动器都调用 `tools/read-config-value.ps1`，所以在控制台修改密钥或适配器端口后，重新启动 CLI 即可使用新值。

最小验证顺序：

```powershell
.\tools\diagnose.ps1
.\agents\claude-code\start-claude-code.bat --bare --no-session-persistence -p "return only PONG"
.\agents\codex\start-codex.bat exec --skip-git-repo-check --ephemeral "Return only PONG"
Get-Content .\logs\anthropic-gateway.log -Tail 20
```

成功时 Claude 日志会出现 `POST /v1/messages`，Codex 日志会出现 `POST /responses`；如果出现 401，先核对 `agent_api_key`，如果 Claude 请求走到外部地址，先核对 `CLAUDE_CONFIG_DIR`，如果 Codex 出现 WebSocket 重试，先核对 F 盘 `home/config.toml` 是否加载。
