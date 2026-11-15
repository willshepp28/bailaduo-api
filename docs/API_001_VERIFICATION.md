# API-001 verification and API-002 proposal

Historical snapshot from the API-001 verification, before API-002 implementation and the feature-branch PR. Git state and open decisions below describe that earlier verification. See `API_CONTRACT.md` for the current implemented API-001/API-002 contract.

## Repository state

Verified on local branch `main`. HEAD and the local `origin/main` reference both equal `9c12f5611f451d5660750ca1649ba495d9657c0d` (`updated gitignore`); the preceding commit is `b542de8` (`first commit`). No local commits are ahead of or behind that reference. This verification did not fetch GitHub again, so it does not assert that the remote branch has remained unchanged since the lead engineer's inspection.

API-001 exists entirely as unstaged modifications and untracked files. Existing work was preserved. No commit, push, staging, deployment or production migration was performed. Live Render deployment state was not inspected. No frontend files or other repositories were modified. No applicable AGENTS.md files were found in the repository or its ancestor directories.

Read `PRODUCT_SPEC.md` and `API_CONTRACT.md`. The exact implemented frontend contract remains in `API_CONTRACT.md`; API-002 below is a proposal only.

## Verification results and fixes

- Existing baseline: 14 tests, 74 assertions, no test failures/errors.
- Added regression tests reproduced two errors: non-string city/style filters called `strip` on arrays; non-object profile envelopes called `permit` on scalars. Both would produce server errors. They now return JSON 400 errors.
- Added checks cover all five CORS-exposed authentication headers, absence of cookie credentials, logout preserving another client session, forged token rejection, and unauthenticated logout's documented 404.
- Final suite: **17 tests, 86 assertions, 0 failures, 0 errors, 0 skips** (seed 7608).
- Both migrations applied from scratch to dedicated local PostgreSQL database `bailaduo_api_api001_verify_test`; final migration status shows both `up`.
- Production-mode `zeitwerk:check` passed with a dummy build secret and fictional frontend origin; no Neon access required.
- `git diff --check` passed.

The first combined `db:create db:migrate test` command emitted a PostgreSQL database-in-use error during Rails' subprocess schema preparation, although its test run passed. Running migrations and tests in separate commands resolved this invocation issue. Final verification had no schema/database errors. Rack emitted deprecation warnings for Rails' `:unprocessable_entity` status alias; responses remain HTTP 422.

Reproduction commands (Ruby 3.2.2, installed dependencies, local PostgreSQL):

```sh
export RAILS_ENV=test
export DATABASE_URL=postgresql:///bailaduo_api_api001_verify_test
bundle exec rails db:create db:migrate
bundle exec rails db:migrate:status
bundle exec rails test
```

Run test commands separately from migration commands. The URL deliberately selects a local database without credentials and overrides any inherited Neon URL. Do not use a shared database for tests.

Verified behavior includes Devise Token Auth registration/login/logout/token validation, safe account serialization, expiry and revocation, protected own-profile create/read/update, server-controlled ownership, public profile detail, required fields and adult age, incomplete/self exclusion, city/style filtering, 15-row pagination and metadata, profile uniqueness at the database level, and CORS auth header exposure.

Profile deletion is intentionally absent: the original API-001 scope requested create/retrieve/update, so “CRUD” here does not include a DELETE endpoint. Public detail exposes the complete public field allowlist; no separate limited anonymous preview has been implemented.

## Local file inventory relative to origin/main

Modified tracked files:

- `Gemfile`
- `Gemfile.lock`
- `app/controllers/application_controller.rb`
- `config/initializers/cors.rb`
- `config/initializers/filter_parameter_logging.rb`
- `config/routes.rb`
- `test/test_helper.rb`

Untracked files:

- `app/controllers/api/profiles_controller.rb`
- `app/models/profile.rb`
- `app/models/user.rb`
- `config/initializers/devise.rb`
- `config/initializers/devise_token_auth.rb`
- `db/migrate/20261115000100_create_users.rb`
- `db/migrate/20261115000200_create_profiles.rb`
- `db/schema.rb`
- `docs/API_CONTRACT.md`
- `docs/PRODUCT_SPEC.md` (existing user-provided source; preserved)
- `docs/API_001_VERIFICATION.md` (this report)
- `test/integration/api_test.rb`
- `test/models/profile_test.rb`

This verification changed only the two controllers, integration tests, API contract, and this report. All other API-001 changes were already present locally.

Deployment still requires an approved release, installation of the locked gems, production migrations, and exact production `FRONTEND_ORIGINS`. Existing Render/Neon connection settings are unchanged.

## Smallest proposed API-002

Add conventional `Connection` and `Message` models and two API controllers. Reuse existing token authentication and public profile serialization. No services, background jobs, WebSockets, uploads or notifications.

### Tables and invariants

