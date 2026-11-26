# Rule 5. How an issue is written, as the owner decided (2026-11-19)

Part of the rules in [`CLAUDE.md`](../../CLAUDE.md), which says when this file is read.

Every issue, a bug or not, has two versions in its body, kept in step (the list of what to read, item 2, is in the English only):

1. **English first**, as it has always been written: what was seen or is wanted, what was tried, what is not known yet, what was decided. Its boxes (`- [ ]`) are the only ones: a box is ticked in one place.
2. **`## Read`** before the definition of done: the sections of `docs/` and the source files a session must read to do this issue, each by its heading or path, and no more than it needs. It is in the English only.
3. **`## Definition of done`** at the end of the English: a numbered list of what must be true for that issue to be closed, written for it, not copied. It takes from rule 2 and the principles what applies:
   - what has to be decided or found out first, and by whom (the owner's choice, a real agent tried at its version);
   - for a bug, a test that fails because of it and is seen failing, then passes and stays; the root cause found and taken away; or principle 8's way, 5 tries not reproduced and said so;
   - what the change must do and must never do, both apps where principle 1 asks it, the words in `AgentTermProtocol` (principle 9), the protocol's number raised for a changed message (principle 6);
   - which docs say it (`docs/SPEC.md`, `docs/DESIGN.md`, `docs/TESTING.md`, the privacy policy at https://bitfaring.com/products/agentterm/privacy/, `docs/PERFORMANCE.md`), and the case a test names;
   - which layers of rule 2's table are run, and which pictures are looked at;
   - `make format` and `make lint`, committed on the milestone's branch and pushed, CI on the branch green.
4. After a horizontal rule, **`# Tiếng Việt`**: the same content in Vietnamese, opened by a line that says it is the translation of the English above (and, where there are boxes, that they are in the English only); boxes become plain bullets. Code, paths, commands and names stay as they are.
5. **`## Định nghĩa hoàn thành`** at the end of the Vietnamese: the definition of done, translated.

When an issue changes (a decision, a finding, what is done), both versions are changed in the same edit. A comment may be in either language.
