# BailaDuo — Product Specification

**Version:** 0.1\
**Status:** Design-ready working specification\
**Date:** November 15, 2026\
**Purpose:** Define the MVP user experience for a high-fidelity, clickable mobile-first prototype, then guide implementation. This document distinguishes confirmed product decisions from proposed scope cuts and unresolved implementation details.

## 1. Product overview

**BailaDuo** helps dancers discover compatible practice partners in their city, connect with mutual consent, and coordinate practice through private messages. It launches in **Playa del Carmen, Mexico**, initially emphasizing **bachata**, while allowing other dance styles.

BailaDuo is **not** a dating app, follower network, class booking platform, or social-content feed. Its primary promise: **find someone to practice dancing with**—for a first session or a recurring partnership.

**Primary audience:** Adult social dancers who want more practice outside group classes and socials, whether beginner, intermediate, or advanced.

**Primary distribution channel:** Instagram, including the @getbailaduo account and dancer-shared profiles.

## 2. MVP success criterion

A real user should be able to:
1. Register and log in.
2. Complete a dancer profile before becoming discoverable or initiating connections.
3. Discover other dancers in a chosen city and open an individual profile.
4. Send a connection request with a required introductory message.
5. Receive an in-app connection request and accept or decline it.
6. Exchange persistent private text messages after acceptance, using manual refresh rather than real-time chat.
7. Share a public profile URL to invite others to discover BailaDuo.

**Demo goal:** Show the end-to-end journey with two different accounts on a phone. A clickable design prototype may simulate data, but production functionality must use real authentication, a database, and access controls.

## 3. Core user journeys

### Journey A — New dancer
Welcome → Register/login → Complete required profile → Discover dancers in selected city → View profile → Send connection request with introduction → See Pending state.

### Journey B — Recipient
Login → View incoming request in Connections/Requests, or open the sender's profile → Read introduction and see sender's profile → Accept or Decline.

### Journey C — Accepted dancers
Open accepted connection → One ongoing private conversation → Send/receive messages → Arrange one or many practice sessions informally in chat.

### Journey D — Instagram discovery
User shares public profile link or branded profile card → Visitor opens a limited public profile preview → Selects Connect → Registers/logs in if necessary → Completes profile → Returns to the originally viewed dancer's profile.

## 4. Account and dancer profile

### User account
- Email and authentication credentials managed using an established Rails authentication library (Devise Token Auth is the leading candidate; compatibility to be confirmed during implementation).
- Logout and authenticated session management.
- Account data remains private; email never displayed on public dancer profiles.

### Dancer profile
**Required at onboarding**
- Display name.
- Primary profile photo.
- Age (self-reported; adult-only initial product).
- City/location (city-level, no precise GPS required).
- At least one dance style (bachata first; other styles possible).
- Experience level.
- General availability (e.g., weekday evenings, weekends).

**Optional**
- Bio / practice goals.
- Additional photos: up to **five photos total**, including primary photo.
- Dance clips: product supports up to **five optional videos** in the longer-term design; full video uploading is not required for the first launch.

**Behavior**
- Users must finish required onboarding before appearing in discovery or sending requests.
- Other dancers can review name, age, city, styles, experience, availability, and shared gallery content before accepting.
- Users can edit their own profiles and manage their photos.
- Use the actual provided BailaDuo logo and branding, not a replacement.
- A profile photo helps identification but is not identity verification.
- Public link previews should avoid exposing email, messages, precise location, and other private data. Design may give users control over whether age or other optional details appear on externally shared cards.

## 5. Discovery

- Default city is the authenticated user's saved profile city; user may change the city selection.
- Fetch/display **15 dancer profiles per page**; use pagination or Load More.
- Each result shows enough information for evaluation: primary photo, display name, age, city, dance style(s), and experience level.
- Selecting a card opens the complete dancer profile.
- Support an initial dance-style filter if it can be delivered simply; no algorithmic matching required.
- Exclude incomplete profiles and the current user's own profile from discovery results.
- Provide loading, zero-results, and basic error states.

