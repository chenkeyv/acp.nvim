#!/usr/bin/env sh
set -eu

usage() {
	cat <<'EOF'
Usage: scripts/update-local-plugin.sh [--restore]

Activates this checkout in the existing vim.pack install slot:
  ${stdpath("data")}/site/pack/core/opt/acp.nvim

The first run moves the installed checkout to acp.nvim.remote, then symlinks this
repo in its place. Later edits in this repo are picked up by a fresh Neovim
session.

Environment:
  NVIM_BIN              Neovim executable to query, default: nvim
  ACP_NVIM_PLUGIN_DIR   Override installed plugin path
EOF
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
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

backup_dir="$plugin_dir.remote"

if [ "${1:-}" = "--restore" ]; then
	if [ -L "$plugin_dir" ]; then
		rm "$plugin_dir"
	elif [ -e "$plugin_dir" ]; then
		echo "error: refusing to restore over non-symlink target:" >&2
		echo "  $plugin_dir" >&2
		exit 1
	fi

	if [ -e "$backup_dir" ]; then
		mv "$backup_dir" "$plugin_dir"
		echo "Restored vim.pack acp.nvim checkout:"
		echo "  $plugin_dir"
	else
		echo "No backup checkout found:"
		echo "  $backup_dir"
	fi
	exit 0
fi

if [ "${1:-}" != "" ]; then
	usage >&2
	exit 1
fi

mkdir -p "$(dirname "$plugin_dir")"

if [ -L "$plugin_dir" ]; then
	current_target=$(readlink "$plugin_dir")
	if [ "$current_target" = "$repo_root" ]; then
		echo "Local acp.nvim checkout already active:"
		echo "  $plugin_dir -> $repo_root"
		exit 0
	fi
	echo "error: target is a symlink to a different path:" >&2
	echo "  $plugin_dir -> $current_target" >&2
	exit 1
fi

if [ -e "$plugin_dir" ]; then
	if [ -e "$backup_dir" ]; then
		echo "error: backup already exists, refusing to move installed checkout:" >&2
		echo "  $backup_dir" >&2
		exit 1
	fi
	mv "$plugin_dir" "$backup_dir"
fi

ln -s "$repo_root" "$plugin_dir"

echo "Activated local acp.nvim checkout:"
echo "  $plugin_dir -> $repo_root"
if [ -e "$backup_dir" ]; then
	echo "Preserved installed checkout:"
	echo "  $backup_dir"
fi
echo
echo "Restart Neovim, then run :AcpHealth or :AcpChat."
