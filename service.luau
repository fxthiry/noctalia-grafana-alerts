--!nonstrict
-- [[service]] entry: polls the Grafana Alertmanager API and publishes the
-- firing alerts to the plugin's shared state for the bar widget and panel.
-- Also owns the side effects: desktop notifications for new alerts and
-- silence creation requested from the panel (all HTTP stays here).
--
-- State keys published:
--   alerts             list of normalized alerts (see normalizeAlert), sorted by
--                      severity then start time (newest first)
--   counts             { total, critical, warning, info, other }
--   fetch_status       "loading" | "ok" | "error" (published last)
--   error_message      human readable error ("" when none)
--   error_kind         "network" (Grafana unreachable: laptop off-site, VPN down)
--                      | "other" | "" — the UI shows network errors as a quiet
--                      offline state rather than an alarm
--   offline_since_text "%H:%M" of the first failed fetch of the current outage ("")
--   last_updated_text  "%H:%M" of the last successful fetch
--   severity_colors    { critical, warning, info, other, ok } — configured colors
--                      (hex) or theme role tokens, single source of truth for
--                      the bar widget and the panel
--   silence_status     { nonce, id, status = "pending"|"ok"|"error", message }
-- State keys consumed:
--   refresh_requested  bumped by the panel to force a refresh
--   silence_requested  { nonce, id } set by the panel to silence one alert

local DEFAULT_INTERVAL_S = 60
local ALERTS_PATH = "/api/alertmanager/grafana/api/v2/alerts?active=true&silenced=false&inhibited=false"
local SILENCES_PATH = "/api/alertmanager/grafana/api/v2/silences"
local SEVERITY_RANK = { critical = 0, warning = 1, info = 2, other = 3 }
-- Fallbacks when the color settings are blank (keep in sync with plugin.toml defaults).
local DEFAULT_COLORS = { critical = "#ff5c5c", warning = "#f1c232", ok = "#3fb950" }
-- Above this many new alerts in one fetch, send a single summary notification.
local MAX_INDIVIDUAL_NOTIFICATIONS = 3
local DEFAULT_SILENCE_MINUTES = 120
-- Back online after an outage longer than this: the first fetch re-baselines
-- silently instead of notifying every change that happened meanwhile.
local REBASELINE_AFTER_OUTAGE_S = 600

local trim = noctalia.string.trim
local tr = noctalia.tr

local generation = 0
local lastRefreshNonce = noctalia.state.get("refresh_requested") or 0
local lastSilenceNonce = (noctalia.state.get("silence_requested") or {}).nonce or 0
-- Alerts of the last successful fetch, by fingerprint. nil until the first one:
-- that fetch is the baseline and never notifies (a restart is not "new alerts").
local known = nil
-- Set after a config change: the next fetch re-baselines silently (new filters
-- or severity label make alerts appear/vanish without anything really changing).
local rebaseline = false
-- Fingerprints silenced from the panel: their disappearance is not a resolution.
local silencedIds = {}
local notifySendAvailable = nil
-- First failed fetch of the current outage (unix seconds), nil while online.
local offlineSince = nil

local function baseUrl()
  local url = trim(noctalia.getConfig("grafana_url") or "")
  return (url:gsub("/+$", ""))
end

local function apiToken()
  return trim(noctalia.getConfig("api_token") or "")
end

local function readIntervalMs()
  local interval = tonumber(noctalia.getConfig("refresh_interval")) or DEFAULT_INTERVAL_S
  return math.max(15, interval) * 1000
end

local function configuredColor(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) ~= "string" or trim(value) == "" then
    return fallback
  end
  return trim(value)
end

local function publishColors()
  noctalia.state.set("severity_colors", {
    critical = configuredColor("critical_color", DEFAULT_COLORS.critical),
    warning = configuredColor("warning_color", DEFAULT_COLORS.warning),
    info = "primary",
    other = "on_surface_variant",
    ok = configuredColor("ok_color", DEFAULT_COLORS.ok),
  })
end

