# Contributing Guidelines

The following is a set of guidelines for contributing to the Proxmox VE Nimble Storage plugin.
We really appreciate that you are considering contributing!

## Table of Contents

- [Ask a Question](#ask-a-question)
- [Report a Bug](#report-a-bug)
- [Suggest a Feature or Enhancement](#suggest-a-feature-or-enhancement)
- [Open a Discussion](#open-a-discussion)
- [Submit a Pull Request](#submit-a-pull-request)
  - [Documentation](#documentation)
- [Issue Lifecycle](#issue-lifecycle)

## Ask a Question

To ask a question, open an issue on GitHub with the label `question`.

## Report a Bug

To report a bug, open an issue on GitHub with the label `bug` using the
available bug report issue template. Before reporting a bug, make sure the
issue has not already been reported.

## Suggest a Feature or Enhancement

To suggest a feature or enhancement, open an issue on GitHub with the label
`feature` or `enhancement` using the available feature request issue template.
Please ensure the feature or enhancement has not already been suggested.

## Open a Discussion

For broader topics—design ideas, how something should work, or help that does
not fit a single bug or feature—use **[GitHub Discussions](https://github.com/brngates98/pve-nimble-plugin/discussions)**
if enabled on the repository. If Discussions are not available, open an issue
with the `question` label instead (see [Ask a Question](#ask-a-question)).

## Submit a Pull Request

Follow this plan to contribute a change to plugin source code:

- Fork repository
- Create a branch
- Implement your changes in this branch
- Submit a pull request (PR) when your changes are tested and ready for review

### Formatting Changes

- Changes should be formatted according to the code style

- Keep a clean, concise and meaningful commit history on your branch, rebasing
  locally and breaking changes logically into commits before submitting a PR

- Each commit message should have a single-line subject line followed by verbose
  description after an empty line

- Limit the subject line to 67 characters, and the rest of the commit message
  to 76 characters

- Reference issues in the subject line; if the commit fixes an issue,
  [name it](https://docs.github.com/en/issues/tracking-your-work-with-issues/linking-a-pull-request-to-an-issue)
  accordingly

### Before Submitting

- Try to make it clear why the suggested change is needed, and provide a use
  case, if possible

### Documentation

- **Feature comparison tables:** The “Feature comparison” and “Content types”
  markdown tables appear in **[README.md](README.md)** and
  **[docs/STORAGE_FEATURES_COMPARISON.md](docs/STORAGE_FEATURES_COMPARISON.md)**.
  If you add or change a row, column, or cell in one file, mirror the change in
  the other so operators and the extended doc stay aligned. Narrative sections
  below the tables (storage-type guides, “when to use”) live only in
  `docs/STORAGE_FEATURES_COMPARISON.md`.

## Issue Lifecycle

- **Triage:** Maintainers may add or adjust labels (e.g. `bug`, `feature`,
  `question`) and ask for missing details (Proxmox version, plugin version,
  logs, steps to reproduce).
- **Pull requests:** Link related issues in the PR description. Prefer
  [closing keywords](https://docs.github.com/en/issues/tracking-your-work-with-issues/linking-a-pull-request-to-an-issue)
  when a PR fully resolves an issue.
- **Closure:** Issues are closed when resolved, declined with a short reason,
  or superseded (e.g. duplicate). Stale threads may be closed after a
  reasonable period if there is no further actionable input.
