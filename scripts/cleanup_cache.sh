#!/usr/bin/env bash
# cleanup_cache.sh — Interactive disk space cleanup script
# Prompts for confirmation before deleting each cache/folder.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

total_estimated_bytes=0
any_cleanup_performed=false

# ── helpers ───────────────────────────────────────────────────────────────────

normalize_path() {
	local path="$1"
	realpath -ms -- "$path"
}

path_contains() {
	local parent="$1"
	local child="$2"

	[[ "$parent" == "/" ]] && return 0
	[[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

collapse_cleanup_candidates() {
	local path normalized
	local skip
	local i
	local -a collapsed=()
	local -a normalized_collapsed=()

	for path in "$@"; do
		[[ -n "$path" ]] || continue

		if [[ "$path" != /* ]]; then
			echo "  Warning: skipped non-absolute cleanup candidate: $path" >&2
			continue
		fi

		[[ -e "$path" ]] || continue

		if [[ ! -r "$path" || ( -d "$path" && ! -x "$path" ) ]]; then
			echo "  Warning: could not estimate cleanup candidate: $path" >&2
			continue
		fi

		normalized=$(normalize_path "$path")
		skip=false

		for i in "${!normalized_collapsed[@]}"; do
			if path_contains "${normalized_collapsed[$i]}" "$normalized"; then
				skip=true
				break
			fi

			if path_contains "$normalized" "${normalized_collapsed[$i]}"; then
				unset 'collapsed[i]' 'normalized_collapsed[i]'
			fi
		done

		[[ "$skip" == true ]] && continue

		collapsed+=("$path")
		normalized_collapsed+=("$normalized")
	done

	printf '%s\n' "${collapsed[@]}"
}

estimate_deletion_bytes() {
	local du_output total
	local -a candidates=()

	if [[ "$#" -eq 0 ]]; then
		echo 0
		return 0
	fi

	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] && candidates+=("$candidate")
	done < <(collapse_cleanup_candidates "$@")

	if [[ "${#candidates[@]}" -eq 0 ]]; then
		echo 0
		return 0
	fi

	du_output=$(
		du -sc -B1 -- "${candidates[@]}" \
			2> >(while IFS= read -r line; do
				[[ -n "$line" ]] && echo "  Warning: $line" >&2
			done)
	) || true

	total=$(awk 'END { print ($1 + 0) }' <<<"$du_output")
	echo "${total:-0}"
}

format_bytes() {
	local bytes="${1:-0}"

	awk -v bytes="$bytes" '
BEGIN {
	split("B K M G T P", units, " ")
	value = bytes + 0
	unit_index = 1

	while (value >= 1024 && unit_index < 6) {
		value /= 1024
		unit_index++
	}

	if (unit_index == 1) {
		printf "%d%s", value, units[unit_index]
		exit
	}

	if (value < 10 && value != int(value)) {
		printf "%.1f%s", value, units[unit_index]
		exit
	}

	printf "%.0f%s", value, units[unit_index]
}'
}

print_deletion_estimate() {
	local bytes="$1"
	echo -e "  Deletion estimate : ${BOLD}$(format_bytes "$bytes")${RESET}"
}

# Best-effort total of Docker's on-disk storage, in bytes. Sums the SIZE column
# of `docker system df`; echoes 0 if Docker is unavailable or output is
# unparsable. Docker prints decimal units (1.234GB / 100MB / 512kB), so strip
# the trailing B and let numfmt parse the SI suffix.
docker_storage_bytes() {
	local total=0 size bytes
	while IFS= read -r size; do
		[[ -z "$size" || "$size" == "0B" ]] && continue
		size="${size^^}"       # 512kB -> 512KB so numfmt accepts the suffix
		bytes=$(numfmt --from=si "${size%B}" 2>/dev/null) || bytes=0
		(( total += bytes )) || true
	done < <(docker system df --format '{{.Size}}' 2>/dev/null)
	echo "$total"
}

mark_cleanup_performed() {
	any_cleanup_performed=true
}

record_path_cleanup() {
	local bytes="$1"
	mark_cleanup_performed
	(( total_estimated_bytes += bytes ))
}

path_size() {
	format_bytes "$(estimate_deletion_bytes "$1")"
}

append_cleanup_candidates() {
	local candidate
	for candidate in "$@"; do
		cleanup_candidates+=("$candidate")
	done
}

gather_cleanup_estimate_candidates() {
	local PUPPETEER_DIR="$HOME/.cache/puppeteer/chrome"
	local PUPPETEER_HEADLESS_DIR="$HOME/.cache/puppeteer/chrome-headless-shell"
	local SELENIUM_CD_DIR="$HOME/.cache/selenium/chromedriver/linux64"
	local COPILOT_PKG_DIR="$HOME/.copilot/pkg/universal"
	local COPILOT_SESSIONS_DIR="$HOME/.copilot/session-state"
	local SESSIONS_KEEP=5
	local EXT_DIR="$HOME/.vscode/extensions"
	local WS_STORAGE="$HOME/.config/Code/User/workspaceStorage"
	local WS_STORAGE_INSIDERS="$HOME/.config/Code - Insiders/User/workspaceStorage"
	local NVM_NODE_DIR="$HOME/.nvm/versions/node"
	local NVM_ALIAS_DIR="$HOME/.nvm/alias"
	local GITHUB_DIR="$HOME/Documents/GitHub"
	local STALE_DAYS=30
	local AWS_CLI_DIR="/usr/local/aws-cli/v2"
	local GHCUP_GHC_DIR="$HOME/.ghcup/ghc"
	local GHCUP_HLS_DIR="$HOME/.ghcup/hls"
	local MPBARBOSA_BACKUPS_DIR="$HOME/Documents/GitHub/mpbarbosa.com/.backups"
	local ws
	local d
	local f
	local pkg
	local proj
	local last
	local age
	local full_v
	local keep
	local major
	local hls_ver
	local lib_dir
	local ghc_ver
	local v
	local b
	local s
	local -a versions=()
	local -a all_sessions=()
	local -a ext_ids=()
	local -a old_ext_versions=()
	local -a backups=()
	local -a stale=()
	local -a all_versions=()
	local -a lts_vers=()
	local -a ghc_versions=()

	cleanup_candidates=(
		"$HOME/.cache/JetBrains"
		"$HOME/.cache/Google"
		"$HOME/.local/share/JetBrains"
		"$HOME/.local/share/nvim/mason"
		"$HOME/.local/share/nvim/lazy"
		"$HOME/.cache/pip/http-v2"
		"$HOME/.npm/_cacache"
		"$HOME/.cache/google-chrome/Default/Cache"
		"$HOME/snap/spotify/common/.cache/spotify"
		"$HOME/snap/spotify/common/.cache/mesa_shader_cache_db"
		"$HOME/.config/google-chrome/OptGuideOnDeviceModel"
		"$HOME/.cache/huggingface/hub"
		"$HOME/.config/Code/Cache"
		"$HOME/.config/Code/CachedExtensionVSIXs"
		"$HOME/.config/google-chrome/Default/Service Worker/CacheStorage"
		"$HOME/.gradle/caches"
	)

	if [[ -d "$PUPPETEER_DIR" ]]; then
		mapfile -t versions < <(ls -1t "$PUPPETEER_DIR")
		if [[ "${#versions[@]}" -gt 1 ]]; then
			for v in "${versions[@]:1}"; do
				append_cleanup_candidates "$PUPPETEER_DIR/$v"
			done
		fi
	fi

	if [[ -d "$PUPPETEER_HEADLESS_DIR" ]]; then
		mapfile -t versions < <(ls -1t "$PUPPETEER_HEADLESS_DIR")
		if [[ "${#versions[@]}" -gt 1 ]]; then
			for v in "${versions[@]:1}"; do
				append_cleanup_candidates "$PUPPETEER_HEADLESS_DIR/$v"
			done
		fi
	fi

	if [[ -d "$SELENIUM_CD_DIR" ]]; then
		mapfile -t versions < <(ls -1 "$SELENIUM_CD_DIR" | sort -V -r)
		if [[ "${#versions[@]}" -gt 1 ]]; then
			for v in "${versions[@]:1}"; do
				append_cleanup_candidates "$SELENIUM_CD_DIR/$v"
			done
		fi
	fi

	if [[ -d "$COPILOT_PKG_DIR" ]]; then
		mapfile -t versions < <(ls -1t "$COPILOT_PKG_DIR")
		if [[ "${#versions[@]}" -gt 1 ]]; then
			for v in "${versions[@]:1}"; do
				append_cleanup_candidates "$COPILOT_PKG_DIR/$v"
			done
		fi
	fi

	if [[ -d "$COPILOT_SESSIONS_DIR" ]]; then
		mapfile -t all_sessions < <(ls -1t "$COPILOT_SESSIONS_DIR")
		if [[ "${#all_sessions[@]}" -gt "$SESSIONS_KEEP" ]]; then
			for s in "${all_sessions[@]:$SESSIONS_KEEP}"; do
				append_cleanup_candidates "$COPILOT_SESSIONS_DIR/$s"
			done
		fi
	fi

	if [[ -d "$EXT_DIR" ]]; then
		mapfile -t ext_ids < <(
			ls -1 "$EXT_DIR" \
				| grep -v '\.obsolete\|extensions\.json' \
				| sed 's/-[0-9][0-9.]*\(-[a-z0-9_-]*\)*$//' \
				| sort -u
		)

		old_ext_versions=()
		for ext_id in "${ext_ids[@]}"; do
			mapfile -t versions < <(ls -1d "$EXT_DIR/$ext_id"-* 2>/dev/null | sort -t'-' -V -r)
			[[ "${#versions[@]}" -le 1 ]] && continue
			old_ext_versions+=("${versions[@]:1}")
		done
		append_cleanup_candidates "${old_ext_versions[@]}"
	fi

	if [[ -d "$WS_STORAGE" ]]; then
		for d in "$WS_STORAGE"/*/; do
			ws=$(python3 -c "
import json
try:
    d = json.load(open('$d/workspace.json'))
    print(d.get('folder','').replace('file://','') or d.get('workspace',''))
except Exception:
    print('')
" 2>/dev/null)
			if [[ -z "$ws" ]] || { [[ ! -d "$ws" ]] && [[ ! -f "$ws" ]]; }; then
				append_cleanup_candidates "$d"
			fi
		done

		while IFS= read -r -d '' f; do
			append_cleanup_candidates "$f"
		done < <(find "$WS_STORAGE" -name "state.vscdb.backup" -print0 2>/dev/null)
	fi

	if [[ -d "$WS_STORAGE_INSIDERS" ]]; then
		for d in "$WS_STORAGE_INSIDERS"/*/; do
			ws=$(python3 -c "
import json
try:
    d = json.load(open('$d/workspace.json'))
    print(d.get('folder','').replace('file://','') or d.get('workspace',''))
except Exception:
    print('')
" 2>/dev/null)
			if [[ -z "$ws" ]] || { [[ ! -d "$ws" ]] && [[ ! -f "$ws" ]]; }; then
				append_cleanup_candidates "$d"
			fi
		done

		while IFS= read -r -d '' f; do
			append_cleanup_candidates "$f"
		done < <(find "$WS_STORAGE_INSIDERS" -name "state.vscdb.backup" -print0 2>/dev/null)
	fi

	if [[ -d "$NVM_NODE_DIR" ]]; then
		default_ver=$(cat "$NVM_ALIAS_DIR/default" 2>/dev/null)
		[[ "$default_ver" != v* ]] && default_ver="v$default_ver"

		lts_vers=()
		if [[ -d "$NVM_ALIAS_DIR/lts" ]]; then
			while IFS= read -r alias_target; do
				ver=$(cat "$NVM_ALIAS_DIR/lts/$alias_target" 2>/dev/null | tr -d '[:space:]')
				[[ -n "$ver" ]] && lts_vers+=("$ver")
			done < <(ls "$NVM_ALIAS_DIR/lts/" 2>/dev/null)
		fi

		mapfile -t all_versions < <(ls -1t "$NVM_NODE_DIR")
		stale=()
		for v in "${all_versions[@]}"; do
			full_v="$v"
			[[ "$full_v" != v* ]] && full_v="v$full_v"
			keep=false
			[[ "$full_v" == "$default_ver" ]] && keep=true
			for lts in "${lts_vers[@]}"; do
				[[ "$full_v" == "$lts" ]] && keep=true
			done
			major=$(echo "$full_v" | grep -oP '(?<=v)\d+')
			(( major % 2 == 0 )) && keep=true
			[[ "$keep" == false ]] && stale+=("$v")
		done

		for v in "${stale[@]}"; do
			append_cleanup_candidates "$NVM_NODE_DIR/$v"
		done
	fi

	if [[ -d "$GITHUB_DIR" ]]; then
		while IFS= read -r nm; do
			proj=$(dirname "$nm")
			last=$(find "$proj" -maxdepth 1 -newer /dev/null -not -path "$nm" \
				-not -name "node_modules" -printf "%T@\n" 2>/dev/null \
				| sort -rn | head -1)
			[[ -z "$last" ]] && continue
			age=$(python3 -c "import time; print(int((time.time() - ${last}) / 86400))" 2>/dev/null)
			if [[ "$age" -ge "$STALE_DAYS" ]]; then
				append_cleanup_candidates "$nm"
			fi
		done < <(find "$GITHUB_DIR" -mindepth 2 -maxdepth 2 -name "node_modules" -type d 2>/dev/null)
	fi

	if [[ -d "$AWS_CLI_DIR" ]]; then
		mapfile -t versions < <(ls -1 "$AWS_CLI_DIR" | grep -v '^current$' | sort -V -r)
		if [[ "${#versions[@]}" -gt 1 ]]; then
			for v in "${versions[@]:1}"; do
				append_cleanup_candidates "$AWS_CLI_DIR/$v"
			done
		fi
	fi

	if [[ -d "$GHCUP_GHC_DIR" ]]; then
		mapfile -t ghc_versions < <(ls -1t "$GHCUP_GHC_DIR")
		if [[ "${#ghc_versions[@]}" -gt 1 ]]; then
			for v in "${ghc_versions[@]:1}"; do
				append_cleanup_candidates "$GHCUP_GHC_DIR/$v"
			done
		fi
	fi

	if [[ -d "$GHCUP_HLS_DIR" ]]; then
		for hls_ver_dir in "$GHCUP_HLS_DIR"/*/; do
			hls_ver=$(basename "$hls_ver_dir")
			lib_dir="$hls_ver_dir/lib/haskell-language-server-${hls_ver}/lib"
			[[ ! -d "$lib_dir" ]] && continue
			for ghc_lib_dir in "$lib_dir"/*/; do
				ghc_ver=$(basename "$ghc_lib_dir")
				if [[ ! -d "$GHCUP_GHC_DIR/$ghc_ver" ]]; then
					append_cleanup_candidates "$ghc_lib_dir"
				fi
			done
		done
	fi

	if [[ -d "$MPBARBOSA_BACKUPS_DIR" ]]; then
		mapfile -t backups < <(ls -1t "$MPBARBOSA_BACKUPS_DIR")
		if [[ "${#backups[@]}" -gt 1 ]]; then
			for b in "${backups[@]:1}"; do
				append_cleanup_candidates "$MPBARBOSA_BACKUPS_DIR/$b"
			done
		fi
	fi
}

emit_total_deletion_estimate_json() {
	local estimated_bytes docker_bytes
	gather_cleanup_estimate_candidates
	estimated_bytes=$(estimate_deletion_bytes "${cleanup_candidates[@]}")

	# Docker's storage is reported by `docker system df`, not by a path on disk, so
	# it cannot join cleanup_candidates and has to be added to the du total here.
	# The interactive walkthrough offers this same data for deletion, so omitting it
	# understates the total by the largest single item on most machines.
	docker_bytes=$(docker_storage_bytes)
	(( estimated_bytes += docker_bytes )) || true

	printf '{"bytes":%s,"formatted":"%s"}\n' "$estimated_bytes" "$(format_bytes "$estimated_bytes")"
}

case "${1:-}" in
--estimate-total-json)
	emit_total_deletion_estimate_json
	exit 0
	;;
esac

confirm() {
	local prompt="$1"
	local answer
	read -rp "$(echo -e "${YELLOW}${prompt} [y/N]: ${RESET}")" answer
	[[ "${answer,,}" == "y" ]]
}

print_header() {
	echo -e "\n${CYAN}${BOLD}──────────────────────────────────────────${RESET}"
	echo -e "${CYAN}${BOLD}  $1${RESET}"
	echo -e "${CYAN}${BOLD}──────────────────────────────────────────${RESET}"
}

delete_folder() {
	local label="$1"
	local path="$2"
	local note="${3:-}"

	print_header "$label"

	if [[ ! -e "$path" ]]; then
		echo -e "${YELLOW}  Not found, skipping: $path${RESET}"
		return
	fi

	local estimated_bytes estimated_size
	estimated_bytes=$(estimate_deletion_bytes "$path")
	estimated_size=$(format_bytes "$estimated_bytes")
	echo -e "  Path : ${BOLD}$path${RESET}"
	print_deletion_estimate "$estimated_bytes"
	[[ -n "$note" ]] && echo -e "  Note : $note"

	if confirm "  Delete?"; then
		rm -rf "$path"
		record_path_cleanup "$estimated_bytes"
		echo -e "  ${GREEN}✓ Deleted (deletion estimate: $estimated_size)${RESET}"
	else
		echo -e "  Skipped."
	fi
}

# ── 1. JetBrains cache ────────────────────────────────────────────────────────

delete_folder \
	"JetBrains IDE cache" \
	"$HOME/.cache/JetBrains" \
	"Caches for Fleet, IntelliJ, PyCharm, WebStorm, Toolbox. Rebuilt on next launch."

# ── 2. Android Studio cache ──────────────────────────────────────────────────

delete_folder \
	"Android Studio cache" \
	"$HOME/.cache/Google" \
	"Indexes, compiled classes, and analysis caches for Android Studio. Rebuilt on next launch."

# ── 3. JetBrains local share ─────────────────────────────────────────────────

delete_folder \
	"JetBrains local share" \
	"$HOME/.local/share/JetBrains" \
	"Plugin data, full-line ML models, REST client collections, Toolbox data. Rebuilt on next IDE launch."

# ── 4. Neovim mason + lazy ───────────────────────────────────────────────────

delete_folder \
	"Neovim mason packages" \
	"$HOME/.local/share/nvim/mason" \
	"LSP servers, linters, formatters, debuggers. Reinstalled via :MasonUpdate on next nvim launch."

delete_folder \
	"Neovim lazy plugins" \
	"$HOME/.local/share/nvim/lazy" \
	"Plugin source code managed by lazy.nvim. Reinstalled via :Lazy restore on next nvim launch."

# ── 5. pip HTTP cache ─────────────────────────────────────────────────────────

delete_folder \
	"pip HTTP cache (http-v2)" \
	"$HOME/.cache/pip/http-v2" \
	"pip network response cache. Rebuilt on next install/download."

# ── 6. npm package cache ──────────────────────────────────────────────────────

delete_folder \
	"npm package cache" \
	"$HOME/.npm/_cacache" \
	"Downloaded package tarballs and metadata. Rebuilt on next npm install."

# ── 7. Chrome HTTP cache ──────────────────────────────────────────────────────

delete_folder \
	"Chrome HTTP cache" \
	"$HOME/.cache/google-chrome/Default/Cache" \
	"Cached web resources (images, scripts, fonts). Rebuilt on next browsing session. Close Chrome first."

# ── 8. Spotify cache ─────────────────────────────────────────────────────────

delete_folder \
	"Spotify cache" \
	"$HOME/snap/spotify/common/.cache/spotify" \
	"Electron/Chromium HTTP cache, buffered audio and track data. Rebuilt on next launch. Close Spotify first."

delete_folder \
	"Spotify Mesa shader cache" \
	"$HOME/snap/spotify/common/.cache/mesa_shader_cache_db" \
	"GPU shader cache. Rebuilt on next launch."

# ── 9. Chrome OptGuide on-device model ───────────────────────────────────────

delete_folder \
	"Chrome OptGuide on-device model" \
	"$HOME/.config/google-chrome/OptGuideOnDeviceModel" \
	"Local ML model for Chrome features (tab grouping, history search). Re-downloaded by Chrome automatically."

# ── 10. HuggingFace Hub model cache ───────────────────────────────────────────

delete_folder \
	"HuggingFace Hub model cache" \
	"$HOME/.cache/huggingface/hub" \
	"Downloaded model weights (flan-t5, DialoGPT, sentence-transformers). Re-downloaded on next use."

# ── 11. Puppeteer Chrome — keep only most recent version ──────────────────────

print_header "Puppeteer Chrome — old versions"

PUPPETEER_DIR="$HOME/.cache/puppeteer/chrome"

if [[ ! -d "$PUPPETEER_DIR" ]]; then
	echo -e "${YELLOW}  Not found, skipping: $PUPPETEER_DIR${RESET}"
else
	mapfile -t versions < <(ls -1t "$PUPPETEER_DIR")
	count="${#versions[@]}"

	if [[ "$count" -le 1 ]]; then
		echo -e "  Only one version present, nothing to delete."
	else
		newest="${versions[0]}"
		old_versions=("${versions[@]:1}")
		old_version_paths=()
		echo -e "  Keeping : ${BOLD}$newest${RESET}"
		echo -e "  To delete (${#old_versions[@]} older versions):"
		for v in "${old_versions[@]}"; do
			path="$PUPPETEER_DIR/$v"
			old_version_paths+=("$path")
			echo -e "    - $v  ($(path_size "$path"))"
		done
		estimated_bytes=$(estimate_deletion_bytes "${old_version_paths[@]}")
		estimated_size=$(format_bytes "$estimated_bytes")
		print_deletion_estimate "$estimated_bytes"

		if confirm "  Delete older versions?"; then
			for v in "${old_versions[@]}"; do
				rm -rf "${PUPPETEER_DIR:?}/$v"
			done
			record_path_cleanup "$estimated_bytes"
			echo -e "  ${GREEN}✓ Deleted ${#old_versions[@]} older version(s) (deletion estimate: $estimated_size)${RESET}"
		else
			echo -e "  Skipped."
		fi
	fi
fi

# ── 12. Puppeteer chrome-headless-shell — keep only most recent version ───────

print_header "Puppeteer chrome-headless-shell — old versions"

PUPPETEER_HEADLESS_DIR="$HOME/.cache/puppeteer/chrome-headless-shell"

if [[ ! -d "$PUPPETEER_HEADLESS_DIR" ]]; then
	echo -e "${YELLOW}  Not found, skipping: $PUPPETEER_HEADLESS_DIR${RESET}"
else
	mapfile -t versions < <(ls -1t "$PUPPETEER_HEADLESS_DIR")
	count="${#versions[@]}"

	if [[ "$count" -le 1 ]]; then
		echo -e "  Only one version present, nothing to delete."
	else
		newest="${versions[0]}"
		old_versions=("${versions[@]:1}")
		old_version_paths=()
		echo -e "  Keeping : ${BOLD}$newest${RESET}"
		echo -e "  To delete (${#old_versions[@]} older versions):"
		for v in "${old_versions[@]}"; do
			path="$PUPPETEER_HEADLESS_DIR/$v"
			old_version_paths+=("$path")
			echo -e "    - $v  ($(path_size "$path"))"
		done
		estimated_bytes=$(estimate_deletion_bytes "${old_version_paths[@]}")
		estimated_size=$(format_bytes "$estimated_bytes")
		print_deletion_estimate "$estimated_bytes"

		if confirm "  Delete older versions?"; then
			for v in "${old_versions[@]}"; do
				rm -rf "${PUPPETEER_HEADLESS_DIR:?}/$v"
			done
			record_path_cleanup "$estimated_bytes"
			echo -e "  ${GREEN}✓ Deleted ${#old_versions[@]} older version(s) (deletion estimate: $estimated_size)${RESET}"
		else
			echo -e "  Skipped."
		fi
	fi
fi

# ── 13. Selenium chromedriver — keep only most recent version ────────────────

print_header "Selenium chromedriver — old versions"

SELENIUM_CD_DIR="$HOME/.cache/selenium/chromedriver/linux64"

if [[ ! -d "$SELENIUM_CD_DIR" ]]; then
	echo -e "${YELLOW}  Not found, skipping: $SELENIUM_CD_DIR${RESET}"
else
	mapfile -t versions < <(ls -1 "$SELENIUM_CD_DIR" | sort -V -r)
	count="${#versions[@]}"

	if [[ "$count" -le 1 ]]; then
		echo -e "  Only one version present, nothing to delete."
	else
		newest="${versions[0]}"
		old_versions=("${versions[@]:1}")
		old_version_paths=()
		echo -e "  Keeping : ${BOLD}$newest${RESET}"
		echo -e "  To delete (${#old_versions[@]} older versions):"
		for v in "${old_versions[@]}"; do
			path="$SELENIUM_CD_DIR/$v"
			old_version_paths+=("$path")
			echo -e "    - $v  ($(path_size "$path"))"
		done
		estimated_bytes=$(estimate_deletion_bytes "${old_version_paths[@]}")
		estimated_size=$(format_bytes "$estimated_bytes")
		print_deletion_estimate "$estimated_bytes"

		if confirm "  Delete older versions?"; then
			for v in "${old_versions[@]}"; do
				rm -rf "${SELENIUM_CD_DIR:?}/$v"
			done
			record_path_cleanup "$estimated_bytes"
			echo -e "  ${GREEN}✓ Deleted ${#old_versions[@]} older version(s) (deletion estimate: $estimated_size)${RESET}"
		else
			echo -e "  Skipped."
		fi
	fi
fi

# ── 14. GitHub Copilot CLI — old versions ────────────────────────────────────

print_header "GitHub Copilot CLI — old versions"

COPILOT_PKG_DIR="$HOME/.copilot/pkg/universal"

if [[ ! -d "$COPILOT_PKG_DIR" ]]; then
	echo -e "${YELLOW}  Not found, skipping: $COPILOT_PKG_DIR${RESET}"
else
	mapfile -t versions < <(ls -1t "$COPILOT_PKG_DIR")
	count="${#versions[@]}"

	if [[ "$count" -le 1 ]]; then
		echo -e "  Only one version present, nothing to delete."
	else
		newest="${versions[0]}"
		old_versions=("${versions[@]:1}")
		old_version_paths=()
		echo -e "  Keeping : ${BOLD}$newest${RESET}"
		echo -e "  To delete (${#old_versions[@]} older versions):"
		for v in "${old_versions[@]}"; do
			path="$COPILOT_PKG_DIR/$v"
			old_version_paths+=("$path")
			echo -e "    - $v  ($(path_size "$path"))"
		done
		estimated_bytes=$(estimate_deletion_bytes "${old_version_paths[@]}")
		estimated_size=$(format_bytes "$estimated_bytes")
		print_deletion_estimate "$estimated_bytes"

		if confirm "  Delete older versions?"; then
			for v in "${old_versions[@]}"; do
				rm -rf "${COPILOT_PKG_DIR:?}/$v"
			done
			record_path_cleanup "$estimated_bytes"
			echo -e "  ${GREEN}✓ Deleted ${#old_versions[@]} older version(s) (deletion estimate: $estimated_size)${RESET}"
		else
			echo -e "  Skipped."
		fi
	fi
fi

# ── 15. GitHub Copilot CLI — old session state ───────────────────────────────

print_header "GitHub Copilot CLI — old session state"

COPILOT_SESSIONS_DIR="$HOME/.copilot/session-state"
SESSIONS_KEEP=5

if [[ ! -d "$COPILOT_SESSIONS_DIR" ]]; then
	echo -e "${YELLOW}  Not found, skipping: $COPILOT_SESSIONS_DIR${RESET}"
else
	mapfile -t all_sessions < <(ls -1t "$COPILOT_SESSIONS_DIR")
	count="${#all_sessions[@]}"

	if [[ "$count" -le "$SESSIONS_KEEP" ]]; then
		echo -e "  Only $count session(s) present (keeping $SESSIONS_KEEP), nothing to delete."
	else
		old_count=$(( count - SESSIONS_KEEP ))
		old_sessions=("${all_sessions[@]:$SESSIONS_KEEP}")
		old_session_paths=()
		echo -e "  Keeping : ${BOLD}$SESSIONS_KEEP most recent sessions${RESET}"
		echo -e "  To delete: $old_count older session(s)"
		for s in "${old_sessions[@]}"; do
			path="$COPILOT_SESSIONS_DIR/$s"
			old_session_paths+=("$path")
			echo -e "    - $s  ($(path_size "$path"))"
		done
		estimated_bytes=$(estimate_deletion_bytes "${old_session_paths[@]}")
		estimated_size=$(format_bytes "$estimated_bytes")
		print_deletion_estimate "$estimated_bytes"

		if confirm "  Delete older sessions?"; then
			for s in "${old_sessions[@]}"; do
				rm -rf "${COPILOT_SESSIONS_DIR:?}/$s"
			done
			record_path_cleanup "$estimated_bytes"
			echo -e "  ${GREEN}✓ Deleted $old_count older session(s) (deletion estimate: $estimated_size)${RESET}"
		else
			echo -e "  Skipped."
		fi
	fi
fi

# ── 16. VS Code extensions — old versions ────────────────────────────────────

print_header "VS Code extensions — old versions"

EXT_DIR="$HOME/.vscode/extensions"

if [[ ! -d "$EXT_DIR" ]]; then
	echo -e "${YELLOW}  Not found, skipping: $EXT_DIR${RESET}"
else
	deleted=0

	mapfile -t ext_ids < <(
		ls -1 "$EXT_DIR" \
			| grep -v '\.obsolete\|extensions\.json' \
			| sed 's/-[0-9][0-9.]*\(-[a-z0-9_-]*\)*$//' \
			| sort -u
	)

	old_ext_versions=()
	for ext_id in "${ext_ids[@]}"; do
		mapfile -t versions < <(ls -1d "$EXT_DIR/$ext_id"-* 2>/dev/null | sort -t'-' -V -r)
		[[ "${#versions[@]}" -le 1 ]] && continue
		old_ext_versions+=("${versions[@]:1}")
	done

	if [[ "${#old_ext_versions[@]}" -eq 0 ]]; then
		echo -e "  No duplicate extension versions found."
	else
		echo -e "  To delete (${#old_ext_versions[@]} old version(s)):"
		for v in "${old_ext_versions[@]}"; do
			echo -e "    - $(basename "$v")  ($(path_size "$v"))"
		done
		estimated_bytes=$(estimate_deletion_bytes "${old_ext_versions[@]}")
		estimated_size=$(format_bytes "$estimated_bytes")
		print_deletion_estimate "$estimated_bytes"

		if confirm "  Delete old extension versions?"; then
			for v in "${old_ext_versions[@]}"; do
				rm -rf "$v"
				(( ++deleted ))
			done
			record_path_cleanup "$estimated_bytes"
			echo -e "  ${GREEN}✓ Removed $deleted old extension version(s) (deletion estimate: $estimated_size)${RESET}"
		else
			echo -e "  Skipped."
		fi
	fi
fi

# ── 17. VS Code HTTP cache ────────────────────────────────────────────────────

delete_folder \
	"VS Code HTTP cache" \
	"$HOME/.config/Code/Cache" \
	"Electron/Chromium HTTP cache for the editor UI and webviews. Rebuilt on next launch. Close VS Code first."

# ── 18. VS Code cached extension VSIXs ───────────────────────────────────────

delete_folder \
	"VS Code cached extension VSIXs" \
	"$HOME/.config/Code/CachedExtensionVSIXs" \
	"Downloaded VSIX packages. Pure download cache — re-fetched by VS Code on demand."

# ── 19. VS Code WorkspaceStorage — orphaned entries ──────────────────────────

print_header "VS Code WorkspaceStorage — orphaned entries"

WS_STORAGE="$HOME/.config/Code/User/workspaceStorage"

if [[ ! -d "$WS_STORAGE" ]]; then
	echo -e "${YELLOW}  Not found, skipping: $WS_STORAGE${RESET}"
else
	orphans=()
	for d in "$WS_STORAGE"/*/; do
		ws=$(python3 -c "
import json, sys
try:
    d = json.load(open('$d/workspace.json'))
    print(d.get('folder','').replace('file://','') or d.get('workspace',''))
except Exception:
    print('')
" 2>/dev/null)
		if [[ -z "$ws" ]] || { [[ ! -d "$ws" ]] && [[ ! -f "$ws" ]]; }; then
			orphans+=("$d")
		fi
	done

	if [[ "${#orphans[@]}" -eq 0 ]]; then
		echo -e "  No orphaned workspace entries found."
	else
		echo -e "  Orphaned entries (${#orphans[@]}) — project folder no longer exists:"
		for d in "${orphans[@]}"; do
			ws=$(python3 -c "
import json
try:
    d = json.load(open('${d}workspace.json'))
    print(d.get('folder','').replace('file://','') or d.get('workspace',''))
except Exception:
    print('<no workspace.json>')
" 2>/dev/null)
			echo -e "    - $(basename "$d")  ($(path_size "$d"))  $ws"
		done
		estimated_bytes=$(estimate_deletion_bytes "${orphans[@]}")
		estimated_size=$(format_bytes "$estimated_bytes")
		print_deletion_estimate "$estimated_bytes"

		if confirm "  Delete orphaned entries?"; then
			for d in "${orphans[@]}"; do
				rm -rf "$d"
			done
			record_path_cleanup "$estimated_bytes"
			echo -e "  ${GREEN}✓ Deleted ${#orphans[@]} orphaned workspace storage entries (deletion estimate: $estimated_size)${RESET}"
		else
			echo -e "  Skipped."
		fi
	fi

	backups=()
	while IFS= read -r -d '' f; do
		backups+=("$f")
	done < <(find "$WS_STORAGE" -name "state.vscdb.backup" -print0 2>/dev/null)

	if [[ "${#backups[@]}" -gt 0 ]]; then
		echo -e "  Found ${#backups[@]} state.vscdb.backup file(s):"
		for f in "${backups[@]}"; do
			echo -e "    - $f  ($(path_size "$f"))"
		done
		estimated_bytes=$(estimate_deletion_bytes "${backups[@]}")
		estimated_size=$(format_bytes "$estimated_bytes")
		print_deletion_estimate "$estimated_bytes"
		if confirm "  Delete .vscdb.backup files?"; then
			for f in "${backups[@]}"; do
				rm -f "$f"
			done
			record_path_cleanup "$estimated_bytes"
			echo -e "  ${GREEN}✓ Deleted ${#backups[@]} .vscdb.backup file(s) (deletion estimate: $estimated_size)${RESET}"
		else
			echo -e "  Skipped."
		fi
	fi
fi

# ── 20. VS Code Insiders WorkspaceStorage — orphaned entries + vscdb backups ─

print_header "VS Code Insiders WorkspaceStorage — orphaned entries"

WS_STORAGE_INSIDERS="$HOME/.config/Code - Insiders/User/workspaceStorage"

if [[ ! -d "$WS_STORAGE_INSIDERS" ]]; then
	echo -e "${YELLOW}  Not found, skipping: $WS_STORAGE_INSIDERS${RESET}"
else
	orphans=()
	for d in "$WS_STORAGE_INSIDERS"/*/; do
		ws=$(python3 -c "
import json, sys
try:
    d = json.load(open('$d/workspace.json'))
    print(d.get('folder','').replace('file://','') or d.get('workspace',''))
except Exception:
    print('')
" 2>/dev/null)
		if [[ -z "$ws" ]] || { [[ ! -d "$ws" ]] && [[ ! -f "$ws" ]]; }; then
			orphans+=("$d")
		fi
	done

	if [[ "${#orphans[@]}" -eq 0 ]]; then
		echo -e "  No orphaned workspace entries found."
	else
		echo -e "  Orphaned entries (${#orphans[@]}) — project folder no longer exists:"
		for d in "${orphans[@]}"; do
			ws=$(python3 -c "
import json
try:
    d = json.load(open('${d}workspace.json'))
    print(d.get('folder','').replace('file://','') or d.get('workspace',''))
except Exception:
    print('<no workspace.json>')
" 2>/dev/null)
			echo -e "    - $(basename "$d")  ($(path_size "$d"))  $ws"
		done
		estimated_bytes=$(estimate_deletion_bytes "${orphans[@]}")
		estimated_size=$(format_bytes "$estimated_bytes")
		print_deletion_estimate "$estimated_bytes"

		if confirm "  Delete orphaned entries?"; then
			for d in "${orphans[@]}"; do
				rm -rf "$d"
			done
			record_path_cleanup "$estimated_bytes"
			echo -e "  ${GREEN}✓ Deleted ${#orphans[@]} orphaned workspace storage entries (deletion estimate: $estimated_size)${RESET}"
		else
			echo -e "  Skipped."
		fi
	fi

	backups=()
	while IFS= read -r -d '' f; do
		backups+=("$f")
	done < <(find "$WS_STORAGE_INSIDERS" -name "state.vscdb.backup" -print0 2>/dev/null)

	if [[ "${#backups[@]}" -gt 0 ]]; then
		echo -e "  Found ${#backups[@]} state.vscdb.backup file(s):"
		for f in "${backups[@]}"; do
			echo -e "    - $f  ($(path_size "$f"))"
		done
		estimated_bytes=$(estimate_deletion_bytes "${backups[@]}")
		estimated_size=$(format_bytes "$estimated_bytes")
		print_deletion_estimate "$estimated_bytes"
		if confirm "  Delete .vscdb.backup files?"; then
			for f in "${backups[@]}"; do
				rm -f "$f"
			done
			record_path_cleanup "$estimated_bytes"
			echo -e "  ${GREEN}✓ Deleted ${#backups[@]} .vscdb.backup file(s) (deletion estimate: $estimated_size)${RESET}"
		else
			echo -e "  Skipped."
		fi
	fi
fi

# ── 21. Chrome Service Worker CacheStorage ───────────────────────────────────

delete_folder \
	"Chrome Service Worker CacheStorage" \
	"$HOME/.config/google-chrome/Default/Service Worker/CacheStorage" \
	"Offline assets cached by websites/PWAs. Rebuilt automatically. Close Chrome before deleting."

# ── 22. Heavy ML pip packages ─────────────────────────────────────────────────

print_header "Heavy ML pip packages (user-level)"

ML_PACKAGES=(
	torch triton
	nvidia-cublas-cu12 nvidia-cuda-cupti-cu12 nvidia-cuda-nvrtc-cu12 nvidia-cuda-runtime-cu12
	nvidia-cudnn-cu12 nvidia-cufft-cu12 nvidia-cufile-cu12 nvidia-curand-cu12
	nvidia-cusolver-cu12 nvidia-cusparse-cu12 nvidia-cusparselt-cu12 nvidia-nccl-cu12
	nvidia-nvjitlink-cu12 nvidia-nvshmem-cu12 nvidia-nvtx-cu12
	transformers tokenizers safetensors
	sentence-transformers faiss-cpu
	langchain langchain-core langgraph langgraph-checkpoint langgraph-prebuilt langgraph-sdk langsmith
	huggingface_hub hf-xet
)

installed=()
for pkg in "${ML_PACKAGES[@]}"; do
	if pip show "$pkg" &>/dev/null 2>&1; then
		installed+=("$pkg")
	fi
done

if [[ "${#installed[@]}" -eq 0 ]]; then
	echo -e "  No heavy ML packages found, skipping."
else
	echo -e "  Installed packages to remove (${#installed[@]}):"
	for pkg in "${installed[@]}"; do
		echo -e "    - $pkg"
	done

	if confirm "  Uninstall all listed packages?"; then
		pip uninstall -y --break-system-packages "${installed[@]}" 2>&1 | grep -E "Successfully|not installed" || true
		mark_cleanup_performed
		echo -e "  ${GREEN}✓ Done${RESET}"
	else
		echo -e "  Skipped."
	fi
fi

# ── 23. NVM — old Node.js versions ──────────────────────────────────────────

print_header "NVM — old Node.js versions"

NVM_NODE_DIR="$HOME/.nvm/versions/node"
NVM_ALIAS_DIR="$HOME/.nvm/alias"

if [[ ! -d "$NVM_NODE_DIR" ]]; then
	echo -e "${YELLOW}  Not found, skipping: $NVM_NODE_DIR${RESET}"
else
	default_ver=$(cat "$NVM_ALIAS_DIR/default" 2>/dev/null)
	[[ "$default_ver" != v* ]] && default_ver="v$default_ver"

	# Collect installed LTS versions (even-major or explicitly aliased lts/*)
	lts_vers=()
	if [[ -d "$NVM_ALIAS_DIR/lts" ]]; then
		while IFS= read -r alias_target; do
			ver=$(cat "$NVM_ALIAS_DIR/lts/$alias_target" 2>/dev/null | tr -d '[:space:]')
			[[ -n "$ver" ]] && lts_vers+=("$ver")
		done < <(ls "$NVM_ALIAS_DIR/lts/" 2>/dev/null)
	fi

	mapfile -t all_versions < <(ls -1t "$NVM_NODE_DIR")
	stale=()
	for v in "${all_versions[@]}"; do
		full_v="$v"
		[[ "$full_v" != v* ]] && full_v="v$full_v"
		keep=false
		[[ "$full_v" == "$default_ver" ]] && keep=true
		for lts in "${lts_vers[@]}"; do
			[[ "$full_v" == "$lts" ]] && keep=true
		done
		# Also keep any even-major LTS series present (v20, v22, v24...)
		major=$(echo "$full_v" | grep -oP '(?<=v)\d+')
		(( major % 2 == 0 )) && keep=true
		[[ "$keep" == false ]] && stale+=("$v")
	done

	echo -e "  Default : ${BOLD}$default_ver${RESET}"
	echo -e "  Keeping LTS/even-major versions: $(printf '%s ' "${all_versions[@]}" | tr ' ' '\n' | grep -v "$(printf '%s\n' "${stale[@]}")" | tr '\n' ' ' || true)"

	if [[ "${#stale[@]}" -eq 0 ]]; then
		echo -e "  No stale Node versions to delete."
	else
		echo -e "  To delete (${#stale[@]} stale version(s)):"
		stale_paths=()
		for v in "${stale[@]}"; do
			path="$NVM_NODE_DIR/$v"
			stale_paths+=("$path")
			echo -e "    - $v  ($(path_size "$path"))"
		done
		estimated_bytes=$(estimate_deletion_bytes "${stale_paths[@]}")
		estimated_size=$(format_bytes "$estimated_bytes")
		print_deletion_estimate "$estimated_bytes"

		if confirm "  Delete stale Node versions?"; then
			for v in "${stale[@]}"; do
				rm -rf "${NVM_NODE_DIR:?}/$v"
			done
			record_path_cleanup "$estimated_bytes"
			echo -e "  ${GREEN}✓ Deleted ${#stale[@]} stale Node version(s) (deletion estimate: $estimated_size)${RESET}"
		else
			echo -e "  Skipped."
		fi
	fi
fi

# ── 24. node_modules — stale GitHub projects ─────────────────────────────────

print_header "node_modules — stale GitHub projects"

GITHUB_DIR="$HOME/Documents/GitHub"
STALE_DAYS=30

if [[ ! -d "$GITHUB_DIR" ]]; then
	echo -e "${YELLOW}  Not found, skipping: $GITHUB_DIR${RESET}"
else
	mapfile -t stale_dirs < <(
		find "$GITHUB_DIR" -mindepth 2 -maxdepth 2 -name "node_modules" -type d \
			| while read -r nm; do
				proj=$(dirname "$nm")
				last=$(find "$proj" -maxdepth 1 -newer /dev/null -not -path "$nm" \
					-not -name "node_modules" -printf "%T@\n" 2>/dev/null \
					| sort -rn | head -1)
				[[ -z "$last" ]] && continue
				age=$(python3 -c "import time; print(int((time.time() - ${last}) / 86400))" 2>/dev/null)
				if [[ "$age" -ge "$STALE_DAYS" ]]; then
					echo "$nm"
				fi
			done
	)

	if [[ "${#stale_dirs[@]}" -eq 0 ]]; then
		echo -e "  No node_modules older than ${STALE_DAYS} days found."
	else
		estimated_bytes=$(estimate_deletion_bytes "${stale_dirs[@]}")
		estimated_size=$(format_bytes "$estimated_bytes")
		echo -e "  Found ${#stale_dirs[@]} stale node_modules:"
		for nm in "${stale_dirs[@]}"; do
			echo -e "    - $(dirname "$nm" | xargs basename)  ($(path_size "$nm"))"
		done
		print_deletion_estimate "$estimated_bytes"

		if confirm "  Delete all stale node_modules?"; then
			for nm in "${stale_dirs[@]}"; do
				rm -rf "$nm"
			done
			record_path_cleanup "$estimated_bytes"
			echo -e "  ${GREEN}✓ Deleted ${#stale_dirs[@]} node_modules folder(s) (deletion estimate: $estimated_size)${RESET}"
		else
			echo -e "  Skipped."
		fi
	fi
fi

# ── 25. Gradle caches ────────────────────────────────────────────────────────

delete_folder \
	"Gradle caches" \
	"$HOME/.gradle/caches" \
	"Version caches, downloaded deps, JAR cache, build outputs. Fully rebuilt on next Gradle build."

# ── 26. AWS CLI — old versions ───────────────────────────────────────────────

print_header "AWS CLI — old versions"

AWS_CLI_DIR="/usr/local/aws-cli/v2"

if [[ ! -d "$AWS_CLI_DIR" ]]; then
	echo -e "${YELLOW}  Not found, skipping: $AWS_CLI_DIR${RESET}"
else
	mapfile -t versions < <(ls -1 "$AWS_CLI_DIR" | grep -v '^current$' | sort -V -r)
	count="${#versions[@]}"

	if [[ "$count" -le 1 ]]; then
		echo -e "  Only one version present, nothing to delete."
	else
		newest="${versions[0]}"
		old_versions=("${versions[@]:1}")
		old_version_paths=()
		echo -e "  Keeping : ${BOLD}$newest${RESET}"
		echo -e "  To delete (${#old_versions[@]} older versions):"
		for v in "${old_versions[@]}"; do
			path="$AWS_CLI_DIR/$v"
			old_version_paths+=("$path")
			echo -e "    - $v  ($(path_size "$path"))"
		done
		estimated_bytes=$(estimate_deletion_bytes "${old_version_paths[@]}")
		estimated_size=$(format_bytes "$estimated_bytes")
		print_deletion_estimate "$estimated_bytes"

		if confirm "  Delete older versions? (requires sudo)"; then
			for v in "${old_versions[@]}"; do
				sudo rm -rf "${AWS_CLI_DIR:?}/$v"
			done
			record_path_cleanup "$estimated_bytes"
			echo -e "  ${GREEN}✓ Deleted ${#old_versions[@]} older version(s) (deletion estimate: $estimated_size)${RESET}"
		else
			echo -e "  Skipped."
		fi
	fi
fi

# ── 27. GHCup — old GHC versions ────────────────────────────────────────────

print_header "GHCup — old GHC versions"

GHCUP_GHC_DIR="$HOME/.ghcup/ghc"

if [[ ! -d "$GHCUP_GHC_DIR" ]]; then
	echo -e "${YELLOW}  Not found, skipping: $GHCUP_GHC_DIR${RESET}"
else
	mapfile -t ghc_versions < <(ls -1t "$GHCUP_GHC_DIR")
	count="${#ghc_versions[@]}"

	if [[ "$count" -le 1 ]]; then
		echo -e "  Only one GHC version present, nothing to delete."
	else
		newest="${ghc_versions[0]}"
		old_versions=("${ghc_versions[@]:1}")
		old_version_paths=()
		echo -e "  Keeping : ${BOLD}$newest${RESET}"
		echo -e "  To delete (${#old_versions[@]} older version(s)):"
		for v in "${old_versions[@]}"; do
			path="$GHCUP_GHC_DIR/$v"
			old_version_paths+=("$path")
			echo -e "    - $v  ($(path_size "$path"))"
		done
		estimated_bytes=$(estimate_deletion_bytes "${old_version_paths[@]}")
		estimated_size=$(format_bytes "$estimated_bytes")
		print_deletion_estimate "$estimated_bytes"

		if confirm "  Delete older GHC versions?"; then
			for v in "${old_versions[@]}"; do
				ghcup rm ghc "$v" 2>&1 | grep -E "Info|Error" || true
			done
			record_path_cleanup "$estimated_bytes"
			echo -e "  ${GREEN}✓ Deleted ${#old_versions[@]} older GHC version(s) (deletion estimate: $estimated_size)${RESET}"
			echo -e "  ${YELLOW}  Note: clean up cabal store at ~/.cabal/store if no longer needed${RESET}"
		else
			echo -e "  Skipped."
		fi
	fi
fi

# ── 28. HLS lib — unused GHC version builds ──────────────────────────────────

print_header "HLS lib — unused GHC version builds"

GHCUP_HLS_DIR="$HOME/.ghcup/hls"

if [[ ! -d "$GHCUP_HLS_DIR" ]]; then
	echo -e "${YELLOW}  Not found, skipping: $GHCUP_HLS_DIR${RESET}"
else
	stale_hls_libs=()
	for hls_ver_dir in "$GHCUP_HLS_DIR"/*/; do
		hls_ver=$(basename "$hls_ver_dir")
		lib_dir="$hls_ver_dir/lib/haskell-language-server-${hls_ver}/lib"
		[[ ! -d "$lib_dir" ]] && continue
		for ghc_lib_dir in "$lib_dir"/*/; do
			ghc_ver=$(basename "$ghc_lib_dir")
			if [[ ! -d "$GHCUP_GHC_DIR/$ghc_ver" ]]; then
				stale_hls_libs+=("$ghc_lib_dir")
			fi
		done
	done

	if [[ "${#stale_hls_libs[@]}" -eq 0 ]]; then
		echo -e "  No unused HLS lib builds found."
	else
		echo -e "  HLS builds for GHC versions no longer installed (${#stale_hls_libs[@]}):"
		for d in "${stale_hls_libs[@]}"; do
			echo -e "    - $(basename "$d")  ($(path_size "$d"))  $d"
		done
		estimated_bytes=$(estimate_deletion_bytes "${stale_hls_libs[@]}")
		estimated_size=$(format_bytes "$estimated_bytes")
		print_deletion_estimate "$estimated_bytes"

		if confirm "  Delete unused HLS lib builds?"; then
			for d in "${stale_hls_libs[@]}"; do
				rm -rf "$d"
			done
			record_path_cleanup "$estimated_bytes"
			echo -e "  ${GREEN}✓ Deleted ${#stale_hls_libs[@]} unused HLS lib build(s) (deletion estimate: $estimated_size)${RESET}"
		else
			echo -e "  Skipped."
		fi
	fi
fi

# ── 29. mpbarbosa.com backups — keep only most recent ────────────────────────

print_header "mpbarbosa.com — old backups"

MPBARBOSA_BACKUPS_DIR="$HOME/Documents/GitHub/mpbarbosa.com/.backups"

if [[ ! -d "$MPBARBOSA_BACKUPS_DIR" ]]; then
	echo -e "${YELLOW}  Not found, skipping: $MPBARBOSA_BACKUPS_DIR${RESET}"
else
	mapfile -t backups < <(ls -1t "$MPBARBOSA_BACKUPS_DIR")
	count="${#backups[@]}"

	if [[ "$count" -le 1 ]]; then
		echo -e "  Only one backup present, nothing to delete."
	else
		newest="${backups[0]}"
		old_backups=("${backups[@]:1}")
		old_backup_paths=()
		echo -e "  Keeping : ${BOLD}$newest${RESET}"
		echo -e "  To delete (${#old_backups[@]} older backup(s)):"
		for b in "${old_backups[@]}"; do
			path="$MPBARBOSA_BACKUPS_DIR/$b"
			old_backup_paths+=("$path")
			echo -e "    - $b  ($(path_size "$path"))"
		done
		estimated_bytes=$(estimate_deletion_bytes "${old_backup_paths[@]}")
		estimated_size=$(format_bytes "$estimated_bytes")
		print_deletion_estimate "$estimated_bytes"

		if confirm "  Delete older backups?"; then
			for b in "${old_backups[@]}"; do
				rm -rf "${MPBARBOSA_BACKUPS_DIR:?}/$b"
			done
			record_path_cleanup "$estimated_bytes"
			echo -e "  ${GREEN}✓ Deleted ${#old_backups[@]} older backup(s) (deletion estimate: $estimated_size)${RESET}"
		else
			echo -e "  Skipped."
		fi
	fi
fi

# ── 30. Docker — all containers, images, and volumes ─────────────────────────

print_header "Docker — all containers, images, and volumes"

if ! command -v docker &>/dev/null; then
	echo -e "${YELLOW}  docker command not found, skipping.${RESET}"
elif ! docker info &>/dev/null; then
	echo -e "${YELLOW}  Cannot reach the Docker daemon (not running, or needs sudo), skipping.${RESET}"
else
	container_count=$(docker ps -aq 2>/dev/null | grep -c . || true)
	image_count=$(docker images -aq 2>/dev/null | grep -c . || true)
	volume_count=$(docker volume ls -q 2>/dev/null | grep -c . || true)

	if (( container_count == 0 && image_count == 0 && volume_count == 0 )); then
		echo -e "  No Docker containers, images, or volumes present, nothing to delete."
	else
		docker_bytes=$(docker_storage_bytes)
		docker_size=$(format_bytes "$docker_bytes")
		echo -e "  ${RED}${BOLD}Removes ALL Docker data — not just unused items:${RESET}"
		echo -e "    - Containers : ${BOLD}$container_count${RESET} (running ones are force-stopped)"
		echo -e "    - Images     : ${BOLD}$image_count${RESET}"
		echo -e "    - Volumes    : ${BOLD}$volume_count${RESET} (data inside them is lost permanently)"
		echo -e "    - Build cache and unused networks"
		print_deletion_estimate "$docker_bytes"

		if confirm "  Remove ALL Docker containers, images, and volumes?"; then
			ids=$(docker ps -aq 2>/dev/null);     [[ -n "$ids" ]] && docker rm -f $ids        >/dev/null 2>&1 || true
			ids=$(docker images -aq 2>/dev/null);  [[ -n "$ids" ]] && docker rmi -f $ids       >/dev/null 2>&1 || true
			ids=$(docker volume ls -q 2>/dev/null); [[ -n "$ids" ]] && docker volume rm -f $ids >/dev/null 2>&1 || true
			docker system prune -a --volumes -f >/dev/null 2>&1 || true
			record_path_cleanup "$docker_bytes"
			echo -e "  ${GREEN}✓ Removed all Docker containers, images, and volumes (deletion estimate: $docker_size)${RESET}"
		else
			echo -e "  Skipped."
		fi
	fi
fi

# ── summary ───────────────────────────────────────────────────────────────────

if (( total_estimated_bytes > 0 )); then
	echo -e "\n${GREEN}${BOLD}Cleanup complete. Total deletion estimate: $(format_bytes "$total_estimated_bytes")${RESET}\n"
elif [[ "$any_cleanup_performed" == true ]]; then
	echo -e "\n${GREEN}${BOLD}Cleanup complete.${RESET}\n"
else
	echo -e "\n${GREEN}${BOLD}Cleanup complete. Nothing was deleted.${RESET}\n"
fi
