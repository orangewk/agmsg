#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   status.sh [team]
#
# Read-only MVP visibility report for agmsg delivery health. This intentionally
# does not kill, restart, join, leave, mark messages read, or modify hooks.
# Runtime probes are opt-in via AGMSG_STATUS_RUNTIME=1 because they can be slow
# or blocked by host-agent sandbox boundaries. Runtime probes are bounded by
# AGMSG_STATUS_DELIVERY_TIMEOUT seconds (default: 5).

TEAM_FILTER="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_NAME="$(basename "$SKILL_DIR")"
TEAMS_DIR="$SKILL_DIR/teams"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"

if [ -n "$TEAM_FILTER" ]; then
  agmsg_validate_team_name "$TEAM_FILTER" || exit 1
fi

core_version="$("$SCRIPT_DIR/version.sh" 2>/dev/null || echo "unknown")"

status_timeout="${AGMSG_STATUS_DELIVERY_TIMEOUT:-5}"
status_runtime="${AGMSG_STATUS_RUNTIME:-0}"

delivery_plug_path() {
  printf '%s\n' "$SCRIPT_DIR/drivers/types/$1/_delivery.sh"
}

has_status_override() {
  local plug
  plug="$(delivery_plug_path "$1")"
  [ -f "$plug" ] && grep -Eq '(^|[[:space:]])agmsg_delivery_status[[:space:]]*\(' "$plug"
}

uses_rulefile_status() {
  local plug
  plug="$(delivery_plug_path "$1")"
  [ -f "$plug" ] && grep -q 'rulefile_status' "$plug"
}

