# BailaDuo API

Rails 7.1 / Ruby 3.2.2 / PostgreSQL. The React frontend is a separate repository. Endpoints and payloads: [API contract](docs/API_CONTRACT.md). Product behavior: [spec](docs/PRODUCT_SPEC.md). Progress and release evidence: [launch issue #5](https://github.com/willshepp28/bailaduo-api/issues/5).

## Local setup and checks

```sh
bundle install
RAILS_ENV=development DATABASE_URL=postgresql:///bailaduo_api_integration_development bin/rails db:prepare
RAILS_ENV=development DATABASE_URL=postgresql:///bailaduo_api_integration_development FRONTEND_ORIGINS=http://localhost:5173,http://localhost:5174 bin/rails server -b 127.0.0.1 -p 3100
```

Use an isolated local database for tests; never use Neon/production:

```sh
RAILS_ENV=test DATABASE_URL=postgresql:///bailaduo_api_api003_test bin/rails db:prepare
RAILS_ENV=test DATABASE_URL=postgresql:///bailaduo_api_api003_test bin/rails test
RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 FRONTEND_ORIGINS=https://frontend.example.test bin/rails zeitwerk:check
git diff --check
```

GitHub Actions runs migrations, the full suite and production autoload on isolated PostgreSQL. Tests use generated credentials and provider doubles; they do not establish real Cloudflare or deployed/browser readiness.

## Local Playa test accounts

Opt in explicitly; this is never part of `db:prepare` or production seeds:

```sh
RAILS_ENV=development DATABASE_URL=postgresql:///bailaduo_api_integration_development bin/rails dev:seed_playa
```

Creates 15 fictional adult dancers (`playa01@bailaduo.test`–`playa15@bailaduo.test`) in Playa del Carmen, with bachata throughout and 6 beginner / 6 intermediate / 3 advanced profiles. After committing the accounts/private credentials, the task uploads the supplied generated portraits through the configured development owned-photo API. It requires the local API at port 3100 and the backend-only development Images configuration below. There are no photo-rule/flag changes, connections or messages added by seeding. If provider setup fails, accounts/credentials remain intact and the task reports failure; rerun the targeted refresh after correcting setup.

The task checks both resolved Rails configuration and the actual PostgreSQL connection: only Rails development, the exact local database above, and port 5432 are allowed. It preserves unrelated data and existing cohort edits/passwords/relationships. Reruns create only missing owned accounts/profiles and retain IDs otherwise. An email collision without matching ownership is refused.

Generated passwords and cohort ownership live only in git-ignored `tmp/playa-test-users.json` (mode 0600). Back it up privately; do not paste it into GitHub, logs, screenshots or traces. Missing/corrupt manifests or identity collisions require restoring the private manifest or deliberate review; the task never resets passwords or guesses credentials. Passwords manually changed later are not overwritten, so exported credentials must be rechecked through real sign-in before handoff. A rare interrupted database commit may leave a manifest needing review; no automatic adoption/reset is attempted. Local API: `http://localhost:3100`; frontend: `http://localhost:5173` when running in live mode. Execution/test evidence belongs to epic #9 and launch issue #5.

Generated replacement portraits are included in `test/fixtures/files/playa_portraits/`: 15 JPEGs (`playa01.jpg`–`playa15.jpg`) and `manifest.json` mapping each file to its seed email/name, SHA-256 checksum, and generation prompt. They depict fictional AI-generated adults, not real members. To update existing profiles without rewriting credentials, run `bin/rails dev:refresh_playa_portraits` with the same development environment/database/provider variables as above. Only the owner's exact old numbered placeholder is eligible; existing managed/manual photos are preserved. Verified attachment rechecks the old reference under a row lock, keeping all other fields unchanged. Reruns preserve the resulting mapping and issue no uploads for attached photos. An ignored mode-0600 `tmp/playa-portrait-progress.json` checkpoints owned upload IDs/checksums (never upload URLs) so interrupted confirmation can resume without reuploading. If confirmation reports 409, retry after processing; an unfinished/expired authorization requires deliberate owner-scoped cancellation/review, not blind reissuance. The task never lists account media, changes variants, or touches production/JabNGo.

## Profile-photo configuration

Keep all credentials in the Rails environment. No `VITE_*` Cloudflare secrets, shared JabNGo token, account-wide cleanup, or changes to existing variants/assets. Create a dedicated BailaDuo Images token with Images read/edit permissions for the intended account, and a new delivery variant such as `bailaduodevelopmentprofile` (800×800, fit crop, no upscaling, metadata none). Cloudflare Images tokens are account-scoped; Rails ownership/environment checks provide asset isolation, not metadata or token naming.

| Variable | Purpose |
| --- | --- |
| `BAILADUO_CLOUDFLARE_ACCOUNT_ID` | Intended Cloudflare account ID |
| `BAILADUO_CLOUDFLARE_IMAGES_TOKEN` | Dedicated server-only Images API token |
| `BAILADUO_CLOUDFLARE_IMAGES_HASH` | Delivery account hash from Images delivery URLs |
| `BAILADUO_CLOUDFLARE_IMAGES_VARIANT` | Existing new BailaDuo variant; must use lowercase letters/digits and start with `bailaduo` plus the media environment with hyphens removed; e.g. `bailaduodevelopmentprofile` |
| `BAILADUO_MEDIA_ENVIRONMENT` | Asset namespace; defaults to Rails environment; use distinct development/staging/production identities |
| `BAILADUO_REQUIRE_MANAGED_PHOTOS` | Set exactly `true` after WEB-003 is ready to require owned uploads for new/replaced photos; default is compatibility mode |
| `FRONTEND_ORIGINS` | Comma-separated exact frontend origins; no wildcard/path/trailing slash |

Rails does not automatically load `.env` files. Export these variables securely or load a private local configuration into the server shell. Never paste secrets or active upload URLs into GitHub/logs. Missing configuration returns a controlled 503 from upload operations; account/profile/discovery functionality remains available.

Uploads use Cloudflare's one-time direct creator API. The browser sends a multipart `file` directly to the returned URL, with **no Rails auth or provider API token**. Rails verifies completion and the original file before accepting its owned record. Supported profile photos: JPEG, PNG or WebP, at most 5,000,000 bytes. Cloudflare's native hosted-image ceiling is 10 MB; Rails enforces its stricter limit and format policy before profile attachment, regardless of browser declarations. Original bytes are inspected in bounded memory, never stored in PostgreSQL or Render disk.

For a real-provider smoke check, use only a disposable local development/test database and the matching media environment with designated BailaDuo credentials/variant:

```sh
RAILS_ENV=development DATABASE_URL=postgresql:///bailaduo_api_integration_development bin/rails photos:smoke
```

This opt-in task generates one tiny disposable PNG in memory, uploads and verifies it, checks profile persistence, and removes only that owned photo and its local smoke account. It never lists account media or touches JabNGo assets/settings. It does not print the upload URL, token or password. If cleanup fails, it retains owned records for retry; do not manually delete arbitrary provider IDs.

Run bounded abandoned/superseded cleanup explicitly in the intended environment:

```sh
bin/rails photos:cleanup
```

Each invocation considers at most 50 unreferenced owned records in that environment/account. Pending/ready/failed/issuing records wait until 24 hours after upload expiry; superseded photos are eligible immediately. Referenced photos (including legacy URL references), foreign IDs/environments/accounts and unrelated media are never deleted. Failed automatic deletion after replacement leaves a superseded record for this retry. No queue, cron, or background infrastructure is required; schedule the existing task only as part of an approved operations setup.

## Coordinated rollout

1. Apply the additive photo migration with the existing Neon configuration during an approved backend release. Existing profile URLs remain unchanged; no provider IDs are inferred/backfilled from them.
2. Configure the dedicated credentials and environment-specific BailaDuo variant. Keep `BAILADUO_REQUIRE_MANAGED_PHOTOS` unset/false while the URL-only frontend is deployed. Confirm the real-provider smoke check in the intended non-production environment first.
3. WEB-003 integrates the pushed contract's upload/confirm/`photo_upload_id` flow. Public responses retain `primary_photo_url`; other screens and auth endpoints stay compatible.
4. After WEB-003 is verified and deployed in the approved release, set the managed-photo flag to `true` and restart Rails. Existing photos and non-photo edits remain usable; new photos and replacements require verified owned upload records. Managed photos cannot be replaced by a pasted URL even in compatibility mode.
5. Verify mobile/desktop upload, replacement failure, reload/login persistence, messaging/privacy, exact CORS and deployed commit SHAs under QA-001. Local tests alone do not establish launch readiness.

There is no destructive data migration. For rollback, disable the requirement flag while coordinating frontend/backend releases; retain the additive tables and existing photos. Do not roll back/drop the photo migration once it contains live data. Merge/deployment still require approval.
