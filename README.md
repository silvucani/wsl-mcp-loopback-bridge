# wsl-mcp-loopback-bridge

Reach a Windows MCP server from a client running inside WSL2.

Paper Desktop was unreachable from my WSL2 setup on Windows 10, so I wrote this. Nothing in it
is specific to Paper.

A desktop MCP server binds `127.0.0.1` on Windows. WSL2 has its own network stack, so that
socket is invisible from inside WSL:

```
Failed to reconnect to plugin:paper-desktop:paper: ConnectionRefused at http://127.0.0.1:29979/mcp
```

You are affected if the server runs as a Windows app, speaks HTTP (a `url` in your client
config, not a `command`), and your client runs in WSL2. Servers launched over stdio and hosted
servers are fine.

## Use

```bash
sudo apt install socat     # once
./bridge.sh                # defaults to port 29979
./bridge.sh 1234           # any other app port
./bridge.sh --stop
```

On success:

```
bridge is up: http://127.0.0.1:29979/mcp
"name":"paper-desktop","version":"0.5.3"
```

Your client config does not change. Reconnect the client afterwards, since Claude Code does not
retry a server that failed at startup.

Needs Node.js on Windows, reachable from WSL as `node.exe`, and `socat` in WSL. No admin rights.

## On Windows 11, use this instead

One line in `C:\Users\<you>\.wslconfig`, then `wsl --shutdown`:

```ini
[wsl2]
networkingMode=mirrored
```

Windows 10 refuses it, since it needs build 22621. Hence this repository.

## How it works

```
client (WSL) -> 127.0.0.1:29979
  -> socat (WSL)          -> 172.29.128.1:39979
    -> relay.js (Windows) -> 127.0.0.1:29979
      -> the app
```

`relay.js` has to run on Windows, because nothing configured inside WSL can reach the Windows
loopback. `bridge.sh` starts it through WSL interop, so it stays one command in one shell.

The `socat` hop is the half that is easy to miss. Some servers check the `Host` header to block
DNS rebinding, so a plain port forward earns:

```
HTTP/1.1 403 Forbidden
{"error":"forbidden","error_description":"Invalid host"}
```

Listening on `127.0.0.1` at the app's own port makes the client send `Host: 127.0.0.1:29979`,
which passes. The port counts as much as the address: `127.0.0.1:39979` is rejected the same way.

Neither hop parses HTTP, so SSE and long-lived sessions work normally.

## Limits

Nothing survives a reboot. Rerun `bridge.sh`, or add it to your `~/.bashrc`.

The relay listens on every interface and is not authenticated. To keep it off your LAN:

```powershell
New-NetFirewallRule -DisplayName "WSL MCP bridge" -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 39979 -InterfaceAlias "vEthernet (WSL)"
```

## Licence

MIT
