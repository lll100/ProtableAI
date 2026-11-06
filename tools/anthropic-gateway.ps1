param(
    [int]$Port = 11436,
    [int]$LlamaPort = 11435,
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$LogDir = Join-Path $Root 'logs'
$LogPath = Join-Path $LogDir 'anthropic-gateway.log'
$PidPath = Join-Path $LogDir 'anthropic-gateway.pid'
$ConfigPath = Join-Path $Root 'config\config.json'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Log { param([string]$Message); Add-Content -LiteralPath $LogPath -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Message) -Encoding UTF8 }
function Config { Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json }
function TextOf { param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return [string]$Value }
    $parts = @()
    foreach ($block in @($Value)) {
        if ($block -is [string]) { $parts += [string]$block; continue }
        if ($block.text) { $parts += [string]$block.text; continue }
        if ($block.content) { $parts += (TextOf $block.content) }
    }
    return ($parts -join "`n")
}
function ReadBody { param($Context); $r=New-Object IO.StreamReader($Context.Request.InputStream,[Text.Encoding]::UTF8); try{return $r.ReadToEnd()}finally{$r.Dispose()} }
function SendBytes { param($Context,[byte[]]$Bytes,[string]$Type='application/json; charset=utf-8',[int]$Status=200);$Context.Response.StatusCode=$Status;$Context.Response.ContentType=$Type;$Context.Response.ContentEncoding=[Text.Encoding]::UTF8;$Context.Response.ContentLength64=$Bytes.Length;$Context.Response.Headers['Cache-Control']='no-store';if($Context.Request.HttpMethod -ne 'HEAD' -and $Bytes.Length -gt 0){$Context.Response.OutputStream.Write($Bytes,0,$Bytes.Length)};$Context.Response.OutputStream.Close() }
function SendJson { param($Context,$Value,[int]$Status=200);SendBytes $Context ([Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 12))) 'application/json; charset=utf-8' $Status }
function Sse { param($Context,[string]$Event,$Data);$nl=[Environment]::NewLine;$payload=('event: {0}{1}' -f $Event,$nl)+'data: '+($Data|ConvertTo-Json -Compress -Depth 12)+$nl+$nl;$bytes=[Text.Encoding]::UTF8.GetBytes($payload);$Context.Response.OutputStream.Write($bytes,0,$bytes.Length);$Context.Response.OutputStream.Flush() }
function Authenticated { param($Context,$Config)
    $expected=[string]$Config.agent_api_key
    if (-not $expected) { return $true }
    $actual=[string]$Context.Request.Headers['x-api-key']
    if (-not $actual) { $auth=[string]$Context.Request.Headers['Authorization']; if($auth -match '^Bearer\s+(.+)$'){$actual=$Matches[1]} }
    if ($actual -eq $expected) { return $true }
    SendJson $Context ([ordered]@{error='invalid local API key'}) 401
    return $false
}
function LlamaChat { param($Request,$Messages)
    $limit=[int]$Request.max_tokens;if($limit -le 0){$limit=[int]$Request.max_output_tokens};if($limit -le 0){$limit=2048}
    $sourceMessages=@($Messages);if($Request.messages){$sourceMessages=@($Request.messages)}
    $payload=[ordered]@{model=[string]$Request.model;messages=$sourceMessages;max_tokens=$limit;stream=$false}
    if ($Request.temperature -ne $null) { $payload.temperature=[double]$Request.temperature }
    if ($Request.top_p -ne $null) { $payload.top_p=[double]$Request.top_p }
    $json=$payload|ConvertTo-Json -Depth 12
    $bytes=[Text.Encoding]::UTF8.GetBytes($json)
    $targetPort=$LlamaPort;try{$cfg=Config;if($cfg.port){$targetPort=[int]$cfg.port}}catch{}
    return Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/v1/chat/completions" -f $targetPort) -Method Post -ContentType 'application/json' -Body $bytes -TimeoutSec 600
}
function AnthropicMessages { param($Request)
    $messages=@()
    if ($Request.system) { $messages += [ordered]@{role='system';content=(TextOf $Request.system)} }
    foreach($m in @($Request.messages)) { $messages += [ordered]@{role=[string]$m.role;content=(TextOf $m.content)} }
    return $messages
}
function ResponseInput { param($Request)
    $messages=@()
    if ($Request.instructions) { $messages += [ordered]@{role='system';content=(TextOf $Request.instructions)} }
    if ($Request.input -is [string]) { $messages += [ordered]@{role='user';content=[string]$Request.input} }
    else { foreach($m in @($Request.input)) { if($m.role){$messages += [ordered]@{role=[string]$m.role;content=(TextOf $m.content)}} elseif($m.type -eq 'message'){$messages += [ordered]@{role=[string]$m.role;content=(TextOf $m.content)}} } }
    return $messages
}
function ResponseUsage { param($Usage)
    $input=0;$output=0;$total=0
    if($Usage){
        if($Usage.prompt_tokens -ne $null){$input=[int]$Usage.prompt_tokens}
        elseif($Usage.input_tokens -ne $null){$input=[int]$Usage.input_tokens}
        if($Usage.completion_tokens -ne $null){$output=[int]$Usage.completion_tokens}
        elseif($Usage.output_tokens -ne $null){$output=[int]$Usage.output_tokens}
        if($Usage.total_tokens -ne $null){$total=[int]$Usage.total_tokens}else{$total=$input+$output}
    }
    return [ordered]@{input_tokens=$input;input_tokens_details=[ordered]@{cached_tokens=0};output_tokens=$output;output_tokens_details=[ordered]@{reasoning_tokens=0};total_tokens=$total}
}
function HandleMessages { param($Context,$Request)
    $chat=LlamaChat -Request $Request -Messages (AnthropicMessages $Request)
    $text=[string]$chat.choices[0].message.content
    $usage=[ordered]@{input_tokens=0;output_tokens=0}
    if($chat.usage){$usage.input_tokens=[int]$chat.usage.prompt_tokens;$usage.output_tokens=[int]$chat.usage.completion_tokens}
    $message=[ordered]@{id=([string]$chat.id);type='message';role='assistant';model=[string]$Request.model;content=@([ordered]@{type='text';text=$text});stop_reason='end_turn';stop_sequence=$null;usage=$usage}
    if ([bool]$Request.stream) {
        $Context.Response.StatusCode=200;$Context.Response.ContentType='text/event-stream';$Context.Response.SendChunked=$true;$Context.Response.Headers['Cache-Control']='no-cache'
        Sse $Context 'message_start' ([ordered]@{type='message_start';message=$message});Sse $Context 'content_block_start' ([ordered]@{type='content_block_start';index=0;content_block=[ordered]@{type='text';text=''}});Sse $Context 'content_block_delta' ([ordered]@{type='content_block_delta';index=0;delta=[ordered]@{type='text_delta';text=$text}});Sse $Context 'content_block_stop' ([ordered]@{type='content_block_stop';index=0});Sse $Context 'message_delta' ([ordered]@{type='message_delta';delta=[ordered]@{stop_reason='end_turn';stop_sequence=$null};usage=$usage});Sse $Context 'message_stop' ([ordered]@{type='message_stop'});$Context.Response.OutputStream.Close();return
    }
    SendJson $Context $message
}
function HandleResponses { param($Context,$Request)
    $chat=LlamaChat -Request $Request -Messages (ResponseInput $Request)
    $text=[string]$chat.choices[0].message.content;$id='resp_'+([guid]::NewGuid().ToString('N'));$messageId='msg_'+([guid]::NewGuid().ToString('N'))
    $usage=ResponseUsage $chat.usage
    $outputItem=[ordered]@{type='message';id=$messageId;status='completed';role='assistant';content=@([ordered]@{type='output_text';text=$text;annotations=@()})}
    $response=[ordered]@{id=$id;object='response';created_at=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();model=[string]$Request.model;output=@($outputItem);output_text=$text;status='completed';incomplete_details=$null;usage=$usage}
    if ([bool]$Request.stream) {
        $Context.Response.StatusCode=200;$Context.Response.ContentType='text/event-stream';$Context.Response.SendChunked=$true;$Context.Response.Headers['Cache-Control']='no-cache'
        $created=[ordered]@{type='response.created';response=([ordered]@{id=$id;object='response';created_at=$response.created_at;model=$response.model;output=@();output_text='';status='in_progress';incomplete_details=$null;usage=$null})}
        $itemInProgress=[ordered]@{type='message';id=$messageId;status='in_progress';role='assistant';content=@()}
        $partInProgress=[ordered]@{type='output_text';annotations=@();text=''}
        Sse $Context 'response.created' $created
        Sse $Context 'response.in_progress' ([ordered]@{type='response.in_progress';response=$created.response})
        Sse $Context 'response.output_item.added' ([ordered]@{type='response.output_item.added';response_id=$id;output_index=0;item=$itemInProgress})
        Sse $Context 'response.content_part.added' ([ordered]@{type='response.content_part.added';response_id=$id;item_id=$messageId;output_index=0;content_index=0;part=$partInProgress})
        Sse $Context 'response.output_text.delta' ([ordered]@{type='response.output_text.delta';response_id=$id;item_id=$messageId;output_index=0;content_index=0;delta=$text})
        Sse $Context 'response.output_text.done' ([ordered]@{type='response.output_text.done';response_id=$id;item_id=$messageId;output_index=0;content_index=0;text=$text})
        Sse $Context 'response.content_part.done' ([ordered]@{type='response.content_part.done';response_id=$id;item_id=$messageId;output_index=0;content_index=0;part=([ordered]@{type='output_text';annotations=@();text=$text})})
        Sse $Context 'response.output_item.done' ([ordered]@{type='response.output_item.done';response_id=$id;output_index=0;item=$outputItem})
        Sse $Context 'response.completed' ([ordered]@{type='response.completed';response=$response})
        $Context.Response.OutputStream.Close();return
    }
    SendJson $Context $response
}

Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII
$listener=New-Object Net.HttpListener;$listener.Prefixes.Add(("http://127.0.0.1:{0}/" -f $Port))
try { $listener.Start();Log ("gateway listening on http://127.0.0.1:{0}" -f $Port);while($listener.IsListening){$ctx=$listener.GetContext();try{$cfg=Config;$path=$ctx.Request.Url.AbsolutePath;Log ("request {0} {1} from {2}" -f $ctx.Request.HttpMethod,$path,$ctx.Request.RemoteEndPoint);if($ctx.Request.HttpMethod -eq 'OPTIONS'){SendBytes $ctx ([Text.Encoding]::UTF8.GetBytes('')) 'text/plain' 204;continue};if($path -eq '/health' -or $path -eq '/api/hello' -or $path -eq '/api/health'){SendJson $ctx ([ordered]@{status='ok';service='PortableAI local gateway'}) 200;continue};if(-not(Authenticated $ctx $cfg)){continue};if($path -eq '/v1/models'){SendJson $ctx ([ordered]@{object='list';data=@([ordered]@{id=[string]$cfg.model;object='model';owned_by='portableai'})});continue};$req=ReadBody $ctx|ConvertFrom-Json;if($path -eq '/v1/messages' -or $path -eq '/messages'){HandleMessages $ctx $req}elseif($path -eq '/v1/responses' -or $path -eq '/responses'){HandleResponses $ctx $req}elseif($path -eq '/v1/chat/completions' -or $path -eq '/chat/completions'){ $up=LlamaChat -Request $req -Messages @();SendJson $ctx $up }else{SendJson $ctx ([ordered]@{error='endpoint not found'}) 404}}catch{Log ('request error: '+$_.Exception.Message);try{SendJson $ctx ([ordered]@{error=$_.Exception.Message}) 500}catch{}}}}finally{if($listener){$listener.Stop();$listener.Close()};Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue;Log 'gateway stopped'}
