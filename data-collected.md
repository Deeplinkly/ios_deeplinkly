# Deeplinkly data collection inventory

**Audit date:** 16 August 2026. **Revised:** 27 August 2026 (catalogue version 9).  
**Status:** Working inventory for integrating customers; not approved legal text  
**Product owner shown publicly:** Apexnova Private Limited / Deeplinkly  
**SDKs reviewed:** `flutter_deeplinkly` 1.11.0, `android_deeplinkly` 1.3.0, `ios_deeplinkly` 1.2.0, `react_native_deeplinkly` 1.2.0  
**Other evidence reviewed:** the live Deeplinkly website, privacy policy, terms, public application bundles, DNS, response headers, and public SDK/API behavior

> **This file is one document kept in five places.** It is distributed by
> `dart run tool/gen_signals.dart` from the copy in `flutter_deeplinkly`, and
> `--check` fails if any copy has drifted. Edit the Flutter copy and regenerate;
> editing any other copy directly will be overwritten. The reason it is not
> simply "the same file, four times, by hand" is that hand-maintained copies of
> a shared list drift, silently, and this is the copy a data-protection
> authority would read.

This is the inventory of personal data and other information processed by the Deeplinkly mobile SDKs and service, written for the teams who integrate them. It is deliberately broader than the 86-field SDK signal catalogue: privacy notices and app-store disclosures must also cover functional API calls, customer-supplied content, click-side data, account and billing data, diagnostics, local storage, and third parties.

> **Scope.** SDK behaviour here is read from the reviewed SDK source. Server-side
> behaviour is described by category — what is held, how long, and how it is
> protected — rather than by internal schema, and covers the service as
> operated by Deeplinkly. Statements about the website, account, and billing
> surfaces come from public policy and publicly observable behaviour. This
> inventory supports, but does not replace, Deeplinkly's privacy policy, DPA,
> and subprocessor notice.

