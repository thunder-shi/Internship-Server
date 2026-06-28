#!/bin/bash
# 定时自动发版：拉取 GitHub main + docker compose up -d --build
# 用法：
#   auto-deploy.sh              # 凌晨 1 点正常执行
#   auto-deploy.sh --retry-if-failed   # 凌晨 2 点：仅当 1 点失败时重试

set -euo pipefail

export TZ=Asia/Shanghai
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ========== 配置（部署前在服务器上修改 TOKEN）==========
GITHUB_USER="DaoyingWen"
GITHUB_TOKEN="在此填入GitHub_Personal_Access_Token"

BASE_DIR="/opt/internship"
NEWBACK_DIR="${BASE_DIR}/Internship-NewBack"
FRONT_DIR="${BASE_DIR}/Internship-Front"
COMPOSE_DIR="${BASE_DIR}/server_directory"
GITHUB_ORG="thunder-shi"

GIT_TIMEOUT=120
BUILD_TIMEOUT=600

LOG_FILE="/var/log/internship-deploy.log"
STATUS_FILE="${COMPOSE_DIR}/logs/deploy-last.status"
LOCK_FILE="/var/run/internship-auto-deploy.lock"

GIT_FETCH_TIMEOUT="${GIT_TIMEOUT}"
GIT_PULL_TIMEOUT="${GIT_TIMEOUT}"

# ========== 日志 ==========
mkdir -p "$(dirname "$LOG_FILE")" "${COMPOSE_DIR}/logs"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

record_status() {
  # SUCCESS|FAIL + unix timestamp
  echo "$1 $(date +%s)" > "$STATUS_FILE"
}

run_with_timeout() {
  local seconds="$1"
  shift
  log "执行（超时 ${seconds}s）: $*"
  if timeout "$seconds" "$@"; then
    return 0
  fi
  local rc=$?
  if [[ "$rc" -eq 124 ]]; then
    log "ERROR: 命令超时（${seconds}s）: $*"
  else
    log "ERROR: 命令失败（exit ${rc}）: $*"
  fi
  return "$rc"
}

should_retry_only() {
  [[ "${1:-}" == "--retry-if-failed" ]]
}

check_retry_if_failed() {
  if [[ ! -f "$STATUS_FILE" ]]; then
    log "重试检查：无状态文件，跳过 2 点重试"
    exit 0
  fi
  read -r status ts <<< "$(tr -s ' ' < "$STATUS_FILE")"
  if [[ "$status" == "SUCCESS" ]]; then
    log "重试检查：1 点已成功，跳过 2 点重试"
    exit 0
  fi
  local today run_day run_hour
  today=$(date +%Y%m%d)
  run_day=$(date -d "@${ts}" +%Y%m%d)
  run_hour=$(date -d "@${ts}" +%H)
  if [[ "$run_day" != "$today" || "$run_hour" != "01" ]]; then
    log "重试检查：上次失败非今日 1 点任务（day=${run_day} hour=${run_hour}），跳过"
    exit 0
  fi
  log "重试检查：1 点失败，开始 2 点重试"
}

validate_config() {
  if [[ -z "$GITHUB_TOKEN" || "$GITHUB_TOKEN" == "在此填入GitHub_Personal_Access_Token" ]]; then
    log "ERROR: 请编辑脚本，设置 GITHUB_TOKEN"
    exit 1
  fi
  for d in "$NEWBACK_DIR" "$FRONT_DIR" "$COMPOSE_DIR"; do
    if [[ ! -d "$d" ]]; then
      log "ERROR: 目录不存在: $d"
      exit 1
    fi
  done
  if ! command -v docker >/dev/null 2>&1; then
    log "ERROR: 未找到 docker"
    exit 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    log "ERROR: 未找到 docker compose v2"
    exit 1
  fi
}

git_sync_repo() {
  local dir="$1"
  local repo_name="$2"
  local remote_url="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${repo_name}.git"

  log "===== 同步仓库: ${repo_name} ====="
  cd "$dir"

  local old_url
  old_url=$(git remote get-url origin 2>/dev/null || true)
  git remote set-url origin "$remote_url"

  if ! run_with_timeout "$GIT_FETCH_TIMEOUT" git fetch origin; then
    [[ -n "$old_url" ]] && git remote set-url origin "$old_url" || true
    return 1
  fi
  if ! run_with_timeout "$GIT_PULL_TIMEOUT" git pull --rebase origin main; then
    [[ -n "$old_url" ]] && git remote set-url origin "$old_url" || true
    return 1
  fi

  if [[ -n "$old_url" ]]; then
    git remote set-url origin "$old_url"
  else
    git remote set-url origin "https://github.com/${GITHUB_ORG}/${repo_name}.git"
  fi

  log "${repo_name} 当前提交: $(git log -1 --oneline)"
  log "${repo_name} 状态: $(git status -sb)"
  return 0
}

docker_build_up() {
  log "===== docker compose up -d --build ====="
  cd "$COMPOSE_DIR"
  if ! run_with_timeout "$BUILD_TIMEOUT" docker compose up -d --build; then
    return 1
  fi
  docker compose ps | tee -a "$LOG_FILE"
  return 0
}

main_deploy() {
  validate_config
  log "========== 自动发版开始 =========="

  if ! git_sync_repo "$NEWBACK_DIR" "Internship-NewBack"; then
    record_status "FAIL"
    log "========== 自动发版失败（NewBack）=========="
    exit 1
  fi
  if ! git_sync_repo "$FRONT_DIR" "Internship-Front"; then
    record_status "FAIL"
    log "========== 自动发版失败（Front）=========="
    exit 1
  fi
  if ! docker_build_up; then
    record_status "FAIL"
    log "========== 自动发版失败（docker build）=========="
    exit 1
  fi

  record_status "SUCCESS"
  log "========== 自动发版成功 =========="
}

# 防止与手动部署重叠
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "ERROR: 已有部署任务在运行，本次跳过"
  exit 1
fi

if should_retry_only "${1:-}"; then
  check_retry_if_failed
fi

main_deploy
