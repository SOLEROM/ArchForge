#!/usr/bin/env bash
set -euo pipefail

################################################################################
# term-tabs.sh - Terminator tabs + optional split frames (panes) per tab
#
# Config file supports:
#   @tab <title>
#   cmd: <command>
#   split: v|h { ... }
#   pane "<pane title>": <command>
################################################################################

TITLE="Terminator Tabs"
WORKDIR="$PWD"
FILE=""
LAYOUT="termtabs_layout"

usage() {
  cat <<'EOF'
Usage:
  term-tabs.sh [-t WINDOW_TITLE] [-d WORKDIR] "name::cmd" "name::cmd" ...
  term-tabs.sh [-t WINDOW_TITLE] [-d WORKDIR] -f commands.txt

CLI entry format (backward compatible):
  name::command     Tab named "name" runs "command"
  command           Tab named "command" runs "command"

Config file (-f) format (supports panes/splits):
  @tab <Tab Title>
  cmd: <command>

  @tab <Tab Title>
  split: v|h
  pane "<pane title>": <command>
  pane "<pane title>": <command>

  Nested splits (optional):
  @tab complex
  split: v {
    pane "left": bash
    split: h {
      pane "top": command1
      pane "bottom": command2
    }
  }

Notes:
- split: v means left/right
- split: h means top/bottom
- Lines starting with # are comments

EOF
  exit 2
}

while getopts ":t:d:f:h" opt; do
  case "$opt" in
    t) TITLE="$OPTARG" ;;
    d) WORKDIR="$OPTARG" ;;
    f) FILE="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done
shift $((OPTIND-1))

command -v terminator >/dev/null 2>&1 || { echo "ERROR: terminator not installed" >&2; exit 2; }
[[ -d "$WORKDIR" ]] || { echo "ERROR: WORKDIR not a directory: $WORKDIR" >&2; exit 2; }

TMPBASE="${TMPDIR:-/tmp}"
WORKBASE="$(mktemp -d -p "$TMPBASE" termtabs.XXXXXX)"
CFG="$WORKBASE/terminator.cfg"

# ------------------------------------------------------------------------------
# Wrapper script creation (used by every terminal pane)
# ------------------------------------------------------------------------------
create_wrapper() {
  local id="$1" tabname="$2" panename="$3" cmd="$4"
  local wrapper="$WORKBASE/w_${id}.sh"

  # Escape values for safe embedding
  local esc_workdir esc_tabname esc_panename esc_cmd
  esc_workdir=$(printf '%q' "$WORKDIR")
  esc_tabname=$(printf '%q' "$tabname")
  esc_panename=$(printf '%q' "$panename")
  esc_cmd=$(printf '%q' "$cmd")

  cat > "$wrapper" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail

cd ${esc_workdir} || exit 1

TABNAME=${esc_tabname}
PANENAME=${esc_panename}
CMD=${esc_cmd}

# Set a useful title (pane name preferred, but include tab context)
set_title() {
  local t="\$PANENAME"
  [[ -n "\$TABNAME" ]] && t="\$TABNAME :: \$PANENAME"
  printf '\033]0;%s\007' "\$t"
  printf '\033]2;%s\007' "\$t"
}
set_title

echo -e "\033[1;34m▶ Running:\033[0m \$CMD"
echo ""

eval "\$CMD"
rc=\$?

echo ""
echo -e "\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[1;32m✓ Command finished\033[0m (exit code: \$rc)"
echo -e "\033[0;36m  Pane stays open. Type 'exit' to close.\033[0m"
echo -e "\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo ""

RCFILE="\$(mktemp)"
cat > "\$RCFILE" <<'RCEOF'
[[ -r /etc/bash.bashrc ]] && source /etc/bash.bashrc
[[ -r ~/.bashrc ]] && source ~/.bashrc

__termtabs_title() {
  local t="\${TABNAME:-}"
  local p="\${PANENAME:-}"
  if [[ -n "\$p" && -n "\$t" ]]; then
    printf '\033]0;%s\007' "\$t :: \$p"
    printf '\033]2;%s\007' "\$t :: \$p"
  elif [[ -n "\$p" ]]; then
    printf '\033]0;%s\007' "\$p"
    printf '\033]2;%s\007' "\$p"
  elif [[ -n "\$t" ]]; then
    printf '\033]0;%s\007' "\$t"
    printf '\033]2;%s\007' "\$t"
  fi
}

if [[ -n "\${PROMPT_COMMAND:-}" ]]; then
  PROMPT_COMMAND="__termtabs_title; \$PROMPT_COMMAND"
else
  PROMPT_COMMAND="__termtabs_title"
fi
__termtabs_title
rm -f "\$BASH_SOURCE" 2>/dev/null || true
RCEOF

export TABNAME PANENAME
exec bash --rcfile "\$RCFILE" -i
WRAPPER

  chmod +x "$wrapper"
  echo "$wrapper"
}

