# BailaDuo API — API-001, API-002 and API-003

Implemented in Rails 7.1 with Devise 4.9 and Devise Token Auth 1.3. All paths below are relative to the API host. Send `Content-Type: application/json` and `Accept: application/json`. IDs are numeric. Example account details and image URLs are fictional; password and token placeholders must be replaced at runtime.

## Authentication

No cookies or Rails sessions are required. Registration and login return these response headers:

```text
access-token: <opaque secret token>
client: <session identifier>
uid: <account email>
token-type: Bearer
expiry: <Unix timestamp in seconds>
```

Send `access-token`, `client`, and `uid` as separate headers on every authenticated request. Preserve their exact values. Tokens remain stable (no rotation per request), expire after two weeks, and are revoked for that client on logout. Other signed-in clients remain valid. The frontend should clear its credentials on logout or a 401 response. Do not put credentials in URLs or log them. CORS exposes the five headers above. Use HTTPS in production.

| Method | URL | Authentication | Success |
|---|---|---|---|
| POST | `/api/auth` | None | 200, registers and signs in |
| POST | `/api/auth/sign_in` | None | 200, signs in |
| DELETE | `/api/auth/sign_out` | Auth headers | 200, revokes current client |
| GET | `/api/auth/validate_token` | Auth headers | 200, retrieves current account |
| POST | `/api/profile` | Auth headers | 201, creates own profile |
| GET | `/api/profile` | Auth headers | 200, retrieves own profile |
| PATCH | `/api/profile` | Auth headers | 200, updates own profile |
| GET | `/api/profiles` | Auth headers | 200, discovery |
| GET | `/api/profiles/:id` | None | 200, public complete profile |
| GET | `/up` | None | 200, existing Rails health check |

### Register

`POST /api/auth`

```json
{
  "email": "dancer@example.test",
  "password": "<user-entered password>",
  "password_confirmation": "<same password>"
}
```

Passwords must be 8–72 characters and **at most 72 UTF-8 bytes**. Both limits apply: 18 four-byte emoji occupy 72 bytes; 19 exceed the byte limit even though there are only 19 characters. Registration rejects longer passwords with 422 using the existing registration `errors.password` / `errors.full_messages` format. The frontend must count encoded bytes (for example, `new TextEncoder().encode(password).length`) and display server validation errors. `password_confirmation`, if supplied, must match. Email must be valid and unique (case normalized). Successful response is 200 with auth headers:

```json
{"status":"success","data":{"id":1,"email":"dancer@example.test"}}
```

Registration creates only an account. The frontend must next create a profile. Email confirmation, password reset, OAuth, account deletion and credential updates are not exposed in this ticket. No mail service is required.

### Login

`POST /api/auth/sign_in`

```json
{"email":"dancer@example.test","password":"<user-entered password>"}
```

200 with auth headers:

```json
{"data":{"id":1,"email":"dancer@example.test"}}
```

Invalid credentials: 401. Login inputs exceeding 72 UTF-8 bytes are also rejected with the existing invalid-credentials 401 response; password suffixes are never silently ignored.

### Current account

`GET /api/auth/validate_token` with auth headers. 200:

```json
{"success":true,"data":{"id":1,"email":"dancer@example.test"}}
```

Missing, invalid, revoked or expired token: 401. Only this account's ID and email appear in account responses. Public profile responses never include account email, user IDs, password hashes or token storage.

### Logout

`DELETE /api/auth/sign_out` with auth headers. 200:

```json
{"success":true}
```

Missing/invalid session: 404 with `{"success":false,"errors":["User was not found or was not logged in."]}` (library behavior).

Logout reloads and revokes the active client under a user-row lock. Concurrent logouts for different clients both revoke their sessions without restoring each other's tokens; unrelated clients remain signed in. URLs, authentication headers, and response formats are unchanged.

## Own profile

`POST /api/profile` creates the authenticated user's profile. Example body:

