# Publier sur le registre Noctalia

Le catalogue [noctalia.dev/plugins](https://noctalia.dev/plugins) est alimenté par le dépôt
[noctalia-dev/community-plugins](https://github.com/noctalia-dev/community-plugins) : un
plugin mergé là-bas apparaît sur le site et dans le store du shell. Il n'y a pas de
formulaire, c'est une PR. Ce dépôt est déjà conforme à leurs règles ; voici la marche à
suivre le jour où on veut le proposer.

## Ce qui est déjà en place

- `plugin.toml` : `id = "fxthiry/grafana-alerts"` (le répertoire dans leur dépôt doit
  s'appeler exactement `grafana-alerts`, nom libre au 27/08/2026), `version` semver,
  `plugin_api = 19`, `description` ≤ 120 caractères, `license = "MIT"`, `tags` pris dans
  leur vocabulaire fermé, `dependencies = ["notify-send", "xdg-open"]`.
- `README.md` au format de leur `README_TEMPLATE.md` : table *Plugin* avec les ids exacts,
  *Requirements* citant chaque dépendance par son nom de manifeste, *Usage* avec la
  commande `panel-toggle`, *Settings* avec les types, *Notes* listant réseau / process /
  fichiers. Leur CI vérifie la présence des ids, de la commande de panneau et des
  dépendances ; les mainteneurs relisent la prose.
- `thumbnail.webp` 960×540 (image de la carte dans le store). À regénérer si l'UI change :
  leur outil est <https://assets.noctalia.dev/plugins/thumbnail-generator.html>.
- `translations/en.json` couvre chaque `label_key` / `description_key` du manifeste
  (`noctalia plugins lint .` = 0 erreur).
- `.luaurc` identique au leur, `noctalia.d.luau` ignoré par git.

## Étapes

1. Fork de `noctalia-dev/community-plugins`, branche depuis `main`.
2. Copier ce dépôt dans `grafana-alerts/` à la racine du fork — **sans** `.git`,
   `screenshots/` (garder seulement ce que le README référence, ou déplacer les captures
   dans le README via des URLs GitHub de ce dépôt) et `PUBLISHING.md`. Seul
   `translations/en.json` existe, conformément à leur règle « `en.json` seulement » (les
   autres langues passent par <https://i18n.noctalia.dev>). Ne pas toucher à
   `catalog.toml` (généré par CI).
3. Vérifier en local avec leur checkout comme source :
   ```sh
   noctalia msg plugins source add dev path ~/dev/community-plugins
   noctalia msg plugins enable fxthiry/grafana-alerts
   ```
4. Ouvrir la PR vers `main` : **un plugin par PR**, captures d'écran jointes, et la
   description ci-dessous. À chaque modification ultérieure du plugin, bumper `version`.

## Description de PR (à coller)

```markdown
## fxthiry/grafana-alerts

Firing Grafana alerts in the bar (severity-tinted counter), a panel listing them with
labels, desktop notifications for new alerts, and one-click Alertmanager silences.

### What it does on the machine

- **Network** — only to the Grafana base URL the user configures, with the user's
  service-account token as `Authorization: Bearer`:
  - `GET /api/alertmanager/grafana/api/v2/alerts?active=true&silenced=false&inhibited=false`
    (+ user-defined `filter=` matchers) on every refresh (`refresh_interval`, 15 s min).
  - `POST /api/alertmanager/grafana/api/v2/silences` only when the user clicks
    *Silence* then *Confirm* on an alert (body: one `=` matcher per label of that alert,
    `createdBy = noctalia`, duration from `silence_duration`).
- **Spawned processes** — `notify-send` (new alert notification, `runAsync`, arguments
  shell-quoted) and `xdg-open <generatorURL>` when the user clicks an alert name.
  Both declared in `dependencies`.
- **Filesystem** — nothing written. Settings (including the token) live in Noctalia's
  own settings store.
- **State** — shared plugin state only (`alerts`, `counts`, `fetch_status`,
  `severity_colors`, `silence_status`…), between the service, the bar widget and the
  panel.

No remote code, no obfuscation, no generated code; every line is in the three `.luau`
files.

### Testing

Tested on Noctalia v5 (plugin API 19) against Grafana 11 unified alerting, with a
Viewer token (silences correctly refused with the 403 hint) and an Editor token.
```

## Rappels

- Le répertoire devient le nôtre après merge : personne ne le modifie sans notre accord,
  et on bumpe `version` à chaque changement.
- Pour arrêter de le maintenir : `deprecated = true` dans `plugin.toml`, pas de
  suppression du répertoire.
