# Repository working rules

## Three current review documents and one product introduction

The three maintained technical review documents are:

- `docs/FRONTEND-DESIGN.zh-HK.md`: App behavior, current implementation,
  indoor guidance, installation and device acceptance.
- `docs/BACKEND-DESIGN.zh-HK.md`: identity, photo contracts, cloud deployment,
  training orchestration, model delivery and GitHub rollback.
- `docs/DATASET-REVIEW.zh-HK.md`: dataset review, taxonomy, model quality,
  active training handoff, evaluation and source attribution.

On 2026-10-31 the user additionally requested
`docs/APP-FEATURES.zh-HK.md`: a concise introduction to the complete target App,
covering all intended features, principal tools and their purpose. It describes
the finished product vision, not current delivery status or another work plan.

Every feature, interface, model or acceptance-status change must update the
relevant document(s) in the same commit. Each technical review document must retain the shared
S0-S7 stage table (work, evidence-based current status, completion criteria and
next dependencies) and a per-feature implementation plan (method/data flow,
dependencies and acceptance). Preserve App background in the frontend document. Update the current-state and limitation
sections as well as the dated maintenance entry. Check behavior against actual
code and evidence; do not mark a feature complete merely because it is planned,
builds, or passes unit tests. Cross-component changes update every affected doc.

Do not create new handoff, roadmap, comparison, dated status, archive, README,
Word or duplicate plan documents under `docs/`. Keep that directory limited to
the three review files above plus the explicitly requested product introduction.
Root/component READMEs are short links to these files,
not additional sources of truth. Replace obsolete information in place rather
than adding a new document for the user to reconcile.

`docs/agents/issue-tracker.md` 與 `docs/agents/domain.md` 僅作技能設定，為上述文件數量限制的例外。

Machine evidence belongs in `verification/`, candidate configuration in
`configs/planning/`, and local/generated review artifacts in
`dataset_pipeline/review_artifacts/` (ignored). Keep original photos, labels,
snapshot manifests and attribution records. Documentation cleanup must not
destroy source data. Historical committed documents are recoverable through Git;
the cleanup backup of uncommitted documents is outside the repository.

The active B11 training handoff is the B11 section in the dataset document.
Do not recreate the retired `docs/dataset-work/` tree. Do not restart a healthy
training run merely because its old handoff path was removed.

## Required version checkpoint

2026-11-05 user-approved cadence: after each ticket passes its scoped checks and
code review, commit and push the relevant source, documents and machine evidence
to `feature/cross-platform-navigation`, verify the remote commit, then mark the
ticket complete. A source checkpoint does not require an App version bump or
Release and is not a delivered phone version. Preserve unrelated dirty work.

Prepare phone prereleases after P2-D, P3-C, P4-B and P5. The first P2-D user
session is approximately 10-15 minutes. P3-A also requires an earlier developer
device check for Keychain, file protection/backup exclusion, reopen and deletion.
Every installation, including engineering device checks, follows the version
checkpoint below. Human acceptance is recorded separately from automated checks;
do not claim acceptance while awaiting the user's phone results.

For each completed App/shared-model version: verify, update the corresponding
documents, commit source/lockfiles/model+mapping, create an immutable version tag
and GitHub Release, push and verify the remote, then install/deliver. Repository:
`https://github.com/actiondarr/pathguide`; existing development branch:
`feature/cross-platform-navigation`. Retain prior releases and exact model hashes;
never force-push or move an existing release tag. Documentation-only commits do
not constitute a complete App rollback checkpoint.

Never upload private photos, per-user weights, credentials or private evaluation
content to the shared repository. Preserve private rollback versions in
authenticated UID-scoped storage. Keep paid GPU submission disabled until a
budget is configured. Preserve unrelated uncommitted App/model/data work.

## Agent skills

### Issue tracker

工作項目及規格使用 `actiondarr/pathguide` 的 GitHub Issues。
操作規則見 `docs/agents/issue-tracker.md`。

### Domain docs

採用 single-context，沿用現有四份產品／技術文件。
閱讀及維護規則見 `docs/agents/domain.md`。

## Current implementation ownership

2026-11-05: The user reassigned implementation and acceptance directly to Codex.
This supersedes earlier DSH-only implementation instructions in plans and reviews.
Preserve rejected DSH drafts and their acceptance evidence. Do not send further
DSH model requests unless the user explicitly asks to use DSH again.
