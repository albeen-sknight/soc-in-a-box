# D02 build and test guide: Password spray from one source

**What it catches:** one machine failing to log in against many different accounts in a short window. That is the shape of a password spray: one password tried against lots of users, instead of lots of passwords against one user (that was D01).

**Logs:** Security 4625 on the workstations, Security 4771 on DC01. Both land in `index=wineventlog`.

**ATT&CK:** T1110.003 Password Spraying. **Severity:** 4 High, pages.

**Test tool:** Windows itself, run from WS01 against DC01. Nothing to install.

Splunk source this is adapted from: "Windows Multiple Users Failed To Authenticate Using Kerberos" (research.splunk.com, id 3a91a212-98a9-11eb-b86a-acde48001122). Their version is 4771 only and fires at 30 users over 5 minutes against a data model. Mine reads your raw indexes, folds in 4625 from the workstations, and drops the threshold to 10 because limonada.local is tiny.

---

## Step 1: check the logs are there before you build anything

1. Open Splunk, go to Search.

2. Paste this. It checks you are getting failed logons from both sources in the last 24 hours.

```
index=wineventlog (EventCode=4625 OR EventCode=4771) earliest=-24h
| stats count by EventCode, host
```

3. You want to see 4625 coming from the workstation hosts and 4771 coming from DC01. If 4771 is missing, the Kerberos audit subcategory is not on at DC01. The fix is the GPO setting "Audit Kerberos Authentication Service" under Account Logon, which your advanced audit GPO should already cover. If it is missing, that is a finding for your notes, not a blocker, because 4625 alone still catches the spray.

4. Check which field holds the source address, because this matters for the search. Paste:

```
index=wineventlog EventCode=4625 earliest=-24h
| table _time, host, IpAddress, src_ip, Source_Network_Address, TargetUserName, user
```

5. Look at which of `IpAddress`, `src_ip`, `Source_Network_Address` actually has the attacker IP in it, and which of `TargetUserName` or `user` holds the account name. On the Windows TA these are usually `IpAddress` and `TargetUserName` for 4625. My search coalesces all three address fields and both name fields, so it works either way, but it is good to know what your data looks like.

---

## Step 2: build the search yourself

Try to write it before you look at mine. The logic you are after:

- read 4625 and 4771 from `index=wineventlog`
- make one source field and one account field that work across both event codes
- drop computer accounts (end in `$`) and `ANONYMOUS LOGON`
- for 4771, keep only `Status="0x18"` (wrong password). 4625 is already a failure so keep all of it
- bucket time into 10 minute windows
- count distinct accounts per source per window
- alert when one source hit more than 10 different accounts

Here is the full search to compare against once you have your own:

```
index=wineventlog (EventCode=4625 OR EventCode=4771)
| eval src=coalesce(IpAddress, src_ip, Source_Network_Address)
| eval acct=coalesce(TargetUserName, user, src_user)
| search NOT acct="*$" NOT acct="ANONYMOUS LOGON"
| where EventCode=4625 OR (EventCode=4771 AND Status="0x18")
| bucket span=10m _time
| stats dc(acct) as accounts values(acct) as accounts_list by _time, src
| where accounts > 10
| eval time=strftime(_time, "%F %T")
```

Run it over "Last 24 hours". With no attack yet it should return nothing, or maybe one row if you have been fat-fingering logons. That empty result is correct.

---

## Step 3: run the attack from WS01

Take the WS01 snapshot first if you have not already (the "clean - six detections" one).

1. On WS01, open PowerShell as a normal user (not admin, a spray does not need admin).

2. This builds a list of accounts to spray. It tries real domain usernames if the RSAT module is present, and falls back to a hardcoded list if not. Paste the whole block:

```powershell
# Build a list of target usernames to spray. Try real domain users first.
$targets = @()
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $targets = (Get-ADUser -Filter * -ErrorAction Stop | Select-Object -Expand SamAccountName)
} catch {
    # RSAT not here, use a made up list. These do not need to exist, failures still log as 4625/4771.
    $targets = @("ana.torres","javier.gomez","lucia.ramos","marco.ruiz","sara.lopez",
                 "diego.marin","elena.vidal","pablo.serra","nuria.cano","ivan.molina",
                 "rosa.peña","hugo.blanco","clara.sanz","raul.ortega","vera.gil")
}
Write-Host "Will spray $($targets.Count) accounts"
```

3. This is the spray. It tries one password against every account by mapping the DC share. Every failure writes a 4625 on WS01 and a 4771 on DC01. Paste the whole block:

```powershell
# Spray one password across all target accounts against DC01.
$dc = "10.10.10.10"
$password = "Autumn2026!"
foreach ($u in $targets) {
    # net use maps a share with those creds. It fails, which is the point.
    net use "\\$dc\IPC$" /user:"limonada\$u" "$password" 2>$null 1>$null
    net use "\\$dc\IPC$" /delete 2>$null 1>$null   # clean up any that somehow stuck
    Write-Host "." -NoNewline
}
Write-Host "`nSpray done"
```

That is 15 failed logons from one source inside a few seconds. Well over the threshold of 10.

---

## Step 4: confirm it fired

1. In Splunk, run the Step 2 search over "Last 15 minutes". You want one row: your WS01 address as `src`, `accounts` above 10, the list of names in `accounts_list`.

2. Screenshot that result for the card.

3. If you want to see both event codes lined up (the one-to-one match the handoff mentions), paste:

```
index=wineventlog (EventCode=4625 OR EventCode=4771) earliest=-15m
| eval acct=coalesce(TargetUserName, user, src_user)
| stats count by EventCode, acct
| sort acct
```

---

## Step 5: add the alert

The stanza is already written in `splunk/apps/limonada_soc/default/savedsearches.conf` under `[D02 Password spray from one source]`. To put it live:

1. Copy the repo's `savedsearches.conf` into the running container. From Windows PowerShell on the PC, in the repo root:

```powershell
# Copy the saved searches file into the Splunk container.
docker cp .\splunk\apps\limonada_soc\default\savedsearches.conf splunk:/opt/splunk/etc/apps/limonada_soc/default/savedsearches.conf
```

2. Restart Splunk so it reads the new stanza:

```powershell
# Restart Splunk to load the alert.
docker restart splunk
```

3. Wait about a minute for it to come back, then in the Splunk UI go to Settings, Searches, reports, and alerts, and confirm "D02 Password spray from one source" is listed and enabled.

---

## Step 6: roll back

1. In VMware, restore WS01 to the "clean - six detections" snapshot so the failed logons and any net use leftovers are gone.

---

## For the card (you write it, this is just raw material)

- **What a false positive looks like:** a vulnerability scanner, a misconfigured service account retrying a stale password across many logins, or a VPN box reconnecting. In a lab this size, basically nothing legitimate hits 10 accounts from one source in 10 minutes.
- **What it misses:** a slow spray that stays under 10 accounts per 10 minute window, which is how a careful attacker throttles to stay quiet. It also misses sprays over protocols that do not raise 4625 or 4771, like some LDAP binds. And with no lockout policy in limonada.local, the attacker can spray freely, so this detection is the only thing watching that door.
- **How I tested it:** net use loop from WS01 against DC01, 15 accounts, one password, inside a snapshot. Rolled back after.
