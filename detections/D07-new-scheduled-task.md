# D07: New scheduled task created by a person

**ATT&CK:** T1053.005 Scheduled Task/Job: Scheduled Task
**Severity:** Medium (dashboard and Triggered Alerts, no page)
**Source:** `index=wineventlog`, event 4698

## What it catches

A person creating a scheduled task.

Tasks are one of the easiest ways to make something run again after a reboot. Attackers love them for that.

## The search

```
index=wineventlog EventCode=4698
| eval creator=coalesce(src_user, user, Account_Name)
| search NOT creator="*$" NOT Task_Name="*OneDrive*Task-S-1-5-21-*"
| table _time host creator Task_Name
```

`src_user` was empty on every 4698, so this event stores who created the task under a different field. The `coalesce` takes whichever one is filled in.

## The decision: filter on who, not where

All the noise was Windows' own tasks under `\Microsoft\Windows\`: Defender, Defrag, Group Policy. The obvious fix is to leave that folder out.

I didn't, because attackers know that folder is ignored and like to hide tasks there.

Windows creates its own tasks as SYSTEM, which logs the computer account (`$`) as the creator. Leaving out `$` creators, the TJ-001 trick again, removed every one of them. So a task a *person* hides in `\Microsoft\Windows\` still gets caught. That's the better trade.

## The OneDrive filter

OneDrive's real update tasks are created under the user's account, so the `$` filter doesn't catch them. They have a very specific shape, ending with the user's SID: `OneDrive Standalone Update Task-S-1-5-21-…`.

My first version left out anything with "OneDrive" in the name. That meant a task called "OneDrive Update" would have slipped through. Now it only skips names that match the full shape, SID included.

## What a false positive looks like

An admin creating a maintenance task, or an installer creating one under the user's account. Check what the task runs.

## What it misses

- Tasks created as SYSTEM. Same blind spot as D03.
- A task named to copy OneDrive's full pattern, SID and all. It takes effort, and it still looks odd to anyone who reads it twice, but it would get through.

## How I tested it

On WS02, as `.\labadmin`:

```powershell
schtasks /create /tn "LimonadaUpdate" /tr "notepad.exe" /sc once /st 23:59 /f
```

It came back as one row: WS02, `labadmin`, `\LimonadaUpdate`. No Windows tasks, no OneDrive rows.

## The incident that proved it

None yet. Tested on purpose, not caught in the wild.
