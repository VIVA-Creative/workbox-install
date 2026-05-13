# workbox-install

Windows installer for **VIVA Workbox** — provisions a Windows 11 Pro machine
as a Workbox service host.

## What this repo is

A PowerShell installer (`install.ps1`) plus a small support script set that
turns a fresh Windows 11 Pro machine into a node that runs the Workbox
service. It:

- Installs Node.js LTS, Git, NSSM, and Tailscale via `winget`
- Installs Claude Code globally via `npm`
- Reads secrets from a Box-synced `.env` file
- Joins the machine to the VIVA Tailscale tailnet
- Generates an SSH deploy key for the private `VIVA-Creative/workbox` repo
  (operator pastes the public key into GitHub when prompted)
- Clones `VIVA-Creative/workbox` into `C:\ProgramData\workbox\app\`
- Registers it as a Windows service named **VIVA Workbox** via NSSM
- Runs smoke tests against `/health` and dispatches a trivial test task

## Related repo

The service itself lives at:
**https://github.com/VIVA-Creative/workbox**

This installer clones that repo and runs `server.js` as a service. Updates to
the service code happen there; updates to how the service is *deployed* happen
here.

## Files

| File | Purpose |
|------|---------|
| `install.ps1`            | Main installer. Idempotent — safe to re-run. |
| `verify.ps1`             | Read-only post-install health check. |
| `uninstall.ps1`          | Cleanly removes the service + state dir + Tailscale registration. |
| `.env.template`          | Documents the secrets file the installer expects to find in Box. |
| `docs/setup.md`          | Manfred-facing setup instructions for the Rockville machine. |
| `docs/troubleshooting.md`| Common failure modes and fixes. |

## Quick start (Manfred)

See **[docs/setup.md](docs/setup.md)**.

## License

MIT. See `LICENSE`.