```json
{
  "profile": {
    "display_name": "Alex",
    "age": 28,
    "city": "Playa del Carmen",
    "dance_styles": ["bachata", "salsa"],
    "experience_level": "intermediate",
    "availability": "Weekday evenings and weekends",
    "bio": "Looking for regular practice partners.",
    "primary_photo_url": "https://images.example.test/alex.jpg"
  }
}
```

Required fields: all above except `bio`. Validation:

- `display_name`, `city`: nonblank strings, at most 100 characters.
- `age`: integer 18–120, self-reported.
- `dance_styles`: array with 1–10 distinct nonblank strings of at most 50 characters. Styles are trimmed and lowercased; duplicates and blank entries are removed. No fixed style vocabulary.
- `experience_level`: `beginner`, `intermediate`, or `advanced`; trimmed and lowercased.
- `availability`: nonblank free text, at most 500 characters.
- `bio`: optional text, at most 2,000 characters; can be cleared with null or an empty string.
- `primary_photo_url`: public HTTPS response field, at most 2,048 characters. API-003 accepts a verified owned `photo_upload_id` to derive this URL. Legacy URL input is temporary rollout compatibility; see API-003 below.

Text fields are trimmed. Incomplete profiles cannot be saved; an account without a profile is considered not onboarded. An invalid update leaves the existing profile unchanged. Discovery and public lookup additionally exclude incomplete imported/legacy rows.

201 response (the same data shape is used by GET, PATCH and public lookup):

```json
{
  "data": {
    "id": 10,
    "display_name": "Alex",
    "age": 28,
    "city": "Playa del Carmen",
    "dance_styles": ["bachata", "salsa"],
    "experience_level": "intermediate",
    "availability": "Weekday evenings and weekends",
    "bio": "Looking for regular practice partners.",
    "primary_photo_url": "https://images.example.test/alex.jpg"
  }
}
```

`GET /api/profile` retrieves your own profile (200); no profile yet returns 404.

`PATCH /api/profile` updates only supplied fields and returns 200. Example:

```json
{"profile":{"availability":"Weekends","bio":null}}
```

Profile ownership always comes from the authenticated account. `user_id` and `id` in payloads are ignored. There is no PATCH route for `/api/profiles/:id` and no profile deletion endpoint in API-001. A second create returns 409. Missing `profile` envelope returns 400; a non-object envelope returns 400 with `{"errors":["profile must be an object"]}`; invalid profile data returns 422; missing authentication returns 401.

## Discovery and public profiles

`GET /api/profiles?city=Playa%20del%20Carmen&dance_style=bachata&page=1`

- Authentication required; completing your own profile is not required to browse.
- City defaults to your saved profile city. Without that or an explicit nonblank city, returns 400.
- City is matched exactly after trimming and ignoring case; use city names, not slugs.
- Optional `dance_style` matches one normalized style, ignoring case.
- `city` and `dance_style` must be strings when supplied. Arrays/objects return 400 with `{"errors":["city must be a string"]}` or `{"errors":["dance_style must be a string"]}`.
- Excludes the current user's profile and incomplete profiles.
- Fixed 15 profiles per page; `per_page` is not supported (ignored).
- `page` defaults to 1 and must be an integer from 1 to 999999999; otherwise 400.
- Results ordered by ascending profile ID for stable pagination on an unchanged dataset.
- Out-of-range pages return an empty array. With zero matches, `total_pages` is 0. `next_page` is null when there are no more results.

200 example (each element in `data` has the full public profile shape shown above):

```json
{
  "data": [],
  "meta": {
    "page": 1,
    "per_page": 15,
    "total_count": 0,
    "total_pages": 0,
    "next_page": null
  }
}
```

`GET /api/profiles/10` returns the complete public profile shape above without authentication. Nonexistent/incomplete profiles return 404. The profile's age, city and availability are publicly visible. Connection state and gallery media are outside API-001.

