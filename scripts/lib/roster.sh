#!/usr/bin/env bash
# Read-only helpers for team rosters and onboarding name suggestions.

_agmsg_roster_lib_dir() {
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
  elif [ -n "${SKILL_DIR:-}" ]; then
    cd "$SKILL_DIR/scripts/lib" && pwd
  else
    echo "Error: cannot resolve roster lib dir (BASH_SOURCE and SKILL_DIR empty)" >&2
    return 1
  fi
}

_AGMSG_ROSTER_LIB_DIR="$(_agmsg_roster_lib_dir)"
_AGMSG_ROSTER_SCRIPTS_DIR="$(cd "$_AGMSG_ROSTER_LIB_DIR/.." && pwd)"
_AGMSG_ROSTER_SKILL_DIR="$(cd "$_AGMSG_ROSTER_SCRIPTS_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$_AGMSG_ROSTER_SCRIPTS_DIR/lib/storage.sh"

agmsg_roster_config_path() {
  local team="$1"
  printf '%s\n' "$_AGMSG_ROSTER_SKILL_DIR/teams/$team/config.json"
}

agmsg_roster_names() {
  local team="$1"
  local config_file
  config_file="$(agmsg_roster_config_path "$team")"
  [ -f "$config_file" ] || return 0

  local cfg_sql
  cfg_sql="$(agmsg_sql_readfile_path "$config_file")"
  agmsg_sqlite_mem "
    WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
    cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw)
    SELECT key
    FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
    ORDER BY key;
  "
}

agmsg_name_pool_path() {
  printf '%s\n' "$_AGMSG_ROSTER_SCRIPTS_DIR/data/name-pool.txt"
}

agmsg_name_hash() {
  printf '%s' "$1" | cksum | awk '{print $1}'
}

agmsg_roster_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

agmsg_pool_names() {
  local pool
  pool="$(agmsg_name_pool_path)"
  [ -f "$pool" ] || return 0
  while IFS= read -r name || [ -n "$name" ]; do
    name="${name%%#*}"
    name="${name//[[:space:]]/}"
    [ -n "$name" ] || continue
    case "$name" in
      *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) continue ;;
      *) printf '%s\n' "$name" ;;
    esac
  done < "$pool"
}

agmsg_suggest_names() {
  local team="$1"
  local count="${2:-5}"
  case "$count" in ''|*[!0-9]*) count=5 ;; esac
  [ "$count" -gt 0 ] || count=5

  local roster=() pool=()
  local name
  while IFS= read -r name; do
    [ -n "$name" ] && roster+=("$name")
  done < <(agmsg_roster_names "$team")
  while IFS= read -r name; do
    [ -n "$name" ] && pool+=("$name")
  done < <(agmsg_pool_names)

  local pool_len="${#pool[@]}"
  [ "$pool_len" -gt 0 ] || return 0

  local offset idx emitted=0 candidate
  offset=$(( $(agmsg_name_hash "$team") % pool_len ))
  for ((idx = 0; idx < pool_len && emitted < count; idx++)); do
    candidate="${pool[$(((offset + idx) % pool_len))]}"
    if ! agmsg_roster_contains "$candidate" ${roster[@]+"${roster[@]}"}; then
      printf '%s\n' "$candidate"
      roster+=("$candidate")
      emitted=$((emitted + 1))
    fi
  done

  local suffix=2 base
  while [ "$emitted" -lt "$count" ]; do
    for base in "${pool[@]}"; do
      candidate="${base}-${suffix}"
      if ! agmsg_roster_contains "$candidate" ${roster[@]+"${roster[@]}"}; then
        printf '%s\n' "$candidate"
        roster+=("$candidate")
        emitted=$((emitted + 1))
        [ "$emitted" -ge "$count" ] && break
      fi
    done
    suffix=$((suffix + 1))
  done
}
