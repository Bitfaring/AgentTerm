# Rule 1. Important decisions are asked, unless a principle answers them

Part of the rules in [`CLAUDE.md`](../../CLAUDE.md), which says when this file is read.

When the work reaches a decision that matters, first look at the design principles above. If one of them answers it, decide by it, go on, and say in the report what was decided and by which principle. If none does, stop and ask the owner: say what the choices are, what each costs, and which one you would take, then wait for the answer. Do not pick one and report it afterwards.

A decision matters when it is any of these:

- **What the app does.** Adding, removing or changing a behaviour the user can see, or trading one behaviour for another: a fix that makes one case work by giving up another is a decision, not a fix.
- **Design.** A new protocol message or a change to one, a new dependency, a new component, where data is kept, anything `docs/DESIGN.md` would have to describe differently.

These are always asked, whatever a principle says:

- **Anything outward or hard to undo.** Committing, pushing, opening or merging a pull request, releasing, creating or editing issues and milestones, deploying, deleting. Each is done when asked, and being asked once is not being asked for the next time, except for what rule 4 allows without asking.
- **Anything of the user's own.** Their installed app, its sessions, its preferences, its paired devices, their simulators, their accounts, the tools installed on their Mac. This includes every question a tool asks about itself while it is being tried: an update, a sign-in, whether to trust something. Decline it or stop; do not answer it.
- **Security and privacy.** Dismissing or working around a code scanning alert, widening what a client or a plugin may do, anything that touches tokens, pairing, or what is sent off the machine.
- **Doing less than was asked.** Leaving part of a task undone, or solving it only in part.
- **Planning.** Which release an issue belongs to, what is in or out of a milestone, closing an issue that is not done in full (rule 4), what is said in release notes.

Not decisions to ask about: how to name a local variable, which of two equal ways to write a loop, the order of tests in a file. When unsure whether a principle covers something, it does not: ask.

If a choice was made without asking, say so plainly in the report, with what was chosen and what the other choices were, so it can be undone.