## Error formats

Profile/discovery errors use an array of messages. Validation errors additionally include field keys. Example 422:

```json
{"errors":["Age must be greater than or equal to 18"],"fields":{"age":["must be greater than or equal to 18"]}}
```

404: `{"errors":["Not found"]}`.

409: `{"errors":["Profile already exists"]}`.

400 discovery examples: `{"errors":["city is required until you have a profile"]}` or `{"errors":["page must be a positive integer (maximum 999999999)"]}`.

Authentication uses the library's response formats. Invalid login (401):

```json
{"success":false,"errors":["Invalid login credentials. Please try again."]}
```

Unauthorized protected requests (401):

```json
{"errors":["You need to sign in or sign up before continuing."]}
```

Invalid token validation (401):

```json
{"success":false,"errors":["Invalid login credentials"]}
```

Registration validation (422) uses an errors object, not an array:

```json
{"status":"error","data":{"id":null,"email":"invalid"},"errors":{"email":["is not an email"],"full_messages":["Email is not an email"]}}
```

Messages may depend on validation failures; use HTTP status and field keys for client logic. A missing registration body returns 422 with a library errors array. Malformed JSON returns Rails' 400 response.

## Environment, development and deployment

Use Ruby 3.2.2 and the checked-in lockfile:

```sh
bundle install
bin/rails db:prepare
bin/rails server
```

Run tests against a local, isolated PostgreSQL test database:

```sh
RAILS_ENV=test bin/rails db:prepare
bin/rails test
bin/rails zeitwerk:check
```

The test helper configures a fictional CORS origin. Tests generate throwaway passwords. Never point the test environment at production or a shared Neon database. Rails merges `DATABASE_URL` into database configuration; unset it when using local test databases.

For Render, keep the existing Neon `DATABASE_URL`, Rails secret/master-key settings and SSL configuration. Run `RAILS_ENV=production bin/rails db:migrate` as part of the approved release (the existing Docker entrypoint runs `db:prepare`). No changes to Neon connection configuration are required.

Set `FRONTEND_ORIGINS` on Render to comma-separated exact frontend origins, e.g. `https://your-app.netlify.app,https://your-custom-domain.example`. No paths, trailing slash, wildcards or credentials. Empty production configuration permits no cross-origin frontend access. Restart after changes. Development defaults to `http://localhost:5173,http://localhost:3000`; override for other ports. Netlify preview origins must be explicitly listed. CORS exposes auth response headers and allows GET, POST, PATCH, DELETE, HEAD and OPTIONS under `/api/*`; credentials/cookies are not enabled.

Authentication configuration choices: stable two-week tokens simplify React request handling; logout still revokes the active client in PostgreSQL. `bypass_sign_in = false` keeps authentication stateless in this Rails API-only app. API-002 connection and messaging endpoints are documented below. API-003 photo uploads are documented below.

## API-002: connections and persistent text messages

The Devise Token Auth contract above is unchanged. All endpoints below require `access-token`, `client`, and `uid` headers and a complete current-user profile. Missing/invalid authentication returns the existing 401 response; an incomplete current profile returns 403:

```json
{"errors":["Complete your dancer profile first"]}
```

Public profile responses and discovery remain unchanged. Use the authenticated relationship endpoint to obtain viewer-relative actions when opening a dancer profile.

### Endpoints

| Method | URL | Success | Purpose |
|---|---|---|---|
| GET | `/api/connections/relationship?profile_id=10` | 200 | Relationship to the dancer with profile ID 10 |
| POST | `/api/connections` | 201 | Request a connection with a required introduction |
| GET | `/api/connections?filter=incoming&page=1` | 200 | Participant's connection list |
| GET | `/api/connections/:id` | 200 | Participant-only connection detail |
| PATCH | `/api/connections/:id` | 200 | Accept, decline, or end a connection |
| GET | `/api/connections/:connection_id/messages?page=1` | 200 | Accepted participants' message history |
| POST | `/api/connections/:connection_id/messages` | 201 | Send persistent text to an accepted connection |

