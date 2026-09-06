# Contributing

## Publishing the documentation site

Keep documentation sources in this repository. The [central documentation repository](https://github.com/modern-swift-dev/docs)
builds the Astro and DocC site daily and publishes it at
https://modern-swift-dev.github.io/docs/swift-markdown-ui/.

After changing documentation or publishing a GitHub release, validate the site locally:

```sh
make site-validate
```

The build fetches the latest published release and writes the assembled site to `.build/site/`.
Review the generated release information and DocC output, and commit only the source changes.
Generated HTML is ignored and is not committed to this module.

Preview the assembled site with `make site-preview` and open the URL printed by the command.
Pages deployment is configured in the central documentation repository.
