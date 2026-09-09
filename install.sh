#!/bin/sh
# claude-setup — install the Caveman output style and/or RTK for Claude Code.
# https://github.com/Nelahia/claude-setup
#
#   curl -fsSL .../install.sh | sh                  # both
#   curl -fsSL .../install.sh | sh -s -- caveman
#   curl -fsSL .../install.sh | sh -s -- rtk
#   curl -fsSL .../install.sh | sh -s -- all --uninstall
set -eu

REPO_RAW="${CLAUDE_SETUP_RAW:-https://raw.githubusercontent.com/Nelahia/claude-setup/main}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
STYLE_NAME="caveman"
BEGIN_MARK="<!-- BEGIN claude-setup -->"
END_MARK="<!-- END claude-setup -->"

COMPONENT="all"
UNINSTALL=0

usage() {
	cat <<'EOF'
usage: install.sh [caveman|rtk|all] [--uninstall]

  caveman      Caveman output style + "outputStyle" in settings.json
  rtk          RTK binary + global Claude Code hook
  all          both (default)
  --uninstall  undo the selected component

env:
  CLAUDE_CONFIG_DIR   target config dir (default: ~/.claude)
  CLAUDE_SETUP_SRC    read styles/ and claude/ from a local checkout instead of GitHub
EOF
}

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

for arg in "$@"; do
	case "$arg" in
	caveman | rtk | all) COMPONENT="$arg" ;;
	--uninstall) UNINSTALL=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'error: unknown argument: %s\n\n' "$arg" >&2
		usage >&2
		exit 2
		;;
	esac
done

# --- shared helpers ---------------------------------------------------------

# Fetch a repo-relative asset. CLAUDE_SETUP_SRC lets the test suite (and anyone
# hacking on this repo) run against a local checkout instead of the published raw URLs.
fetch_asset() { # fetch_asset <repo-relative-path> <dest>
	if [ -n "${CLAUDE_SETUP_SRC:-}" ]; then
		cp "$CLAUDE_SETUP_SRC/$1" "$2"
	else
		command -v curl >/dev/null 2>&1 || die "curl is required"
		curl -fsSL "$REPO_RAW/$1" -o "$2" || die "could not download $1"
	fi
}

backup() { cp "$1" "$1.bak.$(date +%Y%m%d%H%M%S)"; }

# Replace <file> with <candidate> only if they differ. Backs up first, unless the
# file is a placeholder this run just created (nothing worth keeping in it).
# Prints the outcome. Returns 0 when changed, 1 when already up to date.
commit_change() { # commit_change <file> <candidate> <label> [fresh]
	if [ -f "$1" ] && cmp -s "$2" "$1"; then
		rm -f "$2"
		say "  = $3: already up to date"
		return 1
	fi
	if [ -f "$1" ] && [ "${4:-0}" != 1 ]; then backup "$1"; fi
	mv "$2" "$1"
	say "  + $3: written"
	return 0
}

json_tool() {
	if command -v jq >/dev/null 2>&1; then
		echo jq
	elif command -v python3 >/dev/null 2>&1; then
		echo python3
	elif command -v node >/dev/null 2>&1; then
		echo node
	else
		echo none
	fi
}

# Single dispatcher over whichever JSON runtime is available.
#   get        prints the current outputStyle, empty when unset
#   set / del  writes the resulting document to <dest>
json_op() { # json_op <get|set|del> [dest]
	case "$(json_tool)" in
	jq)
		case "$1" in
		get) jq -r '.outputStyle // ""' "$SETTINGS" ;;
		set) jq --arg s "$STYLE_NAME" '.outputStyle = $s' "$SETTINGS" >"$2" ;;
		del) jq 'del(.outputStyle)' "$SETTINGS" >"$2" ;;
		esac
		;;
	python3)
		CS_OP="$1" CS_STYLE="$STYLE_NAME" python3 -c '
import json, os, sys
op = os.environ["CS_OP"]
with open(sys.argv[1]) as fh:
    data = json.load(fh)
if op == "get":
    print(data.get("outputStyle", ""))
    raise SystemExit(0)
if op == "set":
    data["outputStyle"] = os.environ["CS_STYLE"]
else:
    data.pop("outputStyle", None)
with open(sys.argv[2], "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
' "$SETTINGS" "${2:-/dev/null}"
		;;
	node)
		CS_OP="$1" CS_STYLE="$STYLE_NAME" node -e '
const fs = require("fs");
const op = process.env.CS_OP;
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (op === "get") { console.log(data.outputStyle || ""); process.exit(0); }
if (op === "set") data.outputStyle = process.env.CS_STYLE;
else delete data.outputStyle;
fs.writeFileSync(process.argv[2], JSON.stringify(data, null, 2) + "\n");
' "$SETTINGS" "${2:-/dev/null}"
		;;
	none)
		die "need jq, python3 or node to edit $SETTINGS safely.
     Add \"outputStyle\": \"$STYLE_NAME\" to it by hand instead."
		;;
	esac
}

# Set or remove outputStyle in settings.json. Never hand-edit this JSON: it also
# holds apiKeyHelper, env, statusLine and the RTK hook.
#
# The up-to-date check is on the parsed value, not on the file bytes. RTK rewrites
# settings.json with its own formatting, so a byte comparison against our
# serializer would report a change on every single run and pile up backups.
patch_settings() { # patch_settings <set|del>
	op="$1"
	fresh=0
	mkdir -p "$CLAUDE_DIR"
	if [ ! -f "$SETTINGS" ]; then
		printf '{}\n' >"$SETTINGS"
		fresh=1
	fi

	current=$(json_op get) || die "could not parse $SETTINGS — fix the JSON first"
	if [ "$op" = set ] && [ "$current" = "$STYLE_NAME" ]; then
		say "  = settings.json: outputStyle already \"$STYLE_NAME\""
		return 0
	fi
	if [ "$op" = del ] && [ -z "$current" ]; then
		say "  = settings.json: no outputStyle to remove"
		return 0
	fi

	tmp="$SETTINGS.tmp.$$"
	json_op "$op" "$tmp"
	commit_change "$SETTINGS" "$tmp" "settings.json" "$fresh" || true
}

