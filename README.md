# PortableAI

这是一个放在外接硬盘上的离线本地大模型工作区，默认面向 Windows x64。

## 启动

1. 首次运行 `tools\install-runtime.ps1` 安装 CPU、CUDA 核心和 Vulkan 运行时。
2. 首次运行 `tools\download-model.ps1` 下载官方 Qwen3-4B Q4_K_M 模型。
3. 双击 `start.bat`，浏览器打开本地控制台 `http://127.0.0.1:11434`；启动过程会在窗口和 `logs\startup.log` 中显示。
4. 如果需要始终保留 PowerShell 窗口，双击 `start-debug.bat`。
5. 结束模型推理后运行 `stop.bat`；如需连同控制台和 Claude/Codex 适配器一起关闭，运行 `stop-all.bat`，再安全弹出硬盘。

命令行快速提问：`powershell -ExecutionPolicy Bypass -File .\tools\ask.ps1 "你的问题"`。

启动脚本默认只监听本机回环地址，不向局域网提供服务。检测到 NVIDIA 显卡时优先使用 CUDA；没有可用 GPU 时回退到 CPU。Vulkan 运行时作为 Intel/AMD/NVIDIA 的通用备选。

当前安装包包含 CUDA 核心后端，但没有强制下载约 373 MB 的 CUDA 运行库；若主机缺少 cudart，启动脚本会自动使用 Vulkan 或 CPU。需要固定使用 CUDA 时，可后续补充对应运行库。

控制台、模型服务和智能体适配器均只监听本机：控制台是 `11434`，llama.cpp OpenAI 兼容 API 是 `11435/v1`，Claude/Codex 适配器是 `11436`。控制台可以查看配置、健康状态、进程内存、Prometheus 性能指标、启动轨迹和每个后端的错误证据。

## 文档处理

把 `.docx`、`.txt`、`.md`、`.csv` 或代码文件放到 `documents\inbox`，运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\extract-documents.ps1
```

提取后的纯文本在 `documents\extracted`，可在本地网页中粘贴给模型处理。PDF、扫描件和复杂排版建议在确认合规后另行加入 OCR 工具链。

也可以直接分析文本文件：`powershell -ExecutionPolicy Bypass -File .\tools\ask-file.ps1 .\documents\extracted\文件.txt`。

## 目录

- `runtime`：CPU/CUDA/Vulkan 推理程序
- `models`：GGUF 模型文件
- `documents`：输入、提取文本和输出文件
- `logs`：启动进度、服务日志和 PID
- `config`：模型、上下文长度和端口设置
- `tools`：安装、下载和文档提取脚本
- `ui`：离线管理控制台的 HTML/CSS/JavaScript
- `agents`：Claude Code、Codex 的连接器、环境变量模板和说明

## 可移植性说明

当前版本优先覆盖 Windows x64。若目标电脑是 ARM Windows、Linux 或 macOS，需要对应运行时；模型文件可以复用。普通电脑建议使用 4B 模型并把上下文保持在 8K；内存 16 GB 以上的机器可以追加 8B 模型。

## 学习与诊断

- `LEARNING_GUIDE.md`：从启动链路、GGUF、后端、API 到故障排查的学习手册。
- `tools\diagnose.ps1`：自动检查配置、模型、运行时、GPU、进程和 HTTP 健康状态。

运行诊断：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\diagnose.ps1
```

启动失败时重点查看 `logs\service_error.log`。该文件会保留每个后端的退出码、stderr 和 stdout；`logs\server-error.log` 是兼容旧版本的同一份错误摘要。运行时目录已随包放入 VC++/UCRT DLL，不需要在保密电脑联网安装。
## 从 GitHub 获取源代码

GitHub 仓库保存的是脚本、网页、文档和配置模板。模型文件、CPU/CUDA/Vulkan 运行时、日志、缓存、智能体会话和本机配置不会提交，因为它们体积较大或可能包含敏感信息。

克隆后，在项目目录中执行：

```powershell
Copy-Item .\config\config.example.json .\config\config.json
Copy-Item .\config\providers.example.json .\config\providers.json
```

然后按上面的“启动”步骤安装运行时并准备模型。模型校验文件保留在 `models` 目录中，实际 `.gguf` 文件需要单独放入该目录。

