# Building Limonada S.L.

Think of opening a new office. Someone puts the furniture in, someone sets up the front desk that checks every badge, and only then do the staff move in. This folder does the same for the company, in that order.

The front desk is **DC01**, the domain controller. Every login in the company gets checked there, which is also why it's the first place the SOC looks when someone guesses passwords.

## The lab network

All the company machines live on a private network inside my PC that nobody outside can reach. They get out through the PC (NAT) for updates and to send their logs to the laptop.

| Machine | Address | What it does |
| --- | --- | --- |
| The PC itself | 10.10.10.1 | The gateway out of the lab |
| DC01 | 10.10.10.10 | Domain controller and DNS for `limonada.local` |
| WS01 | 10.10.10.21 | Lucia Navarro's PC, in Finance |
| WS02 | 10.10.10.22 | Carmen Vidal's PC, in Sales |

## What's in here

| Folder | What it holds |
| --- | --- |
| `unattend/` | The answer file template and the script that turns it into an "answer ISO" for each VM |
| `dc01/` | The three scripts that build the domain, plus the list of the 40 fictional staff |
| `workstations/` | The script that joins WS01 and WS02 to the domain |

## The order

**On the PC**

1. Open PowerShell in `windows\unattend` and run `.\New-AnswerIso.ps1 -ComputerName DC01`. Do the same for WS01 and WS02.
2. Create each VM with two DVD drives: the Windows ISO in the first, its answer ISO in the second.
3. Start the VM and press a key when it says "Press any key to boot from CD or DVD". Windows then installs itself with no clicking.

**On DC01**, logged in as Administrator. The scripts are on the ANSWER drive, in the `lab` folder:

4. `01-Promote-DC01.ps1` sets the fixed address and creates the domain. DC01 reboots.
5. Log in as `LIMONADA\Administrator` and run `02-Build-Limonada.ps1`. It creates the departments, the groups, the staff and the IT admin account.
6. Run `03-New-SecurityLoggingGpo.ps1`. It turns on the logging the detections need, for every machine in the domain.

**On WS01 and WS02**, logged in as `labadmin`:

7. Run `Join-Limonada.ps1`. It sets the fixed address and joins the domain. The machine reboots.
8. Check the logging reached it: `gpupdate /force`, then `auditpol /get /category:*`.

**Back on the PC**

9. Snapshot all three VMs. This is the clean company I roll back to before every attack day.
10. Delete `windows\unattend\build`. It holds the admin password in plain text.

To run a script from the ANSWER drive (say it's `E:`), open PowerShell as administrator and type:

```powershell
# Runs one lab script, allowing it just this once without changing the machine's script policy
powershell -ExecutionPolicy Bypass -File E:\lab\01-Promote-DC01.ps1
```

## Passwords

None of the scripts store a password. Each one asks for it while it runs, and I type it from my password manager. The domain's default rules apply: at least 7 characters, with three of these four: capitals, lowercase, numbers, symbols.