# ------------------------------------------------------------------------------
# Backward-compatible CLI entries -> tab objects
# ------------------------------------------------------------------------------
split_entry() {
  local entry="$1" name cmd
  if [[ "$entry" == *"::"* ]]; then
    name="${entry%%::*}"
    cmd="${entry#*::}"
  else
    name="$entry"
    cmd="$entry"
  fi
  name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"; cmd="${cmd%"${cmd##*[![:space:]]}"}"
  [[ -n "$cmd" ]] || { echo "ERROR: empty command for entry: $entry" >&2; exit 2; }
  [[ -n "$name" ]] || name="$cmd"
  printf '%s\t%s\n' "$name" "$cmd"
}

# ------------------------------------------------------------------------------
# Parser for config file (-f)
# We build an in-memory structure:
#   TABS: array of tab titles
#   TAB_ROOT[i]: root node id for layout tree
#
# Node model stored in associative arrays:
#   NODE_TYPE[id] = "term"|"split"
#   NODE_SPLIT[id] = "v"|"h"
#   NODE_LEFT[id], NODE_RIGHT[id] = child node ids (for split)
#   NODE_TAB[id] = tab title (for wrapper)
#   NODE_PANE_NAME[id] = pane title (for term)
#   NODE_CMD[id] = command (for term)
# ------------------------------------------------------------------------------
declare -a TABS=()
declare -a TAB_ROOT=()

declare -A NODE_TYPE=()
declare -A NODE_SPLIT=()
declare -A NODE_LEFT=()
declare -A NODE_RIGHT=()
declare -A NODE_TAB=()
declare -A NODE_PANE_NAME=()
declare -A NODE_CMD=()