No DELETE endpoint, reconnect operation, message editing/deletion, or WebSockets are provided. **Disconnection is included through PATCH with `status: "ended"`** because the MVP product spec requires either dancer to be able to end a connection. There is no separate disconnection endpoint.

### Create a connection

`POST /api/connections`

```json
{
  "connection": {
    "recipient_profile_id": 10,
    "intro_message": "Would you like to practice bachata this weekend?"
  }
}
```

Use the public **profile ID**, not an account user ID. `recipient_profile_id` must be a positive decimal integer of at most 18 digits (JSON integer or decimal string). Missing/malformed IDs return 400; missing/incomplete recipient profiles return 404. Requester and recipient must both have complete profiles. Self-requests return 422. The introduction is trimmed, required, and limited to 1,000 characters. It remains on the connection and is readable by the recipient before acceptance; it is not copied into chat history.

Requester always comes from authentication. A supplied requester ID, status, or other unpermitted field is ignored. New connections always start pending. Example 201 response viewed by the requester:

```json
{
  "data": {
    "id": 7,
    "status": "pending",
    "state": "outgoing_pending",
    "direction": "outgoing",
    "actions": [],
    "intro_message": "Would you like to practice bachata this weekend?",
    "requester_profile": {
      "id": 9,
      "display_name": "Sam",
      "age": 27,
      "city": "Playa del Carmen",
      "dance_styles": ["bachata"],
      "experience_level": "beginner",
      "availability": "Weekends",
      "bio": null,
      "primary_photo_url": "https://images.example.test/sam.jpg"
    },
    "recipient_profile": {
      "id": 10,
      "display_name": "Alex",
      "age": 28,
      "city": "Playa del Carmen",
      "dance_styles": ["bachata", "salsa"],
      "experience_level": "intermediate",
      "availability": "Weekday evenings and weekends",
      "bio": "Looking for regular practice partners.",
      "primary_photo_url": "https://images.example.test/alex.jpg"
    },
    "created_at": "2026-11-15T20:00:00.000Z",
    "updated_at": "2026-11-15T20:00:00.000Z"
  }
}
```

POST, GET detail, PATCH, list elements, and the nested relationship `connection` use this same connection shape. Profile objects use API-001's exact public allowlist; account emails, account user IDs, credentials and tokens are never included. Profile objects may be null for externally removed legacy profiles; normal API flows do not delete profiles.

There is exactly **one durable connection row per unordered user pair**, across all statuses. PostgreSQL enforces uniqueness using a unique index on `LEAST(requester_id,recipient_id), GREATEST(requester_id,recipient_id)`. Valid duplicate requests in either direction, including simultaneous cross-requests, return controlled 409 responses:

```json
{"errors":["A connection already exists for these dancers"],"code":"connection_exists"}
```

No additional row is created. Fetch the relationship to obtain the current connection and actions. Declined/ended rows remain permanent and cannot be reopened or replaced.

### Viewer-relative relationship and actions

`GET /api/connections/relationship?profile_id=10` refers only to the current viewer's relationship with that profile. No existing connection:

```json
{"data":{"state":"none","actions":["connect"],"connection":null}}
```

For an existing connection, `connection` is the full connection object above, and outer `state`/`actions` equal that object's fields. An incoming pending result has `state: "incoming_pending"`, `actions: ["accept", "decline"]`, and `connection.intro_message` for the request UI.

| Relationship | `state` | `actions` | UI |
|---|---|---|---|
| No connection | `none` | `["connect"]` | Connect |
| Viewer requested | `outgoing_pending` | `[]` | Request Pending |
| Other dancer requested | `incoming_pending` | `["accept","decline"]` | Introduction and Accept/Decline |
| Accepted | `accepted` | `["message","end"]` | Message / end connection |
| Declined | `declined` | `[]` | Declined; no retry |
| Ended | `ended` | `[]` | Disconnected; no retry |

