# Contributing

## Documentation

Edit the Markdown pages in `Documentation/Site/` or the DocC catalogs beside their Swift targets.
Keep code examples and module-specific guides in this repository. Site pages use YAML `title` and
`description` fields. The central build replaces `{{version}}`, `{{releaseDate}}`, and `{{releaseURL}}`
with the latest published release data.

The [central documentation repository](https://github.com/modern-swift-dev/docs) owns the shared
Astro theme, DocC generation, previews, and daily publication. Follow its
[build and preview instructions](https://github.com/modern-swift-dev/docs/blob/main/README.md) to review changes.
Commit documentation sources here; generated HTML is published centrally.
