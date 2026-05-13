# Troubleshooting

Failure modes you might hit during or after `install.ps1`, with the exact fix
for each.

---

## "winget : The term 'winget' is not recognized..."

**What it means.** Windows didn't ship with the App Installer package, or it's
been stripped from this image.

**Fix.** Open the Microsoft Store, search for **App Installer**, install it,
restart PowerShell, and re-run `install.ps1`.

---

## "Node vX.Y.Z is older than required v20.12"

**What it means.** An older Node is on PATH (often from a Node MSI installed
manually months ago), and winget's newer install isn't first on PATH yet.

**Fix.**
1. Close the PowerShell window.
2. Open a fresh elevated PowerShell window.
3. Confirm: `node --version` (should report v20.12 or newer).
4. If still old: `winget upgrade --id OpenJS.NodeJS.LTS`
5. Re-run `install.ps1`.

If the old Node is from a side install you don't want, uninstall it via
Settings → Apps, then re-run.

---

## "claude not on PATH after npm install"

**What it means.** `npm install -g` succeeded, but the npm global bin
directory isn't yet on the current shell's PATH.

**Fix.** Open a fresh elevated PowerShell window and re-run `install.ps1`.
The installer will detect Claude Code is already installed and skip ahead.

---

## "Box Drive root not found at C:\Users\<user>\Box"

**What it means.** The Windows username you entered doesn't have a `Box`
folder, so either Box Drive isn't installed for that user, or you typed the
wrong username.

**Fix.**
- Check `C:\Users\` and see which folder is yours.
- Confirm Box Drive is installed (Start menu → Box). If not, install it from
  https://www.box.com/resources/downloads.
- Sign in to Box with the VIVA account.
- Re-run `install.ps1` and enter the correct username.

---

## "Secrets folder not found at C:\Users\\...\\VIVA Corner Projection\\secrets"

**What it means.** Box Drive is signed in, but the projection folder hasn't
been added to your sync list, or it hasn't finished syncing yet.

**Fix.**
- Open Box (web or app) → navigate to the folder → make sure it's marked
  for sync (right-click → "Make available offline" if needed).
- Watch for the green check mark in File Explorer next to the folder.
- Re-run `install.ps1`.

---

## "rockville-workbox.env did not appear within 5 minutes"

**What it means.** The secrets file isn't in the expected folder, or Box is
very slow to sync.

**Fix.**
- Ask Bob to confirm he saved `rockville-workbox.env` (no other name) into
  the secrets folder.
- In File Explorer, navigate to the secrets folder and confirm the file is
  visible with a green check (fully synced, not just a placeholder).
- Re-run `install.ps1`.

---

### "Secrets file not found" but Box Drive is synced

The installer defaults to looking for `rockville-workbox.env`. If you need
to point at a different file:

    .\install.ps1 -EnvFile bob.env

Useful for staging tests where a separate secrets file lives in the same
Box folder.

---

## "TAILSCALE_AUTHKEY is still the placeholder"

**What it means.** The `.env` file in Box still contains the literal string
`__FILL_IN_BEFORE_INSTALL__` instead of a real Tailscale auth key.

**Fix.**
- Bob: generate a new auth key at
  https://login.tailscale.com/admin/settings/keys
- Edit `rockville-workbox.env` in Box and replace the placeholder with the
  real key. Save.
- Wait for Box to sync (green check).
- Re-run `install.ps1`.

---

## "tailscale up failed"

**What it means.** Usually the auth key was already used, has expired, or
was revoked. Tailscale auth keys are single-use by default.

**Fix.**
- Bob: generate a *new* auth key in the Tailscale admin console.
- Update `.env` in Box, wait for sync.
- Re-run `install.ps1`.

If the failure mentions DNS or network, check the machine's internet
connection first.

---

## "GitHub did not accept the deploy key"

**What it means.** The public key shown by the installer was never registered
on the `VIVA-Creative/workbox` repo, or was registered on the wrong repo.

**Fix.**
- Open https://github.com/VIVA-Creative/workbox/settings/keys
- Confirm a deploy key titled "Rockville install machine" (or similar) is
  listed and its fingerprint matches the key printed by the installer.
- If not, click **Add deploy key**, paste the key the installer printed,
  leave "Allow write access" unchecked, click Add.
- Press Enter in PowerShell to retry.

If you've lost the public key, you can re-print it:
```powershell
Get-Content C:\ProgramData\workbox\deploy-key.pub
```

---

## "Service did not reach Running state"

**What it means.** NSSM registered the service but the Node process crashed
on startup.

**Fix.**
- Read the last lines of the stderr log:
  ```powershell
  Get-Content C:\ProgramData\workbox\state\logs\nssm-stderr.log -Tail 50
  ```
- The most common cause is a missing or malformed environment variable —
  inspect what `nssm set VIVAWorkbox AppEnvironmentExtra` resolved to:
  ```powershell
  nssm get VIVAWorkbox AppEnvironmentExtra
  ```
- The second most common cause is the wrong `node.exe` path. Confirm:
  ```powershell
  nssm get VIVAWorkbox Application
  ```
  should point to a real `node.exe`.
- Fix the underlying issue, then `Restart-Service VIVAWorkbox`.

To wipe everything and start fresh, use `uninstall.ps1` and re-run
`install.ps1`.

---

## "/health returns 401"

**What it means.** The bearer token sent by the smoke test doesn't match
what the service expects. Almost always a stale `CCWORKBOX_TOKEN` mismatch
between the `.env` and what got baked into the service environment.

**Fix.**
- Inspect the env baked into the service:
  ```powershell
  nssm get VIVAWorkbox AppEnvironmentExtra
  ```
- Compare the `CCWORKBOX_TOKEN=` value to what's in the Box `.env`. If they
  differ, re-run `install.ps1` (it'll tear down and re-register the
  service with the current `.env` values).

---

## "Test task hangs forever" / smoke task times out

**What it means.** The service accepted the task but Claude Code never
returned a result.

**Most common cause:** `ANTHROPIC_API_KEY` is invalid, expired, or out of
credit.

**Fix.**
- Bob: confirm the API key still works (try it from another machine).
- If the key is bad, update it in the Box `.env`, wait for sync, re-run
  `install.ps1`.

**Second-most-common cause:** The Workbox app can't find `claude.cmd`.

- Check the `CC_BIN` value in `nssm get VIVAWorkbox AppEnvironmentExtra` —
  it must point to a real file (typically
  `C:\Users\<admin>\AppData\Roaming\npm\claude.cmd`).
- If it's wrong, re-run `install.ps1`.

---

## "I want to start over completely"

```powershell
.\uninstall.ps1 -Yes
.\install.ps1
```

`uninstall.ps1 -Yes` accepts all defaults, which by default leave the
`C:\ProgramData\workbox` folder and the Tailscale registration in place
(safer). Pass `-Yes` and answer interactively if you want to nuke those
too.
