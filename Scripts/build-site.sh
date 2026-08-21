#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
website_dir="$repository_root/Website"
astro_output="$website_dir/dist"
published_output="$repository_root/docs"
work_dir=$(mktemp -d "$repository_root/.site-build.XXXXXX")
staged_output="$work_dir/docs"
docc_output="$work_dir/docc"
previous_output="$work_dir/previous-docs"

cleanup() {
    status=$?
    trap - EXIT INT TERM

    if [[ $status -ne 0 && -e "$previous_output" && ! -e "$published_output" ]]; then
        mv "$previous_output" "$published_output"
    fi

    if [[ -d "$work_dir" ]]; then
        find "$work_dir" -depth -delete
    fi

    exit "$status"
}
trap cleanup EXIT INT TERM

if [[ ! -f "$website_dir/package.json" ]]; then
    echo "error: Website/package.json is missing" >&2
    exit 1
fi

if [[ "${SITE_SKIP_INSTALL:-0}" != "1" ]]; then
    npm --prefix "$website_dir" ci
fi

npm --prefix "$website_dir" run build

if [[ ! -d "$astro_output" ]]; then
    echo "error: Astro did not create Website/dist" >&2
    exit 1
fi

mkdir -p "$staged_output" "$docc_output"
cp -R "$astro_output"/. "$staged_output"/

SWIFT_DETERMINISTIC_HASHING=1 swift package \
    --package-path "$repository_root" \
    --allow-writing-to-directory "$docc_output" \
    generate-documentation \
    --target MarkdownUI \
    --output-path "$docc_output" \
    --disable-indexing \
    --transform-for-static-hosting \
    --hosting-base-path swift-markdown-ui

for asset_directory in css data downloads images img index js videos; do
    if [[ -d "$docc_output/$asset_directory" ]]; then
        mkdir -p "$staged_output/$asset_directory"
        cp -R "$docc_output/$asset_directory"/. "$staged_output/$asset_directory"/
    fi
done

if [[ ! -d "$docc_output/documentation/markdownui" ]]; then
    echo "error: DocC did not create documentation/markdownui" >&2
    exit 1
fi

mkdir -p "$staged_output/documentation"
mkdir -p "$staged_output/documentation/markdownui"
cp -R "$docc_output/documentation/markdownui"/. "$staged_output/documentation/markdownui"/

for asset_file in favicon.ico favicon.svg; do
    if [[ -f "$docc_output/$asset_file" && ! -f "$staged_output/$asset_file" ]]; then
        cp "$docc_output/$asset_file" "$staged_output/$asset_file"
    fi
done
touch "$staged_output/.nojekyll"

if [[ -e "$published_output" ]]; then
    mv "$published_output" "$previous_output"
fi

mv "$staged_output" "$published_output"
