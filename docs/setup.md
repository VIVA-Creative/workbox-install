# Setting up VIVA Workbox on the Rockville machine

Hi Manfred — this guide walks you through standing up Workbox on the new
Windows 11 Pro machine at the Rockville office. The installer does most of
the work; you mainly need to start it, answer two prompts, and wait.

Plan on about 15–20 minutes once you're at the keyboard. Most of that is
waiting for downloads.

## Before you start — checklist

You'll need:

1. **A Windows 11 Pro machine** (Enterprise or Education edition also work; Home will not).
2. **Administrator rights** on that machine.
3. **Box Drive** installed, signed in to your VIVA account, and finished
   syncing the folder **`VIVA Corner Projection`** inside Bob's Working
   Folder. The installer reads a secrets file from there — if Box hasn't
   synced it, the installer will wait up to 5 minutes and then fail.
4. **A working internet connection.**
5. **About 15 minutes of uninterrupted time at the keyboard.** The
   installer pauses once to ask you to paste a public key into GitHub.

Bob will have:

- Generated the secrets file (`rockville-workbox.env`) and dropped it in Box.
- Generated a Tailscale auth key and written it into that file.
- Given you access to this repo and the `VIVA-Creative/workbox` repo on
  GitHub (you'll need to be signed in to GitHub to add the deploy key).

If anything in the checklist above isn't ready, message Bob before starting.

## Step 1 — Get the installer onto the machine

Open **PowerShell** (Start menu → type "PowerShell" → click "Windows
PowerShell"). Then:

```powershell
cd C:\
git clone https://github.com/VIVA-Creative/workbox-install.git
cd workbox-install
```

If `git` isn't installed yet, download the repo as a ZIP from
https://github.com/VIVA-Creative/workbox-install and extract it to
`C:\workbox-install\`.

## Step 2 — Re-open PowerShell as Administrator

The installer needs admin rights to register a Windows service.

1. Close the PowerShell window from Step 1.
2. Click Start, type **PowerShell**.
3. Right-click **Windows PowerShell** and choose **Run as administrator**.
4. Click **Yes** on the UAC prompt.
5. `cd C:\workbox-install`

## Step 3 — Run the installer

```powershell
.\install.ps1
```

> Note: if Bob asks you to test with an alternate secrets file (e.g., during staging), you can pass `-EnvFile bob.env` as a parameter. For a normal production install, no parameter is needed.

If PowerShell refuses with "execution of scripts is disabled," allow it once
for this session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\install.ps1
```

## What to expect

The installer prints a section header for each phase. It will:

1. Check that everything's in order (admin rights, Windows edition, internet).
2. Show you a summary of what it's about to install and ask **`Proceed? [Y/n]`** — type `Y`.
3. Install Node.js, Git, NSSM, Tailscale, and Claude Code. **Each of these can take a couple minutes.** Output may look noisy. That's normal.
4. Ask: **"Windows username whose Box Drive holds the secrets folder"** — enter your Windows username (whatever's after `C:\Users\` in your home folder).
5. Find and validate the `.env` from Box.
6. Join Tailscale.
7. Generate an SSH key, **show you the public key**, and tell you to add it to GitHub. **This is the one step that requires you to do something in a browser.** Do this:
   - Open https://github.com/VIVA-Creative/workbox/settings/keys (sign in if needed).
   - Click **Add deploy key**.
   - Title: `Rockville install machine`
   - Key: paste the public key shown in PowerShell.
   - **Leave "Allow write access" unchecked.**
   - Click **Add key**.
   - Come back to PowerShell and press **Enter**.
8. Clone the Workbox repo, register the service, and run smoke tests.
9. Print a green success summary with the Tailscale IP — **screenshot or copy this**, and send it to Bob.

## When it's done

The Workbox service is running and set to auto-start with Windows. You
shouldn't need to touch it again unless something breaks.

If you want to confirm it's still healthy any time:

```powershell
cd C:\workbox-install
.\verify.ps1
```

That's a read-only check — it won't change anything.

## If it fails

Each phase prints a clear error if something goes wrong. The most common
issues and how to fix them are in
**[troubleshooting.md](troubleshooting.md)**.

If the fix isn't there, send Bob the full PowerShell output (scroll up,
right-click in the window to select all, copy, paste in a message) and he'll
sort it out.

## Post-install: what Bob needs to do

Nothing on your end. Bob takes the Tailscale IP from the success summary
and configures his MCP client to dispatch tasks to it. After that the
Rockville machine just sits there serving requests over Tailscale.

Thanks Manfred — appreciate the help.
