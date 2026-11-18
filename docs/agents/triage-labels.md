# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Out of the factory: the managing Claude session handles it (not the owner) |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

Edit the right-hand column to match whatever vocabulary you actually use.

## Factory labels

These are not triage roles. The software factory uses them (see `docs/adr/0001-software-factory.md`).

| Label         | Meaning                                                                                     |
| ------------- | ------------------------------------------------------------------------------------------- |
| `spec`        | A spec issue. Triggers the Decompose task, which opens a spec PR of acceptance tests; Odin reviews and merges it, then applies `ready-for-agent` to the tickets. A spec issue never gets `ready-for-agent`, even when `/to-spec` says to apply it. |
| `ready-for-agent` | Also the factory's go signal: the Implementer takes an open ticket with this label once its blockers are closed — a Decompose ticket or one written by hand (its body's checklist is then the acceptance criteria). |
| `in-progress` | An Implementer run has claimed this ticket. The run removes `ready-for-agent` and adds this. |
| `model:sonnet` | The Implementer run uses Sonnet (also the default when a ticket has no model label). Set by the Decompose run. |
| `model:opus`   | The Implementer run uses Opus. Set by the Decompose run. A retry after a code failure (checks or merge) uses Opus; a runner or network failure retries on the same model. |
| `needs-decision` | The factory paused this spec to ask the owner: a `<!-- factory-question -->` comment holds the options and a recommendation. Answer in a comment, then remove the label; the resume workflow continues from the stopped step. Only this spec waits. |
| `spec-pr`      | A spec PR opened by Decompose: the spec's per-ticket acceptance tests, each switched off with a `#<ticket>` marker (`.github/factory/spec-tests.sh`). Odin reviews and merges it. |
| `factory-paused` | The spec reached its cost cap (`예산: $N` in the spec body, else the repo variable, else $60). Raise the cap and remove the label to resume. |
| `factory-ledger` | The single cost ledger issue: one `<!-- ledger -->` comment per Claude step. |
