# Grafana Alerts — plugin Noctalia

Les alertes Grafana **en cours** dans la barre Noctalia : un compteur teinté selon la
sévérité, et au clic un panneau avec la liste (sévérité, dossier, résumé, labels).

- Source : API Alertmanager de Grafana (`/api/alertmanager/grafana/api/v2/alerts`),
  alertes actives, non silencées, non inhibées.
- Le clic sur le nom d'une alerte l'ouvre dans Grafana.
- Les alertes internes `DatasourceNoData` / `DatasourceError` sont ignorées par défaut.

## Installation

```sh
git clone https://github.com/fxthiry/noctalia-grafana-alerts ~/.local/share/noctalia/plugins/grafana-alerts
noctalia msg plugins enable fxthiry/grafana-alerts
```

Puis ajouter le widget à la barre (Réglages → Barre → Ajouter un widget → *Grafana Alerts*),
ou en TOML :

```toml
[widget.grafana]
type = "fxthiry/grafana-alerts:bar"
```

## Configuration

Réglages → Plugins → Grafana Alerts :

| Réglage | Défaut | Rôle |
|---|---|---|
| `grafana_url` | — | URL de base, ex. `https://grafana.example.com` |
| `api_token` | — | Token d'un *service account* Grafana (rôle **Viewer** suffisant) |
| `refresh_interval` | 60 s | Fréquence de récupération |
| `ignore_datasource_alerts` | `true` | Masque `DatasourceNoData` / `DatasourceError` |
| `hidden_labels` | `alertname, grafana_folder, severity` | Labels non affichés en tags |
| `allow_insecure_tls` | `false` | Certificats auto-signés |

Créer le token : Grafana → Administration → Users and access → Service accounts →
*Add service account* (rôle Viewer) → *Add service account token*.

Le token est stocké dans les réglages Noctalia (`~/.local/state/noctalia/settings.toml`),
pas dans ce dépôt.

## Structure

| Fichier | Rôle |
|---|---|
| `plugin.toml` | Manifeste : réglages, entrées (service, widget, panneau) |
| `service.luau` | Service de fond : appel HTTP, normalisation, tri, état partagé |
| `bar.luau` | Widget de barre : icône + compteur, teinte selon sévérité, clic → panneau |
| `panel.luau` | Panneau : cartes d'alertes avec badge de sévérité, résumé et tags |
| `translations/` | Textes en/fr |

Sévérités reconnues (label `severity`) : `critical` (+ crit/error/fatal/p1),
`warning` (+ warn/high/major/p2), `info` (+ notice/low/minor) ; le reste est « autre ».

## Développement

```sh
noctalia plugins lint .          # vérifie réglages déclarés ↔ code
noctalia msg plugins list        # état des plugins sur l'instance
tail -f ~/.cache/noctalia/noctalia.log | grep grafana-alerts
```

Licence MIT.
