# TouchBridge — Task List

## Cleanup

- [x] **Remove `--web` flag + `WebCompanion.swift` from daemon** — removed `--web`/`--web-port` flags from `main.swift`, deleted `runWebMode()`, deleted `WebCompanion.swift`. Build + 112 tests pass.
- [x] **Fix CLAUDE.md** — replaced with thin pointer to AGENTS.md; AGENTS.md is the canonical dev guide (removed stale `tools/` and `.agents/skills/` entries)
- [x] **Fix `.agents/skills/touchbridge/SKILL.md`** — removed "any browser" from tagline, removed `--web` from production mode and modes list
- [ ] **Untrack generated Xcode project** — `git rm --cached -r mac/menubar/TouchBridgeMenu.xcodeproj` (already in .gitignore but still tracked)
- [ ] **Run daemon tests** — verify all tests pass after NMH + web removal (`cd mac/daemon && swift test`)
- [ ] **Verify shell script syntax** — `bash -n` on all scripts in `scripts/`

## Features

- [ ] **Add `ignore_ssh` policy option** — PAM module checks `$SSH_CLIENT`/`$SSH_CONNECTION`/`$SSH_TTY` and falls through to password when SSH'd in. Config: `touchbridge config set --surface sudo --skip-ssh true`. Inspired by `pam_reattach`'s `ignore_ssh` option.
- [ ] **Fix Android companion protocol mismatches** — 5 critical issues per architecture review (wire format headers, Base64 encoding, missing identify message, etc.)

## Deferred

- [ ] **Verify Blume docs build** — `bash scripts/docs.sh build` (deferred until docs content is settled)
