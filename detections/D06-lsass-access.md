# D06: Process opening LSASS memory

**ATT&CK:** T1003.001 LSASS Memory
**Severity:** 5 Critical, pages
**Source:** Sysmon event 10 (ProcessAccess), index=sysmon

## What it catches

A program reaching into lsass.exe, the process that holds Windows sign-in secrets. Opening LSASS with read or copy access rights is how Mimikatz and comsvcs.dll steal credentials. On a clean lab almost nothing does this, which is why it is Critical.

## The search

```
index=sysmon EventCode=10 TargetImage="*\\lsass.exe"
| search GrantedAccess IN ("0x1010", "0x1410", "0x1438", "0x143a", "0x1fffff")
| search NOT SourceUser IN ("NT AUTHORITY\\SYSTEM", "NT AUTHORITY\\NETWORK SERVICE", "NT AUTHORITY\\LOCAL SERVICE")
| stats count min(_time) as first by Computer, SourceImage, SourceUser, GrantedAccess, CallTrace
| eval host=Computer
| eval time=strftime(first, "%F %T")
```

A caveat that turned out to matter a lot (see "what it misses"): the detection can only ever see an access mask that the **Sysmon config chose to log**. My sysmon-modular balanced config includes lsass as a ProcessAccess target, but only for `0x1FFFFF`, `0x1F1FFF`, `0x1010` and `0x143A`. So of the five values above, `0x1410` and `0x1438` are dead weight here: Sysmon never records them, so this clause can never match them unless I widen the config too. I left them in because the detection should be portable to a host whose config does capture them, but on these machines they do nothing.

## What a false positive looks like

Some endpoint-security products, backup agents, and a handful of Microsoft tools open lsass with read rights for legitimate reasons. On a clean lab it's near zero, so a hit is nearly always real. That's the whole reason it's Critical and pages.

The `SourceUser` filter drops the normal Windows accounts (SYSTEM, NETWORK SERVICE, LOCAL SERVICE) that touch lsass constantly for legitimate reasons. Without it the panel would be all noise. The trade: a dumper that already runs as SYSTEM is filtered out, which is a real gap.

## What it misses

The big one, discovered while testing: **on these hosts the technique is blocked before the detection ever sees it.** lsass runs as a Protected Process with a UEFI lock (`RunAsPPL = 2`). An attempt to open lsass for read is denied by the kernel so early that Sysmon logs no event 10 at all. So a straightforward credential dump on WS01 produces *nothing* for D06 to catch, not because the detection is wrong, but because the OS refused the handle. This detection earns its keep on hosts without PPL, or against an attacker who disables PPL first (which is itself loud and worth its own detection).

Beyond that:
- Tools that request a GrantedAccess value the Sysmon config doesn't log. `0x1410` and `0x1438` are literally in my search but are never captured here, so they're invisible until I widen the config.
- Dumps that avoid Sysmon event 10 entirely, like the silent-process-exit / WerFault trick.
- Anything running as SYSTEM, dropped by the SourceUser filter above.

## How I tested it

No Atomic Red Team or ProcDump on this lab, so I skipped the comsvcs route and used a direct handle test: a small PowerShell/P-Invoke that enables SeDebugPrivilege and calls `OpenProcess` on lsass with `0x1010` (PROCESS_QUERY_INFORMATION | PROCESS_VM_READ), the mask a dumper requests. No memory is read or written, so no credentials are exposed, but it's the exact access D06 watches for.

What actually happened, in order:
1. The event-10 gate was empty over 24h. Not a broken config, just a quiet box: the config only logs dump-grade masks on lsass, and nothing had tried.
2. First run, non-elevated: `OpenProcess` failed with error 5 (access denied).
3. Elevated, but without SeDebugPrivilege: still error 5.
4. Elevated *and* with SeDebugPrivilege enabled: **still** error 5.
5. Checked `HKLM\SYSTEM\CurrentControlSet\Control\Lsa\RunAsPPL` → `2`. lsass is a UEFI-locked protected process. That's why nothing short of a signed protected process or a driver can open it.
6. The gate stayed at 0 events after every attempt: the denied opens never produced an event 10.

So I did **not** need the config edit the guide warned about (step 1b) — lsass was already an include target. What I found instead is stronger: the dump technique is neutralised at the OS by PPL, and is invisible to this detection on these hosts.

## The incident that proved it

None yet. Tested on purpose. The test proved the defense (PPL) more than the detection — a good problem to have.
