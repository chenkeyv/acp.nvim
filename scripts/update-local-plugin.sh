#!/usr/bin/env sh
set -eu

usage() {
	cat <<'EOF'
Usage: scripts/update-local-plugin.sh [--restore]

Synchronizes this checkout into the existing vim.pack install slot:
  ${stdpath("data")}/site/pack/core/opt/acp.nvim

vim.pack treats that directory as exclusively managed and removes symlinks. This
script therefore preserves the installed checkout's .git directory and mirrors
the files from this working tree. Run it again after making local changes.

Environment:
  NVIM_BIN              Neovim executable to query, default: nvim
  ACP_NVIM_PLUGIN_DIR   Override installed plugin path
  ACP_NVIM_BACKUP_DIR   Override backup checkout path
EOF
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd -P)
nvim_bin=${NVIM_BIN:-nvim}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	usage
	exit 0
fi

if [ -z "${ACP_NVIM_PLUGIN_DIR:-}" ]; then
	if ! command -v "$nvim_bin" >/dev/null 2>&1; then
		echo "error: '$nvim_bin' not found; set NVIM_BIN or ACP_NVIM_PLUGIN_DIR" >&2
		exit 1
	fi

	NVIM_LOG_FILE=${NVIM_LOG_FILE:-"${TMPDIR:-/tmp}/acp.nvim-nvim.log"}
	export NVIM_LOG_FILE
	nvim_data=$(
		"$nvim_bin" --headless -u NONE -i NONE --cmd "set shadafile=NONE" \
			-c "lua io.write(vim.fn.stdpath('data'))" -c "qa!"
	)
	plugin_dir="$nvim_data/site/pack/core/opt/acp.nvim"
else
	plugin_dir=$ACP_NVIM_PLUGIN_DIR
fi

if ! command -v rsync >/dev/null 2>&1; then
	echo "error: 'rsync' is required" >&2
	exit 1
fi

plugin_parent=$(dirname "$plugin_dir")
mkdir -p "$plugin_parent"
plugin_parent=$(CDPATH='' cd -- "$plugin_parent" && pwd -P)
plugin_dir="$plugin_parent/$(basename "$plugin_dir")"
pack_root=$(CDPATH='' cd -- "$plugin_parent/.." && pwd -P)
backup_dir=${ACP_NVIM_BACKUP_DIR:-"$pack_root/acp.nvim.remote"}
legacy_backup_dir="$plugin_dir.remote"

sync_tree() {
	source_dir=$1
	target_dir=$2
	rsync -a --delete --exclude='.git' --exclude='nvim.log' "$source_dir/" "$target_dir/"
}

if [ "${1:-}" = "--restore" ]; then
	restore_dir=$backup_dir
	if [ ! -e "$restore_dir" ] && [ -e "$legacy_backup_dir" ]; then
		restore_dir=$legacy_backup_dir
	fi

	if [ ! -e "$restore_dir" ]; then
		echo "No backup checkout found:"
		echo "  $backup_dir"
		exit 0
	fi

	if [ -L "$plugin_dir" ]; then
		rm "$plugin_dir"
	fi

	if [ ! -e "$plugin_dir" ]; then
		cp -R "$restore_dir" "$plugin_dir"
	elif [ ! -d "$plugin_dir" ]; then
		echo "error: plugin target is not a directory:" >&2
		echo "  $plugin_dir" >&2
		exit 1
	else
		sync_tree "$restore_dir" "$plugin_dir"
	fi

	echo "Restored vim.pack acp.nvim checkout:"
	echo "  $plugin_dir"
	exit 0
fi

if [ "${1:-}" != "" ]; then
	usage >&2
	exit 1
fi

if [ -L "$plugin_dir" ]; then
	current_target=$(readlink "$plugin_dir")
	if [ "$current_target" != "$repo_root" ]; then
		echo "error: target is a symlink to a different path:" >&2
		echo "  $plugin_dir -> $current_target" >&2
		exit 1
	fi
	rm "$plugin_dir"
fi

if [ ! -e "$backup_dir" ] && [ -e "$legacy_backup_dir" ]; then
	mkdir -p "$(dirname "$backup_dir")"
	cp -R "$legacy_backup_dir" "$backup_dir"
fi

if [ ! -e "$plugin_dir" ]; then
	if [ -e "$backup_dir" ]; then
		cp -R "$backup_dir" "$plugin_dir"
	else
		echo "error: no installed checkout found; start Neovim once so vim.pack installs acp.nvim" >&2
		echo "  $plugin_dir" >&2
		exit 1
	fi
fi

if [ ! -d "$plugin_dir" ]; then
	echo "error: plugin target is not a directory:" >&2
	echo "  $plugin_dir" >&2
	exit 1
fi

if [ ! -e "$plugin_dir/.git" ]; then
	echo "error: plugin target is not a Git checkout:" >&2
	echo "  $plugin_dir" >&2
	exit 1
fi

if [ ! -e "$backup_dir" ]; then
	mkdir -p "$(dirname "$backup_dir")"
	cp -R "$plugin_dir" "$backup_dir"
fi

sync_tree "$repo_root" "$plugin_dir"

echo "Synchronized local acp.nvim checkout:"
echo "  $repo_root -> $plugin_dir"
echo "Preserved installed checkout:"
echo "  $backup_dir"
if [ -e "$legacy_backup_dir" ]; then
	echo "Legacy vim.pack backup still present:"
	echo "  $legacy_backup_dir"
fi
echo
echo "Run :AcpReload in Neovim to load these changes without ending the current Codex thread."
echo "If the loaded version predates :AcpReload, restart Neovim once."