NODE_SEQ=0
new_node_id() {
  # Increment in parent shell, then echo the value
  # We use a temp file to communicate across subshell boundary
  local seq_file="$WORKBASE/.node_seq"
  if [[ -f "$seq_file" ]]; then
    NODE_SEQ=$(<"$seq_file")
  fi
  NODE_SEQ=$((NODE_SEQ+1))
  echo "$NODE_SEQ" > "$seq_file"
  echo "n${NODE_SEQ}"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Tokenizer for simple DSL (handles braces and quoted pane names)
# We parse line-by-line; braces can appear at end of "split:" lines.
parse_config_file() {
  local cur_tab=""
  local stack=()          # stack of split node ids we're filling
  local braced=()         # parallel array: 1 if split was opened with {, 0 otherwise

  local line raw
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="$(trim "$raw")"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" == @tab\ * ]]; then
      cur_tab="$(trim "${line#@tab }")"
      [[ -n "$cur_tab" ]] || { echo "ERROR: @tab with empty title" >&2; exit 2; }
      TABS+=("$cur_tab")
      TAB_ROOT+=("")  # placeholder
      stack=()
      braced=()
      continue
    fi

    [[ -n "$cur_tab" ]] || { echo "ERROR: config content before first @tab" >&2; exit 2; }

    # close brace
    if [[ "$line" == "}" ]]; then
      [[ ${#stack[@]} -gt 0 ]] || { echo "ERROR: unmatched }" >&2; exit 2; }
      unset 'stack[-1]'
      unset 'braced[-1]'
      continue
    fi

    # split line: split: v  OR split: v {  (same for h)
    if [[ "$line" =~ ^split:[[:space:]]*([vh])[[:space:]]*(\{)?$ ]]; then
      local orient="${BASH_REMATCH[1]}"
      local has_brace="${BASH_REMATCH[2]:-}"

      local sid; sid="$(new_node_id)"
      NODE_TYPE["$sid"]="split"
      NODE_SPLIT["$sid"]="$orient"
      NODE_TAB["$sid"]="$cur_tab"

      # attach to current context
      attach_child_to_context "$cur_tab" "$sid" stack braced

      # push onto stack for children
      stack+=("$sid")
      if [[ -n "$has_brace" ]]; then
        braced+=(1)
      else
        braced+=(0)
      fi
      continue
    fi

    # cmd: <command> => shorthand single-terminal tab
    if [[ "$line" == cmd:\ * ]]; then
      local cmd="${line#cmd: }"
      cmd="$(trim "$cmd")"
      [[ -n "$cmd" ]] || { echo "ERROR: empty cmd:" >&2; exit 2; }

      local tid; tid="$(new_node_id)"
      NODE_TYPE["$tid"]="term"
      NODE_TAB["$tid"]="$cur_tab"
      NODE_PANE_NAME["$tid"]="$cur_tab"
      NODE_CMD["$tid"]="$cmd"

      # must be tab root (and tab must not already have root)
      set_tab_root_once "$cur_tab" "$tid"
      continue
    fi

    # pane "<name>": <command>
    if [[ "$line" =~ ^pane[[:space:]]+\"([^\"]+)\"[[:space:]]*:[[:space:]]*(.+)$ ]]; then
      local pname="${BASH_REMATCH[1]}"
      local pcmd="${BASH_REMATCH[2]}"
      pcmd="$(trim "$pcmd")"
      [[ -n "$pcmd" ]] || { echo "ERROR: empty pane command for \"$pname\"" >&2; exit 2; }

      local tid; tid="$(new_node_id)"
      NODE_TYPE["$tid"]="term"
      NODE_TAB["$tid"]="$cur_tab"
      NODE_PANE_NAME["$tid"]="$pname"
      NODE_CMD["$tid"]="$pcmd"

      attach_child_to_context "$cur_tab" "$tid" stack braced
      continue
    fi

    echo "ERROR: unrecognized line: $raw" >&2
    exit 2
  done < "$FILE"

  # validate each tab has a root
  for i in "${!TABS[@]}"; do
    [[ -n "${TAB_ROOT[$i]}" ]] || {
      echo "ERROR: tab \"${TABS[$i]}\" has no cmd: or split/pane content" >&2
      exit 2
    }
  done
}

set_tab_root_once() {
  local tab="$1" node="$2"
  local i
  for i in "${!TABS[@]}"; do
    if [[ "${TABS[$i]}" == "$tab" ]]; then
      if [[ -n "${TAB_ROOT[$i]}" ]]; then
        echo "ERROR: tab \"$tab\" already has content/root; only one root allowed" >&2
        exit 2
      fi
      TAB_ROOT[$i]="$node"
      return 0
    fi
  done
  echo "ERROR: internal: tab not found: $tab" >&2
  exit 2
}

attach_child_to_context() {
  local tab="$1" child="$2"
  local -n st="$3"
  local -n br="$4"

  if [[ ${#st[@]} -eq 0 ]]; then
    # at tab root
    set_tab_root_once "$tab" "$child"
    return 0
  fi

  local parent="${st[-1]}"
  local is_braced="${br[-1]}"
  
  # fill left then right
  if [[ -z "${NODE_LEFT[$parent]:-}" ]]; then
    NODE_LEFT["$parent"]="$child"
  elif [[ -z "${NODE_RIGHT[$parent]:-}" ]]; then
    NODE_RIGHT["$parent"]="$child"
    # Auto-pop only if this split was NOT opened with a brace
    # Braced splits wait for explicit }
    if [[ "$is_braced" != "1" ]]; then
      unset 'st[-1]'
      unset 'br[-1]'
    fi
  else
    echo "ERROR: split node $parent already has two children" >&2
    exit 2
  fi
}

# ------------------------------------------------------------------------------
# Layout generation for Terminator config
# We generate:
#   Window child0
#   If >1 tabs => Notebook child1 with labels
#   For each tab i:
#     If root is term => terminal<i> under notebook
#     If root is split => a Paned node under notebook, recursively generating
# ------------------------------------------------------------------------------
escape_cfg_value() {
  # minimal escaping for Terminator cfg fields (avoid newlines)
  local s="$1"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

build_labels() {
  local result=""
  local i
  for i in "${!TABS[@]}"; do
    local name="${TABS[$i]}"
    name="${name//\'/\'\"\'\"\'}"
    result+="${result:+, }'$name'"
  done
  echo "$result"
}

TERM_SEQ=0
PANED_SEQ=0

emit_tree() {
  local parent="$1" order="$2" node="$3"

  if [[ "${NODE_TYPE[$node]}" == "term" ]]; then
    local tab="${NODE_TAB[$node]}"
    local pname="${NODE_PANE_NAME[$node]}"
    local cmd="${NODE_CMD[$node]}"

    local wid="t$((TERM_SEQ))"
    TERM_SEQ=$((TERM_SEQ+1))

    local wrapper
    wrapper="$(create_wrapper "$wid" "$tab" "$pname" "$cmd")"

    echo "    [[[terminal_${wid}]]]"
    echo "      type = Terminal"
    echo "      parent = ${parent}"
    echo "      order = ${order}"
    echo "      profile = default"
    echo "      directory = $(escape_cfg_value "$WORKDIR")"
    echo "      command = $(escape_cfg_value "$wrapper")"
    echo "      title = $(escape_cfg_value "$pname")"
    echo ""
    return 0
  fi

  if [[ "${NODE_TYPE[$node]}" == "split" ]]; then
    local orient="${NODE_SPLIT[$node]}"
    local left="${NODE_LEFT[$node]:-}"
    local right="${NODE_RIGHT[$node]:-}"
    [[ -n "$left" && -n "$right" ]] || { echo "ERROR: split node missing children" >&2; exit 2; }

    local pid="p$((PANED_SEQ))"
    PANED_SEQ=$((PANED_SEQ+1))

    # Terminator uses HPaned for horizontal (left/right) and VPaned for vertical (top/bottom)
    # Our DSL: split: v means vertical divider = left/right = HPaned
    #          split: h means horizontal divider = top/bottom = VPaned
    local paned_type
    if [[ "$orient" == "v" ]]; then
      paned_type="HPaned"
    else
      paned_type="VPaned"
    fi

    echo "    [[[child_${pid}]]]"
    echo "      type = ${paned_type}"
    echo "      parent = ${parent}"
    echo "      order = ${order}"
    echo ""

    # children order 0/1
    emit_tree "child_${pid}" 0 "$left"
    emit_tree "child_${pid}" 1 "$right"
    return 0
  fi

  echo "ERROR: unknown node type for $node" >&2
  exit 2
}

# ------------------------------------------------------------------------------
# Input handling: either -f DSL, or CLI entries
# ------------------------------------------------------------------------------
if [[ -n "$FILE" ]]; then
  [[ -r "$FILE" ]] || { echo "ERROR: cannot read $FILE" >&2; exit 2; }
  parse_config_file
else
  [[ $# -gt 0 ]] || usage
  for entry in "$@"; do
    IFS=$'\t' read -r name cmd < <(split_entry "$entry")
    TABS+=("$name")

    tid="$(new_node_id)"
    NODE_TYPE["$tid"]="term"
    NODE_TAB["$tid"]="$name"
    NODE_PANE_NAME["$tid"]="$name"
    NODE_CMD["$tid"]="$cmd"

    TAB_ROOT+=("$tid")
  done
fi

# ------------------------------------------------------------------------------
# Generate Terminator config
# ------------------------------------------------------------------------------
LABELS="$(build_labels)"

{
  cat <<'CFG_HEAD'
[global_config]
  suppress_multiple_term_dialog = True

[keybindings]

[profiles]
  [[default]]
    scrollback_lines = 5000
    use_system_font = True

[layouts]
CFG_HEAD

  echo "  [[${LAYOUT}]]"
  echo "    [[[child0]]]"
  echo "      type = Window"
  echo "      parent = \"\""
  echo "      order = 0"
  echo "      size = 1200, 800"

  if [[ ${#TABS[@]} -eq 1 ]]; then
    # Single tab: no Notebook; emit root directly under Window
    root="${TAB_ROOT[0]}"
    emit_tree "child0" 0 "$root"
  else
    # Multiple tabs: Notebook
    echo "    [[[child1]]]"
    echo "      type = Notebook"
    echo "      parent = child0"
    echo "      order = 0"
    echo "      labels = ${LABELS}"
    echo ""

    for i in "${!TABS[@]}"; do
      root="${TAB_ROOT[$i]}"
      emit_tree "child1" "$i" "$root"
    done
  fi

  echo ""
  echo "[plugins]"
} > "$CFG"

if [[ "${DEBUG:-}" == "1" ]]; then
  echo "=== Generated Config ===" >&2
  cat "$CFG" >&2
  echo "========================" >&2
fi

terminator --no-dbus -g "$CFG" -l "$LAYOUT" -T "$TITLE" &

(
  sleep 10
  rm -rf "$WORKBASE" 2>/dev/null || true
) &
disown 2>/dev/null || true

echo "Launched Terminator with ${#TABS[@]} tab(s)"
