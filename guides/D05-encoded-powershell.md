# D05 build and test guide: Encoded or hidden PowerShell

**What it catches:** PowerShell started in a way meant to hide what it runs. The two big tells are an encoded command (base64 passed with `-EncodedCommand`), and a hidden window (`-WindowStyle Hidden`). Both show up in real intrusions constantly.

**Logs:** PowerShell Operational 4104 (script block logging) and Security 4688 (process start with command line). Both land in `index=wineventlog`.

**ATT&CK:** T1059.001 PowerShell. **Severity:** 4 High, pages.

**Test tool:** PowerShell itself, with a harmless command. Nothing to install.

Splunk sources this is adapted from: "Powershell Fileless Script Contains Base64 Encoded Content" (id 8acbc04c-c882-11eb-b060-acde48001122), which keys on `frombase64string` in 4104, and "Malicious PowerShell Process - Encoded Command" (id c4db14d9-7909-48b4-a054-aa14d89dbb19), which keys on `-EncodedCommand` / `-enc` in the process command line. Mine joins both ideas and reads your raw indexes instead of the Endpoint data model.

This one is mostly tuning, because Windows and installers run plenty of normal PowerShell. Expect to adjust after you see what your own machines generate.

---

## Step 1: check both log sources are there

1. Script block logging (4104). Paste:

```
index=wineventlog EventCode=4104 earliest=-24h
| stats count by host
```

You should see rows for your workstations. If this is empty, the GPO for "Turn on PowerShell Script Block Logging" is not applying. Your handoff says the GPO already turns it on, so this is just confirming.

2. Command line in 4688. Paste:

```
index=wineventlog EventCode=4688 earliest=-24h
| table _time, host, New_Process_Name, CommandLine, Process_Command_Line
| head 20
```

Check whether the command line sits in `CommandLine` or `Process_Command_Line`. On Windows TA 11.0.3 it is usually `CommandLine` for 4688, but confirm, because the search coalesces both to be safe.

---

## Step 2: build the search yourself

The logic:

- two sources ORed together: 4104 where the script block text contains `frombase64string` (or the reversed form, which shows up when the text itself is reversed), and 4688 where the command line has the encoding or hidden-window switches
- make one `cmd` field and one `user` field across both
- drop computer accounts
- tag each hit with which source caught it, so you know in the alert

Full search to compare against:

```
(index=wineventlog EventCode=4104 (Message="*frombase64string*" OR Message="*gnirtS46esaBmorF*" OR ScriptBlockText="*frombase64string*" OR ScriptBlockText="*gnirtS46esaBmorF*"))
OR (index=wineventlog EventCode=4688 (Process_Command_Line="*-enc *" OR Process_Command_Line="*-encodedcommand*" OR Process_Command_Line="* -w hidden*" OR Process_Command_Line="*-windowstyle hidden*" OR Process_Command_Line="*frombase64string*" OR CommandLine="*-enc *" OR CommandLine="*-encodedcommand*" OR CommandLine="* -w hidden*" OR CommandLine="*-windowstyle hidden*" OR CommandLine="*frombase64string*"))
| eval user=coalesce(user, src_user, Account_Name)
| eval cmd=coalesce(Process_Command_Line, CommandLine, ScriptBlockText, Message)
| eval evidence=if(EventCode=4104, "script block 4104", "command line 4688")
| search NOT user="*$"
| stats count min(_time) as first values(evidence) as evidence by host, user, cmd
| eval time=strftime(first, "%F %T")
```

> Field note from the build: on this lab the 4688 command line is in `Process_Command_Line` (not `CommandLine`), and the 4104 script text is in `Message` (not `ScriptBlockText`). The search above reads both of each. If your first run returns 0 rows, table the raw events and check which field holds the data before you touch the logic.

