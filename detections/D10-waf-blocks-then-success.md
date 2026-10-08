# D10: WAF blocks, then a success from the same source

**ATT&CK:** T1190 Exploit Public Facing Application
**Log:** ModSecurity audit log from WEB01 (`index=waf`)
**Alert:** `D10 WAF blocks then a success from the same source`, every 5 minutes over the last 15
**Severity:** high, pages my phone

## What it catches

Think of a bouncer who turns someone away at the door five times. That's the bouncer doing the job. But if the same person walks in on the sixth try, the bouncer should tell the manager, because something changed. The WAF is my bouncer; this detection is the manager.

One block on its own means the WAF worked. Lots of blocks from one source on one page, followed by a success on that same page, means someone kept trying until something got through. That's the bridge between my two projects: the WAF blocks the attack at the door, and the SOC notices the pattern.

## The search

```
index=waf
| stats count AS total,
        count(eval(status=403)) AS blocks,
        min(eval(if(status=403, _time, null()))) AS first_block,
        max(eval(if(status>=200 AND status<400, _time, null()))) AS last_ok
        BY src_ip uri_path
| where blocks >= 5 AND last_ok > first_block
| eval first_block=strftime(first_block, "%F %T"),
       last_ok=strftime(last_ok, "%F %T")
```

It counts the blocks (status 403) for each source and page, remembers when the first block happened and when the last success happened, and keeps only the rows where a success came after the blocks started. A success is any 2xx or 3xx, because a redirect can mean someone got in too.

I first wrote the last two lines with `fieldformat`, which only changes how the times look on screen. That's fine in Splunk, but the alert sends the real value to my phone, and the phone got a number like `1791413683`. With `eval` the phone gets a readable time. The `where` runs before it, so the comparison still uses the real numbers.

## What a false positive looks like

A real customer searches for something with an apostrophe, like `O'Reilly`. The WAF reads the quote as SQL injection and blocks it. They try a few times, give up on the apostrophe, and search normally. Same pattern, no attacker. It's the same family of problem as FP-001 in my WAF project, where a newsletter link looked like command injection.

How I'd tell them apart: look at what got blocked. A customer's blocked requests look like normal words with one odd character. An attacker's look like a list of payloads, each one slightly different.

## How I tested it

I sent six SQL injections to `/rest/products/search` and then one normal search for `apple`. The search returned one row: my source IP, that page, the blocks, the time of the first block and the success after it.

## The incident that proved it

INC-05, during the compressed week. _To be filled in._
