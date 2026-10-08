# D01: Many failed logons, then a success

**ATT&CK:** T1110 Brute Force
**Log:** Windows Security log, events 4625 (failed logon) and 4624 (successful logon), `index=wineventlog`
**Alert:** `D01 Many failed logons then a success`, every 5 minutes over the last 15
**Severity:** high, pages my phone

## What it catches

Picture someone at a locked door with a big bunch of keys, trying them one after another. Every wrong key is a failed logon. The key that finally turns is the successful one. One wrong key means nothing. Ten wrong keys and then the door opens means someone might be inside who shouldn't be.

That's a brute force attack: guessing one account's password over and over until it works. The scary part isn't the failures, it's the success at the end.

## The search

```
index=wineventlog (EventCode=4625 OR EventCode=4624) user!="*$" Logon_Type IN (2, 3, 7, 10, 11)
| stats count(eval(EventCode=4625)) AS failures,
        count(eval(EventCode=4624)) AS successes,
        min(eval(if(EventCode=4625, _time, null()))) AS first_fail,
        max(eval(if(EventCode=4624, _time, null()))) AS last_success,
        values(host) AS host, values(src_ip) AS src_ip
        BY user
| where failures >= 10 AND successes >= 1 AND last_success > first_fail
| eval first_fail=strftime(first_fail, "%F %T"), last_success=strftime(last_success, "%F %T")
```

For each account it counts the failures and the successes, remembers when the failures started and when the last success happened, and keeps only accounts with ten or more failures followed by a way in.

`user!="*$"` leaves out computer accounts. The logon types keep the ways people actually log in: at the keyboard (2), over the network (3), unlocking the screen (7), remote desktop (10) and cached logons (11). That drops the hundreds of Windows services logging in as SYSTEM (type 5), which never fail and only slow the search down.

## What a false positive looks like

Someone comes back from holiday, has forgotten their password, tries ten times and then remembers it. Same pattern, no attacker.

How I'd tell them apart: a person is slow, with seconds between tries, and usually stops at the lockout. A tool is fast and steady. The source matters too: a failure at the person's own desk is less worrying than the same failures from a machine they never use.

## How I tested it

At WS01's login screen I typed the wrong password for `labadmin` ten times, then the right one. The search returned one row: `labadmin`, 10 failures, then successes, with the first failure at 00:19 and the last success at 00:26.

Two things I learned from it:

- **`labadmin` is a local account, so only WS01 saw the failures.** DC01 never knew. For a domain account like `lucia.navarro`, DC01 would also log each wrong password as a Kerberos failure (4771). D02, the password spray detection, uses those.
- **One login makes more than one 4624.** An admin login gets split into normal and elevated rights, and every screen unlock is a logon too. That's why I saw 18 successes for one test.

## The incident that proved it

INC-01, during the compressed week. _To be filled in._
