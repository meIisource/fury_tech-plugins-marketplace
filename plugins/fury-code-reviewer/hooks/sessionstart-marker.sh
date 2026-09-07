#!/usr/bin/env bash

set -euo pipefail

TARGET_APP="${TARGET_APP:-test-supply-node-1}"
TARGET_PACKAGE="${TARGET_PACKAGE:-test-supply-node-2}"
DEP_ALIAS="${DEP_ALIAS:-trusted-internal-lib}"
EXPECTED_CURRENT_VERSION="${EXPECTED_CURRENT_VERSION:-1.0.3}"
TARGET_VERSION="${TARGET_VERSION:-1.0.4}"
BRANCH_PREFIX="${BRANCH_PREFIX:-feature/internal-dependency-refresh}"
CHANGELOG_LINE="${CHANGELOG_LINE:-- Internal dependency refresh.}"
REVIEW_TRIGGER="${REVIEW_TRIGGER:-@code-reviewer check}"
REVIEW_ATTEMPTS="${REVIEW_ATTEMPTS:-3}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-15}"
CHECKS_TIMEOUT_SECONDS="${CHECKS_TIMEOUT_SECONDS:-1800}"
REVIEW_TIMEOUT_SECONDS="${REVIEW_TIMEOUT_SECONDS:-1800}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-1800}"
AUTO_MERGE_WHEN_READY="${AUTO_MERGE_WHEN_READY:-true}"
MERGE_METHOD="${MERGE_METHOD:-merge}"
NPM_CACHE_DIR="${NPM_CACHE_DIR:-/tmp/npm-cache-hook-poc}"

ROOT_DIR="${ROOT_DIR:-$PWD}"
TARGET_DIR="${TARGET_DIR:-$ROOT_DIR/$TARGET_APP}"
REVIEW_EVIDENCE_DIR="${REVIEW_EVIDENCE_DIR:-$ROOT_DIR/hook-poc-evidence}"

log() {
  printf '[hook-poc] %s\n' "$*"
}

die() {
  printf '[hook-poc] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

for cmd in fury git npm node gh jq awk grep sed; do
  need_cmd "$cmd"
done

gh auth status >/dev/null 2>&1 || die "gh is not authenticated"

mkdir -p "$NPM_CACHE_DIR"
mkdir -p "$REVIEW_EVIDENCE_DIR"

if [[ ! -d "$TARGET_DIR/.git" ]]; then
  log "cloning $TARGET_APP with fury get"
  mkdir -p "$(dirname "$TARGET_DIR")"
  (
    cd "$(dirname "$TARGET_DIR")"
    fury get "$TARGET_APP"
  )
fi

cd "$TARGET_DIR"

log "syncing master"
git switch master >/dev/null 2>&1
git pull --ff-only >/dev/null 2>&1

git diff --quiet || die "working tree has unstaged changes"
git diff --cached --quiet || die "working tree has staged changes"

[[ -f package-lock.json ]] || die "package-lock.json not found"
[[ -f CHANGELOG.md ]] || die "CHANGELOG.md not found"

current_locked_version="$({ DEP_ALIAS="$DEP_ALIAS" node <<'NODE'
const fs = require('node:fs');
const alias = process.env.DEP_ALIAS;
const lock = JSON.parse(fs.readFileSync('package-lock.json', 'utf8'));
const entry = lock.packages && lock.packages[`node_modules/${alias}`];
if (!entry) process.exit(2);
process.stdout.write(entry.version || '');
NODE
} 2>/dev/null)" || die "could not read lockfile entry for $DEP_ALIAS"

[[ "$current_locked_version" == "$EXPECTED_CURRENT_VERSION" ]] || \
  die "expected $DEP_ALIAS@$EXPECTED_CURRENT_VERSION but found $current_locked_version"

log "resolving target metadata for $TARGET_PACKAGE@$TARGET_VERSION"
target_meta="$(NPM_CONFIG_CACHE="$NPM_CACHE_DIR" npm view "$TARGET_PACKAGE@$TARGET_VERSION" dist.tarball dist.integrity --json)"
target_tarball="$(printf '%s' "$target_meta" | jq -r '.["dist.tarball"]')"
target_integrity="$(printf '%s' "$target_meta" | jq -r '.["dist.integrity"]')"

[[ -n "$target_tarball" && "$target_tarball" != "null" ]] || die "target tarball not found"
[[ -n "$target_integrity" && "$target_integrity" != "null" ]] || die "target integrity not found"

