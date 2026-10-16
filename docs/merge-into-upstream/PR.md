Follow-up to #<issue-number>.

Adds the unofficial HarmonyOS port discussed there, as a self-contained
`harmonyos/` subdirectory.

### What this does not touch

- No Gradle files. `settings.gradle.kts` still includes only `:app`.
- No Android sources, no resources, no `fastlane/`, no CI workflows.
- No existing file is modified except a short new section in the top-level
  `README.md`.

### Verification

- [x] `cd harmonyos && ./build.sh all` completes with `BUILD SUCCESSFUL` and
      produces a HAP that passes `verify-app` (253 KB signed).
- [x] Tracked files under `harmonyos/` are 50, and `git check-ignore` confirms
      no build output or signing material is tracked (the directory carries its
      own `.gitignore` for `build/`, `dist/` and `entry/build/`).
- [x] The UI is localized in English and Simplified Chinese; the Chinese strings
      reuse the wording from `app/src/main/res/values-zh-rCN/strings.xml`.
- [x] The app launches on a HarmonyOS emulator (API 21) and the full
      pick-image to pick-drive flow renders.
- [ ] Writing to a real USB drive on physical hardware. **Not verified**, the
      emulator has no USB host service. I will confirm this before anyone calls
      it releasable, and I will say so in the README until then.

### Maintenance

Maintained by me (@<your-github-username>). It has no effect on your build,
your releases, or your CI.

If you would rather not carry a second toolchain in this repository, say so and
I will take option B from the linked issue instead - a one-line README link to
my own repository - without any further discussion.