`direction` on a connection is always `outgoing` for its original requester and `incoming` for its original recipient, including after acceptance. Actions are informational; the server enforces permissions and current state on every operation. Opening your own profile's relationship returns 422 `{"errors":["Choose another dancer"]}`. A nonexistent/incomplete target profile returns 404. Missing/malformed `profile_id` returns 400.

### Connection lists and detail

`GET /api/connections` returns only the viewer's connections, in ascending connection ID order, 15 per page:

```json
{"data":[],"meta":{"page":1,"per_page":15,"total_count":0,"total_pages":0,"next_page":null}}
```

Each nonempty `data` element is the full connection object above. `filter` options:

- Absent or `all`: all statuses, both directions.
- `incoming`: pending requests where viewer is recipient.
- `outgoing`: pending requests where viewer is requester.
- `accepted`: accepted connections in either direction.
- `declined` or `ended`: corresponding status in either direction.

Invalid filters return 400 with `{"errors":["filter must be all, incoming, outgoing, accepted, declined, or ended"]}`. `page` defaults to 1; it must be a positive decimal integer at most 999999999. Page sizes are fixed; `per_page` is ignored. Out-of-range pages return an empty array with counts unchanged and `next_page: null`. Zero matches give `total_pages: 0`.

`GET /api/connections/7` returns `{"data": <connection object>}` for either participant. Nonparticipants and missing records both receive 404 `{"errors":["Not found"]}`. Introductions and connection IDs/state are private to participants.

### Accept, decline and disconnect

`PATCH /api/connections/7`

```json
{"connection":{"status":"accepted"}}
```

The same payload accepts `declined` or `ended`. Response 200 is the updated full connection object in `data`.

| Current status | Target status | Authorized actor |
|---|---|---|
| `pending` | `accepted` | Recipient only; both profiles complete |
| `pending` | `declined` | Recipient only |
| `accepted` | `ended` | Either participant |

All other transitions, including repeating an already completed transition, return 409 `{"errors":["Invalid connection state transition"]}`. A pending requester attempting accept/decline returns 403 `{"errors":["Only the recipient may accept or decline"]}`. A non-string/missing status returns 400 `{"errors":["status must be a string"]}`. Participant IDs and introduction cannot be changed through PATCH.

Transitions run under a PostgreSQL connection-row lock and recheck status after locking. Concurrent acceptance and decline produce one success and one conflict. Ending preserves the connection and its messages, prevents new requests for the pair, and denies subsequent message reads and writes. Pending-request withdrawal is not implemented.

### Send and read messages

`POST /api/connections/7/messages`

```json
{"message":{"body":"Saturday afternoon works for me."}}
```

Body is trimmed, required, and limited to 5,000 characters. Sender always comes from authentication; supplied sender/connection IDs in the body are ignored. Both dancers must still have complete profiles to send. Response 201:

```json
{
  "data": {
    "id": 25,
    "connection_id": 7,
    "sender_profile_id": 9,
    "body": "Saturday afternoon works for me.",
    "created_at": "2026-11-15T20:05:00.000Z"
  }
}
```

`GET /api/connections/7/messages?page=1` returns the same message objects in `data`, sorted chronologically by `(created_at, id)` ascending. It uses the same `meta` shape and page validation as connections, but **50 messages per page**. The oldest messages are on page 1; use `next_page`/`total_pages` for later history. A manual refresh of the latest page(s) retrieves newly persisted messages. There is no polling requirement or real-time transport.

Both message reads and sends require an accepted connection and participant membership. Outsiders/missing connections return 404. A participant attempting either operation in pending, declined, or ended state returns 403:

```json
{"errors":["Messages require an accepted connection"]}
```

