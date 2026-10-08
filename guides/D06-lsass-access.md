# D06 build and test guide: Process opening LSASS memory

**What it catches:** a program reaching into lsass.exe, the process that holds Windows sign-in secrets. Opening LSASS with read or copy access rights is how tools like Mimikatz and comsvcs.dll steal credentials.

**Logs:** Sysmon event 10 (ProcessAccess), in `index=sysmon`.

**ATT&CK:** T1003.001 LSASS Memory. **Severity:** 5 Critical, pages.

**Test tool:** Atomic Red Team. Install on WS01 only.

Splunk source this is adapted from: "Windows Possible Credential Dumping" (id e4723b92-7266-11ec-af45-acde48001122), which keys on Sysmon 10 against lsass.exe with a list of GrantedAccess values and debug-DLL call traces, excluding SYSTEM and NETWORK SERVICE. Mine reads your raw `index=sysmon` instead of the `sysmon` macro and keeps the field names your TA produces.

**The catch the handoff warns about:** your sysmon-modular "balanced" config logs event 10 only for SOME processes. Event 10 for lsass.exe might not be captured at all. So step one is proving the event even shows up before you build anything on it. If it does not, there is a config decision to make, and it is spelled out below.

---

## Step 1: prove Sysmon event 10 against lsass exists

1. Paste this. It asks whether you are getting event 10 at all, and specifically against lsass.

```
index=sysmon EventCode=10 earliest=-24h
| stats count by TargetImage
```

2. Look for a row where `TargetImage` ends in `lsass.exe`. Three outcomes:

   - **You see lsass.exe rows:** good, your config already logs it. Skip to Step 2.
   - **You see event 10 for other processes but never lsass:** the balanced config is filtering lsass out. Go to Step 1b.
   - **You see no event 10 at all:** ProcessAccess logging is off entirely in your config. Go to Step 1b.

### Step 1b: turn on event 10 for lsass in the Sysmon config

The sysmon-modular balanced config needs a rule that includes lsass as a ProcessAccess target. You edit the Sysmon config on WS01 (the test VM), not on your real PC.

1. On WS01, find the active Sysmon config. If you installed sysmon-modular the usual way, the merged config is a file like `sysmonconfig.xml` wherever you dropped it. Confirm what is loaded:

```powershell
# Show which config Sysmon is currently running.
sysmon.exe -c
```

2. You need a ProcessAccess rule that keeps lsass access. Open your `sysmonconfig.xml` in Notepad and make sure the ProcessAccess section has an include rule for lsass. The minimal shape is:

```xml
<RuleGroup name="lsass access" groupRelation="or">
  <ProcessAccess onmatch="include">
    <TargetImage condition="image">lsass.exe</TargetImage>
  </ProcessAccess>
</RuleGroup>
```

If your config uses a big `exclude` block for ProcessAccess, the cleanest lab fix is to add a small `include` group like the above so lsass is always kept.

3. Reload the config:

```powershell
# Reload Sysmon with the edited config. Run PowerShell as admin for this.
sysmon.exe -c .\sysmonconfig.xml
```

4. Re-run the Step 1 search over "Last 15 minutes" after you do any sign-in activity, and confirm lsass rows now appear. Note in the card that you had to adjust the Sysmon config, that is a real finding worth writing up.

---

## Step 2: check the field names

1. Paste this to see what your Sysmon TA calls the fields:

```
index=sysmon EventCode=10 TargetImage="*lsass.exe" earliest=-24h
| table _time, Computer, SourceImage, SourceUser, GrantedAccess, CallTrace
| head 20
```

2. Confirm `GrantedAccess`, `SourceImage`, `SourceUser`, `CallTrace`, `Computer` are populated. On Sysmon TA 5.0.1 with renderXml these are the standard names. If `SourceUser` is blank on your version, that is fine, the search still works, you just lose the SYSTEM exclusion. If it is blank, swap the exclusion to use `SourceImage` instead (exclude known-good source images).

---

## Step 3: build the search yourself

The logic:

- `index=sysmon EventCode=10` where `TargetImage` is lsass
- keep only the GrantedAccess values that mean read or copy memory. `0x1010` and `0x1410` are the classic Mimikatz values. The wider list catches more tools
- drop the normal Windows accounts that touch lsass legitimately (SYSTEM, NETWORK SERVICE, LOCAL SERVICE)

Full search to compare against:

```
index=sysmon EventCode=10 TargetImage="*\\lsass.exe"
| search GrantedAccess IN ("0x1010", "0x1410", "0x1438", "0x143a", "0x1fffff", "0x1010", "0x1438")
| search NOT SourceUser IN ("NT AUTHORITY\\SYSTEM", "NT AUTHORITY\\NETWORK SERVICE", "NT AUTHORITY\\LOCAL SERVICE")
| stats count min(_time) as first by Computer, SourceImage, SourceUser, GrantedAccess, CallTrace
| eval host=Computer
| eval time=strftime(first, "%F %T")
```

