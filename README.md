# SilentFrame
A Research POC on Post-Exploitation Credential Collection through Chromium Browsers

## Screenshots of tool

#### Hooked Page
<img width="632" height="497" alt="image" src="https://github.com/user-attachments/assets/fc8aa018-7fe6-40e3-aa5d-76561185abb5" />

#### SilentFrame  
<img width="975" height="379" alt="image" src="https://github.com/user-attachments/assets/18ed6f76-44d5-475a-845e-66acc3239b61" />

## Setup

Since SilentFrame requires CDP to be running you must either execute the Chroumium based browser with the debugger flag like so:
```powershell
& "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"   --remote-debugging-port=9222
```

or poison the .lnk aka the shortcut file

Multi Lined
```PowerShell
$wsh = New-Object -ComObject WScript.Shell
$sc  = $wsh.CreateShortcut("$env:USERPROFILE\Desktop\Microsoft Edge.lnk")
$sc.TargetPath = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
$sc.Arguments  = "--remote-debugging-port=9222"
$sc.Save()
```

One-Line
```powershell
$sc=(New-Object -ComObject WScript.Shell).CreateShortcut("$env:USERPROFILE\Desktop\Microsoft Edge.lnk");$sc.Arguments=($sc.Arguments+" --remote-debugging-port=9222").Trim();$sc.Save()
```


#### To Run
```Powershell
./SilentFrame 
```
If you want to change the JavaScript being run can use the `-Js` flag 
If you want to change the debugging port you can use the `-Port` flag

> [!IMPORTANT]
> Due to the nature of this script we intentionally neutered the capabilites to not work within multi‑step login flows like those found on Gmail or O365 in order to prvent script-kiddie level wins. Though, if properly modified the script can work within these environments. 



## How It Works

SilentFrame works by initally querying `http://127.0.0.1:9222/json/version`, which is the CDP discovery endpoint exposed by the browser when remote debugging is enabled. This endpoint returns metadata about the running browser instance, including the `webSocketDebuggerUrl`, which represents the browser’s primary control channel. It then establishes a single browser-level WebSocket connection to this endpoint rather than opening a per-tab connection, enabling it to operate as a centralized observer and controller.

Once connected, SilentFrame enables target discovery and automatic attachment by invoking `Target.setDiscoverTargets` and `Target.setAutoAttach`. This places the browser into an observable state where all existing and future targets, which include tabs, iframes, and background pages, emit lifecycle events. Any newly created targets are automatically attached to the session without operator intervention, while targets that existed prior to the connection are enumerated using `Target.getTargets` and manually attached via  the `Target.attachToTarget` function.

As targets are attached, SilentFrame maintains an internal mapping of `targetId` to `sessionId`. This mapping helps tremendously, as all subsequent CDP messages are multiplexed over the same WebSocket and must be demultiplexed to attribute events, logs, and script execution to the correct browsing context. At this point within the script, SilentFrame has persistent, browser-wide visibility into tab creation, navigation, and teardown without ever interacting with the desktop or browser UI. We purposely left artifacts within the POC so as not to just hand a dangerous weapon over to those with less morals, but with the proper background knowledge it could be modified to remove these artifacts. 

For each attached target, SilentFrame waits until a valid web context exists before enabling higher-level domains. In this context, domain isn’t referring to a hosted named location, like a webpage, but instead a functional internal namespace within CDP, like `Runtime` or `Page`. Now once a target resolves to an HTTP or HTTPS URL, it enables the `Runtime`, `Page`, and `Log` domains and turns on lifecycle event reporting. This ensures that the attack mechanism occurs only for actual web content, not for internal browser pages or transient targets.

From there, SilentFrame operates as a passive listener with selective active execution. It consumes messages forwarded through `Target.receivedMessageFromTarget`, logging console output, runtime exceptions, page lifecycle events, and other execution signals in real time. We decided that all message types should be consumed for debugging and visibility, though in practice, this can be reduced to a smaller subset focused on DOM activity, navigation events, runtime evaluation, and logging for brevity of logging without impacting functionality.

On `DOMContentLoaded`, a single JavaScript payload is injected using `Runtime.evaluate`, tracked with a unique message identifier to confirm execution and capture results. The page continues to load and function normally, but its execution environment now includes our script operator as an observer.

## Defensive Considerations

Detection and prevention of this proof-of-concept or others similar to it hinge less on the JavaScript executed within the browser and more on the conditions that enable CDP access in the first place. High-confidence indicators include Chromium-based browsers launched with the `--remote-debugging-port` flag, persistent local WebSocket connections to 127.0.0.1, and repeated use of the CDP `Target` domain consistent with automation or instrumentation workflows. When correlated together, these signals strongly suggest that the browser’s control plane has been externally attached, even if the browser’s visible behavior remains unchanged. 

The best way to monitor for these would be to use a tool like SysInternal’s Sysmon ingested into your SIEM.

For process-level detection, the anchor event is Sysmon `Event ID 1, Process Create`. This is where you catch the Chromium-based browsers being launched with non-standard command-line arguments. You’re specifically looking for `msedge.exe`, `chrome.exe`, or other Chromium derivatives where the `CommandLine` field contains `--remote-debugging-port`. That flag alone isn’t malicious, but in user workstations it is rare enough to be a meaningful starting condition. If you already log parent process information, correlating the browser launch back to `explorer.exe` versus a background process or script host adds even more context.

For the control channel itself, `Sysmon Event ID 3, Network Connection`, is the next high-signal source. This event will show loopback connections to `127.0.0.1` on the specified debugging port, typically `9222` but not always as the debugging flag allows for any port to be specified. Normal browsing does not involve persistent loopback TCP connections to the browser process, so a long-lived or repeatedly re-established connection to `localhost` tied to a Chromium PID is a strong indicator that CDP is in use. When you can correlate `Event ID 3` back to a browser process previously flagged in `Event ID 1`, the confidence jumps significantly.

If you want to catch the “poisoning-the-well” setup step rather than just the runtime behavior, `Sysmon Event ID 11`, File Create, is useful for monitoring `.lnk` modifications in user-accessible locations such as the Desktop, Start Menu, or Taskbar pin directories. Changes to existing browser shortcuts, especially when followed by a browser relaunch with modified arguments, form a clean before-and-after trail that is easy to explain to incident responders.

Optionally, `Sysmon Event ID 7`, Image Load, can provide supporting context by showing script engines or unusual modules being loaded into non-interactive processes that later establish loopback connections to the browser. This is not a primary signal, but it helps distinguish developer tooling from malicious automation during deeper triage.

## Testing Results

The following vendor detection table presents our test results on whether the action was detected by the vendor. This table is only relevant as of 01-29-2026. Any testing conducted after this date may yield different results. 

| AV Vendor 	|  Detected? 		| Notes 	|
| ------------  	| -----------| ---------------		|
| McAffee	| Not Detected	|		|
| Avast 	| Not Detected	|		|
| TrendMicro	| Not Detected 	|		|	
| ESET		| Not Detected 	|		|
| Defender	| Not Detected 	|		|
| BitDefender | Not Detected 	|		|
| AVG		| Not Detected 	|		|
| CS Falcon	| Not Detected	| Not Aggressive Mode 	|
| Sophos	| Not Detected 	|		|
| Cylance	| Not Detected	|		|