Evidence labels used here mean: **code-confirmed** (present in the reviewed SDK source), **policy-confirmed** (stated by Deeplinkly's current public policy), **live-observed** (visible in production-facing network/DNS/client code on the audit date), and **inferred** (necessary or strongly indicated, but not verified against running infrastructure or contracts).

## Executive findings

1. The shared catalogue contains **86 enrichment signals**: 30 Minimal, 34 additional Reduced, and 22 additional Full. The four checked-in catalogue JSON files are byte-for-byte identical (SHA-256 `f699036f4439f8a667a5cd483877f45e7c2306464d8a1f64d5e205077436f3fb`, catalogue version 9).
2. **Full is the default attribution level** unless the integrating app changes it in its manifest/plist or at runtime. Automatic startup/app-open reporting occurs without a link click.
3. **`NONE` does not mean “no data leaves the device.”** Link resolution and link generation still call Deeplinkly and include a stable Deeplinkly device ID, tenant API key, optional custom user ID, public IP/network metadata visible to the server, and the functional request data. Global tracking-disabled mode is stricter: functional calls continue but omit the stable Deeplinkly and custom user IDs.
4. `NONE` suppresses `/enrich` device reports but still permits developer-configured event names and parameters unless tracking is globally disabled. A custom event at `NONE` has no catalogue-derived device block, but the standard request identifiers still apply.
5. Developer-controlled fields can contain personal or sensitive data even though the SDK does not create that data: custom user IDs, event properties, generated-link metadata, deep-link parameters, error messages, and stack traces. Technical length limits are not a privacy filter.
6. **Catalogue version 9 adds eleven directly identifying fields.** `setUserData()` accepts email, phone, first and last name, date of birth, gender, street, city, state, postal code and country. Unlike every other catalogue entry these are not observations about a device — they are personal data the integrating app already held and chose to pass on. They are classified **Minimal**, so they ship at every level except `NONE`, on the reasoning that the attribution tiers gate device observation rather than first-party identity. They travel over TLS and are held encrypted at rest; they are **not hashed** in storage, and are hashed only when a conversion is forwarded to an advertising destination. Three consequences for an integrating app: Deeplinkly holds directly identifying data on your behalf rather than pseudonymous identifiers; these fields are in scope for access and erasure requests; and the lawful basis for each field is the integrating app's to establish, not Deeplinkly's. `clearUserData()` erases them on the device and instructs the service to erase the stored values — the one erasure path in the product that an SDK call can trigger. **code-confirmed** as of 27 August 2026.
7. Android sends the **raw Google Play Install Referrer string at Minimal**. That string can contain arbitrary parameters supplied by a campaign, not merely the named UTM and ad-click fields.
8. iOS automatic pasteboard inspection is **enabled by default**, once per install. It reads URL/string content, accepts only a URL on an allowed Deeplinkly domain with a click ID/code, stores the accepted URL locally, and clears the pasteboard after an automatic accepted read. Reading may cause Apple’s paste notification. The optional `UIPasteControl` path is user initiated and does not clear the pasteboard.
9. The iOS Deeplinkly device ID is stored in Keychain and normally **survives app uninstall/reinstall**. Android stores its UUID in shared preferences, which may participate in Android backup/restore. SDK versions audited here now expose `resetPrivacyData()` to delete these identifiers and other local SDK data while leaving tracking disabled.
10. Deeplinkly uses **deterministic attribution only**: click IDs, short codes, and Android Play Install Referrer. The product owner confirms probabilistic/device-fingerprint matching has been retired, and the reviewed SDKs contain no matcher or device-profile input on `/resolve`. Any remaining public or internal language claiming otherwise is stale and must be removed.
11. **The public policy names its recipients.** As of the 15 August 2026 policy, Deeplinkly publicly names AWS (Mumbai-region hosting and storage, CloudFront delivery, SES email), ZeroBuffer.io for static-asset delivery, Google Firebase for website and dashboard analytics, Google Workspace for company email, Google and GitHub OAuth, Stripe for customers outside India and Razorpay for customers in India, and Sentry for error monitoring. The table below cross-checks that list against what is technically observable. It remains a working inventory rather than the contractual subprocessor notice; the DPA governs.

## Roles and data subjects

| Context | Likely role | Data subjects |
|---|---|---|
| Customer app attribution, deep linking, events, and reporting | Customer is normally controller/business; Deeplinkly is normally processor/service provider. The DPA and actual instructions control. | Customer app users, link clickers, installers, and re-engaged users |
| Deeplinkly website, account, billing, security, support, and marketing | Deeplinkly is normally controller/business | Prospects, customers, account users, payers, and support contacts |
| Customer-directed integrations, exports, or webhooks | Depends on the integration; recipient may be another processor or independent controller | Customer app users and account users represented in the exported data |

## Tier behavior at a glance

The SDK tiers are cumulative: Reduced includes Minimal; Full includes Minimal and Reduced. Availability is conditional on platform APIs, permissions, host-app configuration, consent state, and whether a value exists.

| Effective mode | Catalogue enrichment sent | Events | Functional resolve/generate calls | Important qualification |
|---|---|---|---|---|
| Tracking disabled (`setTrackingEnabled(false)`) | No new enrichment | New events and SDK error reports are blocked; pending reporting retries are deleted | **Still sent without stable/custom identity headers** | iOS pasteboard checking is skipped. Both platforms reject new retry entries and re-check opt-out during drains. The tenant key, functional request data, public IP, and ordinary network metadata remain. |
| `NONE` attribution level | None | Event name + developer parameters still sent; no catalogue device block | **Still sent** | This is data minimization, not a global opt-out. |
| Minimal | 19 catalogue fields when available | Event data plus Minimal device block | **Still sent** | Includes stable/install IDs, timestamps, link identity, optional custom ID, iOS ATT state, and Android raw install referrer. |
| Reduced | Minimal + 32 fields when available | Event data plus Reduced device block | **Still sent** | Adds OS/environment, locale/time zone/network, emulator flags, campaign/ad-click IDs, and Android install timing. |
| Full (default) | Reduced + 22 fields when available | Event data plus Full device block | **Still sent** | Adds hardware/device characteristics and optional platform advertising/vendor identifiers and local LAN IP. |

Every Deeplinkly API request also exposes ordinary transport metadata to the receiving infrastructure, including the source/public IP address, request time, TLS/HTTP characteristics, endpoint, response status, and potentially server-derived approximate location. Android adds a random `X-Request-Id`. These are not governed by the enrichment catalogue.

Disabling tracking cannot recall a reporting request that the operating system
has already dispatched; such an in-flight request may complete. The opt-out
blocks subsequent reporting dispatches, purges pending reporting retries, and
prevents an in-flight failure from creating a new retry item.

## Tier 1 — Minimal (30 catalogue fields)

These fields can be sent to `/enrich` and in an event's device block at Minimal, Reduced, and Full. “Static” values are cached locally and recollected when the profile stamp changes; “dynamic” values are sampled for reporting; “identity” values describe the user/link/campaign.

| Field | Platform | Scope and meaning |
|---|---|---|
| `deeplinkly_device_id` | Android, iOS | Deeplinkly-generated stable identifier. Android: preferences UUID. iOS: Keychain UUID that normally survives reinstall. Also sent as `X-Deeplinkly-User-Id` on API requests, including resolve/generate at `NONE`, but omitted while global tracking is disabled. |
| `install_instance_id` | Android, iOS | Random identifier for the current installation instance; stored in preferences/UserDefaults. |
| `platform` | Android, iOS | Operating platform. |
| `app_id` | Android, iOS | Android application/package ID or iOS bundle ID. |
| `app_version` | Android, iOS | Customer app release version. |
| `app_build_number` | Android, iOS | Customer app build/version code. |
| `installed_at` | Android, iOS | Approximate install time. Android uses package first-install time; iOS derives it from the app Documents directory creation timestamp. |
| `sdk_version` | Android, iOS | Native Deeplinkly SDK version. Flutter uses the native Android/iOS SDK and does not add a separate network payload. |
| `static_profile_version` | Android, iOS | Hash/stamp used to detect profile changes. Android's stamp includes build fingerprint as an input, but the raw fingerprint is not a catalogue field. |
| `collected_at` | Android, iOS | Time the report was assembled. |
| `last_opened_at` | Android, iOS | Time the app was most recently opened/reported. |
| `session_id` | Android, iOS | Random Deeplinkly session identifier; sessions roll after about 30 minutes of inactivity. |
| `attribution_level` | Android, iOS | Effective reporting tier, allowing the backend to interpret a deliberately thin payload. |
| `att_status` | iOS | App Tracking Transparency authorization state. The SDK reads the state but does not itself display the ATT prompt. |
| `custom_user_id` | Android, iOS | Optional customer-supplied identifier. Also sent as `X-Deeplinkly-Custom-User-Id` on API requests after it is set, except while global tracking is disabled. It may become directly identifying if a customer supplies email, phone, account ID, or another identifier. |
| `click_id` | Android, iOS | Deeplinkly click/token identifier from a link, pasteboard, or referrer. |
| `code` | Android, iOS | Deeplinkly short-link/code identifier. |
| `source` | Android, iOS | Attribution/lifecycle source such as a link, install referrer, pasteboard/clipboard, app start, or app open. |
| `install_referrer` | Android | **Raw Google Play Install Referrer string.** It can include the complete campaign-supplied query and therefore arbitrary values beyond Deeplinkly's named fields. |
| `user_email` | Android, iOS | **Directly identifying.** Email address supplied by the integrating app via `setUserData()`. Transmitted over TLS and stored encrypted at rest; not hashed in storage, and hashed only when a conversion is forwarded to an advertising destination. |
| `user_phone` | Android, iOS | **Directly identifying.** Phone number supplied via `setUserData()`. Encrypted at rest but not hashed, as above. |
| `user_first_name` | Android, iOS | **Directly identifying.** Supplied via `setUserData()`. |
| `user_last_name` | Android, iOS | **Directly identifying.** Supplied via `setUserData()`. |
| `user_date_of_birth` | Android, iOS | **Directly identifying, and an age indicator.** `YYYY-MM-DD`, supplied via `setUserData()`. Combined with a name or address this is a strong identifier; on its own it may also bring minors into scope. |
| `user_gender` | Android, iOS | **Special-category-adjacent.** Restricted by the SDK to `m` or `f`, the only two values Meta's `ge` parameter accepts. Supplied via `setUserData()`. |
| `user_street` | Android, iOS | **Directly identifying.** Street address supplied via `setUserData()`. |
| `user_city` | Android, iOS | Supplied via `setUserData()`. Identifying in combination with the other address fields. |
| `user_state` | Android, iOS | Supplied via `setUserData()`. |
| `user_zip` | Android, iOS | Supplied via `setUserData()`. Identifying in combination, and on its own a coarse location. |
| `user_country` | Android, iOS | ISO-3166-1 alpha-2, supplied via `setUserData()`. |

## Tier 2 — Reduced (34 additional catalogue fields)

Reduced sends all Minimal fields plus the following when available.

| Field | Platform | Scope and meaning |
|---|---|---|
| `os_version` | Android, iOS | Operating-system version. |
| `sdk_int` | Android | Android API level. |
| `installer_package` | Android | Package/source that installed the app. |
| `first_app_version` | Android, iOS | App version recorded on first Deeplinkly open. |
| `first_open_at` | Android, iOS | First Deeplinkly open time. |
| `environment` | Android, iOS | Runtime environment, including full app versus instant/App Clip where applicable. |
| `device_class` | Android, iOS | Coarse form factor/class, such as phone or tablet. |
| `is_hardware_id_real` | Android, iOS | Whether an available device/vendor identifier appears to be a real hardware-backed/non-placeholder value. |
| `is_emulator` | Android, iOS | Emulator/simulator indicator. |
| `referrer_click_at` | Android | Click time reported by Google Play Install Referrer. |
| `install_begin_at` | Android | Install-begin time reported by Google Play Install Referrer. |
| `google_play_instant` | Android | Whether Google Play reports an Instant experience. |
| `referrer_install_version` | Android | App version associated with the install-referrer response. |
| `android_reported_at` | Android | Android-side report timestamp. |
| `ios_reported_at` | iOS | iOS-side report timestamp. |
| `locale` | Android, iOS | Device locale. |
| `language` | Android, iOS | Preferred/device language. |
| `region` | Android, iOS | Locale region/country code; not GPS location. |
| `timezone` | Android, iOS | Time-zone identifier. |
| `timezone_offset_min` | Android, iOS | UTC offset in minutes. |
| `connection_type` | Android, iOS | Coarse network type. On Android it is only available if the host app has the relevant network-state permission. |
| `ui_mode_night` | Android, iOS | Dark/night appearance setting. |
| `limit_ad_tracking` | Android, iOS | Advertising-limitation/authorization indicator where the platform exposes it. |
| `unidentified_device` | Android, iOS | Indicator that an expected platform/device advertising identity is unavailable. |
| `utm_source` | Android, iOS | Campaign source. |
| `utm_medium` | Android, iOS | Campaign medium. |
| `utm_campaign` | Android, iOS | Campaign name/identifier. |
| `utm_term` | Android, iOS | Campaign/search term; may contain customer or campaign-entered content. |
| `utm_content` | Android, iOS | Campaign content variant; may contain customer or campaign-entered content. |
| `gclid` | Android, iOS | Google advertising click identifier. |
| `fbclid` | Android, iOS | Meta/Facebook click identifier. |
| `ttclid` | Android, iOS | TikTok click identifier. |
| `gbraid` | Android, iOS | Google Ads click identifier for iOS app campaigns and web-to-app journeys, sent in place of `gclid` when no device advertising identifier is available. |
| `wbraid` | Android, iOS | Google Ads click identifier for web-to-app journeys, sent in place of `gclid` when no device advertising identifier is available. |

## Tier 3 — Full (22 additional catalogue fields)

Full is the current default and sends all Minimal and Reduced fields plus the following when available.

| Field | Platform | Scope and meaning |
|---|---|---|
| `manufacturer` | Android, iOS | Device manufacturer/vendor. |
| `brand` | Android, iOS | Device brand. |
| `device` | Android | Android build device name. |
| `product` | Android | Android build product name. |
| `device_model` | Android, iOS | Device model/hardware identifier. |
| `screen_width` | Android, iOS | Screen width in pixels. |
| `screen_height` | Android, iOS | Screen height in pixels. |
| `screen_dpi` | Android, iOS | Display density/DPI estimate. |
| `pixel_ratio` | Android, iOS | Display scale/pixel ratio. |
| `hardware_concurrency` | Android, iOS | Available processor/core count. |
| `cpu_abi` | Android | CPU architecture/ABI. |
| `cpu_type` | iOS | CPU type/architecture. |
| `os_build_id` | Android, iOS | OS/build identifier. |
| `android_id` | Android | Android Settings Secure ID. If an allowed advertising ID is collected, Android omits `android_id` from that payload. |
| `idfv` | iOS | Apple's Identifier for Vendor. |
| `app_set_id` | Android | Google Play Services App Set ID. Obtaining it communicates with Google Play Services. |
| `app_set_id_scope` | Android | App Set ID scope. |
| `webview_user_agent` | Android, iOS | WebView user-agent string, capped at 512 characters. |
| `advertising_id` | Android | Google Advertising ID. The SDK dependency is compile-only/host opt-in; collection is conditional on host integration and the user's advertising preference. |
| `idfa` | iOS | Apple advertising identifier. Disabled unless the host sets `DeeplinklyEnableIDFA`; only read when ATT is authorized. The SDK does not prompt for ATT. |
| `device_carrier` | Android | Mobile carrier/operator name. |
| `local_ip` | Android, iOS | Local/LAN IPv4 address, capped at 64 characters. This is distinct from the public IP visible to Deeplinkly on every network request. |

## Data outside the tier catalogue

### 1. Link clicks and redirects

The public privacy policy says Deeplinkly collects link clicks, IP address/approximate location, device metadata, referral data, and engagement data. A click/redirect service necessarily handles at least the requested Deeplinkly/custom-domain URL, short code or click ID, redirect destination, request time, public IP, HTTP headers/user agent, and response outcome. Referrer and campaign query parameters may also be present. Approximate location, fraud indicators, and click-to-install timing can be derived server-side.

**Verification status:** the click record's contents are **code-confirmed** and listed under Server-side handling below. Access-log fields, cookie behaviour, and cache TTLs are properties of the serving infrastructure rather than the application, and remain **inferred**.

### 2. Link resolution (`/api/v1/resolve`)

Resolution is functional and remains enabled at `NONE` and when tracking is disabled.

- Link identity: `click_id` or `code`.
- Allowed attribution query values: UTM fields, `gclid`, `fbclid`, `ttclid`,
  `gbraid`, and `wbraid` when present.
- Tenant API key in the authorization header.
- Stable Deeplinkly device ID and optional customer user ID in headers at every
  attribution tier, including `NONE`; both identity headers are omitted while
  global tracking is disabled.
- Android random request ID.
- Public IP, time, endpoint, and ordinary request metadata visible to the server.
- Returned link parameters/metadata are delivered to the customer app. If resolution fails, local URL parameters may be delivered as fallback.

The current Android/iOS implementations do **not** attach the catalogue device profile to `/resolve`. Resolution is deterministic and requires a click ID or short code; there is no client entry point for device-based matching.

### 3. Link creation (`/api/v1/generate-url`)

Link generation remains functional at `NONE` and when tracking is disabled. It sends:

- required `canonical_identifier`;
- optional title, description, and image URL;
- arbitrary customer-supplied metadata map;
- channel and feature labels;
- optional tags;
- the same tenant and network metadata described above, plus device/custom-user
  headers unless global tracking is disabled.

Link content can identify a product, account, referral, cart, media item, or other user context. Customers must not place sensitive or directly identifying data in link URLs or metadata unless the legal basis, disclosure, access controls, and contract explicitly allow it.

### 4. Developer-configured events (`/api/v1/log-event`)

- Normalized event name (up to 64 characters).
- Up to 25 developer-supplied parameters. Keys are capped at 64 characters; strings and serialized nested values are capped at 256 characters. Values may be strings, numbers, booleans, lists, or maps.
- SDK bookkeeping injected into parameters: event sequence, client elapsed time since SDK initialization, client wall-clock epoch time, time-zone offset, and session ID.
- A device block filtered to the effective Minimal/Reduced/Full tier. At `NONE`, the device block is absent but the event and parameters still go.
- Standard API headers and public network metadata.

Event limits prevent oversized data but do not detect names, email addresses, phone numbers, purchase details, health data, precise location, children’s data, or other sensitive content. The Terms prohibit transmitting sensitive personal data; enforcement was not visible in the SDKs.

### 5. SDK diagnostics (`/api/v1/sdk-error`)

- Error message.
- Stack trace.
- Optional click ID.
- Standard API headers and public network metadata.

Error text and stack traces can contain app class/function names, URLs, identifiers, or developer-provided values depending on the failure. Diagnostics are blocked for new sends when global tracking is disabled, and pending diagnostic retries are deleted on both platforms.

### 6. Account, authentication, dashboard, and billing

The public policy and live public application code show or state processing of:

- first and last name;
- email address and email-verification state;
- password data for email signup. Passwords are never stored: only a salted PBKDF2-SHA256 hash, written and verified through Django's password machinery, with strength validators enforced at signup, reset, and member password set. The API field is write-only, so a password is never returned in a response, and password-like key names are redacted before any request body reaches an error log. **code-confirmed**;
- internal account/user ID and avatar URL;
- optional WhatsApp number and notification preferences visible in the public account bundle;
- invitation token, team/project membership, role, and account configuration;
- OAuth identity/profile data when Google or GitHub sign-in is selected;
- cookies, CSRF/session credentials, login state, and Firebase installation/analytics identifiers;
- pages and URLs viewed, page title, browser/device/network metadata, public IP, and timestamps;
- signup/sign-in method and associated analytics events;
- purchase analytics: value, currency, transaction ID, items, and internal Deeplinkly user ID;
- billing plan/subscription, invoices, transaction status, payment method metadata, and billing/contact details. Card and bank credentials are handled by the payment provider and do not reach Deeplinkly: what is stored is the provider's payment-method token plus card brand, last four digits, and printed expiry. No PAN or CVV is stored. **code-confirmed**;
- project API keys, app configuration, links/campaigns, analytics/report selections, exports, and dashboard activity;
- support inquiries, sales/demo submissions, survey responses, communications, and any attachments or content a person supplies;
- security, fraud, rate-limit, and audit logs.

The live site uses Firebase Analytics to set the Deeplinkly internal user ID as Firebase `user_id`, record page URL/path/title, record sign-in/signup method, and record purchase value/currency/transaction/items. Firebase Analytics therefore processes pseudonymous account-linked usage and commercial activity, not merely anonymous traffic counts.

### 7. Information received from third parties

The public policy states that Deeplinkly may receive campaign and engagement data from ad networks, analytics partners, or customer-enabled integrations. This can include advertising/click IDs, campaign metadata, conversion/event data, integration account identifiers, webhook/API payloads, and delivery/error logs. Each active integration needs its own field-level inventory and recipient/controller analysis.

### 8. Derived and combined information

The public policy states that Deeplinkly uses information to connect activity across platforms/devices, create reports, detect fraud, and create aggregated/de-identified research, benchmarking, and product-improvement data. Potential derived data therefore includes:

- deterministic click-to-install/open/event attribution;
- campaign, channel, cohort, funnel, conversion, and retention metrics;
- approximate location derived from public IP;
- device/session uniqueness and install/reinstall indicators;
- suspected duplicate, emulator, bot, abuse, or fraud classifications;
- aggregated benchmarks and de-identified statistics.

The product position is that probabilistic device matching is not performed. Backend owners must keep legacy matching jobs and fields disabled or removed and verify that production behavior remains deterministic.

## On-device processing and storage

Local processing is still relevant to platform privacy disclosures even where the value is not immediately transmitted.

| Data/store | Android | iOS | Retention/behavior found in code |
|---|---|---|---|
| Deeplinkly device ID | SharedPreferences UUID | Keychain UUID, `kSecAttrAccessibleAfterFirstUnlock` | Android normally until app data is cleared/uninstall, subject to backup/restore. iOS normally survives uninstall/reinstall until Keychain removal/reset. |
| Custom user ID and privacy settings | SharedPreferences | UserDefaults | Until replaced/cleared, app data removal, or applicable backup restore. Disabling tracking does not itself purge them. |
| User data supplied via `setUserData()` | SharedPreferences, one JSON entry (`dl_user_data`) | UserDefaults, one JSON entry (`dl_user_data`) | Held on the device until overwritten, cleared, or local data is removed. Deliberately preserved across an Android backup/restore, on the same reasoning as the custom user ID: it is the same person on the new device. `clearUserData()` replaces each set field with an empty value and **keeps** that tombstone rather than deleting the entry, so the erasure is re-reported until the server acknowledges it; `resetPrivacyData()` deletes the entry outright, which also discards any undelivered erasure. |
| Static device profile and profile stamp | SharedPreferences | UserDefaults | Cached until invalidated/recollected or local data is cleared. |
| First-touch attribution/referrer | SharedPreferences | UserDefaults | Persists locally to support deferred attribution; no fixed deletion TTL was found for the stored first-touch record. |
| Deep-link queue | Full original URI, parsed local parameters, resolved parameters, identity, timestamps, attempts/delivery state | Raw URI, identity, timestamps, attempts/delivery state | Supports retry and delivery. Accepted URLs may contain arbitrary customer query values. |
| Failed network retry queue | Enrichment, event, and diagnostic payloads | Enrichment, event, and diagnostic payloads | Up to 50 items; 7-day maximum age; Android up to 5 retry attempts. Stored payloads can contain customer event/error content. |
| Session/counters/dedupe state | Preferences | UserDefaults | Session ID and timing, event sequence, report latches, attribution delivery state. |
| iOS pasteboard | Not applicable | Reads URL/string item once per install by default; accepted Deeplinkly link is queued; automatic accepted read clears all pasteboard items | Skipped if globally disabled. Pattern/type probes precede content access. Unrelated content is not sent, but an unrelated URL may still be read before domain validation. |
| Flutter lifecycle/stream data | Passed over the local Flutter/native method channel | Passed over the local Flutter/native method channel | App lifecycle state and deep-link results are held in process; Flutter itself does not add a separate remote analytics service. |

When attribution is downgraded, queued enrichment and the nested device block on queued events are re-filtered before retry. Customer event parameters and diagnostics are not catalogue-filtered. Global opt-out purges pending reporting retries on both platforms and prevents an in-flight failure from recreating them.

## SDK platform dependencies and permissions

### Android

- Declares only `INTERNET` in the SDK manifest.
- Bundles Google Play Install Referrer and Google Play Services App Set libraries.
- Google Advertising ID support is compile-only and requires the host app to opt in/include the dependency and applicable permission/configuration.
- Connection type is only read if the host app already has network-state permission.
- App Set ID, Install Referrer, and optional Advertising ID involve Google/Google Play Services. Google is a platform/service recipient in that flow, but is not automatically a Deeplinkly subprocessor merely because the SDK calls the platform API.

### iOS

- Uses Apple system frameworks only; no third-party package dependency is declared in the native SDK.
- IDFA is off by default and conditional on host opt-in plus ATT authorization.
- Reads ATT status but never prompts on its own.
- Uses UserDefaults, system uptime, and a filesystem timestamp under Apple's required-reason API framework.
- Automatic pasteboard behavior requires especially clear customer/app disclosure.
- The included privacy manifest declares linked Device ID, User ID, Product Interaction, Diagnostic, and Other Data for app functionality/analytics; an optional IDFA manifest declares tracking/advertising use. Each customer remains responsible for the final merged App Store privacy answers, including custom events and any server-derived coarse location.

## Server-side handling

Deeplinkly's service records, described by category. This states what is held and how it is treated; it is not a description of Deeplinkly's internal systems.

| Record category | What it holds |
|---|---|
| Device and install record | One record per install per tenant: the Deeplinkly device ID, the custom user ID and its history, the static device profile, the most recent dynamic signals, first- and last-touch attribution, and click identifiers with an observation timestamp. Since catalogue 9 it also holds the eleven `user_*` fields supplied through `setUserData()`. Rewritten on each app open. |
| Click record | One record per link click: click identifier, tenant, link, timestamp, source IP, user agent, UTM and ad-click identifiers, and the original query string of the requested link. Because that query string is captured as requested, it can hold arbitrary customer- or campaign-supplied values, **including personal data that neither Deeplinkly nor the SDK placed there**. Campaign URLs should be treated as a channel that can carry personal data. |
| Event record | Developer-configured events: name, the caller's parameter blob, device and custom user IDs, the request's public IP and user agent, and — since catalogue 9 — a typed value, currency, and client-generated event ID. Parameters are caller-controlled and are not catalogue-filtered; they are capped and truncated, which is a size limit and not a privacy filter. |
| Device signal samples | Time series of the dynamic half of the catalogue, plus the request IP and user agent. |
| Install attribution | The attribution decision for an install, including the network click identifier and its type, kept expressly to feed a Conversions API postback. |
| Diagnostics | SDK and server error reports, used to debug integrations. |

**Personal data is encrypted in transit and at rest.**

**Diagnostics stay with Deeplinkly.** SDK and server error reports are retained in Deeplinkly's own systems. Sentry is used for application error monitoring and is configured not to receive request bodies, user identity, or SDK attribution and customer-event data, so an end user's `setUserData()` values are not exposed to it. **code-confirmed**, and consistent with the recipient statement in the 15 August 2026 privacy policy.

**Every catalogued signal is re-filtered on ingest.** The service applies the same fail-closed catalogue the SDKs compile against, so a key that nobody has classified is dropped on arrival rather than stored because it was sent. A field that is not in the catalogue cannot enter the device and install record as a side effect of an SDK change.

## Third-party recipients

The list below cross-checks the recipients named in the 15 August 2026 privacy policy against what was technically observable, and records the data each recipient could receive. **policy-confirmed** below means the current public policy names the recipient and its purpose; **live-observed** means it was independently visible in production-facing behaviour on the audit date. It is a working inventory, not Deeplinkly's contractual subprocessor notice; for the authoritative list, including legal entities and transfer mechanisms, refer to Deeplinkly's DPA.

| Provider/recipient | Evidence and status | Data potentially received | Required legal verification |
|---|---|---|---|
| **Amazon Web Services (AWS), including CloudFront** | **policy-confirmed and live-observed.** The policy names AWS for **Mumbai-region hosting and storage**, CloudFront delivery, and SES email delivery; live responses carry CloudFront headers and current API-host IPs are in AWS infrastructure. | Website visitor public IP, request headers, requested URL, timestamps, response/log data, and cached site content. If API/backend/database hosting is AWS, potentially all SDK/API/account data described here. | Contracting AWS entity, replicas/backups, log retention, encryption configuration, sub-subprocessors, and DPA/SCCs. Region and services are now stated publicly. |
| **Bunny.net / BunnyCDN** (`cdn.zerobuffer.io`, underlying `zerobuffer.b-cdn.net`) | **policy-confirmed and live-observed.** The policy names **ZeroBuffer.io** for public static-asset and image delivery; live headers on `cdn.zerobuffer.io` identify BunnyCDN as the underlying provider. No evidence from the SDKs that SDK API payloads go to it. The policy names the service, not the underlying CDN vendor — reconcile the two before publishing a subprocessor register. | CDN visitor public IP, request metadata, requested asset URL, cache/log information, and public images/assets. | Contracting entity, storage/pull-zone regions, log/cookie retention, DPA/transfers, and whether any private/customer assets are served. |
| **Google — Firebase Analytics / Firebase Installations** | **Confirmed in live website bundles.** Firebase Analytics is initialized for project `deeplinkly-app`; the site sets internal user ID and logs page, auth-method, and purchase events. | Firebase installation ID/technical metadata; page path, full page location, title; internal Deeplinkly user ID; signup/sign-in method; purchase value, currency, transaction ID, and items; browser/public IP and Google Analytics metadata. | Analytics property settings, consent mode/cookie behavior, signals/ads features, retention, data sharing, regions, deletion, DPA/SCCs, and whether URL query strings can expose tokens or identifiers. |
| **Google OAuth** | **Confirmed optional login route** in public signup code. Used only when selected by the account user. | OAuth identifiers/tokens and permitted Google profile fields such as name, email, avatar; login metadata. | Exact scopes, token retention, controller roles, revocation/deletion, and Google terms/DPA. |
| **Google Workspace / email infrastructure** | **Confirmed mail routing:** current MX records point to Google. The actual outbound transactional/marketing email sender was not identified. | Customer/support email addresses, message content, attachments, delivery metadata, and possibly contact lists. | Workspace entity/region/retention/DPA; identify any separate email delivery or CRM provider. |
| **GitHub OAuth** | **Confirmed optional login route** in public signup code. Used only when selected. | OAuth identifier/token and permitted GitHub profile/email/avatar fields; login metadata. | Exact scopes, token retention, controller roles, revocation/deletion, and applicable terms. |
| **Stripe** | **policy-confirmed and live-observed.** The policy states Stripe handles payments for customers **outside India**; the website CSP allows Stripe scripts, frames, and hooks, and public code contains billing/purchase flows. | Billing/contact data, transaction amount/currency/status, subscription and payment-method metadata, fraud/security data; payment credentials if entered into Stripe-hosted fields. | Confirm activation, Stripe contracting entity, countries, Stripe roles, Connect use, DPA/SCCs, retention, Radar, and exact fields stored back in Deeplinkly. |
| **Razorpay** | **policy-confirmed and live-observed.** The policy states Razorpay handles payments for customers **in India**; the website CSP allows Razorpay checkout/API frames and public code contains billing flows. | Billing/contact data, transaction amount/currency/status, payment-method metadata, fraud/security data; payment credentials if entered into Razorpay checkout. | Confirm activation, Razorpay entity, countries, roles, DPA/transfer basis, retention, and exact fields stored back in Deeplinkly. |
| **Sentry** | **policy-confirmed and code-confirmed.** Named in the policy for application error monitoring, "configured not to receive SDK attribution or customer-event data". | Error type and message, stack trace, and the request metadata explicitly attached at the call site. Configured to exclude request bodies, user identity, and stack-frame local variables. | Contracting entity, region, retention, DPA/SCCs, and who holds project access. |
| **Customer-selected ad networks, analytics integrations, webhooks, exports, or APIs** | **Policy-confirmed category; individual integrations not inventoried.** These are customer-directed recipients and may not be Deeplinkly subprocessors. | Selected link, click, install, event, campaign, device/user identifier, and report data. | Maintain per-integration field mapping, purpose, authentication, recipient role, location, retention, and customer controls. |
| **Apple and Google platform services** | SDK relies on Apple OS/App Store mechanisms and Google Play Services/Install Referrer/App Set ID; optional platform advertising IDs. | Platform already holds or supplies install/referrer/advertising/vendor state; calls may generate platform-side operational logs. | Describe as platform dependencies/independent providers where appropriate, not automatically as Deeplinkly subprocessors. Confirm platform terms and customer app disclosures. |

No evidence in the audited mobile repositories showed an additional mobile analytics, crash-reporting, location, advertising-network, or social SDK embedded by Deeplinkly.

## Data not collected by the native SDK by default

The reviewed SDK code does not directly request or enumerate:

- precise GPS location;
- contacts or address book;
- photos, videos, files, or media library;
- microphone, camera, or audio;
- SMS, call logs, phone number, or email address **read from the device**;
- IMEI, device serial number, Wi-Fi SSID/BSSID, or MAC address;
- health, fitness, medical, biometric, financial-account, or government-ID data;
- advertising ID when the relevant host opt-in/authorization is absent.

This is not a guarantee that such data can never reach Deeplinkly. A customer can place arbitrary values into custom user ID, custom events, link metadata/parameters, install-referrer content, support messages, or API/integration payloads. Policies and contracts must describe and restrict those customer-controlled channels.

**Since catalogue version 9 this list needs reading carefully.** The SDK still does not *read* an email address or phone number from the device, and none of the platform permissions that would allow it are requested. But `setUserData()` exists precisely so the integrating app can hand over an email, phone number, name and postal address it already holds, and the SDK then transmits them and Deeplinkly stores them — encrypted at rest, but not hashed. The distinction — the SDK does not harvest this data, but it is built to carry it — is the one that matters for an App Store privacy answer and for a processing record, and it must not be flattened in either direction.

## Retention and deletion inventory

| Dataset | Known client-side retention | Server-side retention |
|---|---|---|
| Static profile, identity, attribution, settings | Generally until app data is cleared/uninstalled or `resetPrivacyData()` is called; iOS Keychain ID can survive reinstall absent that reset; backup/restore may extend persistence | Held for the life of the tenant account, or until erased on request. |
| Retry payloads | Up to 50; 7-day maximum age; Android maximum 5 attempts | Once accepted, becomes the record it created; the payload itself is not separately stored |
| Deep-link/pending delivery state | Persists for functional retry/delivery; exact all-item lifetime varies by queue state | Not applicable — client-side only |
| User data supplied via `setUserData()` | Until overwritten, cleared, or local data is removed | Held encrypted at rest until erased by `clearUserData()`, by an erasure request, or with the tenant account. |
| Device signal samples | Not retained client-side | **90 days**, or **14 days** for samples attached to an event, enforced by a scheduled purge that deletes. **code-confirmed** |
| Click and SDK event data | Local caches as above | Governed by the tenant's plan retention window, which sets the period available for reporting, analytics, and export. |
| Install attribution | Not applicable | Retained for the life of the tenant account, or until erased on request. |
| Account, security, billing, support, website analytics | Browser/provider/app storage according to implementation/provider settings | Governed by Deeplinkly's privacy policy; payment, tax, and legal retention obligations may require longer periods. |
| Backups, logs, aggregates/de-identified data | Not applicable/unknown | Backups and operational logs follow their own rotation; aggregated and de-identified data is not subject to erasure because it no longer identifies a person. |

Deeplinkly is extending enforced deletion schedules beyond device signal samples to the remaining record categories, alongside the erasure endpoints described in the next section. Customers with a contractual retention requirement should agree it in the DPA rather than rely on the plan retention window, which governs data availability rather than acting as a deletion guarantee.

Integrating customers remain responsible for the retention they promise their own users, and for what they place into custom user IDs, event parameters, link metadata, and campaign query strings.

## Deletion and erasure: what each control actually does

This is the section most likely to be read as a promise, so it states the boundary explicitly.

| Control | Scope | Reaches the server? |
|---|---|---|
| `setUserId(null)` | Clears `custom_user_id` on the device. | **No.** The server keeps the current custom user ID and its history. Use an erasure request to remove them. |
| `clearUserData()` | Clears the eleven `user_*` fields on the device, **and** instructs the server to erase the matching stored values. | **Yes**, for those eleven fields. The device reports each previously-set field as empty and keeps doing so until the report is delivered, so an offline device still takes effect later. It does **not** clear `custom_user_id` or its history. **code-confirmed** |
| `setTrackingEnabled(false)` | Stops all reporting, purges pending retries. | **No.** Nothing already sent is deleted. |
| `resetPrivacyData()` | Deletes the SDK's entire local store — device ID, attribution, queues, user data — and leaves tracking disabled. | **No. This is a purely local wipe.** The server retains what was previously sent, and because the local device ID is destroyed the record can no longer be addressed from that device. |

**Two consequences to describe accurately in your own policy text.**

1. `resetPrivacyData()` is a local deletion, not a right-to-erasure mechanism. Calling it *after* `clearUserData()` but before the erasure has been delivered destroys the pending erasure along with everything else.
2. Of the four SDK controls, only `clearUserData()` reaches the server. Anything wider — erasing an end user's full record, or a tenant's data — is an erasure request, not an SDK call.

**Erasure requests.** Today, an end user's erasure request is made by the integrating customer to Deeplinkly, which executes it against the customer's tenant. A self-serve deletion API and a dashboard flow for submitting and tracking erasure requests are in development and will be documented here when they ship; until then, route requests through your usual Deeplinkly support contact, and allow for that path in the response times you promise your own users.

## Suggested policy category mapping

| Policy category | Included data |
|---|---|
| Identifiers | Deeplinkly device ID, install instance ID, custom user ID, click ID/code, Android ID, IDFV, App Set ID, IDFA/Advertising ID, account ID, email, OAuth identifiers, session/Firebase IDs, IP address |
| Direct personal identifiers supplied by the customer's app | End-user email address, phone number, first and last name, date of birth, gender, street, city, state/region, postal code, country — all via `setUserData()`, all transmitted over TLS and stored encrypted at rest but not hashed, all hashed only when a conversion is forwarded to an advertising destination |
| Device and internet activity | App/bundle/version, OS/build/API level, model/manufacturer/brand, CPU/core, screen, emulator, environment, locale/time zone, carrier/network, user agent, local IP, public IP, requested URLs/pages, timestamps, interactions |
| Attribution and commercial activity | Install referrer, click/install/open, campaign/UTM/ad-click IDs, link data, events/conversions, source/channel, attribution result/confidence, purchase/subscription/invoice data |
| User/customer content | Event names/properties, custom IDs, link canonical ID/title/description/image/metadata/tags, deep-link query values, support/sales/survey messages, integration payloads |
| Diagnostics and security | Error message/stack/click ID, request IDs, response/status logs, authentication/audit/rate-limit/fraud indicators |
| Inferences | Approximate location, device/session uniqueness, funnel/cohort/benchmark reports, deterministic attribution, fraud/bot/emulator classifications |

## Evidence trail

### Repository evidence

- Shared canonical catalogue: `tool/signals.json` in `flutter_deeplinkly`, distributed byte-identically to `android_deeplinkly/tool/signals.json`, `ios_deeplinkly/tool/signals.json`, and `DeepLinkly/links/signals.json`. SHA-256 `f699036f4439f8a667a5cd483877f45e7c2306464d8a1f64d5e205077436f3fb` at catalogue version 9; `dart run tool/gen_signals.dart --check` proves the copies agree.
- Flutter API and models: `lib/flutter_deeplinkly.dart`, `lib/models/deeplinkly.dart`, platform bridges, `README.md`, and `pubspec.yaml`.
- Android: `deeplinkly/src/main/kotlin/.../privacy`, `core/DeviceProfile.kt`, `core/DynamicSignals.kt`, `network/DeeplinklyNetwork.kt`, `attribution/EnrichmentSender.kt`, Install Referrer/App Set/Advertising ID providers, queues, manifest, Gradle dependencies, README, and tests.
- iOS: `Sources/Deeplinkly/SignalCatalogue.swift`, `DeviceProfile.swift`, `DynamicSignals.swift`, `DeviceIdManager.swift`, `NetworkUtils.swift`, `PasteboardHandler.swift`, `DeepLinkQueue.swift`, `RetryQueue.swift`, `PrivacyData.swift`, `UserDataStore.swift`, `DeeplinklyUserData.swift`, `PrivacyInfo.xcprivacy`, IDFA privacy-manifest template, Package.swift, README, and tests.
- React Native: `src/index.tsx`, `src/types.ts`, `src/NativeDeeplinkly.ts`, and the Android/iOS bridges. It holds no catalogue and no key lists of its own; it forwards to the two native SDKs, so it collects whatever they collect.

### Public/live evidence checked on 15 August 2026, re-checked 27 August 2026

- [Deeplinkly Privacy Policy](https://www.deeplinkly.com/privacy-policy), effective 15 August 2026.
- [Deeplinkly Terms of Use](https://www.deeplinkly.com/terms-of-use), effective 15 August 2026.
- [Deeplinkly homepage](https://www.deeplinkly.com/) and public signup/application JavaScript bundles.
- Live HTTP response headers for the website, API, and `cdn.zerobuffer.io`; DNS A/CNAME/MX records; public Content Security Policy.

This evidence records what was observable on the audit date. Vendor use, schemas, policies, and code can change; repeat the reconciliation before each material legal-policy update.