Accepted participants with incomplete current profiles receive the global API-002 403 above. Acceptance/message creation also rejects an incomplete other participant with 403 `{"errors":["Both dancers must have complete profiles"]}`. Message history is retained in PostgreSQL after ending but cannot be retrieved through the API while ended.

Message reads and writes check accepted status under the same connection-row lock used by transitions. A simultaneous send/end is serialized: a send committed first may succeed; if ending takes the lock first, the send is denied. No send succeeds after observing ended state. History reads are authorized while holding that lock and may complete before a concurrent end.

### API-002 validation/error summary

- 400: missing/non-object `connection` or `message` envelope, malformed profile IDs/page/filter/status. Example `{"errors":["connection must be an object"]}`. Page errors use `page must be a positive integer` or `page must be at most 999999999`.
- 401: existing Devise Token Auth unauthenticated format.
- 403: incomplete profile, forbidden recipient-only action, or non-accepted messaging, as above.
- 404: missing/incomplete recipient profile, or connection not visible to the viewer.
- 409: existing durable pair (`code: "connection_exists"`) or invalid state transition.
- 422: model validation errors, with the same `errors` array and `fields` object pattern as profile validation.

Example missing introduction:

```json
{"errors":["Intro message can't be blank"],"fields":{"intro_message":["can't be blank"]}}
```

A self-request additionally reports that both dancers must have complete profiles because there must be two distinct complete participants. Use status/field keys rather than exact validation message lists for frontend decisions.

### API-002 migration and release

New migration: `20261115000300_create_connections_and_messages.rb`. It creates both tables, user/connection foreign keys, the unordered-pair unique index, history-ordering index, and database checks for distinct participants, valid statuses, required introduction, and required message body. It does not change API-001 tables or authentication configuration.

For an approved release, apply migrations using the existing production database setup. Verification uses the separate local test database:

```sh
RAILS_ENV=test DATABASE_URL=postgresql:///bailaduo_api_api001_verify_test bundle exec rails db:migrate
RAILS_ENV=test DATABASE_URL=postgresql:///bailaduo_api_api001_verify_test bundle exec rails test
RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 FRONTEND_ORIGINS=https://frontend.example.test bundle exec rails zeitwerk:check
```

The last command checks production autoloading with a dummy build secret and fictional CORS origin; it is not a deployment. Production continues to require the real exact frontend origins and existing Render/Neon credentials. API-002 requires no additional gems or environment variables.

## Automated verification and launch tracking

The `Rails CI` GitHub Actions workflow runs on pull requests, pushes to `main`, and manual dispatch. Its `Rails / PostgreSQL` job uses Ruby from `.ruby-version`, the locked bundle, and an ephemeral PostgreSQL 16 test database. It runs migrations, the full Rails suite (including authorization, concurrent requests/transitions, and logout/login persistence), and production autoloading with a dummy build secret. CI does not use Neon, deploy, or require production secrets.

