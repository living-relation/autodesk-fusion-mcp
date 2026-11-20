#!/usr/bin/env bash
# Merge upstream's default branch into this fork's main.
#
# Fast-forward when possible. Otherwise create a normal merge commit.
# Never force-push. On conflict, or when the result cannot be pushed with
# the default GITHUB_TOKEN, leave the remote branch unchanged and exit 1.
# When Issues are enabled, open or update one issue titled "$ISSUE_TITLE".

set -euo pipefail

: "${UPSTREAM_REPOSITORY:?UPSTREAM_REPOSITORY is required}"
: "${FORK_BRANCH:?FORK_BRANCH is required}"
: "${ISSUE_TITLE:?ISSUE_TITLE is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SERVER_URL:?GITHUB_SERVER_URL is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"

export GIT_TERMINAL_PROMPT=0
export GIT_MERGE_AUTOEDIT=no
export GIT_EDITOR=false

run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
base_sha="unknown"
upstream_sha="unknown"
upstream_branch="${UPSTREAM_BRANCH:-unknown}"
upstream_ref="refs/sync/upstream"
sync_mode="unknown"
merge_message=""

cd "$(git rev-parse --show-toplevel)"

require_repo_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
}

require_branch_name() {
  local name="$1"
  # Git ref characters that are not in this set cannot appear in a branch we fetch or push.
  [[ "$name" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  [[ "$name" != -* && "$name" != /* && "$name" != */ ]] || return 1
  [[ "$name" != *..* && "$name" != *//* ]] || return 1
}

sanitize() {
  sed -E \
    -e 's/(ghs_|github_pat_|ghp_|gho_)[A-Za-z0-9_]+/[redacted]/g' \
    -e 's#x-access-token:[^@[:space:]]+#x-access-token:[redacted]#g'
}

note_summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

issues_are_enabled() {
  local flag err_file
  err_file=$(mktemp)
  if ! flag=$(gh api "repos/${GITHUB_REPOSITORY}" --jq .has_issues 2>"$err_file"); then
    echo "Could not tell whether Issues are enabled."
    cat "$err_file"
    rm -f "$err_file"
    return 2
  fi
  rm -f "$err_file"
  [[ "$flag" == "true" ]]
}

open_sync_issue_number() {
  local json
  if ! json=$(gh issue list \
    --repo "$GITHUB_REPOSITORY" \
    --state open \
    --limit 50 \
    --search "in:title \"${ISSUE_TITLE}\"" \
    --json number,title); then
    echo "Could not list issues." >&2
    return 1
  fi
  jq -r --arg title "$ISSUE_TITLE" \
    '[.[] | select(.title == $title) | .number] | sort | .[0] // empty' <<<"$json"
}

write_issue_body() {
  local summary="$1"
  local details="$2"
  local kind="$3"
  local howto safe_details fence broken_fence

  case "$kind" in
    conflict)
      howto="Check out ${FORK_BRANCH} and merge https://github.com/${UPSTREAM_REPOSITORY}.git branch ${upstream_branch}. Fix the conflicts, commit, and push without --force. The next sync continues from that push."
      ;;
    workflow-files)
      howto="The merge itself was clean. GitHub's default GITHUB_TOKEN cannot push a commit that creates or edits files under .github/workflows (the workflow permissions block has no workflows scope). Merge upstream into ${FORK_BRANCH} on your machine and push without --force. A normal login can update those files."
      ;;
    push-rejected)
      howto="The push was rejected, so the remote branch was left as it was. A branch protection rule is a common cause. Fix the rejection below, or merge upstream locally and push without --force."
      ;;
    *)
      howto="Merge upstream into ${FORK_BRANCH} locally and push without --force."
      ;;
  esac

  safe_details=$(printf '%s' "$details" | sanitize)
  if [[ ${#safe_details} -gt 12000 ]]; then
    safe_details="${safe_details:0:12000}"$'\n''[truncated]'
  fi
  # Keep the markdown fence intact if a path contains three backticks.
  fence=$(printf '\140\140\140')
  broken_fence=$(printf '\140\140 ')
  safe_details=${safe_details//"$fence"/"$broken_fence"}

  cat <<EOF
The daily sync from \`${UPSTREAM_REPOSITORY}\` into \`${FORK_BRANCH}\` did not update the branch.

${summary}

- Upstream \`${upstream_branch}\`: \`${upstream_sha}\`
- \`${FORK_BRANCH}\` before this attempt: \`${base_sha}\`
- Failed run: ${run_url}

## How to fix

${howto}

A later run that finds upstream already contained in \`${FORK_BRANCH}\` closes this issue.

## Details

\`\`\`text
${safe_details}
\`\`\`
EOF
}

file_sync_issue() {
  local summary="$1"
  local details="$2"
  local kind="$3"
  local enabled_status number body_file

  set +e
  issues_are_enabled
  enabled_status=$?
  set -e
  if [[ "$enabled_status" -eq 2 ]]; then
    echo "No issue was opened. The failure is in this log."
    return 0
  fi
  if [[ "$enabled_status" -ne 0 ]]; then
    echo "Issues are disabled on ${GITHUB_REPOSITORY}, so no issue was opened. The failure is in this log."
    return 0
  fi

  if ! number=$(open_sync_issue_number); then
    echo "No issue was opened. The failure is in this log."
    return 0
  fi

  body_file=$(mktemp)
  write_issue_body "$summary" "$details" "$kind" >"$body_file"

  if [[ -n "$number" ]]; then
    if ! gh issue edit "$number" --repo "$GITHUB_REPOSITORY" --body-file "$body_file"; then
      echo "Could not update issue #${number}. The failure is in this log."
      rm -f "$body_file"
      return 0
    fi
    if ! gh issue comment "$number" --repo "$GITHUB_REPOSITORY" \
      --body "Sync failed again (${kind}): ${run_url}"; then
      echo "Updated issue #${number}, but could not add a comment."
      rm -f "$body_file"
      return 0
    fi
    echo "Updated issue #${number}."
  elif ! gh issue create --repo "$GITHUB_REPOSITORY" --title "$ISSUE_TITLE" --body-file "$body_file"; then
    echo "Could not open an issue. The failure is in this log."
    rm -f "$body_file"
    return 0
  else
    echo "Opened an issue titled: ${ISSUE_TITLE}"
  fi
  rm -f "$body_file"
}

close_sync_issue() {
  local enabled_status number sha
  set +e
  issues_are_enabled
  enabled_status=$?
  set -e
  if [[ "$enabled_status" -eq 2 ]]; then
    echo "Synced. Could not check Issues, so no issue was closed."
    return 0
  fi
  if [[ "$enabled_status" -ne 0 ]]; then
    echo "Synced. Issues are disabled, so there was no conflict issue to close."
    return 0
  fi
  if ! number=$(open_sync_issue_number); then
    echo "::warning::Synced, but the conflict issue could not be looked up."
    return 0
  fi
  if [[ -z "$number" ]]; then
    echo "Synced. No open issue titled '${ISSUE_TITLE}'."
    return 0
  fi
  sha=$(git rev-parse HEAD)
  if ! gh issue close "$number" --repo "$GITHUB_REPOSITORY" --reason completed \
    --comment "Upstream ${upstream_branch} (${upstream_sha}) is now in ${FORK_BRANCH} (${sha}). Closing this report."; then
    echo "::warning::Synced, but issue #${number} could not be closed."
    return 0
  fi
  echo "Closed issue #${number}."
}

die() {
  local summary="$1"
  local details="$2"
  local kind="$3"
  echo "::error::${summary}"
  echo "$summary"
  note_summary "## Sync failed"
  note_summary ""
  note_summary "$summary"
  file_sync_issue "$summary" "$details" "$kind"
  exit 1
}

refuse_outside_actions() {
  local origin_url
  origin_url=$(git remote get-url origin)
  case "$origin_url" in
    *github.com*)
      if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
        echo "::error::Refusing to push to GitHub from outside GitHub Actions."
        exit 1
      fi
      ;;
  esac
}

prepare_git() {
  local current
  if [[ "${GITHUB_ACTIONS:-}" == "true" && -z "${GH_TOKEN:-}" ]]; then
    echo "::error::GH_TOKEN is empty. Pass github.token into the workflow."
    exit 1
  fi
  if [[ "$(git rev-parse --is-shallow-repository)" == "true" ]]; then
    echo "::error::Refusing to merge a shallow clone. Check out with fetch-depth: 0."
    exit 1
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "::error::Working tree is dirty. ${FORK_BRANCH} was not changed."
    exit 1
  fi
  current=$(git rev-parse --abbrev-ref HEAD)
  if [[ "$current" != "$FORK_BRANCH" ]]; then
    echo "::error::Expected branch ${FORK_BRANCH}, found ${current}."
    exit 1
  fi
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git fetch origin "$FORK_BRANCH"
  if ! git merge-base --is-ancestor HEAD "origin/${FORK_BRANCH}"; then
    echo "::error::Local ${FORK_BRANCH} is not contained in origin/${FORK_BRANCH}. Refusing to merge."
    exit 1
  fi
  if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/${FORK_BRANCH}")" ]]; then
    git merge --ff-only "origin/${FORK_BRANCH}"
  fi
}

resolve_upstream_branch() {
  local resolved err_file
  if [[ -n "${UPSTREAM_BRANCH:-}" ]]; then
    upstream_branch="$UPSTREAM_BRANCH"
    return 0
  fi
  err_file=$(mktemp)
  if ! resolved=$(gh api "repos/${UPSTREAM_REPOSITORY}" --jq .default_branch 2>"$err_file"); then
    echo "::error::Could not read the default branch of ${UPSTREAM_REPOSITORY}. ${FORK_BRANCH} was not changed."
    cat "$err_file"
    rm -f "$err_file"
    exit 1
  fi
  rm -f "$err_file"
  if [[ -z "$resolved" || "$resolved" == "null" ]]; then
    echo "::error::${UPSTREAM_REPOSITORY} did not report a default branch. ${FORK_BRANCH} was not changed."
    exit 1
  fi
  upstream_branch="$resolved"
}

warn_if_parent_differs() {
  local parent err_file
  # Local rehearsals set UPSTREAM_GIT_URL and skip the GitHub parent lookup.
  if [[ -n "${UPSTREAM_GIT_URL:-}" ]]; then
    return 0
  fi
  err_file=$(mktemp)
  if ! parent=$(gh api "repos/${GITHUB_REPOSITORY}" --jq '.parent.full_name // empty' 2>"$err_file"); then
    echo "Could not read the fork parent. Continuing with ${UPSTREAM_REPOSITORY}."
    rm -f "$err_file"
    return 0
  fi
  rm -f "$err_file"
  if [[ -n "$parent" && "$parent" != "$UPSTREAM_REPOSITORY" ]]; then
    echo "::warning::Fork parent is ${parent}. This workflow still syncs ${UPSTREAM_REPOSITORY}."
  fi
}

fetch_upstream() {
  local upstream_url
  upstream_url="${UPSTREAM_GIT_URL:-https://github.com/${UPSTREAM_REPOSITORY}.git}"
  # The plus sign updates only the local marker ref. The push to origin never uses --force.
  if ! git fetch --no-tags "$upstream_url" "+${upstream_branch}:${upstream_ref}"; then
    echo "::error::Could not fetch ${UPSTREAM_REPOSITORY} ${upstream_branch}. ${FORK_BRANCH} was not changed."
    exit 1
  fi
  upstream_sha=$(git rev-parse "$upstream_ref")
  echo "Fork ${FORK_BRANCH}: ${base_sha}"
  echo "Upstream ${upstream_branch}: ${upstream_sha}"
}

handle_merge_failure() {
  local out_file="$1"
  local conflicts message merge_head
  conflicts=$(git diff --name-only --diff-filter=U || true)
  message=$(sanitize <"$out_file")
  merge_head=$(git rev-parse --git-path MERGE_HEAD)
  if [[ -f "$merge_head" ]]; then
    git merge --abort
  fi
  if [[ -n "$conflicts" ]]; then
    die "Merge conflicts. Nothing was pushed, and ${FORK_BRANCH} is unchanged." "$conflicts" "conflict"
  fi
  die "The merge failed before it could commit. Nothing was pushed, and ${FORK_BRANCH} is unchanged." "$message" "merge-failed"
}

merge_upstream() {
  local out_file status
  out_file=$(mktemp)
  merge_message=$(
    cat <<EOF
Merge upstream ${UPSTREAM_REPOSITORY} (${upstream_branch}) into ${FORK_BRANCH}

Upstream commit: ${upstream_sha}
EOF
  )

  if git merge-base --is-ancestor "$upstream_ref" HEAD; then
    sync_mode="already up to date"
    rm -f "$out_file"
    return 0
  fi

  if git merge-base --is-ancestor HEAD "$upstream_ref"; then
    set +e
    git merge --ff-only "$upstream_ref" >"$out_file" 2>&1
    status=$?
    set -e
    cat "$out_file"
    if [[ "$status" -ne 0 ]]; then
      handle_merge_failure "$out_file"
    fi
    sync_mode="fast-forward"
    rm -f "$out_file"
    if [[ "$(git rev-parse HEAD)" != "$upstream_sha" ]]; then
      die "Fast-forward did not land on the upstream commit. Nothing was pushed." "$(git status --porcelain)" "merge-failed"
    fi
    return 0
  fi

  set +e
  git -c commit.gpgsign=false merge --no-ff --no-edit -m "$merge_message" "$upstream_ref" >"$out_file" 2>&1
  status=$?
  set -e
  cat "$out_file"
  if [[ "$status" -ne 0 ]]; then
    handle_merge_failure "$out_file"
  fi
  rm -f "$out_file"
  sync_mode="merge commit"
  if [[ "$(git rev-parse 'HEAD^1')" != "$base_sha" || "$(git rev-parse 'HEAD^2')" != "$upstream_sha" ]]; then
    die "Merge commit did not join ${FORK_BRANCH} and upstream. Nothing was pushed." "$(git rev-parse 'HEAD^1' 'HEAD^2')" "merge-failed"
  fi
}

workflow_files_in_push() {
  {
    git diff --name-only "origin/${FORK_BRANCH}" HEAD -- .github/workflows
    git log --name-only --pretty=format: "origin/${FORK_BRANCH}..HEAD" -- .github/workflows
  } | sed '/^$/d' | sort -u
}

ensure_workflow_push_allowed() {
  local files
  files=$(workflow_files_in_push)
  if [[ -n "$files" ]]; then
    die "Refusing to push because this update changes files under .github/workflows. The default GITHUB_TOKEN cannot push those changes, so ${FORK_BRANCH} was left unchanged." "$files" "workflow-files"
  fi
}

push_main() {
  local attempt err_file status push_error
  err_file=$(mktemp)
  for attempt in 1 2; do
    ensure_workflow_push_allowed
    set +e
    git push origin "HEAD:${FORK_BRANCH}" >"$err_file" 2>&1
    status=$?
    set -e
    sanitize <"$err_file"
    if [[ "$status" -eq 0 ]]; then
      rm -f "$err_file"
      return 0
    fi
    push_error=$(sanitize <"$err_file")
    if [[ "$attempt" -eq 1 ]] && grep -Eqi 'non-fast-forward|fetch first|tip of your current branch is behind' "$err_file"; then
      echo "origin/${FORK_BRANCH} moved during the push. Merging it and trying once more."
      git fetch origin "$FORK_BRANCH"
      set +e
      git -c commit.gpgsign=false merge --ff --no-edit \
        -m "Merge origin/${FORK_BRANCH} into upstream sync" \
        "origin/${FORK_BRANCH}" >"$err_file" 2>&1
      status=$?
      set -e
      cat "$err_file"
      if [[ "$status" -ne 0 ]]; then
        handle_merge_failure "$err_file"
      fi
      continue
    fi
    if grep -Eqi 'workflow' "$err_file" && grep -Eqi 'permission' "$err_file"; then
      die "The push was rejected because it updates .github/workflows. The default GITHUB_TOKEN cannot push those changes, so ${FORK_BRANCH} was left unchanged." "$push_error" "workflow-files"
    fi
    die "git push was rejected. ${FORK_BRANCH} was left unchanged." "$push_error" "push-rejected"
  done
  die "git push did not finish. ${FORK_BRANCH} was left unchanged." "push attempts exhausted" "push-rejected"
}

confirm_remote() {
  local local_sha remote_sha
  git fetch origin "$FORK_BRANCH"
  local_sha=$(git rev-parse HEAD)
  remote_sha=$(git rev-parse "origin/${FORK_BRANCH}")
  if [[ "$local_sha" != "$remote_sha" ]]; then
    die "Push finished but origin/${FORK_BRANCH} is ${remote_sha}, expected ${local_sha}." "local ${local_sha}" "push-rejected"
  fi
}

finish_success() {
  local sha
  sha=$(git rev-parse HEAD)
  echo "Sync finished. ${FORK_BRANCH} is ${sha} (${sync_mode})."
  note_summary "## Sync finished"
  note_summary ""
  note_summary "\`${FORK_BRANCH}\` is \`${sha}\` (${sync_mode})."
  note_summary ""
  note_summary "Upstream \`${UPSTREAM_REPOSITORY}\` \`${upstream_branch}\` is \`${upstream_sha}\`."
  close_sync_issue
}

main() {
  if ! require_repo_name "$UPSTREAM_REPOSITORY"; then
    echo "::error::Refusing upstream repository name."
    exit 1
  fi
  if ! require_repo_name "$GITHUB_REPOSITORY"; then
    echo "::error::Refusing GITHUB_REPOSITORY."
    exit 1
  fi
  if ! require_branch_name "$FORK_BRANCH"; then
    echo "::error::Refusing fork branch name."
    exit 1
  fi

  refuse_outside_actions
  prepare_git
  base_sha=$(git rev-parse HEAD)
  resolve_upstream_branch
  if ! require_branch_name "$upstream_branch"; then
    echo "::error::Refusing upstream branch name '${upstream_branch}'. ${FORK_BRANCH} was not changed."
    exit 1
  fi
  warn_if_parent_differs
  fetch_upstream
  merge_upstream

  if [[ "$sync_mode" == "already up to date" ]]; then
    echo "${FORK_BRANCH} already contains upstream/${upstream_branch} (${upstream_sha})."
    finish_success
    exit 0
  fi

  push_main
  confirm_remote
  finish_success
}

main "$@"
