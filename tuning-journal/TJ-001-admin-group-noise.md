# TJ-001 — Admin group changes: mostly the build talking

**Written:** 8 Oct 2026, the night after
**Where:** Limonada S.L. SOC wall screen, the "Admin group changes" tile and the table behind it
**Window:** last 24 hours (Wed 7 Oct)
**Change:** leave out subjects ending in `$`

## What I saw

76. In red.

Everything else on the wall was calm. Four failed logons, one WAF block, no alerts fired. And then this tile, shouting. I clicked through and the table ran to eight pages, all of it 4732s and 4728s, members being added to groups on WS01 and WS02 within about half an hour of each other on Wednesday evening.

So my first thought was: either something's very wrong, or someone's been building machines. It was the second one.

## What it turned out to be

Two things, and neither one was a person doing anything sneaky.

**The build.** Most rows had `WS02$` as the subject. That's the computer account, which is how Windows signs its own work when it acts as SYSTEM. When you set a machine up, Windows fills its local groups with their default members, and it logs every single one. On WS02 you can watch it happen twice, a second apart: a 4728 into `None`, then 4732s into `Users` and `Administrators` at 22:45:50, and the same three again at 22:45:51. Nobody typed any of that. It's most of the 76.

**The domain join.** The `labadmin` rows show up in pairs. `Administrators` and `Users`, about 3 ms apart, once on WS01 (22:29:26) and once on WS02 (22:56:26). That's the join dropping Domain Admins into the local Administrators group and Domain Users into local Users. One action, two log lines.

One annoying thing: the `user` column, the one that should say *who got added*, is empty on every row. I had to read all this from the subject, the timing, and the pattern. Not ideal. More on that at the bottom.

## What I changed

I told the search to skip events where the subject ends in `$`, so anything a computer account did on its own drops out:

```
NOT src_user="*$"
```

I picked `NOT src_user=` over `src_user!=` deliberately. The `!=` version also throws away events with no `src_user` at all, and I'd rather see those than lose them without noticing.

Small gotcha if you edit this in the dashboard source: `$` marks a token there, so you have to write it as `$$`, as in `NOT src_user="*$$"`.

What should happen now: the build rows disappear, and the `labadmin` join pairs stay. I'm fine with that. A domain join really does hand Domain Admins local admin rights, and it's a few rows, not 76.

## What I'd still catch

The thing this tile is actually for: **a person adding someone to Administrators.** If a human account shows up as the subject on a 4732 or 4728, it still lands on the tile and in the table. You can see it working already. The `labadmin` change on WS02 at 22:56 survives the filter.

Same goes for any other security group, local or domain. And for joins like these two, since they ran under the account doing the join.

## What I'd miss now

This filter isn't free, and I want that written down.

Anything done *as SYSTEM* now hides. A service, a scheduled task, a GPO pushing group membership, someone running `net localgroup administrators <name> /add` from a SYSTEM shell: all of those get logged with the computer account as the subject. And that's exactly how an attacker who already has SYSTEM would plant a backdoor admin. So yes, I've just made that quieter.

Then there's the naming trick. Windows lets you call a normal user account something like `svc$`, and `net user` won't list it. My filter won't show it either.

## Next

- [ ] Narrow the filter so it only skips each host's *own* computer account, not every name ending in `$`. Something like `| where NOT (src_user == host . "$")`. Check first that `host` and `src_user` use the same form of the name, short name vs. FQDN, or it'll match nothing.
- [ ] Get the added member into the table. The panel should tell me who received the access, not just who gave it.
- [ ] Check the tile after the next refresh and write the new count here, so I know the change did what I think it did:
