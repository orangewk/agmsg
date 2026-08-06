#!/usr/bin/env bash
# Qwen delivery plug — Qwen's JSON hook schema matches agmsg's default nested
# event shape, but native Windows needs an explicit PowerShell hook shell.
# The hook calls a Node wrapper which selects Git Bash without falling through
# to the WindowsApps WSL shim.
agmsg_delivery_apply() {
  local type="$1"
  local project="$2"
  local mode="$3"
  local hooks_file
  hooks_file=$(resolve_hooks_file "$type" "$project")
  mkdir -p "$(dirname "$hooks_file")"

  local tmp_state
  tmp_state=$(mktemp "${TMPDIR:-/tmp}/agmsg-state.XXXXXX")
  if [ -f "$hooks_file" ]; then
    cp "$hooks_file" "$tmp_state"
  else
    printf '{}' > "$tmp_state"
  fi

  strip_agmsg_event_file "$tmp_state" "SessionStart"
  strip_agmsg_event_file "$tmp_state" "SessionEnd"
  strip_agmsg_event_file "$tmp_state" "Stop"

  case "$mode" in
    turn)
      local wrapper="$SKILL_DIR/scripts/drivers/types/qwen/hook.mjs"
      local hook_shell=""
      case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*|CLANGARM*)
          hook_shell="powershell"
          if command -v cygpath >/dev/null 2>&1; then
            wrapper=$(cygpath -m "$wrapper")
            project=$(cygpath -m "$project")
          fi
          ;;
      esac
      local cmd="node $(_agmsg_shq "$wrapper") $(_agmsg_shq "$project")"
      add_event_entry_file "$tmp_state" "Stop" "$cmd" "" "$hook_shell"
      ;;
    off)
      : # agmsg-owned entries were already stripped
      ;;
  esac

  prune_empty_hooks_file "$tmp_state"
  mv "$tmp_state" "$hooks_file"
}
