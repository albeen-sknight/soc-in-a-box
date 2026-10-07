# Splunk add-ons

An add-on is like a phrasebook. Windows writes its logs in its own language, and the add-on teaches Splunk how to read them, so `user`, `host` and `process` turn into fields I can search on.

I don't keep the add-on files in Git. Splunkbase asks you not to share them, so each machine downloads its own copy.

## The two I use

| Add-on | Splunkbase | Save it here as |
| --- | --- | --- |
| Splunk Add-on for Microsoft Windows | [app 742](https://splunkbase.splunk.com/app/742) | `windows-ta.tgz` |
| Splunk Add-on for Sysmon | [app 5709](https://splunkbase.splunk.com/app/5709) | `sysmon-ta.tgz` |

## How to get them

1. Sign in to Splunkbase with my Splunk account.
2. Open each link above and download the latest version.
3. Rename each file to the name in the table and put it in this folder.
4. Start Splunk with `docker compose up -d`. It installs both add-ons on the first start.

If a file is missing, Splunk won't finish starting. The container logs say which one.
