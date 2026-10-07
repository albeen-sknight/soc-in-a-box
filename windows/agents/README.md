# Agents: Sysmon and the forwarder

Windows keeps a diary of what happens on each machine, but it writes very little by default. It's like a shop camera that only films the front door. Sysmon is a free Microsoft tool that adds cameras everywhere else: which program started which, with what command line, what it connected to, and whether anything touched LSASS, the part of Windows that keeps passwords in memory.

## The config

Sysmon does nothing until a config tells it what to record. Writing a good one from scratch takes years of tuning, so I use the balanced profile from [sysmon-modular](https://github.com/olafhartong/sysmon-modular) by Olaf Hartong, the same starting point a lot of SOC teams use.

| | |
| --- | --- |
| File | `sysmonconfig.xml`, unchanged from the release |
| Release | `configs-082cba578667` (commit `082cba5`, September 2026) |
| Built for | Sysmon 15.21, schema 4.91 |
| SHA256 | `f115aac5770dae468e5cfb48c58a8b6e37588208a31f1b746812c534577a244b` |
| Licence | MIT, copied in `sysmon-modular-LICENSE.md` |

Three parts of it matter most for my detections:

| What it records | Sysmon event | Detection |
| --- | --- | --- |
| Word, Excel or PowerPoint starting another program | 1, process created | D09 |
| Command lines with `FromBase64` and other hiding tricks | 1, process created | D05 |
| Any program opening `lsass.exe` | 10, process access | D06 |

## Installing it

On each Windows VM, from the `lab` folder on the ANSWER drive, in PowerShell as administrator:

```powershell
# Downloads Sysmon from Microsoft, checks its signature, and installs it with this config
powershell -ExecutionPolicy Bypass -File E:\lab\Install-Sysmon.ps1
```

The script refuses to run if the config has been changed or if `Sysmon64.exe` isn't signed by Microsoft.

To check it's logging: open Event Viewer, then **Applications and Services Logs → Microsoft → Windows → Sysmon → Operational**.

## The forwarder

Sysmon and Windows write their logs on each machine, but the SOC lives outside the lab. The Splunk Universal Forwarder is the courier: it reads the logs and carries them to Splunk at `10.10.10.1:9997`, the PC's address on the lab network.

| Log | Splunk index | Why I want it |
| --- | --- | --- |
| Security | `wineventlog` | Logons, account and group changes, new processes, scheduled tasks, log cleared |
| System and Application | `wineventlog` | Services, drivers and errors, for context |
| PowerShell Operational | `wineventlog` | The text of every script that runs (4104) |
| Sysmon Operational | `sysmon` | Process trees, network connections, LSASS access, sent as XML for the Sysmon add-on |

The settings live in my own small app, `forwarder/limonada_forwarder`: `inputs.conf` says what to read, `outputs.conf` says where to send it.

The installer itself (`splunkforwarder-*-x64.msi`) comes from splunk.com with my account, so it's not in Git. I put it in this folder before building the lab tools ISO.

The forwarder runs as Local System so it can read the Security and Sysmon logs. Its own admin account gets a random password, because nobody ever logs into it.

I left TLS off between the forwarders and Splunk. The logs never leave the PC: they go from VMware's virtual network straight into Docker, so there's no home network for anyone to listen on.