Launch status and browser/deployment evidence belong in [launch issue #5](https://github.com/willshepp28/bailaduo-api/issues/5) and its linked tickets. Passing backend tests does not establish React browser integration or production readiness. One owned Cloudflare Images primary-photo upload is required for launch through API-003/WEB-003. Extra galleries, videos, scheduling, and real-time messaging remain deferred.

## API-003: owned primary-photo uploads

All photo endpoints require existing Devise Token Auth headers. **A completed profile is not required**, so signup can proceed to photo upload during onboarding. No provider credentials are exposed to the browser. The existing `primary_photo_url` public response field and API-001/API-002 authentication remain unchanged.

### Endpoints and flow

| Method | URL | Success | Behavior |
| --- | --- | --- | --- |
| POST | `/api/photo_uploads` | 201 | Issue one short-lived upload authorization |
| GET | `/api/photo_uploads/:id` | 200 | Read your upload's current stored status; does not call Cloudflare |
| POST | `/api/photo_uploads/:id/complete` | 200 | Ask Rails to verify actual provider completion, format and size |
| DELETE | `/api/photo_uploads/:id` | 200 | Cancel/delete your unreferenced upload; never deletes a referenced photo |

1. Request authorization with declared file MIME/size (JSON number, not a string):

```json
{"photo_upload":{"content_type":"image/png","byte_size":12345}}
```

Only `image/jpeg`, `image/png`, `image/webp` and sizes 1–5,000,000 are accepted. Declarations are checked at issuance, but never establish validity/ownership. Cloudflare enforces its hosted-image constraints (including a 10 MB hard ceiling); Rails streams the provider's original under a 5 MB cap and checks its file signature before allowing attachment. Bypassing browser checks cannot attach oversized/unsupported content. No image binaries are stored in the database or application filesystem.

201 example (authorization is returned **once**, not stored or returned by GET):

```json
{
  "data": {
    "id": 21,
    "status": "pending",
    "expires_at": "2026-11-16T14:10:00.000Z",
    "claim_expires_at": "2026-11-17T14:10:00.000Z",
    "primary_photo_url": null,
    "content_type": null,
    "byte_size": null,
    "upload_url": "<one-time HTTPS URL returned by Cloudflare>"
  },
  "limits": {"max_bytes":5000000,"content_types":["image/jpeg","image/png","image/webp"]}
}
```

2. POST a multipart `file` directly to `upload_url`. **Do not send Rails authentication headers or the Cloudflare API token to that host.** Use the returned URL exactly; do not construct it. Do not log/store/share it in GitHub, telemetry or persistent browser storage. The upload authorization expires after 10 minutes and is single-use. Retry by obtaining a new authorization, not by inventing an image ID.
3. Call `POST /api/photo_uploads/21/complete` with auth headers and no body. Rails checks the owned database record, intended account/app/environment, Cloudflare draft/completion status, configured BailaDuo variant, and actual original bytes. A client-asserted upload success, provider ID, delivery URL or metadata is not proof. Pending provider processing returns 409 and can be retried until expiry.

200 confirmation example:

```json
{
  "data": {
    "id":21,
    "status":"ready",
    "expires_at":"2026-11-16T14:10:00.000Z",
    "claim_expires_at":"2026-11-17T14:10:00.000Z",
    "primary_photo_url":"https://imagedelivery.net/<configured-account-hash>/<server-issued-image-id>/bailaduo-development-profile",
    "content_type":"image/png",
    "byte_size":12345
  }
}
```

`GET` returns this shape without `upload_url`/`limits`, reflecting the current stored status. Completion is idempotent for ready/attached photos. Pending uploads cannot be confirmed after `expires_at`; verified, unattached photos must be selected before `claim_expires_at`. Attached photos remain valid after both timestamps.

4. Submit the returned **Rails photo-upload record ID** as `profile.photo_upload_id` with the existing profile creation/update endpoint. For onboarding:

```json
{
  "profile": {
    "display_name":"Alex",
    "age":28,
    "city":"Playa del Carmen",
    "dance_styles":["bachata"],
    "experience_level":"beginner",
    "availability":"Weekends",
    "photo_upload_id":21
  }
}
```

Replacement: `PATCH /api/profile` with `{"profile":{"photo_upload_id":22}}`. A valid integer/string ID is required, never a Cloudflare image ID. Server ownership/environment lookup is enforced even if the upload ID is known. Profile save also verifies a pending upload if completion was not called separately; using the explicit completion endpoint gives the frontend clearer upload/error states.

Rails derives `primary_photo_url` from the verified record, ignoring any simultaneously supplied URL. Successful profile responses keep the exact existing public profile shape; internal upload/provider IDs are not added to public profiles. Upload state becomes `attached`. Update other profile fields as before; omit `photo_upload_id` to retain the photo. Failed verification or profile validation rolls back the attachment and leaves the previous profile/photo intact.

### Ownership, states, quotas and cleanup

Upload states are `issuing` → `pending` → `ready` → `attached`. Issuance failures leave `failed` owned records for safe cleanup. A replaced photo becomes `superseded`; deletion results in `deleted`. Provider errors do not create simulated completion. All upload responses use `Cache-Control: no-store`.

The server generates and records provider IDs, ownership, app, environment and account identity before contacting Cloudflare. Every provider operation checks that record; client-supplied IDs/metadata cannot claim another asset. Foreign-user/app/environment/account references return 404. Unrelated/invalid provider IDs are refused before network access. The implementation never lists account assets or changes variants, signing keys or JabNGo settings.

Per user: at most **5 authorizations/hour**, **20/day**, and **3 active issuing/pending/ready slots** before upload expiry. Failed/deleted requests still count toward hourly/daily issuance totals. User-row locking prevents concurrent quota bypass. Quotas are fixed for this release. A full quota returns 429, `Retry-After: 3600` and `code: "upload_quota_exceeded"`. Cancel unused records through DELETE; cancellation does not reset issuance quotas.

DELETE verifies ownership, rejects any current profile reference with 409, and returns the owner-data shape with `status: "deleted"` and `primary_photo_url: null`. Repeated deletion is idempotent. No profile deletion endpoint is added. Replacement cleanup runs only after a successful committed profile change. Provider failures leave superseded records for the bounded `photos:cleanup` task; they do not roll back the new profile or delete the previous photo before success. Cleanup waits 24 hours after expiry for abandoned uploads and acts only on unreferenced, known BailaDuo records for the configured environment/account, at most 50 per invocation. Imported URL references are also protected. See README for operator setup and the opt-in real-provider smoke check.

### Error behavior

Photo/profile-upload errors use `{"errors":["message"]}`; ordinary profile validation retains `errors` plus `fields`. Relevant statuses:

- 400: missing/non-object `photo_upload` payload or malformed `photo_upload_id`.
- 401: existing Devise Token Auth format; no profile-completion gate on upload endpoints.
- 404: missing upload, foreign ownership/app/environment/account.
- 409: provider upload not complete yet, or attempted deletion of a referenced photo.
- 410: pending authorization expired or unattached verified photo's claim window expired; choose/re-upload the file.
- 422: unsupported/oversized declared or actual file, unusable/deleted/failed record, unverified photo reference, or invalid profile fields.
- 429: quota exceeded, e.g. `{"errors":["Photo upload limit reached; cancel unused uploads or try again later"],"code":"upload_quota_exceeded"}`.
- 502: provider request/verification/deletion failure; sanitized retry message, no provider body/secret URL.
- 503: BailaDuo Images configuration missing/invalid. Do not fall back to demo data or invent success.

### Rollout compatibility

`BAILADUO_REQUIRE_MANAGED_PHOTOS` defaults to false/unset during coordinated rollout. This temporarily allows existing URL-only clients to create/edit legacy HTTPS photos. New/changed raw Cloudflare delivery URLs are rejected even in this mode: they are not owned upload references. A managed photo can never be replaced by a pasted URL.

Once WEB-003 is verified/deployed, set the flag exactly `true`: new profiles and photo replacements require `photo_upload_id`. Existing legacy photos remain visible; unchanged photo URLs and non-photo edits remain supported. Do not infer/backfill ownership from existing URLs. Deploy the additive backend migration/configuration first, integrate the frontend, then enable enforcement; see README. Auth endpoints, discovery, public profiles and connections continue using their existing contracts. Real Cloudflare credentials, a new BailaDuo delivery variant and the real-provider smoke check are prerequisites for claiming photo release readiness.

Provider references: [Direct creator uploads](https://developers.cloudflare.com/images/storage/upload-images/direct-creator-upload/), [hosted image limits/formats](https://developers.cloudflare.com/images/get-started/limits/). Metadata/names are organizational only; Images permissions remain account-scoped.
