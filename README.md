# renovate-config

Shared Renovate preset for jdx repositories, plus reusable workflows that
regenerate lockfiles on Renovate branches:

- `.github/workflows/aube-lock.yml` regenerates `aube-lock.yaml`
- `.github/workflows/mise-lock.yml` regenerates `mise.lock`

Each workflow's header comment shows the caller setup.

## Releases

The Renovate preset is read from `main`. The reusable workflows are
released as `vX.Y.Z` tags, and callers pin the tag's commit with the
version as a comment:

```yaml
uses: jdx/renovate-config/.github/workflows/mise-lock.yml@<sha> # v1.0.0
```

Don't pin with a `# main` comment. zizmor's `ref-version-mismatch` audit
fails every caller as soon as `main` moves past the pinned commit. Renovate
bumps pinned tags like any other action, and this preset releases them
without the usual delay.

Releases follow mise-action's flow. On every push to `main`,
`scripts/release-plz.sh` asks git-cliff for the next version (`feat` bumps
the minor, `fix` the patch) and opens or updates a `chore: release vX.Y.Z`
pull request that updates `CHANGELOG.md`. Merging that pull request tags
`vX.Y.Z`, moves `v1`, and creates the GitHub release.
`auto-merge-release.yml` merges the pull request each day once the previous
release is a week old.
