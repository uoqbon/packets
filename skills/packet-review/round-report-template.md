`packet:round <N> head=<head sha> tier=<tier> lenses=<a,b,c> confirmed=<lenses or -> outcome=<pass|fix|needs-human>`
### Review panel · round <N> of <maxRounds> · <outcome>

**Head** `<short sha>` · **Base** `<base ref>` · **Tier** <tier> <name> (`<agent>`, <model the reviewers ran on>): <review-scope reasons; any raise and why>

| Pair | Lens | Reported | Confirmed | Rejected |
| --- | --- | --- | --- | --- |
| 1 | security | 2 | 1 blocking | 1 |
| 1 | data | 0 | – | – |
| 2 | correctness | … | … | … |

#### Confirmed

<!-- A finding about something the packet Provides adds the tag contract, e.g. [should-fix · correctness · contract]. -->
1. **[blocking · security]** `path/File.cs:42`: <the claim in one sentence>.
   Reproduction: <command, input or trace>. Consequence: <what goes wrong>.
   Fix plan: <one line>. <After the fix round: "Fixed in `<sha>`: <what changed>.">

#### Rejected

- **[concurrency]** <claim>: rejected, <evidence with file:line or command output>.

#### Follow-ups (real, outside this packet; contract questions first)

- #<issue>: <title>

#### Next

<Round <N+1> runs: <lenses> at tier <t>, because <confirmed lenses / the fix touched …>.>
<or: Panel passed after <N> round(s). The dispatcher checks CI on `<short sha>` and hands the PR to the owner; never "Ready to merge" from the panel itself.>
<or: Needs human: <the question>.>
