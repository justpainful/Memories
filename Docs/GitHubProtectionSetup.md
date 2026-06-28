# GitHub Protection Setup

## Required owners

- `/.github/CODEOWNERS` assigns the repository and protected identity/build paths to `@gnooouk`.

## Recommended branch protection

Apply a branch ruleset to the default branch with these minimum rules:

1. Require pull requests before merging.
2. Require status checks to pass before merging.
3. Require the `CI / ci` job from `/.github/workflows/ci.yml`.
4. Require review from Code Owners.
5. Block direct pushes to the default branch.
6. Restrict force pushes and branch deletion.

## Repository variable

Create an optional repository variable named `EXPECTED_BUNDLE_ID`.

- Recommended value: `space.hi.memories`
- If omitted, both workflows fall back to `space.hi.memories`.

## Artifact expectations

- The CI workflow uploads build logs and result bundles only on failure.
- The unsigned IPA workflow uploads the `.ipa`, `.sha256`, and `.manifest.json` artifacts for every successful manual or tag-triggered run.
