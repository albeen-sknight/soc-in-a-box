# Remaining detections package: D02, D05, D06, D09

Everything to build and test the last four detections on your own. Built from the Splunk public detection library adapted to your raw indexes and field names.

## What is in here

```
soc-in-a-box/
  splunk/apps/limonada_soc/default/
    savedsearches.conf        <- all four alert stanzas, LF endings
  guides/
    D02-password-spray.md     <- step by step, every command copy-paste ready
    D05-encoded-powershell.md
    D06-lsass-access.md
    D09-office-spawns-shell.md
  detections/
    D02-password-spray.md     <- card templates in your format, you fill the prose
    D05-encoded-powershell.md
    D06-lsass-access.md
    D09-office-spawns-shell.md
```

## How to use it

Do them in order: D02, D05, D06, D09. For each one:

1. Open the matching guide in `guides/`.
2. Work through the steps at the PC. Each guide checks the logs exist, has you build the search yourself with the full version to compare against, runs the attack, confirms the hit, then applies the alert.
3. Fill in the card in `detections/` in your own words. The headers and search are already there; the HTML comments are raw material for the prose sections.

## Merge these into your repo

These files mirror your repo layout. Copy them into your real repo, do not overwrite without checking:

- `savedsearches.conf` here has ONLY the four new stanzas. Your repo's real file already has the six live detections. Do not replace it. Open both and paste the four new stanzas onto the end of your real file instead.
- The guides and cards are new files, safe to drop in.

Commit as yourself. I did not run git or add any attribution.

## The one decision waiting for you

D09 needs an Office parent process and Office is not installed. The D09 guide lays out two routes: install an Office trial on WS01 (real macro chain, a few GB), or fake the parent with a renamed binary (nothing to install, proves the logic but not a real macro). Pick one when you get there. Both are written out.

## Before you start

- Run Start-Lab, all three VMs green.
- Snapshot each VM as "clean - six detections" if you have not. You roll back after every test.
- D06 and D09 Option A use Atomic Red Team and need a Defender exclusion. You set that yourself (per your rules); the exact commands are in those guides.

## The savedsearches shape, confirmed against your template

Each stanza uses `eval time=strftime(_time, "%F %T")` so your phone shows readable times, `cron_schedule = * * * * *`, a 15 minute lookback, suppress on the right field, and webhook priority matching severity (4 for High, 5 for D06 Critical). Apply with:

```powershell
docker cp .\splunk\apps\limonada_soc\default\savedsearches.conf splunk:/opt/splunk/etc/apps/limonada_soc/default/savedsearches.conf
docker restart splunk
```