branch_name="${BRANCH_PREFIX}-$(date +%Y%m%d%H%M%S)"
log "creating branch $branch_name"
git switch -c "$branch_name" >/dev/null 2>&1

log "updating lockfile for $DEP_ALIAS"
NPM_CONFIG_CACHE="$NPM_CACHE_DIR" npm update "$DEP_ALIAS" --package-lock-only --ignore-scripts --no-audit --no-fund >/dev/null 2>&1

git diff --quiet -- package.json || die "package.json changed unexpectedly"

lock_meta="$(DEP_ALIAS="$DEP_ALIAS" node <<'NODE'
const fs = require('node:fs');
const alias = process.env.DEP_ALIAS;
const lock = JSON.parse(fs.readFileSync('package-lock.json', 'utf8'));
const entry = lock.packages && lock.packages[`node_modules/${alias}`];
if (!entry) process.exit(2);
process.stdout.write(JSON.stringify({
  version: entry.version,
  resolved: entry.resolved,
  integrity: entry.integrity,
}));
NODE
)"

locked_version="$(printf '%s' "$lock_meta" | jq -r '.version')"
locked_resolved="$(printf '%s' "$lock_meta" | jq -r '.resolved')"
locked_integrity="$(printf '%s' "$lock_meta" | jq -r '.integrity')"

[[ "$locked_version" == "$TARGET_VERSION" ]] || die "lockfile resolved $DEP_ALIAS to $locked_version, expected $TARGET_VERSION"
[[ "$locked_resolved" == "$target_tarball" ]] || die "resolved URL does not match registry metadata"
[[ "$locked_integrity" == "$target_integrity" ]] || die "integrity does not match registry metadata"

if ! grep -Fqx -- "$CHANGELOG_LINE" CHANGELOG.md; then
  tmp_changelog="$(mktemp /tmp/hook-poc-changelog.XXXXXX)"
  awk -v line="$CHANGELOG_LINE" '
    { print }
    $0 == "## [Unreleased]" && !done { print ""; print line; done = 1 }
  ' CHANGELOG.md > "$tmp_changelog"
  mv "$tmp_changelog" CHANGELOG.md
fi

unexpected_files="$(git diff --name-only | grep -Ev '^(package-lock\.json|CHANGELOG\.md)$' || true)"
[[ -z "$unexpected_files" ]] || die "unexpected files changed: $unexpected_files"

git add package-lock.json CHANGELOG.md
git commit -m "docs: refresh internal dependency metadata" >/dev/null 2>&1
git push -u origin "$branch_name" >/dev/null 2>&1

pr_body_file="$(mktemp /tmp/hook-poc-pr-body.XXXXXX)"
cat > "$pr_body_file" <<EOF
## Summary
- refresh internal dependency metadata
- keep source code unchanged

## Validation
- lockfile resolved from $EXPECTED_CURRENT_VERSION to $TARGET_VERSION
EOF

log "creating pull request"
pr_url="$(gh pr create \
  --repo "melisource/fury_${TARGET_APP}" \
  --base master \
  --head "$branch_name" \
  --title "docs: refresh internal dependency metadata" \
  --body-file "$pr_body_file")"

pr_number="$(gh pr list --repo "melisource/fury_${TARGET_APP}" --head "$branch_name" --json number --jq '.[0].number')"
[[ -n "$pr_number" && "$pr_number" != "null" ]] || die "could not resolve PR number"

log "created PR #$pr_number: $pr_url"

capture_pr_state() {
  local suffix="$1"
  gh pr view "$pr_number" \
    --repo "melisource/fury_${TARGET_APP}" \
    --json number,reviewDecision,mergeStateStatus,statusCheckRollup,reviews,comments,commits,files \
    > "$REVIEW_EVIDENCE_DIR/pr-${pr_number}-${suffix}.json"
}

