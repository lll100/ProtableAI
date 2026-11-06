(() => {
  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));
  const state = {
    config: {}, status: {}, environment: null, providers: { active_provider: '', providers: [] }, selectedProviderId: '',
    view: 'dashboard', systemHistory: [], tokenHistory: [], lastPollError: '', modalTimer: null, configDirty: false
  };

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>"']/g, ch => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[ch]));
  }
  function showModal(type, title, message, detail = '') {
    const modal = $('#modal');
    $('#modal-title').textContent = title || '提示';
    $('#modal-message').textContent = message || '';
    const detailNode = $('#modal-detail');
    detailNode.textContent = detail || '';
    detailNode.hidden = !detail;
    const icon = $('#modal-icon');
    icon.className = `modal-icon ${type || ''}`;
    icon.textContent = type === 'success' ? '✓' : type === 'error' ? '!' : type === 'warning' ? '!' : 'i';
    modal.hidden = false;
    $('#modal-ok').focus();
  }
  function closeModal() { $('#modal').hidden = true; }
  $('#modal-close').addEventListener('click', closeModal);
  $('#modal-ok').addEventListener('click', closeModal);
  $('#modal').addEventListener('click', event => { if (event.target === $('#modal')) closeModal(); });
  document.addEventListener('keydown', event => { if (event.key === 'Escape' && !$('#modal').hidden) closeModal(); });

  async function api(path, options = {}) {
    const { silent = false, ...fetchOptions } = options;
    let response;
    let payload;
    try {
      response = await fetch(path, { cache: 'no-store', ...fetchOptions, headers: { 'Content-Type': 'application/json', ...(fetchOptions.headers || {}) } });
      const text = await response.text();
      try { payload = text ? JSON.parse(text) : {}; } catch { payload = { raw: text }; }
    } catch (error) {
      const wrapped = new Error(`无法连接控制服务：${error.message}`);
      wrapped.detail = '请确认 F:\\PortableAI 的控制台服务正在运行，并检查 control.log。';
      if (!silent) showModal('error', '请求失败', wrapped.message, wrapped.detail);
      throw wrapped;
    }
    if (!response.ok) {
      const message = payload?.error || payload?.message || `HTTP ${response.status} ${response.statusText}`;
      const wrapped = new Error(message);
      wrapped.detail = `请求：${path}\nHTTP 状态：${response.status}\n${payload?.detail || payload?.raw || ''}`.trim();
      if (!silent) showModal('error', '操作失败', wrapped.message, wrapped.detail);
      throw wrapped;
    }
    return payload;
  }

  function fmtUptime(seconds) {
    const n = Number(seconds);
    if (!Number.isFinite(n) || n < 0) return '—';
    const h = Math.floor(n / 3600), m = Math.floor((n % 3600) / 60), s = Math.floor(n % 60);
    return h ? `${h}小时 ${m}分` : `${m}分 ${s}秒`;
  }
  function fmtNumber(value, digits = 1) { return Number.isFinite(Number(value)) ? Number(value).toFixed(digits) : '—'; }
  function setControlHealth(type, text) { const node = $('#control-health'); node.className = `health-pill ${type}`; node.textContent = text; }
  function setText(selector, value) { const node = $(selector); if (node) node.textContent = value ?? '—'; }

  function switchView(view) {
    state.view = view;
    $$('.nav-item').forEach(item => item.classList.toggle('active', item.dataset.view === view));
    $$('.view').forEach(section => section.classList.toggle('active', section.id === `view-${view}`));
    const labels = { dashboard: '工作台', environment: '上游环境', deploy: '部署配置', providers: '下游供应商', monitor: '监控面板', logs: '日志与调试' };
    setText('#view-title', labels[view] || view);
    if (view === 'environment' && !state.environment) loadEnvironment(true);
    if (view === 'providers' && !state.providers.providers.length) loadProviders(true);
    if (view === 'logs') loadLog(true);
    if (view === 'monitor') { drawCharts(); }
  }
  $$('.nav-item').forEach(item => item.addEventListener('click', () => switchView(item.dataset.view)));
  $$('[data-view-link]').forEach(item => item.addEventListener('click', () => switchView(item.dataset.viewLink)));

  function renderStatus(status) {
    state.status = status || {};
    const health = status?.health?.status;
    const running = !!status?.process?.running;
    const ready = health === 'ok';
    const loading = health === 'loading model';
    const serviceText = ready ? '在线' : loading ? '加载中' : running ? '等待响应' : '已停止';
    const note = ready ? '模型已加载，接受本机请求' : loading ? '正在从外接硬盘加载模型…' : running ? (status?.health?.detail || '进程存在但尚未健康') : (status?.health?.detail || '可从服务操作中启动');
    setText('#dash-service', serviceText); setText('#dash-service-note', note);
    const stateDot = $('#dash-service-state'); stateDot.className = `summary-state ${ready ? 'ok' : loading || running ? 'warn' : 'error'}`;
    setText('#dash-model', status?.model || state.config?.model || '—'); setText('#dash-model-note', `${status?.model_size_gb || 0} GB · GGUF`);
    setText('#dash-backend', (status?.backend || '—').toUpperCase()); setText('#dash-backend-note', `配置：${state.config?.backend || 'auto'}`);
    setText('#dash-memory', status?.process?.memory_mb ? `${status.process.memory_mb} MB` : '—'); setText('#dash-memory-note', `系统 ${fmtNumber(status?.system?.memory_used_percent)}%`);
    setText('#dash-last-refresh', `同步于 ${new Date().toLocaleTimeString('zh-CN', { hour12: false })}`);
    setText('#dash-control-url', `http://127.0.0.1:${status?.control_port || state.config?.control_port || 11434}`);
    setText('#dash-model-url', `http://127.0.0.1:${status?.model_port || state.config?.port || 11435}`);
    setText('#dash-agent-url', `http://127.0.0.1:${status?.anthropic_port || state.config?.anthropic_port || 11436}`);
    setText('#dash-context', `${Number(status?.context || state.config?.context || 0).toLocaleString()} / ${Number(status?.max_tokens || state.config?.max_tokens || 0).toLocaleString()} tokens`);
    setText('#dash-process', `${status?.process?.pid || '—'} / ${fmtUptime(status?.process?.uptime_sec)}`);
    const active = state.providers.providers.find(p => p.id === state.providers.active_provider);
    setText('#dash-provider', active?.name || state.providers.active_provider || '未配置');
    setControlHealth(ready ? 'ok' : loading || running ? 'warn' : 'error', ready ? '模型服务在线' : loading ? '模型加载中' : running ? '服务运行中' : '服务未运行');
    if (health === 'offline' && status?.health?.detail) state.lastPollError = status.health.detail;
    renderMonitor(status);
  }

  function parseMetric(raw, names) {
    for (const name of names) {
      const match = String(raw || '').match(new RegExp(`^${name}\\s+([0-9.+-]+)`, 'm'));
      if (match) return Number(match[1]);
    }
    return 0;
  }
  function renderMonitor(status) {
    const cpu = Number(status?.system?.cpu_percent); const memory = Number(status?.system?.memory_used_percent);
    setText('#monitor-cpu', Number.isFinite(cpu) ? `${cpu.toFixed(1)}%` : '—');
    setText('#monitor-memory', Number.isFinite(memory) ? `${memory.toFixed(1)}%` : '—');
    setText('#monitor-memory-note', status?.system?.memory_total_gb ? `${status.system.memory_free_gb} GB 可用 / ${status.system.memory_total_gb} GB` : '系统内存');
    setText('#monitor-process-memory', status?.process?.memory_mb ? `${status.process.memory_mb} MB` : '—');
    setText('#monitor-uptime', fmtUptime(status?.process?.uptime_sec)); setText('#monitor-backend', `后端 ${(status?.backend || '—').toUpperCase()}`);
    setText('#monitor-model', status?.model || '—'); setText('#monitor-model-backend', (status?.backend || '—').toUpperCase());
    setText('#monitor-model-context', status?.context ? `${Number(status.context).toLocaleString()} tokens` : '—'); setText('#monitor-model-max', status?.max_tokens ? `${Number(status.max_tokens).toLocaleString()} tokens` : '—');
    setText('#monitor-model-size', status?.model_size_gb ? `${status.model_size_gb} GB` : '—'); setText('#monitor-metrics-enabled', status?.metrics_enabled ? '已启用' : '未启用');
    if (Number.isFinite(cpu) && Number.isFinite(memory)) { state.systemHistory.push({ cpu, memory }); state.systemHistory = state.systemHistory.slice(-40); }
  }
  function renderMetrics(metrics) {
    const raw = metrics?.raw || '';
    const generated = parseMetric(raw, ['llamacpp:predicted_tokens_seconds', 'llama:predicted_tokens_seconds']);
    const prompt = parseMetric(raw, ['llamacpp:prompt_tokens_seconds', 'llama:prompt_tokens_seconds']);
    const requests = parseMetric(raw, ['llamacpp:requests_processing', 'llama:requests_processing']);
    setText('#monitor-tokens', generated ? `${generated.toFixed(1)} tok/s` : '—'); setText('#monitor-tokens-note', prompt ? `输入 ${prompt.toFixed(1)} tok/s` : '等待请求采样'); setText('#monitor-requests', Number.isFinite(requests) ? String(requests) : '—');
    state.tokenHistory.push({ generated, prompt }); state.tokenHistory = state.tokenHistory.slice(-40);
  }

  async function refreshStatus(showFeedback = false) {
    try {
      const [status, config, metrics] = await Promise.all([api('/api/status', { silent: true }), api('/api/config', { silent: true }), api('/api/metrics', { silent: true })]);
      state.config = config; renderStatus(status); renderMetrics(metrics); fillConfig(config); updateDashboardLogs();
      if (showFeedback) showModal('success', '状态已刷新', '控制服务、模型健康状态和系统指标已经更新。');
    } catch (error) {
      setControlHealth('error', '控制服务不可用'); setText('#dash-service', '控制台离线'); setText('#dash-service-note', error.message); setText('#dash-service-state', '');
      if (showFeedback) showModal('error', '刷新失败', error.message, error.detail || '');
    }
  }

  function fillConfig(config, force = false) {
    if (state.configDirty && !force) return;
    const next = config || state.config || {};
    state.config = next;
    const modelSelect = $('#cfg-model');
    if (modelSelect) {
      const models = (state.environment?.models || []).map(m => m.name);
      const names = Array.from(new Set([...(models || []), next.model].filter(Boolean)));
      modelSelect.innerHTML = names.length ? names.map(name => `<option value="${escapeHtml(name)}">${escapeHtml(name)}</option>`).join('') : '<option value="">未发现 GGUF 模型</option>';
      modelSelect.value = next.model || '';
    }
    const map = { backend: '#cfg-backend', port: '#cfg-port', context: '#cfg-context', max_tokens: '#cfg-max-tokens', temperature: '#cfg-temperature', threads: '#cfg-threads', gpu_layers: '#cfg-gpu-layers', startup_timeout_sec: '#cfg-timeout', reasoning: '#cfg-reasoning' };
    Object.entries(map).forEach(([key, selector]) => { if ($(selector)) $(selector).value = next[key] ?? ''; });
    [['prefer_gpu','#cfg-prefer-gpu'], ['auto_cpu_fallback','#cfg-auto-fallback'], ['metrics','#cfg-metrics']].forEach(([key, selector]) => { if ($(selector)) $(selector).checked = !!next[key]; });
    setText('#config-state', '已同步');
  }
  function readConfigForm() {
    return { ...state.config, model: $('#cfg-model').value, backend: $('#cfg-backend').value, port: Number($('#cfg-port').value), context: Number($('#cfg-context').value), max_tokens: Number($('#cfg-max-tokens').value), temperature: Number($('#cfg-temperature').value), threads: Number($('#cfg-threads').value), gpu_layers: Number($('#cfg-gpu-layers').value), startup_timeout_sec: Number($('#cfg-timeout').value), reasoning: $('#cfg-reasoning').value, prefer_gpu: $('#cfg-prefer-gpu').checked, auto_cpu_fallback: $('#cfg-auto-fallback').checked, metrics: $('#cfg-metrics').checked };
  }
  async function saveConfig(restart = false) {
    try {
      state.config = await api('/api/config', { method: 'PUT', body: JSON.stringify(readConfigForm()) });
      state.configDirty = false;
      fillConfig(state.config, true);
      if (restart) { await api('/api/action', { method: 'POST', body: JSON.stringify({ action: 'restart' }) }); showModal('success', '配置已应用', '配置已保存，模型服务正在重启。请在监控面板等待健康状态恢复。'); }
      else showModal('success', '配置已保存', '部署参数已写入 F:\\PortableAI\\config\\config.json。');
    } catch (error) { showModal('error', restart ? '应用失败' : '保存失败', error.message, error.detail || ''); }
  }
  $$('#config-form input, #config-form select').forEach(node => {
    node.addEventListener('input', () => { state.configDirty = true; setText('#config-state', '有未保存修改'); });
    node.addEventListener('change', () => { state.configDirty = true; setText('#config-state', '有未保存修改'); });
  });
  $('#config-form').addEventListener('submit', event => { event.preventDefault(); saveConfig(false); });
  $('#config-apply').addEventListener('click', () => saveConfig(true));
  $('#config-reset').addEventListener('click', () => { state.configDirty = false; fillConfig(state.config, true); showModal('success', '已恢复', '表单已恢复为最近一次保存的配置。'); });

  async function runAction(action) {
    const labels = { start: '启动', stop: '停止', restart: '重启' };
    try { await api('/api/action', { method: 'POST', body: JSON.stringify({ action }) }); showModal('success', `${labels[action]}请求已发送`, '后台脚本已接受请求，控制台会持续采样服务状态。'); setTimeout(() => refreshStatus(false), 900); }
    catch (error) { showModal('error', `${labels[action]}失败`, error.message, error.detail || ''); }
  }
  $$('[data-action]').forEach(button => button.addEventListener('click', () => runAction(button.dataset.action)));
  $('#dashboard-refresh').addEventListener('click', () => refreshStatus(true));

  async function loadEnvironment(showFeedback = false) {
    try { state.environment = await api('/api/environment', { silent: !showFeedback }); renderEnvironment(); fillConfig(state.config); if (showFeedback) showModal('success', '环境检测完成', `检测到 ${state.environment.models?.length || 0} 个模型和 ${state.environment.runtimes?.filter(r => r.available).length || 0} 个可用推理后端。`); }
    catch (error) { if (showFeedback) showModal('error', '环境检测失败', error.message, error.detail || ''); }
  }
  function renderEnvironment() {
    const env = state.environment || {}; const system = env.system || {};
    $('#environment-cards').innerHTML = [
      ['操作系统', env.os || '—', env.computer ? `计算机：${env.computer}` : '—'],
      ['处理器', `${env.logical_processors || '—'} 个逻辑处理器`, '可用于 CPU 推理和服务辅助线程'],
      ['显卡', env.gpus?.length ? env.gpus.join(' / ') : '未检测到独立显卡', env.gpus?.length ? '可进一步检查 Vulkan / CUDA' : '建议选择 CPU 或安装对应运行时'],
      ['内存', system.memory_total_gb ? `${system.memory_total_gb} GB` : '—', system.memory_used_percent != null ? `已使用 ${system.memory_used_percent}% · 可用 ${system.memory_free_gb} GB` : '—']
    ].map(item => `<div class="env-card"><span>${escapeHtml(item[0])}</span><strong title="${escapeHtml(item[1])}">${escapeHtml(item[1])}</strong><small>${escapeHtml(item[2])}</small></div>`).join('');
    setText('#recommended-backend', `推荐：${String(env.recommended_backend || '—').toUpperCase()}`);
    $('#runtime-table').innerHTML = (env.runtimes || []).length ? env.runtimes.map(runtime => `<div class="runtime-row"><strong>${escapeHtml(runtime.name.toUpperCase())}</strong><code title="${escapeHtml(runtime.path)}">${escapeHtml(runtime.available ? runtime.path : (runtime.detail || '不可用'))}</code><span class="tag ${runtime.available ? 'ok' : 'off'}">${runtime.available ? '可用' : '缺失'}</span></div>`).join('') : '<span class="muted">未检测到运行时。</span>';
    $('#model-table').innerHTML = (env.models || []).length ? env.models.map(model => `<div class="model-row"><strong>${escapeHtml(model.name)}</strong><span class="tag ok">${escapeHtml(model.size_gb)} GB</span><small>${escapeHtml(model.path)}</small></div>`).join('') : '<span class="muted">models 目录中没有 GGUF 文件。</span>';
  }

  async function loadProviders(showFeedback = false) {
    try { state.providers = await api('/api/providers', { silent: !showFeedback }); state.selectedProviderId = state.selectedProviderId || state.providers.active_provider || state.providers.providers[0]?.id || ''; renderProviders(); if (showFeedback) showModal('success', '供应商已刷新', `已读取 ${state.providers.providers?.length || 0} 个供应商配置。`); }
    catch (error) { if (showFeedback) showModal('error', '读取供应商失败', error.message, error.detail || ''); }
  }
  function selectedProvider() { return state.providers.providers.find(provider => provider.id === state.selectedProviderId); }
  function renderProviders() {
    setText('#provider-count', `${state.providers.providers.length} 个`);
    $('#provider-list').innerHTML = state.providers.providers.length ? state.providers.providers.map(provider => `<div class="provider-item ${provider.id === state.selectedProviderId ? 'selected' : ''}" data-provider-id="${escapeHtml(provider.id)}"><div class="provider-item-top"><strong>${escapeHtml(provider.name || provider.id)}</strong><span class="tag ${provider.enabled ? 'ok' : 'off'}">${provider.enabled ? '启用' : '停用'}</span></div><small>${escapeHtml(provider.base_url || '未配置地址')}</small><div class="provider-item-meta"><span>${escapeHtml(provider.kind || '自定义')}</span>${provider.id === state.providers.active_provider ? '<span class="current">当前供应商</span>' : ''}</div></div>`).join('') : '<span class="muted">尚未配置供应商。</span>';
    $$('.provider-item').forEach(item => item.addEventListener('click', () => { state.selectedProviderId = item.dataset.providerId; renderProviders(); fillProviderEditor(); }));
    fillProviderEditor();
  }
  function fillProviderEditor() {
    const provider = selectedProvider();
    if (!provider) { setText('#provider-editor-title', '选择供应商'); setText('#provider-active-mark', '未选择'); $('#provider-form').querySelectorAll('input, textarea, select, button').forEach(node => { node.disabled = true; }); return; }
    $('#provider-form').querySelectorAll('input, textarea, select, button').forEach(node => { node.disabled = false; });
    setText('#provider-editor-title', provider.name || provider.id); setText('#provider-active-mark', provider.id === state.providers.active_provider ? '当前供应商' : '未设为当前'); $('#provider-active-mark').className = `active-mark ${provider.id === state.providers.active_provider ? 'active' : ''}`;
    const modelSelect = $('#provider-model'); const modelOptions = Array.from(new Set([...(provider.models || []), provider.model].filter(Boolean))); modelSelect.innerHTML = '<option value="">未选择</option>' + modelOptions.map(model => `<option value="${escapeHtml(model)}">${escapeHtml(model)}</option>`).join(''); modelSelect.value = provider.model || modelOptions[0] || '';
    const values = { '#provider-id': provider.id, '#provider-name': provider.name, '#provider-kind': provider.kind, '#provider-format': provider.api_format, '#provider-url': provider.base_url, '#provider-key': provider.api_key, '#provider-models': (provider.models || []).join('\n'), '#provider-config-file': provider.config_file, '#provider-config-content': '', '#provider-description': provider.description };
    Object.entries(values).forEach(([selector, value]) => { if ($(selector)) $(selector).value = value || ''; }); $('#provider-enabled').checked = provider.enabled !== false;
  }
  function readProviderEditor() {
    const current = selectedProvider(); if (!current) throw new Error('请先选择一个供应商');
    return { ...current, id: $('#provider-id').value.trim(), name: $('#provider-name').value.trim(), kind: $('#provider-kind').value, api_format: $('#provider-format').value, base_url: $('#provider-url').value.trim(), api_key: $('#provider-key').value, model: $('#provider-model').value.trim(), models: $('#provider-models').value.split(/\r?\n/).map(item => item.trim()).filter(Boolean), config_file: $('#provider-config-file').value.trim(), description: $('#provider-description').value.trim(), enabled: $('#provider-enabled').checked };
  }
  function updateSelectedProviderFromForm() { const updated = readProviderEditor(); const index = state.providers.providers.findIndex(provider => provider.id === state.selectedProviderId); if (index < 0) throw new Error('供应商不存在'); state.providers.providers[index] = updated; state.selectedProviderId = updated.id; }
  $('#provider-new').addEventListener('click', () => { const id = `provider-${Date.now()}`; state.providers.providers.push({ id, name: '新供应商', kind: '自定义', enabled: true, base_url: 'http://127.0.0.1:11436', api_format: 'OpenAI Chat Completions', api_key: '', models: [], config_file: '', description: '' }); state.selectedProviderId = id; renderProviders(); showModal('success', '已新增供应商', '请填写右侧配置并点击“保存供应商”写入文件。'); });
  $('#provider-save').addEventListener('click', async () => { try { updateSelectedProviderFromForm(); state.providers = await api('/api/providers', { method: 'PUT', body: JSON.stringify(state.providers) }); state.selectedProviderId = state.providers.active_provider || state.selectedProviderId; renderProviders(); showModal('success', '供应商已保存', '供应商配置已写入 F:\\PortableAI\\config\\providers.json。'); } catch (error) { showModal('error', '保存供应商失败', error.message, error.detail || ''); } });
  $('#provider-test').addEventListener('click', async () => { try { updateSelectedProviderFromForm(); const provider = selectedProvider(); const result = await api('/api/providers/test', { method: 'POST', body: JSON.stringify({ provider_id: provider.id }) }); if (!result.ok) { showModal('error', '供应商连接失败', result.message, `地址：${result.checked_url}\n状态：${result.status_code || '未获得 HTTP 状态'}`); return; } showModal('success', '供应商连接成功', `${provider.name} 返回了可用响应。`, `地址：${result.checked_url}\n发现模型：${(result.models || []).join(', ') || '接口未返回模型列表'}`); } catch (error) { showModal('error', '测试连接失败', error.message, error.detail || ''); } });
  $('#provider-models-fetch').addEventListener('click', async () => { try { updateSelectedProviderFromForm(); const provider = selectedProvider(); const result = await api('/api/providers/test', { method: 'POST', body: JSON.stringify({ provider_id: provider.id }) }); if (!result.ok) { showModal('error', '获取模型失败', result.message, `地址：${result.checked_url}`); return; } $('#provider-models').value = (result.models || []).join('\n'); const modelSelect = $('#provider-model'); modelSelect.innerHTML = '<option value="">未选择</option>' + (result.models || []).map(model => `<option value="${escapeHtml(model)}">${escapeHtml(model)}</option>`).join(''); if (result.models?.length) modelSelect.value = result.models[0]; showModal('success', '模型获取成功', `已从 ${result.checked_url} 获取 ${result.models?.length || 0} 个模型。请点击“保存供应商”保存列表。`); } catch (error) { showModal('error', '获取模型失败', error.message, error.detail || ''); } });
  $('#provider-file-view').addEventListener('click', async () => { try { const provider = selectedProvider(); const result = await api(`/api/providers/file?id=${encodeURIComponent(provider.id)}`); $('#provider-config-content').value = result.content || ''; showModal('success', '配置文件已读取', `已载入 ${result.path}，可在右侧编辑后保存。`, result.content || '(文件为空)'); } catch (error) { showModal('error', '读取配置文件失败', error.message, error.detail || ''); } });
  $('#provider-file-save').addEventListener('click', async () => { try { const provider = selectedProvider(); const result = await api('/api/providers/file', { method: 'PUT', body: JSON.stringify({ provider_id: provider.id, content: $('#provider-config-content').value }) }); showModal('success', '配置文件已保存', `已写入 ${result.path}。`); } catch (error) { showModal('error', '保存配置文件失败', error.message, error.detail || ''); } });
  $('#provider-set-active').addEventListener('click', async () => { try { updateSelectedProviderFromForm(); state.providers.active_provider = state.selectedProviderId; state.providers = await api('/api/providers', { method: 'PUT', body: JSON.stringify(state.providers) }); renderProviders(); showModal('success', '当前供应商已切换', `已将“${selectedProvider()?.name || state.selectedProviderId}”设为当前供应商。`); } catch (error) { showModal('error', '切换供应商失败', error.message, error.detail || ''); } });

  async function updateDashboardLogs() { try { const data = await api('/api/logs?name=startup&tail=7', { silent: true }); const lines = (data.lines || []).filter(Boolean).slice(-6); $('#dash-log-lines').innerHTML = lines.length ? lines.map(line => { const match = line.match(/^\[([^\]]+)\]\s*(.*)$/); return `<div class="log-line"><time>${escapeHtml(match ? match[1] : '')}</time><span title="${escapeHtml(match ? match[2] : line)}">${escapeHtml(match ? match[2] : line)}</span></div>`; }).join('') : '<span class="muted">暂无启动日志</span>'; } catch { /* 后台刷新不打断页面 */ } }
  async function loadLog(showFeedback = false) { const name = $('#log-source').value; const tail = $('#log-tail').value; try { const data = await api(`/api/logs?name=${encodeURIComponent(name)}&tail=${encodeURIComponent(tail)}`, { silent: !showFeedback }); $('#log-viewer').textContent = (data.lines || []).join('\n') || '(日志为空)'; setText('#log-file-label', `${name} · ${data.lines?.length || 0} 行`); if (showFeedback) showModal('success', '日志已刷新', `已读取 ${data.lines?.length || 0} 行 ${name} 日志。`); } catch (error) { $('#log-viewer').textContent = `读取失败：${error.message}`; if (showFeedback) showModal('error', '日志读取失败', error.message, error.detail || ''); } }
  $('#logs-refresh').addEventListener('click', () => loadLog(true)); $('#log-source').addEventListener('change', () => loadLog(false)); $('#log-tail').addEventListener('change', () => loadLog(false));

  function drawLineChart(canvasSelector, series, colors, maxValue = 100) {
    const canvas = $(canvasSelector); if (!canvas) return; const rect = canvas.getBoundingClientRect(); const ratio = window.devicePixelRatio || 1; const width = Math.max(300, rect.width); const height = 260; canvas.width = width * ratio; canvas.height = height * ratio; const ctx = canvas.getContext('2d'); ctx.scale(ratio, ratio); ctx.clearRect(0, 0, width, height);
    const pad = { left: 36, right: 14, top: 15, bottom: 28 }; const chartW = width - pad.left - pad.right; const chartH = height - pad.top - pad.bottom; ctx.strokeStyle = '#e6ebef'; ctx.lineWidth = 1; ctx.fillStyle = '#87939d'; ctx.font = '11px Segoe UI';
    [0, .25, .5, .75, 1].forEach(t => { const y = pad.top + chartH * (1 - t); ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(width - pad.right, y); ctx.stroke(); ctx.fillText(`${Math.round(maxValue * t)}`, 3, y + 4); });
    series.forEach((values, index) => { if (!values.length) return; ctx.strokeStyle = colors[index]; ctx.lineWidth = 2; ctx.beginPath(); values.forEach((value, pointIndex) => { const x = pad.left + chartW * (pointIndex / Math.max(values.length - 1, 1)); const y = pad.top + chartH * (1 - Math.min(Math.max(Number(value) || 0, 0), maxValue) / maxValue); pointIndex ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }); ctx.stroke(); });
  }
  function drawCharts() { drawLineChart('#system-chart', [state.systemHistory.map(point => point.cpu), state.systemHistory.map(point => point.memory)], ['#2879e8', '#17a673'], 100); const tokenMax = Math.max(10, ...state.tokenHistory.flatMap(point => [point.generated || 0, point.prompt || 0])); drawLineChart('#token-chart', [state.tokenHistory.map(point => point.generated), state.tokenHistory.map(point => point.prompt)], ['#b76712', '#8b5fc1'], tokenMax); }
  window.addEventListener('resize', drawCharts);

  function tickClock() { setText('#clock', new Date().toLocaleTimeString('zh-CN', { hour12: false })); }
  setInterval(tickClock, 1000); tickClock();
  $('#scan-environment').addEventListener('click', () => loadEnvironment(true));
  (async function init() { await Promise.all([loadEnvironment(false), loadProviders(false)]); await refreshStatus(false); loadLog(false); setInterval(() => { refreshStatus(false); drawCharts(); }, 3000); })();
})();
