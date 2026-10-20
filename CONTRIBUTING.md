# Contributing

Issues and pull requests are welcome. The kit is the agents, skills and scripts in this repository; the [README](README.md) explains how it works and why.

## Before you open a pull request

- **Run the offline tests.** They need PowerShell 7.2+ and git 2.38+, and no network:

  ```bash
  pwsh -File tests/run-tests.ps1
  ```

  They must end with `0 failed`. A change to what a script does comes with a test that fails without it.
- **Say how you checked it inside Copilot** when you change an agent, a skill's instructions or a template. The offline tests can't see how a model follows instructions. Name the stages of [tests/copilot-e2e.prompt.md](tests/copilot-e2e.prompt.md) you ran on a sandbox repository, the harness and the models. If you couldn't run them, say so.
- **Keep the safety model intact.** A change to claims, markers, `trustedAuthors`, the pinned kit, `check-scope.ps1`, `review-scope.ps1` or the review tiers needs a sentence in the pull request on what it does to the [safety model](README.md#safety-model). When a rule, or where it's enforced, changes, update that table too.
- **Keep the kit provider-neutral.** Put board-specific code in a provider under `skills/packet-board/scripts/providers/`. `board.ps1` still has a few Azure Boards branches; don't add more.

## Conventions

- Scripts are PowerShell 7 and run on Windows, macOS and Linux. The scripts the skills run exit 2 on an error, and the instructions stop on exit 2, so a failed check never reads as a pass.
- Instructions (agents, skills, templates) say what to do, in order, and when to stop. When a script can decide something, check it in the script rather than in an instruction.
- Leave `VERSION` alone; it changes with a release.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