-- Name of the label carrying the severity ("severity" by default; some setups use "level").
local function severityLabelKey()
  local key = trim(tostring(noctalia.getConfig("severity_label") or ""))
  return key ~= "" and key or "severity"
end

local function hiddenLabelSet()
  local set = { [severityLabelKey()] = true }
  local raw = noctalia.getConfig("hidden_labels")
  if type(raw) == "table" then
    for _, name in ipairs(raw) do
      set[trim(tostring(name))] = true
    end
  end
  return set
end

local function percentEncode(s)
  return (s:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-- Alerts endpoint plus the user's matchers (`?filter=team=infra`, Alertmanager syntax).
local function alertsUrl()
  local url = baseUrl() .. ALERTS_PATH
  local filters = noctalia.getConfig("filters")
  if type(filters) == "table" then
    for _, raw in ipairs(filters) do
      local matcher = trim(tostring(raw))
      if matcher ~= "" then
        url ..= "&filter=" .. percentEncode(matcher)
      end
    end
  end
  return url
end

local function requestBase()
  return {
    follow_redirects = true,
    allow_insecure_tls = noctalia.getConfig("allow_insecure_tls") == true,
  }
end

local function authHeaders(extra)
  local headers = { "Accept: application/json", "Authorization: Bearer " .. apiToken() }
  for _, h in ipairs(extra or {}) do
    table.insert(headers, h)
  end
  return headers
end

-- Severity buckets: Grafana has no fixed vocabulary, so map the usual ones.
local function normalizeSeverity(raw)
  local s = trim(tostring(raw or "")):lower()
  if s == "critical" or s == "crit" or s == "error" or s == "fatal" or s == "emergency" or s == "p1" then
    return "critical"
  end
  if s == "warning" or s == "warn" or s == "high" or s == "major" or s == "p2" then
    return "warning"
  end
  if s == "info" or s == "informational" or s == "notice" or s == "low" or s == "minor" then
    return "info"
  end
  return "other"
end

-- Date helpers (no os.date/os.time in the sandbox). Days since 1970-01-01 <-> civil date,
-- after Howard Hinnant's algorithms.
local function daysFromCivil(y, m, d)
  if m <= 2 then
    y -= 1
  end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function civilFromDays(z)
  z += 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then
    y += 1
  end
  return y, m, d
end

-- RFC 3339 → unix seconds (UTC), handling "Z" and "+hh:mm" offsets.
local function isoToEpoch(iso)
  if type(iso) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s = iso:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
  if y == nil then
    return nil
  end
  local epoch = daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
  local sign, oh, om = iso:match("([%+%-])(%d%d):?(%d%d)$")
  if sign then
    local offset = tonumber(oh) * 3600 + tonumber(om) * 60
    epoch = sign == "+" and epoch - offset or epoch + offset
  end
  return epoch
end

-- unix seconds → RFC 3339 UTC ("2026-08-27T10:00:00Z"), what the silences API expects.
local function epochToIso(epoch)
  local days = math.floor(epoch / 86400)
  local rem = epoch - days * 86400
  local y, m, d = civilFromDays(days)
  return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", y, m, d,
    math.floor(rem / 3600), math.floor(rem % 3600 / 60), rem % 60)
end

local function nowSeconds()
  return math.floor(noctalia.nowMs() / 1000)
end

local function normalizeAlert(raw, hidden, severityKey)
  local labels = raw.labels or {}
  local annotations = raw.annotations or {}
  local name = labels.alertname or tr("service.unnamed")

  local allLabels = {}
  local tags = {}
  for key, value in pairs(labels) do
    allLabels[key] = tostring(value)
    if not hidden[key] and key:sub(1, 2) ~= "__" then
      table.insert(tags, { key = key, value = tostring(value) })
    end
  end
  table.sort(tags, function(a, b)
    return a.key < b.key
  end)

  local startedAt = isoToEpoch(raw.startsAt) or 0
  return {
    id = raw.fingerprint or name,
    name = name,
    severity = normalizeSeverity(labels[severityKey]),
    severityLabel = trim(tostring(labels[severityKey] or "")),
    folder = labels.grafana_folder or "",
    summary = trim(tostring(annotations.summary or "")),
    description = trim(tostring(annotations.description or "")),
    startedAt = startedAt,
    startedText = startedAt > 0 and noctalia.formatTime("%d/%m %H:%M", startedAt) or "",
    url = raw.generatorURL or (baseUrl() .. "/alerting/list"),
    tags = tags,
    labels = allLabels, -- full label set, used for silence matchers and copy
  }
