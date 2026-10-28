# Repository working rules

## Exactly three current documents

The user explicitly requested only these three maintained documents:

- `docs/FRONTEND-DESIGN.zh-HK.md`: App behavior, current implementation,
  indoor guidance, installation and device acceptance.
- `docs/BACKEND-DESIGN.zh-HK.md`: identity, photo contracts, cloud deployment,
  training orchestration, model delivery and GitHub rollback.
- `docs/DATASET-REVIEW.zh-HK.md`: dataset review, taxonomy, model quality,
  active training handoff, evaluation and source attribution.

Every feature, interface, model or acceptance-status change must update the
relevant document(s) in the same commit. Each document must retain the shared
S0-S7 stage table (work, evidence-based current status, completion criteria and
next dependencies) and a per-feature implementation plan (method/data flow,
dependencies and acceptance). Preserve App background in the frontend document. Update the current-state and limitation
sections as well as the dated maintenance entry. Check behavior against actual
code and evidence; do not mark a feature complete merely because it is planned,
builds, or passes unit tests. Cross-component changes update every affected doc.

Do not create new handoff, roadmap, comparison, dated status, archive, README,
Word or duplicate plan documents under `docs/`. Keep that directory limited to
the three files above. Root/component READMEs are short links to these files,
not additional sources of truth. Replace obsolete information in place rather
than adding a new document for the user to reconcile.

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