## 6. Connection model — CONFIRMED: Connect once, message continuously

A **Connection** represents a durable relationship between two users, not an individual practice session.

- A user visits another dancer's profile, selects **Connect**, and must write an introductory message.
- Recipient sees the introduction and the sender's profile before deciding.
- Recipient may **Accept** or **Decline**.
- When accepted, both users can message in **one persistent thread** for this connection. They may arrange multiple practices in that same conversation.
- Acceptance allows communication; it **does not** imply agreement to meet or practice.
- At most **one active relationship/request per unordered pair of users**, regardless of request direction.
- If an incoming request already exists, the recipient visiting the sender's profile sees **Accept / Decline**, not an option to create a reciprocal request.
- Either user can end a connection, which prevents additional messages; a full reconnect/retry policy can be decided later.

### Profile action states
| Relationship relative to current user | Primary action |
|---|---|
| None | Connect |
| Outgoing pending | Request Pending |
| Incoming pending | Accept / Decline, displaying introduction |
| Accepted | Message |
| Declined / ended | Clear non-messaging state; exact retry UX deferred |

### Essential server-side behavior
- Only the intended recipient can accept or decline a pending request.
- Only participants may access their connection information.
- Only participants in an accepted connection may read or send its messages.
- Prevent duplicate active connections, including simultaneous cross-requests.
- No infinite/request spam by repeatedly creating duplicate pending records.

## 7. Messaging

- Private 1:1 text messages between accepted connections.
- Persist messages in PostgreSQL.
- Display message history in chronological order with sender and timestamp.
- Send message and refresh messages using regular HTTP API calls.
- A visible **Refresh** affordance is acceptable; live delivery is **not required**.
- No WebSockets, push notifications, read receipts, media attachments in chat, typing indicators, or per-session threads in v0.1.
- Only authenticated authorized users may view or send messages.

## 8. Instagram-first growth and sharing

**Recommended launch-oriented UI:**
- A stable shareable public URL for each dancer profile.
- **Share Profile / Copy Link** action.
- **Invite a Dancer** action using a shareable link.
- A limited public profile preview for nonmembers, with a clear sign-up CTA and return-to-profile behavior.

**Design for future / only if time permits:**
- Downloadable **Instagram Story-sized dancer profile card** that uses the person's selected public photo and information.
- Dance video previews.
- Shareable practice/partner success stories and instructor/community invitations.

Do not assume a web page can automatically publish an Instagram Story with a clickable sticker. A realistic flow is to download/copy content and share through Instagram.

## 9. Required prototype screens

1. **Welcome and Authentication** — value proposition, signup, login.
2. **Profile Onboarding** — photo, required information, optional bio; validation.
3. **Discover Dancers** — city-focused listing, 15/page, cards, basic filters, empty state.
4. **Dancer Detail** — gallery, availability, optional video placeholder, connection-state CTA, share profile.
5. **Connection Request Composer** — required introduction, confirmation/pending state.
6. **Connections / Requests** — incoming, outgoing pending, accepted, accept/decline.
7. **Messaging / Conversation** — messages, composer, refresh; only for accepted connections.
8. **My Profile / Edit Profile** — public preview, edit details, photos, share/invite.
9. **Public Profile Preview** — limited nonmember view reached from shareable links, with signup/login and return path. This may reuse Dancer Detail rather than being a fully independent screen.

All interactions should be clickable in the prototype, with realistic fictional accounts and clear state transitions.

## 10. Visual and interaction direction

- **Mobile-first** responsive web app; polished on iPhone-size screens and usable on desktop.
- Brand personality: warm, energetic, inviting, dance-focused, trustworthy; not a dating-app imitation.
- Start with the existing **BailaDuo** brand: deep burgundy/red handwritten logo on a warm cream background. Extract exact colors from the actual supplied assets; do not treat placeholder hex codes as final brand tokens.
- Photo-forward dancer cards and profile galleries.
- Obvious navigation among Discover, Connections, Messages, and My Profile.
- Clear CTA hierarchy and status feedback for requests.
- Include loading, empty, error, and success states.
- Use realistic sample data and photos for which usage is allowed; do not present sample personas as real enrolled dancers.

