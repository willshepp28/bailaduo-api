# Repository workflow

- Use https://github.com/willshepp28/bailaduo-api/issues/5 as the authoritative launch tracker. Follow its linked ticket sequence, update GitHub progress with test evidence, and commit/push coherent milestones. Do not create a second launch checklist.
- Work only in `bailaduo-api`; the React frontend is a separate repository.
- Read `docs/PRODUCT_SPEC.md` and `docs/API_CONTRACT.md` before changing API behavior. Keep the contract aligned with implemented endpoints.
- Inspect the branch, working tree, and differences from `origin/main` before starting. Preserve existing and unrelated work.
- Use an appropriately named feature branch for each ticket; do not implement tickets directly on `main`.
- Review the complete diff and run migrations and the full Rails test suite against a separate local PostgreSQL test database. Never use Neon/production for tests.
- Run the production-mode Rails autoload check and `git diff --check` before committing.
- For completed tickets, commit the work, push the feature branch to `origin`, and open a pull request against `main` with a concise description and validation results. Report the PR URL, failing checks, and merge conflicts.
- Do not merge until the user approves the PR. Do not deploy without explicit authorization.
- Preserve the established Devise Token Auth contract and working Render/Neon configuration. Keep credentials out of source, logs, tests, and documentation.
