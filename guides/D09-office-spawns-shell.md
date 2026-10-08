# D09 build and test guide: Office starting a shell

**What it catches:** Word or Excel opening a command prompt or PowerShell. This is the classic sign of a malicious attachment: the victim opens a document, a macro fires, and the Office app spawns a shell to run the payload. A normal Word document never launches cmd.exe.

**Logs:** Sysmon event 1 (process create) and Security 4688 (process start), both read for the parent-child link. Sysmon 1 is in `index=sysmon`, 4688 is in `index=wineventlog`.

**ATT&CK:** T1204.002 Malicious File. **Severity:** 4 High, pages.

**Test tool:** Atomic Red Team, plus Office. Office is the gap, see the decision below.

Splunk source this is adapted from: "Windows Office Product Spawned Uncommon Process" (id 55d8741c-fa32-4692-8109-410304961eb8), the current replacement for the old "Office Product Spawn CMD Process". It matches an Office product as the parent process and an uncommon child like cmd.exe. Mine reads your raw indexes and checks both Sysmon 1 and 4688 so it still works if the balanced Sysmon config does not log the Office process start.

---

## The decision you have to make first: how to get an Office parent

Office is not installed on WS01 or WS02. D09 needs an Office process (winword.exe or excel.exe) to be the parent of the shell, so you have two honest ways forward. Pick one.

**Option A: install a Microsoft Office trial on WS01.** This is the real thing. The Atomic tests use `Invoke-MalDoc`, which drives a real Word or Excel instance through COM to run macro code, and that produces a genuine winword.exe to cmd.exe parent-child pair, exactly what a real maldoc looks like. Cost: a few GB download, and a Microsoft account for the trial. This is the most convincing version for an internship story because the telemetry is identical to a real attack.

**Option B: fake the parent process, no Office.** You rename a copy of cmd.exe or a small launcher to `winword.exe`, run it, and have it spawn a child shell. The detection keys on the parent being named winword.exe or excel.exe, so a process literally named winword.exe spawning cmd.exe will trip it. Cost: nothing to install. Downside: it is a simulation of the name, not a real macro chain, and you should say so plainly on the card. It still proves the detection logic works.

My recommendation: **Option A if you have the disk space and 30 minutes, Option B if you want D09 done today with no download.** Both are written out below. Do one.

---

## Step 1: check both log sources and the field names

1. Confirm 4688 process starts are flowing with parent and child fields. Paste:

```
index=wineventlog EventCode=4688 earliest=-24h
| table _time, host, Parent_Process_Name, ParentProcessName, New_Process_Name, NewProcessName, CommandLine, Process_Command_Line
| head 20
```

Note which fields are populated. On Windows TA 11.0.3, 4688 usually gives `Parent_Process_Name`, `New_Process_Name`, and `Process_Command_Line`. My search coalesces the variants so it works either way.

2. Confirm Sysmon event 1 is flowing and whether it logs Office. Paste:

```
index=sysmon EventCode=1 earliest=-24h
| stats count by ParentImage
| head 20
```

Remember the balanced Sysmon config only logs SOME event 1 process starts. If Office is not in the list after you have Office running, do not worry: the 4688 half of the search covers every process start, so D09 still fires off 4688 even when Sysmon 1 misses it. That is exactly why the search reads both.

---

## Step 2: build the search yourself

The logic:

- read Sysmon 1 (`index=sysmon`) and 4688 (`index=wineventlog`) together
- build one `parent` field and one `child` field across both, lowercased so matching is easy
- keep rows where the parent is an Office app and the child is a shell or script host
- drop computer accounts is not needed here because we are matching on process names, but we keep a user field for the alert

Full search to compare against:

```
(index=sysmon EventCode=1) OR (index=wineventlog EventCode=4688)
| eval parent=lower(coalesce(ParentImage, Parent_Process_Name, ParentProcessName))
| eval child=lower(coalesce(Image, New_Process_Name, NewProcessName))
| eval cmd=coalesce(CommandLine, Process_Command_Line)
| eval user=coalesce(user, src_user, Account_Name)
| where (like(parent, "%winword.exe") OR like(parent, "%excel.exe") OR like(parent, "%powerpnt.exe"))
| where (like(child, "%cmd.exe") OR like(child, "%powershell.exe") OR like(child, "%pwsh.exe") OR like(child, "%wscript.exe") OR like(child, "%cscript.exe") OR like(child, "%mshta.exe"))
| stats count min(_time) as first values(cmd) as cmd by host, user, parent, child
| eval time=strftime(first, "%F %T")
```

Run over "Last 24 hours". With no Office activity it returns nothing. Correct.

---

## Step 3a: the attack, Option A (real Office)

Snapshot WS01 first. Install Atomic Red Team if you have not (steps are in the D06 guide, Step 4, including the Defender exclusion you run yourself).