## 11. Technical implementation constraints (context for design)

- Two separate repositories: **React frontend** and **Ruby on Rails REST API backend**.
- Database: **PostgreSQL on Neon** (separate BailaDuo project/database from JABNGO).
- Hosting: **Netlify frontend**, **Render Free backend** (cold starts acceptable for MVP).
- Authentication: established Rails auth library; no bespoke auth protocol.
- Initial conceptual models: `User`, `Profile`, `Connection`, `Message`; add a small `ProfileMedia` association for multiple uploads if implementing gallery management.
- Media stored with a managed service, not as binaries inside PostgreSQL or ephemeral Render filesystem. Cloudflare is a possible existing service, but exact account/product still needs confirmation.
- The prototype should be HTML/CSS/JavaScript with **mock state**; the production app must implement authorization and persistence through Rails.

### Proposed illustrative REST API operations (not a binding final contract)
| Method | Endpoint | Use |
|---|---|---|
| GET | `/api/profiles?city=playa-del-carmen&page=1&per_page=15` | City discovery |
| GET | `/api/profiles/:id` | Public profile + current viewer's connection state |
| POST | `/api/connections` | Request connection with introduction |
| GET | `/api/connections` | List incoming/outgoing/accepted connections |
| PATCH | `/api/connections/:id` | Accept or decline request |
| GET | `/api/connections/:id/messages` | Retrieve messages |
| POST | `/api/connections/:id/messages` | Send message |

Authentication, current-profile management, photo upload authorization, and public share-link endpoints will also be needed; exact paths may follow library conventions.

## 12. Scope priorities for fast launch

### P0 — Must work to validate the product
- Real registration/login and required profile onboarding.
- City-based discovery and dancer detail.
- Connection requests and incoming accept/decline.
- Persistent messaging for accepted connections.
- Deploy and verify with two accounts.

### P1 — High-value, include if it does not endanger P0
- Additional photo gallery with up to five images.
- Public profile link, Copy Link, Invite a Dancer.
- Profile editing / primary photo selection.

### P2 — After first release unless already trivial
- Full user-uploaded dance video workflow (up to five).
- Automatically generated Instagram Story share cards.
- Advanced filters, referrals analytics, sophisticated moderation, practice-session scheduling.

**Time constraint:** Build the smallest real app that supports the complete connection journey. If time runs short, keep the UI attractive but narrow the feature set rather than replacing real behavior with fake production flows.

## 13. Explicit exclusions

No followers/following graph, dating or matching swipe system, algorithmic compatibility ranking, class booking, calendar scheduling, payments, public content feed/posts/comments, WebSockets, push notifications, or gamification for the initial launch.

## 14. Open questions — not blockers for prototype

- Final media provider and upload integration (Cloudflare Images/Stream vs. other managed service).
- Exact age input format and external sharing visibility.
- Reconnect/retry behavior after a declined or ended relationship.
- Exact REST payloads, migrations, and Devise integration/version compatibility.
- Whether a video can be seeded manually as a demo clip before uploads are supported.

These should be decided when implementing the relevant feature, not before creating UI screens.

## 15. Deliverable requested from Claude

Produce a **single clickable, high-fidelity mobile-first HTML/CSS/JavaScript prototype** (or a well-organized small set of files) that demonstrates the full BailaDuo journey with realistic fictional profiles and in-memory/mock data. Simulate two users so the incoming request → acceptance → messaging transition can be inspected. Include mobile and desktop responsive states, public-profile sharing, and a coherent reusable visual system. **Do not connect a backend or imply that mock signup/messages are real.**

The approved prototype will be handed to Codex as the visual and interaction reference for the actual React frontend and Rails API.
