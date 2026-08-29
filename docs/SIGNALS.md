<!-- GENERATED FILE — do not edit. -->
<!-- Source: tool/signals.json -->
<!-- Regenerate: dart run tool/gen_signals.dart -->

# Device signals

Every field the SDK may send to `/api/v1/enrich`, and the lowest
[attribution level](IOS_SDK.md#attribution-levels-and-tracking-consent) at which each still
ships. Catalogue version 13.

A field absent from this table is never sent, at any level: the SDK drops
anything it cannot find in the catalogue rather than defaulting to
permissive.

**Level** — `minimal` also ships at `reduced` and `full`; `reduced` also
ships at `full`; `full` ships only at `full`. At `none` nothing is sent.

**When** — `static` is collected once per device and cached until the app,
OS or SDK version changes. `dynamic` is re-read on every send. `identity`
names the link being reported on rather than the device, and `user` is what
the host app told us about the person via `setUserData()`.

## Link identity

| Field | Level | Type | Platforms |
| --- | --- | --- | --- |
| `click_id` | minimal | string | both |
| `code` | minimal | string | both |
| `install_referrer` | minimal | string | android |
| `source` | minimal | string | both |
| `fbclid` | reduced | string | both |
| `gad_campaignid` | reduced | string | both |
| `gad_source` | reduced | string | both |
| `gbraid` | reduced | string | both |
| `gclid` | reduced | string | both |
| `ttclid` | reduced | string | both |
| `utm_campaign` | reduced | string | both |
| `utm_content` | reduced | string | both |
| `utm_medium` | reduced | string | both |
| `utm_source` | reduced | string | both |
| `utm_term` | reduced | string | both |
| `wbraid` | reduced | string | both |

## User data

| Field | Level | Type | Platforms |
| --- | --- | --- | --- |
| `custom_user_id` | minimal | string | both |
| `user_city` | minimal | string | both |
| `user_country` | minimal | string | both |
| `user_custom_data` | minimal | string | both |
| `user_date_of_birth` | minimal | string | both |
| `user_email` | minimal | string | both |
| `user_first_name` | minimal | string | both |
| `user_gender` | minimal | string | both |
| `user_last_name` | minimal | string | both |
| `user_phone` | minimal | string | both |
| `user_state` | minimal | string | both |
| `user_street` | minimal | string | both |
| `user_zip` | minimal | string | both |

## Static device profile

| Field | Level | Type | Platforms |
| --- | --- | --- | --- |
| `app_build_number` | minimal | string | both |
| `app_id` | minimal | string | both |
| `app_version` | minimal | string | both |
| `deeplinkly_device_id` | minimal | string | both |
| `install_instance_id` | minimal | string | both |
| `installed_at` | minimal | datetime | both |
| `platform` | minimal | string | both |
| `sdk_version` | minimal | string | both |
| `static_profile_version` | minimal | string | both |
| `device_class` | reduced | string | both |
| `environment` | reduced | string | both |
| `first_app_version` | reduced | string | both |
| `first_open_at` | reduced | datetime | both |
| `google_play_instant` | reduced | bool | android |
| `install_begin_at` | reduced | datetime | android |
| `installer_package` | reduced | string | android |
| `is_emulator` | reduced | bool | both |
| `is_hardware_id_real` | reduced | bool | both |
| `os_version` | reduced | string | both |
| `referrer_click_at` | reduced | datetime | android |
| `referrer_install_version` | reduced | string | android |
| `sdk_int` | reduced | int | android |
| `android_id` | full | string | android |
| `app_set_id` | full | string | android |
| `app_set_id_scope` | full | string | android |
| `brand` | full | string | both |
| `cpu_abi` | full | string | android |
| `cpu_type` | full | string | ios |
| `device` | full | string | android |
| `device_model` | full | string | both |
| `hardware_concurrency` | full | int | both |
| `idfv` | full | string | ios |
| `manufacturer` | full | string | both |
| `os_build_id` | full | string | both |
| `pixel_ratio` | full | float | both |
| `product` | full | string | android |
| `screen_dpi` | full | int | both |
| `screen_height` | full | int | both |
| `screen_width` | full | int | both |
| `total_storage_gb` | full | int | android |
| `webview_user_agent` | full | string | both |

## Dynamic signals

| Field | Level | Type | Platforms |
| --- | --- | --- | --- |
| `att_status` | minimal | string | ios |
| `attribution_level` | minimal | string | both |
| `collected_at` | minimal | datetime | both |
| `consent_ad_personalization` | minimal | string | both |
| `consent_ad_user_data` | minimal | string | both |
| `consent_is_eea` | minimal | bool | both |
| `last_opened_at` | minimal | datetime | both |
| `pii_hashing_enabled` | minimal | bool | both |
| `session_id` | minimal | string | both |
| `android_reported_at` | reduced | string | android |
| `connection_type` | reduced | string | both |
| `ios_reported_at` | reduced | string | ios |
| `language` | reduced | string | both |
| `limit_ad_tracking` | reduced | bool | both |
| `locale` | reduced | string | both |
| `region` | reduced | string | both |
| `timezone` | reduced | string | both |
| `timezone_offset_min` | reduced | int | both |
| `ui_mode_night` | reduced | bool | both |
| `unidentified_device` | reduced | bool | both |
| `advertising_id` | full | string | android |
| `device_carrier` | full | string | android |
| `free_storage_gb` | full | int | android |
| `idfa` | full | string | ios |
| `local_ip` | full | string | both |
| `push_provider` | full | string | both |
| `push_token` | full | string | both |

