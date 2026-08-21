# Contributing

## Publishing the documentation site

The documentation is a static Astro and DocC build committed in `docs/`. A release update is manual:

1. Publish the GitHub release.
2. Run `make site-build` from the repository root. The build fetches the latest published release and replaces `docs/`.
3. Review the release details and DocC changes in the generated output.
4. Run `make site-validate`, then commit `docs/` with the related source changes.

GitHub Pages needs one repository setting before the first publication. In **Settings > Pages**, choose
**Deploy from a branch**, select `main` and `/docs`, then save. Do not automate this repository setting.
See GitHub's [branch publishing instructions](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)
for the current interface.