delivery_mode_from_hooks() {
  local agent_type="$1" project_path="$2" rel hooks_file sql_hf has_ss has_st
  rel="$(agmsg_type_get "$agent_type" hooks_file 2>/dev/null || true)"
  if [ -z "$rel" ]; then
    echo "unknown"
    return 0
  fi
  case "$rel" in
    /*|*..*) echo "unknown"; return 0 ;;
  esac
  hooks_file="$project_path/$rel"
  if [ ! -f "$hooks_file" ]; then
    echo "off"
    return 0
  fi
  sql_hf="$(agmsg_sql_readfile_path "$hooks_file")"
  has_ss="$(agmsg_sqlite_mem "
    SELECT EXISTS(
      SELECT 1 FROM json_each(json_extract(readfile('$sql_hf'), '\$.hooks.SessionStart')) AS s,
        json_each(json_extract(s.value, '\$.hooks')) AS h
      WHERE instr(COALESCE(json_extract(h.value, '\$.command'), ''), '$SKILL_NAME') > 0
    );" 2>/dev/null || echo 0)"
  has_st="$(agmsg_sqlite_mem "
    SELECT EXISTS(
      SELECT 1 FROM json_each(json_extract(readfile('$sql_hf'), '\$.hooks.Stop')) AS s,
        json_each(json_extract(s.value, '\$.hooks')) AS h
      WHERE instr(COALESCE(json_extract(h.value, '\$.command'), ''), '$SKILL_NAME') > 0
    );" 2>/dev/null || echo 0)"
  if [ "$has_ss" = "1" ] && [ "$has_st" = "1" ]; then echo "both"
  elif [ "$has_ss" = "1" ]; then echo "monitor"
  elif [ "$has_st" = "1" ]; then echo "turn"
  else echo "off"
  fi
}

delivery_status_output() {
  local agent_type="$1" project_path="$2" out rc
  if command -v timeout >/dev/null 2>&1; then
    set +e
    out="$(timeout "$status_timeout" "$SCRIPT_DIR/delivery.sh" status "$agent_type" "$project_path" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -eq 124 ]; then
      printf '%s\n' "status-check-timeout after ${status_timeout}s"
      return 0
    fi
    printf '%s\n' "$out"
    return 0
  fi
  "$SCRIPT_DIR/delivery.sh" status "$agent_type" "$project_path" 2>&1 || true
}

delivery_mode_from_status_output() {
  printf '%s\n' "$1" | awk -F: '/^mode:/ { sub(/^[ \t]+/, "", $2); print $2; exit }'
}

delivery_mode_from_file_presence() {
  local agent_type="$1" project_path="$2" rel hooks_file
  rel="$(agmsg_type_get "$agent_type" hooks_file 2>/dev/null || true)"
  if [ -z "$rel" ]; then
    echo "unknown"
    return 0
  fi
  case "$rel" in
    /*|*..*) echo "unknown"; return 0 ;;
  esac
  hooks_file="$project_path/$rel"
  if [ -f "$hooks_file" ]; then echo "turn"; else echo "off"; fi
}

echo "agmsg status"
echo "core: $core_version"
echo "runtime: $([ "$status_runtime" = "1" ] && echo "checked" || echo "not checked")"
echo ""

if [ ! -d "$TEAMS_DIR" ]; then
  if [ -n "$TEAM_FILTER" ]; then
    echo "team not found: $TEAM_FILTER" >&2
    exit 1
  fi
  echo "teams: none"
  exit 0
fi

found=0
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "team" "agent" "type" "mode" "project" "runtime"

for config_file in "$TEAMS_DIR"/*/config.json; do
  [ -f "$config_file" ] || continue

  cfg_sql="$(agmsg_sql_readfile_path "$config_file")"
  team_name="$(agmsg_sqlite_mem "
    WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
    cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw)
    SELECT COALESCE(json_extract(json, '\$.name'), '') FROM cfg;
  " 2>/dev/null || true)"

  [ -n "$team_name" ] || continue
  if [ -n "$TEAM_FILTER" ] && [ "$team_name" != "$TEAM_FILTER" ]; then
    continue
  fi

  found=1

  while IFS=$'\t' read -r agent_name agent_type project_path; do
    [ -n "$agent_name" ] || continue
    [ -n "$agent_type" ] || agent_type="?"
    [ -n "$project_path" ] || project_path="?"

    mode="unknown"
    runtime="not checked"
    if [ "$agent_type" != "?" ] && [ "$project_path" != "?" ]; then
      delivery_output=""
      if uses_rulefile_status "$agent_type"; then
        mode="$(delivery_mode_from_file_presence "$agent_type" "$project_path")"
      elif has_status_override "$agent_type"; then
        delivery_output="$(delivery_status_output "$agent_type" "$project_path")"
        parsed_mode="$(delivery_mode_from_status_output "$delivery_output")"
        [ -n "$parsed_mode" ] && mode="$parsed_mode"
      else
        mode="$(delivery_mode_from_hooks "$agent_type" "$project_path")"
      fi

      if [ "$status_runtime" = "1" ]; then
        [ -n "$delivery_output" ] || delivery_output="$(delivery_status_output "$agent_type" "$project_path")"
        # MVP intentionally extracts only known runtime/status summary prefixes.
        # New delivery plugs may need to add a stable summary prefix later.
        parsed_runtime="$(printf '%s\n' "$delivery_output" | awk '/^(watch processes:|Codex bridge:|status-check-timeout)/ { print }' | paste -sd '; ' -)"
        [ -n "$parsed_runtime" ] && runtime="$parsed_runtime"
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$team_name" "$agent_name" "$agent_type" "$mode" "$project_path" "$runtime"
  done < <(agmsg_sqlite_mem -separator $'\t' "
    WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
    cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw),
    agents AS (
      SELECT
        key AS name,
        CASE
          WHEN json_type(json_extract(value, '\$.registrations')) = 'array' THEN json_extract(value, '\$.registrations')
          ELSE json_array(json_object('type', json_extract(value, '\$.type'), 'project', json_extract(value, '\$.project')))
        END AS registrations
      FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
    )
    SELECT
      name,
      COALESCE(json_extract(r.value, '\$.type'), ''),
      COALESCE(json_extract(r.value, '\$.project'), '')
    FROM agents, json_each(agents.registrations) AS r
    ORDER BY name, json_extract(r.value, '\$.type'), json_extract(r.value, '\$.project');
  " | tr -d '\r')
done

if [ "$found" -eq 0 ]; then
  if [ -n "$TEAM_FILTER" ]; then
    echo "team not found: $TEAM_FILTER" >&2
    exit 1
  fi
  echo "teams: none"
fi

