#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
website_dir="$repository_root/Website"
astro_output="$website_dir/dist"
published_output="$repository_root/.build/site"
work_dir=$(mktemp -d "$repository_root/.site-build.XXXXXX")
staged_output="$work_dir/docs"
docc_output="$work_dir/MarkdownLibraries.doccarchive"
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

mkdir -p "$staged_output"
cp -R "$astro_output"/. "$staged_output"/

for target in MarkdownUI MarkdownUIEditor; do
    archive="$work_dir/$target.doccarchive"
    SWIFT_DETERMINISTIC_HASHING=1 swift package \
        --package-path "$repository_root" \
        --allow-writing-to-directory "$archive" \
        generate-documentation \
        --target "$target" \
        --output-path "$archive" \
        --disable-indexing \
        --warnings-as-errors
done

xcrun docc merge \
    "$work_dir/MarkdownUI.doccarchive" \
    "$work_dir/MarkdownUIEditor.doccarchive" \
    --synthesized-landing-page-name "Markdown Libraries" \
    --output-path "$docc_output"
xcrun docc process-archive transform-for-static-hosting "$docc_output" \
    --hosting-base-path docs/swift-markdown-ui

for asset_directory in css data downloads images img index js videos; do
    if [[ -d "$docc_output/$asset_directory" ]]; then
        mkdir -p "$staged_output/$asset_directory"
        cp -R "$docc_output/$asset_directory"/. "$staged_output/$asset_directory"/
    fi
done

mkdir -p "$staged_output/documentation"
for module in markdownui markdownuieditor; do
    if [[ ! -d "$docc_output/documentation/$module" ]]; then
        echo "error: DocC did not create documentation/$module" >&2
        exit 1
    fi
done
# Include the merged archive's landing page as well as both module references.
# Keep the site's existing documentation overview when DocC has an index page.
cp "$staged_output/documentation/index.html" "$work_dir/documentation-overview.html"
cp -R "$docc_output/documentation"/. "$staged_output/documentation"/
cp "$work_dir/documentation-overview.html" "$staged_output/documentation/index.html"

for asset_file in favicon.ico favicon.svg; do
    if [[ -f "$docc_output/$asset_file" && ! -f "$staged_output/$asset_file" ]]; then
        cp "$docc_output/$asset_file" "$staged_output/$asset_file"
    fi
done
touch "$staged_output/.nojekyll"

if [[ -e "$published_output" ]]; then
    mv "$published_output" "$previous_output"
fi

mkdir -p "$(dirname "$published_output")"
mv "$staged_output" "$published_output"