1. Install the Office trial on WS01. Download from microsoft.com/microsoft-365/try or your usual trial source, run the installer, sign in with a throwaway Microsoft account. This is the few-GB download.

2. Confirm Word is really there:

```powershell
# Check Word is installed and COM-accessible.
try { $w = New-Object -ComObject Word.Application; $w.Quit(); Write-Host "Word OK" } catch { Write-Host "Word not available" }
```

3. See the test first:

```powershell
# Show the Office-spawns-shell tests without running them.
Invoke-AtomicTest T1204.002 -ShowDetailsBrief
```

4. Run test 3, "Maldoc choice flags command execution". It drives Word through COM to run a macro that shells out to cmd.exe. That is a real winword.exe to cmd.exe pair. Paste:

```powershell
# Run the maldoc test that makes Word spawn cmd.exe.
Invoke-AtomicTest T1204.002 -TestNumbers 3
```

5. Cleanup:

```powershell
# Clean up after the test.
Invoke-AtomicTest T1204.002 -TestNumbers 3 -Cleanup
```

Test 5 ("Office launching .bat file from AppData") is a good second one if you want another hit: it makes Word launch cmd to run a .bat that opens calc. Same invoke, `-TestNumbers 5`.

Skip to Step 4.

---

## Step 3b: the attack, Option B (no Office, fake the parent)

Snapshot WS01 first. No Atomic Red Team or Office needed for this version.

1. On WS01, open PowerShell as a normal user.

2. This makes a copy of cmd.exe named winword.exe, then has it spawn a child cmd.exe. The child's parent is named winword.exe, which is what D09 matches. Paste the whole block:

```powershell
# Make a fake "winword.exe" and have it launch a shell, to mimic a maldoc parent-child pair.
$dir = "C:\Users\Public\d09test"
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Copy-Item "C:\Windows\System32\cmd.exe" "$dir\winword.exe" -Force
# Launch the fake Word, which runs a child cmd that echoes and exits.
Start-Process "$dir\winword.exe" -ArgumentList '/c "cmd.exe /c echo D09 test from fake winword & timeout 2"'
```

3. For an Excel variant too, paste:

```powershell
# Same idea with a fake excel.exe spawning PowerShell.
$dir = "C:\Users\Public\d09test"
Copy-Item "C:\Windows\System32\cmd.exe" "$dir\excel.exe" -Force
Start-Process "$dir\excel.exe" -ArgumentList '/c "powershell.exe -NoProfile -Command Write-Host D09-excel-test"'
```

4. Cleanup (the rollback handles it too, but just so you know):

```powershell
# Remove the fake binaries.
Remove-Item "C:\Users\Public\d09test" -Recurse -Force -ErrorAction Ignore
```

Be honest about this on the card: the parent process is named winword.exe but there is no real macro. It proves the detection logic, not the full maldoc chain.

---

## Step 4: confirm it fired

1. Run the Step 2 search over "Last 15 minutes". You want a row where `parent` ends in winword.exe or excel.exe and `child` is a shell.

2. If Option A ran but nothing shows, check whether the event landed in 4688 or Sysmon 1:

```
index=* (EventCode=1 OR EventCode=4688) earliest=-15m
| eval parent=lower(coalesce(ParentImage, Parent_Process_Name, ParentProcessName))
| search parent="*winword.exe" OR parent="*excel.exe"
| table _time, index, EventCode, parent, Image, New_Process_Name
```

That tells you which log actually caught it, which is a nice detail for the card.

3. Screenshot the hit.

---

## Step 5: add the alert

Stanza is in `savedsearches.conf` under `[D09 Office starting a shell]`.

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

3. Confirm "D09 Office starting a shell" is enabled.

---

## Step 6: roll back

1. Restore WS01 to the "clean - six detections" snapshot. For Option A this also removes Office and the Atomic install. For Option B it removes the fake binaries.

---

## For the card

- **What a false positive looks like:** a few enterprise setups have Office legitimately call scripts, like an approved macro that runs a PowerShell reporting job. In limonada.local there are none, so any hit is suspicious. If you add a known-good macro later, exclude its exact command line.
- **What it misses:** maldocs that spawn something not in my child list (for example rundll32 or regsvr32 instead of a shell). Attacks where Office injects into an existing process instead of spawning a new child, so there is no parent-child pair to see. And if you used Option B, it misses nothing about the logic but it did not exercise a real macro engine.
- **How I tested it:** [Option A] Atomic Red Team T1204.002 test 3 driving real Word to spawn cmd, on WS01 inside a snapshot, rolled back. OR [Option B] a renamed cmd.exe acting as winword.exe spawning a child shell, on WS01 inside a snapshot, rolled back.
