# The pager

A real SOC analyst doesn't stare at the screen all night. When something serious happens, their phone buzzes. This folder makes my phone the pager for Limonada S.L.

## How an alert reaches my phone

1. A detection fires in Splunk, for example D10.
2. Splunk's webhook action sends the alert, as JSON, to `pager-relay` inside Docker's network.
3. `relay.py` picks the alert name and the first few useful fields, and writes a short message a person can read half asleep.
4. It pushes that message to my ntfy topic, and the ntfy app on my phone buzzes.

The title shows the severity and the detection, like `[High] D10 WAF blocks then a success from the same source`. The body shows the fields that matter, like the source IP and the page.

## Why a relay, and not Splunk straight to ntfy

The ntfy topic works like a password: anyone who knows it can read my alerts. If Splunk sent to ntfy directly, the topic would sit in `savedsearches.conf`, and that file is in Git. With the relay, the topic lives only in `.env`, which Git ignores.

The relay has no published ports, so nothing outside the PC can reach it, and it only uses Python's standard library.

## Setting it up

1. Install the ntfy app on my phone.
2. Make a long random topic name in PowerShell: `"limonada-soc-" + [guid]::NewGuid().ToString("N")`
3. Put it in `.env` as `NTFY_TOPIC=...`, and subscribe to the same topic in the app.
4. `docker compose up -d` starts the relay.

## What leaves the PC

Only the alert title and a handful of fields from the first result, like a source IP and a page. All of it is about the lab. No raw logs, no passwords.