Heads up on `-e `: that short form is real (PowerShell accepts any unambiguous prefix of `-EncodedCommand`), but it is also a substring of lots of innocent text. If it floods you with noise, drop the `"*-e *"` clause and keep the longer `-enc` and `-encodedcommand`. Note that choice in the card under "what it misses".

Run it over "Last 24 hours" first. Whatever comes back is your baseline noise. Read each row. If something is a scheduled task or an installer that always runs encoded, that is a tuning target: add a `NOT cmd="*thatstring*"` line, or better, add it to the alert's filter later. This baseline reading IS the work for D05.

---

## Step 3: run the attack from WS01

Snapshot WS01 first.

1. On WS01, open PowerShell as a normal user.

2. Encoded command. This builds a base64 of a harmless `Write-Host` and runs it with `-EncodedCommand`, exactly how an attacker hides a payload. Paste the whole block:

```powershell
# Encode a harmless command and run it the way malware does.
$plain = 'Write-Host "D05 encoded test, hello from the Atomic style payload"'
$bytes = [System.Text.Encoding]::Unicode.GetBytes($plain)
$enc = [Convert]::ToBase64String($bytes)
powershell.exe -NoProfile -EncodedCommand $enc
```

3. Hidden window. Paste:

```powershell
# Start PowerShell with a hidden window, another classic hide.
powershell.exe -NoProfile -WindowStyle Hidden -Command "Start-Sleep -Seconds 2; Write-Host 'D05 hidden window test'"
```

4. FromBase64String in a script block, which is what the 4104 half keys on. Paste:

```powershell
# Decode a base64 string in-line. This writes a 4104 containing frombase64string.
$s = [System.Text.Encoding]::ASCII.GetString([System.Convert]::FromBase64String("RDA1IGZyb21iYXNlNjQgdGVzdA=="))
Write-Host $s
```

That is three hits across both log sources.

Optional, the Red Canary way: Atomic Red Team test T1059.001-17 runs an obfuscated encoded command, and tests -15/-16 cover `-EncodedCommand` variations through the AtomicTestHarnesses module. You do not need them here, the three commands above are enough, but if you want the "I used Atomic Red Team" line on this card too, the install steps are in the D06 guide and the invoke is:

```powershell
# Optional, only if Atomic Red Team is already installed on this VM.
Invoke-AtomicTest T1059.001 -TestNumbers 17
```

---

## Step 4: confirm it fired

1. Run the Step 2 search over "Last 15 minutes". You want rows for all three tests: two from 4688 (encoded, hidden) and at least one from 4104 (the FromBase64String ones, and the encoded command also logs a 4104 with its decoded text).

2. Screenshot it for the card.

---

## Step 5: add the alert

Stanza is in `savedsearches.conf` under `[D05 Encoded or hidden PowerShell]`.

1. Copy the file in:

```powershell
# Copy the saved searches file into the Splunk container.
docker cp .\splunk\apps\limonada_soc\default\savedsearches.conf splunk:/opt/splunk/etc/apps/limonada_soc/default/savedsearches.conf
```

2. Restart:

```powershell
# Restart Splunk to load the alert.
docker restart splunk
```

3. Confirm "D05 Encoded or hidden PowerShell" shows up enabled under Settings, Searches, reports, and alerts.

---

## Step 6: roll back

1. Restore WS01 to the "clean - six detections" snapshot.

---

## For the card

- **What a false positive looks like:** software installers and management tools (Chocolatey, some Microsoft components, SCCM-style agents) legitimately run encoded or hidden PowerShell. In a real network you tune these out by publisher or by the exact repeated command. This is why D05 is a tuning job, not a drop-in.
- **What it misses:** encoding that is not base64, like gzip or XOR wrappers. Hiding that does not use the obvious switches. PowerShell run through a different host process that does not raise 4688 with a clean command line. And if I dropped the `-e ` short-form clause for noise, it misses that abbreviation.
- **How I tested it:** three PowerShell one-liners on WS01 inside a snapshot, one encoded command, one hidden window, one FromBase64String, then rolled back.