end

local function computeCounts(alerts)
  local counts = { total = #alerts, critical = 0, warning = 0, info = 0, other = 0 }
  for _, alert in ipairs(alerts) do
    counts[alert.severity] += 1
  end
  return counts
end

local function publish(alerts, status, errorMessage, updated, errorKind)
  noctalia.state.set("alerts", alerts)
  noctalia.state.set("counts", computeCounts(alerts))
  if updated then
    noctalia.state.set("last_updated_text", noctalia.formatTime("%H:%M"))
  end
  noctalia.state.set("error_message", errorMessage or "")
  noctalia.state.set("error_kind", status == "error" and (errorKind or "other") or "")
  noctalia.state.set("offline_since_text", offlineSince and noctalia.formatTime("%H:%M", offlineSince) or "")
  noctalia.state.set("fetch_status", status)
end

local function previousAlerts()
  return noctalia.state.get("alerts") or {}
end

-- Shared HTTP error mapping; returns (decodedBody, nil, nil) or (nil, message, kind)
-- where kind is "network" (no answer at all) or "other".
local function classify(res, forbiddenKey)
  if type(res) ~= "table" then
    return nil, tr("error.network"), "network"
  end
  if res.status == 401 or res.status == 403 then
    return nil, tr(forbiddenKey or "error.unauthorized"), "other"
  end
  if res.status == 0 or res.status == nil then
    local body = trim(res.body or "")
    return nil, body ~= "" and body or tr("error.network"), "network"
  end
  if not res.ok or res.status < 200 or res.status >= 300 then
    local detail = ""
    local decoded = noctalia.json.decode(res.body or "")
    if type(decoded) == "table" and type(decoded.message) == "string" then
      detail = " — " .. decoded.message
    end
    return nil, tr("error.http", { status = tostring(res.status) }) .. detail, "other"
  end
  local decoded = noctalia.json.decode(res.body or "")
  if type(decoded) ~= "table" then
    return nil, tr("error.parse"), "other"
  end
  return decoded, nil, nil
end

-- Desktop notifications --------------------------------------------------------

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function sendNotification(urgency, icon, title, body)
  noctalia.log(`grafana-alerts: notify [{urgency}] {title}`)
  noctalia.runAsync(`notify-send -a {shellQuote(tr("title"))} -u {urgency} -i {icon} {shellQuote(title)} {shellQuote(body)}`)
end

local function alertBody(alert)
  if alert.summary ~= "" then
    return alert.summary
  end
  return alert.description ~= "" and alert.description or alert.folder
end

local function worstSeverity(list)
  local worst = "other"
  for _, alert in ipairs(list) do
    if SEVERITY_RANK[alert.severity] < SEVERITY_RANK[worst] then
      worst = alert.severity
    end
  end
  return worst
end

-- Up to MAX_INDIVIDUAL_NOTIFICATIONS one-per-alert notifications, else one summary.
local function notifyFiring(list)
  if #list <= MAX_INDIVIDUAL_NOTIFICATIONS then
    for _, alert in ipairs(list) do
      local title = alert.severityLabel ~= "" and `{alert.severityLabel}: {alert.name}` or alert.name
      sendNotification(alert.severity == "critical" and "critical" or "normal", "dialog-warning", title, alertBody(alert))
    end
    return
  end
  local names = {}
  for _, alert in ipairs(list) do
    table.insert(names, alert.name)
  end
  sendNotification(worstSeverity(list) == "critical" and "critical" or "normal", "dialog-warning",
    tr("notify.summary_title", { count = tostring(#list) }), table.concat(names, "\n"))
end

local function notifyResolved(list)
  if #list <= MAX_INDIVIDUAL_NOTIFICATIONS then
    for _, alert in ipairs(list) do
      sendNotification("low", "dialog-information", tr("notify.resolved_title", { name = alert.name }), alertBody(alert))
    end
    return
  end
  local names = {}
  for _, alert in ipairs(list) do
    table.insert(names, alert.name)
  end
  sendNotification("low", "dialog-information",
    tr("notify.resolved_summary_title", { count = tostring(#list) }), table.concat(names, "\n"))
end

-- Diff the fetch against the previous one: alerts that appeared start firing,
-- alerts that vanished are resolved (unless we silenced them ourselves).
local function notifyChanges(alerts)
  local current = {}
  for _, alert in ipairs(alerts) do
    current[alert.id] = alert
  end
  local baseline = known
  known = current
  if baseline == nil or rebaseline then
    rebaseline = false
    return
  end

  local maxRank = SEVERITY_RANK[normalizeSeverity(noctalia.getConfig("notify_min_severity"))] or SEVERITY_RANK.warning
  local fresh, resolved = {}, {}
  if noctalia.getConfig("notify_new_alerts") ~= false then
    for _, alert in ipairs(alerts) do
      if not baseline[alert.id] and SEVERITY_RANK[alert.severity] <= maxRank then
        table.insert(fresh, alert)
      end
    end
  end
  for id, alert in pairs(baseline) do
    if current[id] == nil then
      if silencedIds[id] then
        silencedIds[id] = nil
      elseif noctalia.getConfig("notify_resolved") ~= false and SEVERITY_RANK[alert.severity] <= maxRank then
        table.insert(resolved, alert)
      end
    end
  end
  table.sort(resolved, function(a, b)
    return a.name < b.name
  end)
  if #fresh == 0 and #resolved == 0 then
    return
  end

  if notifySendAvailable == nil then
    notifySendAvailable = noctalia.commandExists("notify-send") ~= false
  end
  if not notifySendAvailable then
    noctalia.log("grafana-alerts: notify-send not found, skipping desktop notification")
    return
  end
  if #fresh > 0 then
    notifyFiring(fresh)
  end
  if #resolved > 0 then
    notifyResolved(resolved)
  end
end

-- Fetch ------------------------------------------------------------------------

local function startFetch()
  generation += 1
  local myGeneration = generation

  local url = baseUrl()
  if url == "" or apiToken() == "" then
    publish({}, "error", tr("error.not_configured"), false)
    return
  end

  noctalia.state.set("fetch_status", "loading")

  local request = requestBase()
  request.url = alertsUrl()
  request.method = "GET"
  request.headers = authHeaders()

  local started = noctalia.http(request, function(res)
    if myGeneration ~= generation then
      return -- superseded by a newer fetch
    end
    local ok, err = pcall(function()
      local data, message, kind = classify(res)
      if data == nil then
        if kind == "network" then
          -- Off-site laptop / VPN down: log once per outage, not every fetch.
          if offlineSince == nil then
            offlineSince = nowSeconds()
            noctalia.log(`grafana-alerts: Grafana unreachable ({message}), going offline`)
          end
        else
          noctalia.log(`grafana-alerts: fetch failed: {message}`)
        end
        publish(previousAlerts(), "error", message, false, kind)
        return
      end
      if offlineSince ~= nil then
        local outage = nowSeconds() - offlineSince
        offlineSince = nil
        if outage > REBASELINE_AFTER_OUTAGE_S then
          rebaseline = true -- what fired or resolved during a long outage is history, not news
        end
        noctalia.log(`grafana-alerts: back online after {outage}s{rebaseline and ", re-baselining" or ""}`)
      end

      local hidden = hiddenLabelSet()
      local severityKey = severityLabelKey()
      local ignoreDatasource = noctalia.getConfig("ignore_datasource_alerts") ~= false
      local alerts = {}
      for _, raw in ipairs(data) do
        local name = (raw.labels or {}).alertname or ""
        local state = (raw.status or {}).state or "active"
        local skip = state ~= "active"
          or (ignoreDatasource and (name == "DatasourceNoData" or name == "DatasourceError"))
        if not skip then
          table.insert(alerts, normalizeAlert(raw, hidden, severityKey))
        end
      end
      table.sort(alerts, function(a, b)
        local ra, rb = SEVERITY_RANK[a.severity], SEVERITY_RANK[b.severity]
        if ra ~= rb then
          return ra < rb
        end
        if a.startedAt ~= b.startedAt then
          return a.startedAt > b.startedAt
        end
        return a.name < b.name
      end)
      publish(alerts, "ok", "", true)
      notifyChanges(alerts)
    end)
    if not ok then
      noctalia.log(`grafana-alerts: callback error: {tostring(err)}`)
      publish(previousAlerts(), "error", tostring(err), false, "other")
    end
  end)

  if not started then
    publish(previousAlerts(), "error", tr("error.queue"), false, "other")
  end
end

-- Silences ---------------------------------------------------------------------

local function publishSilence(nonce, id, status, message)
  noctalia.state.set("silence_status", { nonce = nonce, id = id, status = status, message = message or "" })
end

local function silenceAlert(nonce, id)
  local alert = nil
  for _, candidate in ipairs(previousAlerts()) do
    if candidate.id == id then
      alert = candidate
      break
    end
  end
  if alert == nil then
    publishSilence(nonce, id, "error", tr("silence.not_found"))
    return
  end
  publishSilence(nonce, id, "pending", "")

  -- Match the alert's own labels, like Grafana's "Silence" button does; the
  -- __grafana_* routing labels are skipped (they change with the policy tree).
  local matchers = {}
  for key, value in pairs(alert.labels or {}) do
    if key:sub(1, 10) ~= "__grafana_" then
      table.insert(matchers, { name = key, value = value, isRegex = false, isEqual = true })
    end
  end
  table.sort(matchers, function(a, b)
    return a.name < b.name
  end)

  local minutes = tonumber(noctalia.getConfig("silence_duration")) or DEFAULT_SILENCE_MINUTES
  minutes = math.max(5, minutes)
  local now = nowSeconds()
  local request = requestBase()
  request.url = baseUrl() .. SILENCES_PATH
  request.method = "POST"
  request.headers = authHeaders({ "Content-Type: application/json" })
  request.body = noctalia.json.encode({
    matchers = matchers,
    startsAt = epochToIso(now),
    endsAt = epochToIso(now + minutes * 60),
    createdBy = "noctalia",
    comment = tr("silence.comment", { minutes = tostring(minutes) }),
  })

  local started = noctalia.http(request, function(res)
    local ok, err = pcall(function()
      local data, message = classify(res, "silence.forbidden")
      if data == nil then
        noctalia.log(`grafana-alerts: silence failed: {message}`)
        publishSilence(nonce, id, "error", message)
        return
      end
      noctalia.log(`grafana-alerts: silenced {alert.name} for {minutes} min (silence {tostring(data.silenceID)})`)
      silencedIds[id] = true -- it will vanish from the list: not a resolution
      publishSilence(nonce, id, "ok", "")
      startFetch() -- the alert leaves the active&silenced=false list
    end)
    if not ok then
      publishSilence(nonce, id, "error", tostring(err))
    end
  end)
  if not started then
    publishSilence(nonce, id, "error", tr("error.queue"))
  end
end

-- Wiring -----------------------------------------------------------------------

noctalia.state.watch("refresh_requested", function(value)
  if value ~= lastRefreshNonce then
    lastRefreshNonce = value
    startFetch()
  end
end)

noctalia.state.watch("silence_requested", function(value)
  if type(value) == "table" and value.nonce ~= lastSilenceNonce then
    lastSilenceNonce = value.nonce
    silenceAlert(value.nonce, value.id)
  end
end)

function update()
  noctalia.setUpdateInterval(readIntervalMs())
  startFetch()
end

function onConfigChanged()
  publishColors()
  rebaseline = true
  startFetch()
end

publishColors()
startFetch()
