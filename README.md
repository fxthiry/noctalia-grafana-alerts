# Grafana Alerts — plugin Noctalia

Les alertes Grafana **en cours** dans la barre Noctalia : un compteur teinté selon la
sévérité, et au clic un panneau avec la liste (sévérité, dossier, résumé, labels).

- Source : API Alertmanager de Grafana (`/api/alertmanager/grafana/api/v2/alerts`),
  alertes actives, non silencées, non inhibées.
- Le clic sur le nom d'une alerte l'ouvre dans Grafana.
- Le panneau s'ouvre au clic sur le widget, ou en ligne de commande :
  `noctalia msg panel-toggle fxthiry/grafana-alerts:panel`. Clic droit sur le widget
  (ou l'engrenage du panneau) : réglages ; clic du milieu : réglages du widget (Noctalia).
- Les alertes internes `DatasourceNoData` / `DatasourceError` sont ignorées par défaut.
- Notification bureau (`notify-send`) quand une nouvelle alerte se déclenche.
- Depuis le panneau : filtre par sévérité, copie de l'alerte (nom, résumé, labels, URL),
  et pose d'un silence en deux clics.

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
| `filters` | — | Matchers Alertmanager ajoutés à la requête (`team=infra`, `env!~"staging\|dev"`), un par entrée |
| `severity_label` | `severity` | Label qui porte la sévérité (`level`, `priority`…) ; toujours masqué des tags |
| `hidden_labels` | `alertname, grafana_folder, severity` | Labels non affichés en tags |
| `notify_new_alerts` | `true` | Notification bureau à chaque nouvelle alerte (via `notify-send`) |
| `notify_min_severity` | `warning` | Sévérité minimale notifiée (`critical`, `warning`, `info`, toutes) |
| `show_silence_button` | `true` | Bouton *Silence* sur chaque alerte |
| `silence_duration` | 120 min | Durée des silences créés depuis le panneau |
| `critical_color` | `#ff5c5c` | Couleur des alertes critiques (teinte de la barre, badges, bordures) |
| `warning_color` | `#f1c232` | Couleur des alertes warning |
| `allow_insecure_tls` | `false` | Certificats auto-signés |

Réglages propres au widget de barre (Réglages → Barre → widget *Grafana Alerts*) :

| Réglage | Défaut | Rôle |
|---|---|---|
| `glyph` | `alert-triangle` | Icône affichée dans la barre |
| `hide_when_zero` | `false` | Masque le widget quand aucune alerte n'est active |

Créer le token : Grafana → Administration → Users and access → Service accounts →
*Add service account* (rôle Viewer) → *Add service account token*.
Pour poser des silences depuis le panneau, le service account doit avoir le rôle **Editor**
(ou la permission `alert.silences:create`) ; sinon le panneau affiche l'erreur 403 et rien
d'autre ne change.

## Notifications

Au premier fetch après démarrage, les alertes déjà actives servent de référence et ne sont
pas notifiées. Ensuite, chaque nouvelle empreinte d'alerte de sévérité ≥ `notify_min_severity`
déclenche un `notify-send` (urgence `critical` pour les critiques). Au-delà de 3 nouvelles
alertes dans un même fetch, une seule notification récapitulative est envoyée.

## Silences

*Silence 2 h* → *Confirmer* (6 s pour cliquer) → `POST /api/alertmanager/grafana/api/v2/silences`
avec un matcher `=` par label de l'alerte (hors `__grafana_*`), comme le bouton *Silence*
de Grafana. La liste est rafraîchie juste après : l'alerte disparaît puisque la requête
exclut les alertes silencées.

Le token est stocké dans les réglages Noctalia (`~/.local/state/noctalia/settings.toml`),
pas dans ce dépôt.

## Structure

| Fichier | Rôle |
|---|---|
| `plugin.toml` | Manifeste : réglages, entrées (service, widget, panneau) |
| `service.luau` | Service de fond : appels HTTP (alertes, silences), normalisation, tri, notifications, état partagé |
| `bar.luau` | Widget de barre : icône + compteur, teinte selon sévérité, clic → panneau |
| `panel.luau` | Panneau : filtre par sévérité, cartes d'alertes (badge, résumé, tags), copie et silence |
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