`connections`: `requester_id`, `recipient_id` (non-null user foreign keys), `status` (non-null string, default `pending`), `intro_message` (non-null text), timestamps. Validate introduction length 1–1,000 characters after trimming. Add database checks against self-connections, blank introduction and statuses outside `pending`, `accepted`, `declined`, `ended`.

Use a PostgreSQL expression unique index:

```sql
CREATE UNIQUE INDEX index_connections_on_unordered_pair
ON connections (
  LEAST(requester_id, recipient_id),
  GREATEST(requester_id, recipient_id)
);
```

This index enforces one durable row per pair in either direction even under simultaneous requests. Preserve request direction in the original two columns; no extra pair columns or join table. Catch uniqueness violations outside the insert transaction and return 409. An application uniqueness check alone is insufficient.

Recommendation for the smallest release: keep the index unconditional and disallow retry/reconnect after decline/end. This is stricter than one *active* connection per pair and requires product agreement. If retries are required, agree the policy first, then either reopen the same row through explicit transitions or use a partial active-status unique index with a separate abuse/cooldown policy. Do not silently allow a new request after each decline.

`messages`: `connection_id`, `sender_id` (non-null foreign keys), `body` (non-null text), timestamps; index `(connection_id, created_at, id)`. Validate trimmed body length 1–5,000 characters and add database nonblank checks. Store text directly in PostgreSQL. Render as text in the frontend.

### Proposed endpoints

All require auth headers. Envelopes follow API-001's `data`, `meta`, `errors` conventions.

| Method | Path | Behavior |
|---|---|---|
| POST | `/api/connections` | Body `{"connection":{"recipient_profile_id":10,"intro_message":"Would you like to practice?"}}`; sender always current user; 201 |
| GET | `/api/connections` | Participant-only paginated list with state and direction, optional status filter; 200 |
| GET | `/api/connections/:id` | Participant-only detail, introduction and other dancer's public profile; 200 |
| PATCH | `/api/connections/:id` | Body `{"connection":{"status":"accepted"}}`, `declined` or `ended`; 200 |
| GET | `/api/connections/:id/messages?page=1` | Accepted participant only; chronological `(created_at,id)` order, 50/page with metadata; 200 |
| POST | `/api/connections/:id/messages` | Body `{"message":{"body":"Saturday afternoon?"}}`; accepted participant only; 201 |

Use `recipient_profile_id` so the existing public profile contract need not expose account user IDs. Resolve a complete recipient profile server-side. Require a complete sender profile before creating a connection. Prevent self-requests. Return safe participant profile data, status and `incoming`/`outgoing` direction; message responses include ID, sender profile ID, body and timestamp. Account emails and tokens stay private. The required introduction is stored on the connection and visible before acceptance; it need not be duplicated as a chat message.

### Authorization and concurrency

Scope every connection lookup to `(requester_id = current_user.id OR recipient_id = current_user.id)` before accessing its attributes. Return 404 for outsiders; 401 without valid authentication. Only the recipient may transition pending to accepted/declined; either participant may transition accepted to ended. Reject other transitions with 409. Never accept sender or participant IDs from update/message payloads.

Use the same connection row lock (`with_lock`) for state transitions and message creation. Recheck participant membership and accepted status inside the lock before persisting a message. This serializes send/end races. Message reads also require membership and accepted status; load messages only through the authorized connection. Return 403 to a participant attempting a recipient-only action or messaging on a non-accepted connection. Reject invalid data with 422 and duplicates/conflicting transitions with 409.

The strict reading of the current spec allows reading messages only while accepted. Therefore recommend denying both message reads and writes after ending, while retaining history in PostgreSQL. Read authorization can be checked in the same row-lock transaction if strict serialization with an end operation is required.

### Meaningful API-002 tests

Test complete-profile gating, required introduction, self-request rejection, incoming/outgoing states, duplicate same-direction and reciprocal requests, and a genuine concurrent cross-request insert using independent PostgreSQL connections. Verify exactly one row survives and the loser receives a conflict. Add direct database invariant tests as well as request tests.

Test outsider read/update/send denial, sender inability to accept/decline, recipient-only transitions, invalid transition rejection, no reads/sends before acceptance or after ending, forged sender IDs ignored, persistence across requests, chronological pagination, and a send/end race using the shared row lock. Verify no account email/token data appears in responses.

### Decisions still needed

- Reconnect/retry after decline/end: recommend disabled for the smallest release; approval needed before making the unconditional index a product rule.
- Ended-thread readability: spec currently implies no access; confirm whether users should retain read-only history.
- Confirm the proposed introduction/message limits (1,000/5,000) and 50-message pages.
- Before frontend launch, set actual production frontend origins and choose the image host/provider; photo uploads remain a later ticket.
- Public anonymous profile preview currently exposes age, availability and all other public fields. Decide whether a reduced anonymous preview is wanted; the product spec leaves external-sharing visibility open.
