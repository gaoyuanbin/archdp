# Arch Linux Desktop in Browser

Spin up a temporary Arch Linux desktop you can access from any browser. Runs on GitHub Actions, tunneled through zrok. Use it, close it — nothing persists.

## What you get

- Full Arch Linux desktop with dark theme, accessible in your browser
- Pre-installed: (idk lol) `kali-tools-top10` (nmap, metasploit, burpsuite, sqlmap, wireshark, hydra, john, aircrack-ng, responder, netexec)
- Firefox, terminal, file manager, and standard CLI tools
- Hack Nerd Font pre-installed for terminal symbol rendering
- Auto-expires after your chosen duration (30min–6 hours)

## Setup

1. **Fork/clone** this repo

2. **Get a free zrok token** at [myzrok.io](https://myzrok.io) — sign up, then copy your enable token from Settings

3. **Add the token** as a GitHub Actions secret:
   - Repo → Settings → Secrets → Actions → `ZROK_ENABLE_TOKEN`

4. **Build the image** (one-time):
   - Actions → "Build Arch Desktop Image" → Run workflow

5. **Start a session**:
   - Actions → "Arch Desktop Session" → Run workflow
   - Pick duration (default 1h) and password (default `abc123`)
   - Grab the zrok URL from the workflow logs
   - Log in with username `user` and your chosen password

## How it works

```
Browser → zrok (HTTPS) → KasmVNC (:6901) → Arch Desktop
```

Single container on a GitHub Actions runner. KasmVNC handles the VNC server, web client, and WebSocket transport. Session auto-terminates after your chosen duration.

## Customizing tools

Edit `Dockerfile` layer 4:

```dockerfile
kali-tools-top10          # Default — top 10 tools
kali-linux-headless       # More tools (masscan, amass, etc.)
kali-tools-top10 kali-tools-web  # Web-focused
kali-linux-default        # Full Kali (large image)
```

Push and the image auto-rebuilds.