Run over "Last 24 hours". Should be empty or near-empty on a quiet lab. Some AV or EDR-like tooling can open lsass with these rights, so if you see a steady source, note it and exclude that `SourceImage`.

---

## Step 4: install Atomic Red Team on WS01

Snapshot WS01 first. This is the first detection that needs the module.

1. On WS01, open PowerShell **as administrator**.

2. Install the module and the atomics folder. Paste:

```powershell
# Install the Atomic Red Team PowerShell module and the test definitions.
IEX (IWR 'https://raw.githubusercontent.com/redcanaryco/invoke-atomicredteam/master/install-atomicredteam.ps1' -UseBasicParsing)
Install-AtomicRedTeam -getAtomics -Force
```

3. Load the module into this session:

```powershell
# Import the module so Invoke-AtomicTest is available.
Import-Module "C:\AtomicRedTeam\invoke-atomicredteam\Invoke-AtomicRedTeam.psd1" -Force
```

### Defender will fight you here. You do this part, per your rules.

The LSASS tests look exactly like real credential theft, so Microsoft Defender will quarantine them. You need a Defender exclusion folder on WS01. **You run these, I do not touch security settings.** Open PowerShell as admin on WS01:

```powershell
# Exclude the Atomic folder from Defender so the tests can run. You run this yourself.
Add-MpPreference -ExclusionPath "C:\AtomicRedTeam"
Add-MpPreference -ExclusionPath "C:\Users\Public\AtomicRedTeam"
```

If you would rather turn real-time protection off for the test window instead (blunter, also your call):

```powershell
# Alternative: turn off real-time protection for the test. You run this yourself.
Set-MpPreference -DisableRealtimeMonitoring $true
```

Remember you are rolling the VM back after, so these changes do not stick.

---

## Step 5: run the attack

1. See what the test will do before running it (good habit, good card material):

```powershell
# Show the LSASS dump tests without running them.
Invoke-AtomicTest T1003.001 -ShowDetailsBrief
```

2. Run test 2, the comsvcs.dll dump. This uses a built-in Windows DLL to dump lsass, needs no download, and opens lsass with exactly the access rights D06 watches for. Paste:

```powershell
# Run the comsvcs.dll LSASS dump test. Must be an elevated PowerShell.
Invoke-AtomicTest T1003.001 -TestNumbers 2
```

3. Clean up the dump file the test leaves behind:

```powershell
# Remove the dump file the test created.
Invoke-AtomicTest T1003.001 -TestNumbers 2 -Cleanup
```

If test 2 is blocked even with the exclusion, test 1 (ProcDump) is another option, but it downloads ProcDump first:

```powershell
# Fallback: ProcDump LSASS dump. Downloads ProcDump, then dumps.
Invoke-AtomicTest T1003.001 -TestNumbers 1 -GetPrereqs
Invoke-AtomicTest T1003.001 -TestNumbers 1
Invoke-AtomicTest T1003.001 -TestNumbers 1 -Cleanup
```

---

## Step 6: confirm it fired

1. Run the Step 3 search over "Last 15 minutes". You want a row with `SourceImage` showing rundll32.exe (for the comsvcs test) and a `GrantedAccess` from the list.

2. If nothing shows but the test ran, the GrantedAccess value your dump used is not in my list. Widen the net to see what it actually requested:

```
index=sysmon EventCode=10 TargetImage="*lsass.exe" earliest=-15m
| stats count by SourceImage, GrantedAccess
```

Add whatever GrantedAccess value rundll32 used to the alert's `IN (...)` list.

3. Screenshot the hit for the card.

---

## Step 7: add the alert

Stanza is in `savedsearches.conf` under `[D06 Process opening LSASS memory]`. Note this one is `alert.severity = 5` and `priority=5` because it is Critical.

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

3. Confirm "D06 Process opening LSASS memory" is enabled.

---

## Step 8: roll back

1. Restore WS01 to the "clean - six detections" snapshot. This undoes the Atomic install, the Defender exclusion, and the dump files all at once. This is why you snapshot first.

---

## For the card

- **What a false positive looks like:** some endpoint security products, backup agents, and a few Microsoft tools open lsass with read rights for legitimate reasons. On a clean lab there is almost nothing, which is why the severity is Critical: a hit here is nearly always real.
- **What it misses:** tools that open lsass with an access-rights value not in my list (I widen the list when I see a new one). Dumps that avoid Sysmon event 10 entirely, like the silent-process-exit WerFault trick. And if the balanced Sysmon config ever stops logging event 10 for lsass, the whole detection goes blind, so the config include rule is load-bearing.
- **How I tested it:** Atomic Red Team T1003.001 test 2 (comsvcs.dll) on WS01 inside a snapshot, with a Defender exclusion I set myself, then rolled back.
