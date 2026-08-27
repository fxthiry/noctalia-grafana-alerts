# Grafana Alerts for Noctalia

Firing Grafana alerts in your [Noctalia](https://noctalia.dev) bar: a counter tinted by
severity, and one click away a panel with the full list — severity, folder, summary,
labels — plus desktop notifications, one-click silences and copy-to-clipboard.

![Grafana Alerts panel](screenshots/panel.png)

## Features

- **Bar widget** — glyph + number of firing alerts, tinted by the worst severity
  (critical / warning / all clear). Tooltip with the per-severity breakdown and the last
  error, if any. Left click opens the panel, right click opens the settings.

  ![Bar widget](screenshots/bar.png)

- **Panel** — one card per alert: severity badge, name (click opens the alert in
  Grafana), folder, start time and age, summary, label chips. Header badges filter by
  severity.
- **Desktop notifications** — a `notify-send` notification when a new alert starts
  firing (urgency `critical` for critical ones), with a minimum severity setting.
- **Silences** — *Silence 2 h* → *Confirm* creates an Alertmanager silence matching
  the alert's labels, exactly like Grafana's own *Silence* button.
- **Copy** — name, folder, summary, labels and URL to the clipboard.
- **API-side filters** — Alertmanager matchers (`team=infra`, `env!~"staging|dev"`) so
  you only fetch what you care about.
- **Configurable** — severity label name, severity colors, hidden labels, refresh
  interval, self-signed certificates, translations in English and French.

The data comes from Grafana's built-in Alertmanager API
(`/api/alertmanager/grafana/api/v2/alerts`): active alerts, not silenced, not inhibited.
The internal `DatasourceNoData` / `DatasourceError` alerts are ignored by default.

## Installation

```sh
git clone https://github.com/fxthiry/noctalia-grafana-alerts ~/.local/share/noctalia/plugins/grafana-alerts
noctalia msg plugins enable fxthiry/grafana-alerts
```

Then add the widget to your bar (Settings → Bar → Add widget → *Grafana Alerts*), or in
TOML:

```toml
[widget.grafana]
type = "fxthiry/grafana-alerts:bar"
```

The panel opens with a click on the widget, or from the command line:

```sh
noctalia msg panel-toggle fxthiry/grafana-alerts:panel
```

Requires Noctalia v5 (plugin API ≥ 19), `notify-send` for desktop notifications and
`xdg-open` to open alerts in your browser.

## Configuration

Settings → Plugins → Grafana Alerts:

| Setting | Default | Description |
|---|---|---|
| `grafana_url` | — | Base URL, e.g. `https://grafana.example.com` |
| `api_token` | — | Grafana *service account* token (role **Viewer** is enough to read; **Editor** to create silences) |
| `refresh_interval` | 60 s | Polling interval (15 s minimum) |
| `ignore_datasource_alerts` | `true` | Hide `DatasourceNoData` / `DatasourceError` |
| `filters` | — | Alertmanager matchers appended to the request, one per entry (`team=infra`, `env!~"staging\|dev"`) |
| `severity_label` | `severity` | Label carrying the severity (`level`, `priority`…); always hidden from the chips |
| `hidden_labels` | `alertname, grafana_folder, severity` | Labels not shown as chips (`__*` labels are always hidden) |
| `critical_color` | `#ff5c5c` | Color for critical alerts (bar tint, badges, card borders) |
| `warning_color` | `#f1c232` | Color for warning alerts |
| `notify_new_alerts` | `true` | Desktop notification for every new alert |
| `notify_min_severity` | `warning` | Minimum severity to notify (`critical`, `warning`, `info`, all) |
| `show_silence_button` | `true` | Show the *Silence* action on each card |
| `silence_duration` | 120 min | Length of the silences created from the panel |
| `allow_insecure_tls` | `false` | Accept self-signed certificates |

Bar widget settings (Settings → Bar → *Grafana Alerts* widget):

| Setting | Default | Description |
|---|---|---|
| `glyph` | `alert-triangle` | Icon shown in the bar |
| `hide_when_zero` | `false` | Hide the widget when nothing is firing |

### Creating the token

Grafana → Administration → Users and access → Service accounts → *Add service account*
(role Viewer) → *Add service account token*.

To create silences from the panel, the service account needs the **Editor** role (or the
`alert.silences:create` permission); otherwise the panel shows the 403 error on the card
and nothing else changes.

The token is stored in Noctalia's settings (`~/.local/state/noctalia/settings.toml`), not
in this repository.

## Notifications

The first fetch after startup is a baseline: alerts already firing are not notified.
After that, every new alert fingerprint with a severity ≥ `notify_min_severity` triggers a
`notify-send` (urgency `critical` for critical alerts). More than 3 new alerts in one
fetch → a single summary notification.

## Silences

*Silence 2 h* → *Confirm* (6 seconds to click) → `POST /api/alertmanager/grafana/api/v2/silences`
with one `=` matcher per label of the alert (except the `__grafana_*` routing labels),
like Grafana's *Silence* button. The list refreshes right after: the alert disappears since
the request excludes silenced alerts.

## Severity mapping

Grafana has no fixed vocabulary, so the `severity` label (or the one set in
`severity_label`) is bucketed:

| Bucket | Values |
|---|---|
| critical | `critical`, `crit`, `error`, `fatal`, `emergency`, `p1` |
| warning | `warning`, `warn`, `high`, `major`, `p2` |
| info | `info`, `informational`, `notice`, `low`, `minor` |
| other | anything else |

Alerts are sorted by severity, then start time (newest first).

## Layout

| File | Role |
|---|---|
| `plugin.toml` | Manifest: settings, entries (service, widget, panel) |
| `service.luau` | Background service: HTTP calls (alerts, silences), normalisation, sorting, notifications, shared state |
| `bar.luau` | Bar widget: glyph + counter, severity tint, click → panel, right click → settings |
| `panel.luau` | Panel: severity filter, alert cards (badge, summary, chips), copy and silence actions |
| `translations/` | English and French strings |

## Development

The plugin hot-reloads `.luau` files; manifest changes need a plugin disable/enable.

```sh
noctalia plugins lint .                                   # declared settings ↔ code
noctalia msg plugins list                                 # plugin state on the running instance
tail -f ~/.cache/noctalia/noctalia.log | grep grafana     # logs
```

## What it touches

- **Network**: `GET …/api/alertmanager/grafana/api/v2/alerts` on every refresh,
  `POST …/api/alertmanager/grafana/api/v2/silences` when you confirm a silence. Nothing
  else; the token is only ever sent to the configured Grafana URL.
- **Processes**: `notify-send` for notifications, `xdg-open` when you click an alert
  name.
- **Files**: none written by the plugin; settings live in Noctalia's own settings file.

## License

MIT.