# Everything in CLAUDE.md except our managed block, trailing blank lines removed.
# Trimming matters: without it a second run appends a second blank separator and
# the script stops being idempotent.
claude_md_body() {
	if [ -f "$CLAUDE_MD" ]; then
		awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
			$0 == b { skip = 1 }
			skip != 1 { print }
			$0 == e { skip = 0 }
		' "$CLAUDE_MD"
	fi | awk '
		{ line[NR] = $0 }
		END {
			last = NR
			while (last > 0 && line[last] ~ /^[[:space:]]*$/) last--
			for (i = 1; i <= last; i++) print line[i]
		}
	'
}

sync_claude_md() { # sync_claude_md <install|remove>
	mkdir -p "$CLAUDE_DIR"
	tmp="$CLAUDE_MD.tmp.$$"
	body="$CLAUDE_MD.body.$$"
	claude_md_body >"$body"

	if [ "$1" = install ]; then
		block="$CLAUDE_MD.block.$$"
		fetch_asset claude/tools-block.md "$block"
		{
			if [ -s "$body" ]; then
				cat "$body"
				echo
			fi
			printf '%s\n' "$BEGIN_MARK"
			cat "$block"
			printf '%s\n' "$END_MARK"
		} >"$tmp"
		rm -f "$block"
	else
		cat "$body" >"$tmp"
	fi
	rm -f "$body"

	if [ "$1" = remove ] && [ ! -s "$tmp" ] && [ -f "$CLAUDE_MD" ]; then
		backup "$CLAUDE_MD"
		rm -f "$CLAUDE_MD" "$tmp"
		say "  - CLAUDE.md: removed (nothing left in it)"
		return 0
	fi

	commit_change "$CLAUDE_MD" "$tmp" "CLAUDE.md managed block" || true
}

# --- caveman ----------------------------------------------------------------

do_caveman() {
	say "caveman:"
	if [ "$UNINSTALL" = 1 ]; then
		style="$CLAUDE_DIR/output-styles/$STYLE_NAME.md"
		if [ -f "$style" ]; then
			rm -f "$style"
			say "  - output-styles/$STYLE_NAME.md: removed"
		else
			say "  = output-styles/$STYLE_NAME.md: not present"
		fi
		patch_settings del
		return 0
	fi

	mkdir -p "$CLAUDE_DIR/output-styles"
	tmp="$CLAUDE_DIR/output-styles/$STYLE_NAME.md.tmp.$$"
	fetch_asset "styles/$STYLE_NAME.md" "$tmp"
	commit_change "$CLAUDE_DIR/output-styles/$STYLE_NAME.md" "$tmp" "output-styles/$STYLE_NAME.md" || true
	patch_settings set
}

# --- rtk --------------------------------------------------------------------

do_rtk() {
	say "rtk:"
	if [ "$UNINSTALL" = 1 ]; then
		if command -v rtk >/dev/null 2>&1; then
			rtk init -g --uninstall >/dev/null 2>&1 || warn "rtk init -g --uninstall failed"
			say "  - hook, RTK.md and settings.json entry removed"
			say "  i binary kept — remove it with 'brew uninstall rtk' if you want it gone"
		else
			say "  = rtk not installed"
		fi
		return 0
	fi

	if command -v rtk >/dev/null 2>&1; then
		say "  = binary: already installed ($(rtk --version 2>/dev/null || echo unknown))"
	elif command -v brew >/dev/null 2>&1; then
		say "  + binary: installing via Homebrew"
		brew install rtk >/dev/null || die "brew install rtk failed"
	else
		say "  + binary: installing via upstream install.sh into ~/.local/bin"
		curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh >/dev/null ||
			die "upstream rtk install failed"
		PATH="$HOME/.local/bin:$PATH"
		export PATH
		case ":$PATH:" in
		*":$HOME/.local/bin:"*) ;;
		*) warn "add \$HOME/.local/bin to your PATH to keep rtk available" ;;
		esac
	fi

	command -v rtk >/dev/null 2>&1 || die "rtk installed but not on PATH"
	# --auto-patch keeps it non-interactive; the telemetry prompt would hang inside a pipe.
	rtk init -g --auto-patch >/dev/null || die "rtk init -g --auto-patch failed"
	say "  + hook: registered globally (rtk hook claude)"
}

# --- main -------------------------------------------------------------------

say "claude-setup -> $CLAUDE_DIR"
say ""

case "$COMPONENT" in
caveman) do_caveman ;;
rtk) do_rtk ;;
all)
	do_caveman
	say ""
	do_rtk
	;;
esac

say ""
if [ "$UNINSTALL" = 1 ]; then
	# The managed block documents both tools, so only drop it on a full uninstall.
	if [ "$COMPONENT" = all ]; then
		sync_claude_md remove
	else
		say "  i CLAUDE.md managed block kept (other component still installed)"
	fi
	say ""
	say "Done. Restart Claude Code."
else
	sync_claude_md install
	say ""
	say "Done. Restart Claude Code for the hook and output style to take effect."
fi
