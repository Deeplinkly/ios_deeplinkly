# iOS device signals

This is the iOS subset of [`tool/signals.json`](../tool/signals.json), the
catalogue that controls every field the SDK may send to `/api/v1/enrich` and
inside an event's optional device block. Catalogue version 7.

A field absent from the catalogue is dropped at every attribution level,
including `full`.

The level column is the lowest level at which a field is included:

- `minimal` fields are included at `minimal`, `reduced`, and `full`.
- `reduced` fields are included at `reduced` and `full`.
- `full` fields are included only at `full`.
- At `none`, no enrichment or event device block is sent.

Static fields are cached and refreshed when the app, OS, SDK, or catalogue
version changes. Dynamic fields are collected at send time. Identity fields
describe the user or link rather than the device.

## Link identity

| Field | Level | Type |
| --- | --- | --- |
| `click_id` | minimal | string |
| `code` | minimal | string |
| `custom_user_id` | minimal | string |
| `source` | minimal | string |
| `fbclid` | reduced | string |
| `gclid` | reduced | string |
| `ttclid` | reduced | string |
| `utm_campaign` | reduced | string |
| `utm_content` | reduced | string |
| `utm_medium` | reduced | string |
| `utm_source` | reduced | string |
| `utm_term` | reduced | string |

## Static device profile

| Field | Level | Type |
| --- | --- | --- |
| `app_build_number` | minimal | string |
| `app_id` | minimal | string |
| `app_version` | minimal | string |
| `deeplinkly_device_id` | minimal | string |
| `install_instance_id` | minimal | string |
| `installed_at` | minimal | datetime |
| `platform` | minimal | string |
| `sdk_version` | minimal | string |
| `static_profile_version` | minimal | string |
| `device_class` | reduced | string |
| `environment` | reduced | string |
| `first_app_version` | reduced | string |
| `first_open_at` | reduced | datetime |
| `is_emulator` | reduced | bool |
| `is_hardware_id_real` | reduced | bool |
| `os_version` | reduced | string |
| `brand` | full | string |
| `cpu_type` | full | string |
| `device_model` | full | string |
| `hardware_concurrency` | full | int |
| `idfv` | full | string |
| `manufacturer` | full | string |
| `os_build_id` | full | string |
| `pixel_ratio` | full | float |
| `screen_dpi` | full | int |
| `screen_height` | full | int |
| `screen_width` | full | int |
| `webview_user_agent` | full | string |

## Dynamic signals

| Field | Level | Type |
| --- | --- | --- |
| `att_status` | minimal | string |
| `attribution_level` | minimal | string |
| `collected_at` | minimal | datetime |
| `last_opened_at` | minimal | datetime |
| `session_id` | minimal | string |
| `connection_type` | reduced | string |
| `ios_reported_at` | reduced | string |
| `language` | reduced | string |
| `limit_ad_tracking` | reduced | bool |
| `locale` | reduced | string |
| `region` | reduced | string |
| `timezone` | reduced | string |
| `timezone_offset_min` | reduced | int |
| `ui_mode_night` | reduced | bool |
| `unidentified_device` | reduced | bool |
| `idfa` | full | string |
| `local_ip` | full | string |

`idfa` is additionally gated by `DeeplinklyEnableIDFA` and authorized App
Tracking Transparency status. It is absent by default even at `full`.

## Changing the catalogue

Update [`tool/signals.json`](../tool/signals.json) and regenerate
`Sources/Deeplinkly/SignalCatalogue.swift` with the cross-repository catalogue
tool. Keep this table in sync with the iOS entries in that source of truth and
bump `catalogue_version` whenever the catalogue changes.