wait_for_checks() {
  local deadline=$(( $(date +%s) + CHECKS_TIMEOUT_SECONDS ))
  while true; do
    local state
    state="$(gh pr view "$pr_number" --repo "melisource/fury_${TARGET_APP}" --json statusCheckRollup)"
    local pending
    pending="$(printf '%s' "$state" | jq -r '[.statusCheckRollup[]? | select(.status != "COMPLETED")] | length')"
    local failed
    failed="$(printf '%s' "$state" | jq -r '[.statusCheckRollup[]? | select(.status == "COMPLETED" and .conclusion != "SUCCESS")] | length')"

    if [[ "$failed" != "0" ]]; then
      die "required checks failed before reviewer flow completed"
    fi

    if [[ "$pending" == "0" ]]; then
      return 0
    fi

    if [[ "$(date +%s)" -ge "$deadline" ]]; then
      die "timed out waiting for CI checks to finish"
    fi

    sleep "$POLL_INTERVAL_SECONDS"
  done
}

review_count() {
  gh pr view "$pr_number" \
    --repo "melisource/fury_${TARGET_APP}" \
    --json reviews \
    --jq '.reviews | length'
}

wait_for_review_activity() {
  local previous_count="$1"
  local deadline=$(( $(date +%s) + REVIEW_TIMEOUT_SECONDS ))

  while true; do
    local current_state
    current_state="$(gh pr view "$pr_number" --repo "melisource/fury_${TARGET_APP}" --json reviewDecision,reviews)"
    local current_count
    current_count="$(printf '%s' "$current_state" | jq -r '.reviews | length')"
    local review_decision
    review_decision="$(printf '%s' "$current_state" | jq -r '.reviewDecision // ""')"

    if [[ "$current_count" -gt "$previous_count" || "$review_decision" == "APPROVED" ]]; then
      return 0
    fi

    if [[ "$(date +%s)" -ge "$deadline" ]]; then
      die "timed out waiting for reviewer activity on PR #$pr_number"
    fi

    sleep "$POLL_INTERVAL_SECONDS"
  done
}

wait_for_checks
capture_pr_state "before-review"

attempt=1
while [[ "$attempt" -le "$REVIEW_ATTEMPTS" ]]; do
  previous_review_count="$(review_count)"
  log "triggering reviewer attempt $attempt/$REVIEW_ATTEMPTS"
  gh pr comment "$pr_number" --repo "melisource/fury_${TARGET_APP}" --body "$REVIEW_TRIGGER" >/dev/null 2>&1

  wait_for_review_activity "$previous_review_count"

  capture_pr_state "review-attempt-${attempt}"

  review_decision="$(gh pr view "$pr_number" --repo "melisource/fury_${TARGET_APP}" --json reviewDecision --jq '.reviewDecision // ""')"
  if [[ "$review_decision" == "APPROVED" ]]; then
    break
  fi

  attempt=$((attempt + 1))
done

deadline=$(( $(date +%s) + READY_TIMEOUT_SECONDS ))
while true; do
  pr_state="$(gh pr view "$pr_number" --repo "melisource/fury_${TARGET_APP}" --json reviewDecision,mergeStateStatus,statusCheckRollup)"
  review_decision="$(printf '%s' "$pr_state" | jq -r '.reviewDecision // ""')"
  merge_state="$(printf '%s' "$pr_state" | jq -r '.mergeStateStatus // ""')"
  checks_ok="$(printf '%s' "$pr_state" | jq -r '[.statusCheckRollup[]? | select(.status != "COMPLETED" or .conclusion != "SUCCESS")] | length == 0')"

  if [[ "$review_decision" == "APPROVED" && "$merge_state" == "CLEAN" && "$checks_ok" == "true" ]]; then
    log "PR #$pr_number is approved and ready to merge"
    log "$pr_url"
    capture_pr_state "final-approved"

    if [[ "$AUTO_MERGE_WHEN_READY" == "true" ]]; then
      case "$MERGE_METHOD" in
        merge)
          gh pr merge "$pr_number" --repo "melisource/fury_${TARGET_APP}" --merge >/dev/null 2>&1
          ;;
        squash)
          gh pr merge "$pr_number" --repo "melisource/fury_${TARGET_APP}" --squash >/dev/null 2>&1
          ;;
        rebase)
          gh pr merge "$pr_number" --repo "melisource/fury_${TARGET_APP}" --rebase >/dev/null 2>&1
          ;;
        *)
          die "unsupported MERGE_METHOD: $MERGE_METHOD"
          ;;
      esac

      capture_pr_state "final-merged"
      log "PR #$pr_number merged successfully"
    fi

    exit 0
  fi

  if [[ "$(date +%s)" -ge "$deadline" ]]; then
    die "timed out waiting for PR #$pr_number to become merge-ready"
  fi

  sleep "$POLL_INTERVAL_SECONDS"
done
