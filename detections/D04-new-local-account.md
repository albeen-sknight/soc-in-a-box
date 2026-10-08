# D04: New local account created

**ATT&CK:** T1136.001 Create Account: Local Account
**Severity:** Medium (dashboard and Triggered Alerts, no page)
**Source:** `index=wineventlog`, event 4720

## What it catches

Someone creating a local account on a workstation.

On a PC that's joined to the domain, people sign in with domain accounts. A new local one is the classic way to keep a way back in that doesn't show up in Active Directory.

## The search

```
index=wineventlog EventCode=4720 NOT host=DC01 NOT src_user="*$" NOT src_user="ANONYMOUS LOGON"
| table _time host src_user user
```

The raw search returned **49 rows. With the filters, it's 1**, my test account:

- `NOT host=DC01`: 40 of them were Administrator creating the staff accounts on DC01. Those are domain accounts, and this detection is about local ones.
- `NOT src_user="*$"` and `NOT src_user="ANONYMOUS LOGON"`: the rest were Windows and the domain setting themselves up, creating Windows' own accounts like `krbtgt` and `defaultuser0`.

## Why Medium

On its own, a new local account is often legitimate: a kiosk, a test, an emergency account IT forgot to mention. Paging on every one would teach me to ignore the pager.

The dangerous version is a new account that then **gets admin rights**, and D03 pages for that at High. So the bad case still wakes me up. D04 is the context I see when I open it.

## What a false positive looks like

IT creating a local account on purpose. Check who created it (`src_user`) and whether there's a ticket.

## What it misses

- Accounts created as SYSTEM, which the `$` filter hides.
- Any domain controller other than DC01. If I add a second DC, the host filter needs updating.
- New domain accounts. Those are by design out of scope; they'd need their own detection.

## How I tested it

On WS02, as `.\labadmin`:

```powershell
New-LocalUser -Name "helpdesk.temp" -NoPassword -Description "SOC test account"
```

It came back as one row: WS02, `labadmin` created `helpdesk.temp`.

## The incident that proved it

None yet. Tested on purpose, not caught in the wild.
