#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
docs_dir="$repository_root/.build/site"
serve_dir=$(mktemp -d "${TMPDIR:-/tmp}/swift-markdown-ui-preview.XXXXXX")
port=${SITE_PORT:-8000}
bind_address=${SITE_BIND_ADDRESS:-127.0.0.1}

cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [[ -d "$serve_dir" ]]; then
        find "$serve_dir" -depth -delete
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

if [[ ! -d "$docs_dir" ]]; then
    echo "error: .build/site/ is missing; run make site-build first" >&2
    exit 1
fi

mkdir -p "$serve_dir/docs"
ln -s "$docs_dir" "$serve_dir/docs/swift-markdown-ui"
echo "Previewing http://$bind_address:$port/docs/swift-markdown-ui/"
python3 -m http.server "$port" --bind "$bind_address" --directory "$serve_dir"
