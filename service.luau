--!nonstrict
-- [[service]] entry: polls the Grafana Alertmanager API and publishes the
-- firing alerts to the plugin's shared state for the bar widget and panel.
--
-- State keys published:
--   alerts             list of normalized alerts (see normalizeAlert), sorted by
--                      severity then start time (newest first)
--   counts             { total, critical, warning, info, other }
--   fetch_status       "loading" | "ok" | "error" (published last)
--   error_message      human readable error ("" when none)
--   last_updated_text  "%H:%M" of the last successful fetch
--   severity_colors    { critical, warning, info, other } — configured colors
--                      (hex) or theme role tokens, single source of truth for
--                      the bar widget and the panel
-- State keys consumed:
--   refresh_requested  bumped by the panel to force a refresh

local DEFAULT_INTERVAL_S = 60
local ALERTS_PATH = "/api/alertmanager/grafana/api/v2/alerts?active=true&silenced=false&inhibited=false"
local SEVERITY_RANK = { critical = 0, warning = 1, info = 2, other = 3 }
-- Fallbacks when the color settings are blank (keep in sync with plugin.toml defaults).
local DEFAULT_COLORS = { critical = "#ff5c5c", warning = "#f1c232" }

local trim = noctalia.string.trim
local tr = noctalia.tr

local generation = 0
local lastRefreshNonce = noctalia.state.get("refresh_requested") or 0

local function baseUrl()
  local url = trim(noctalia.getConfig("grafana_url") or "")
  return (url:gsub("/+$", ""))
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
  })
end

local function hiddenLabelSet()
  local set = {}
  local raw = noctalia.getConfig("hidden_labels")
  if type(raw) == "table" then
    for _, name in ipairs(raw) do
      set[trim(tostring(name))] = true
    end
  end
  return set
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

-- RFC 3339 → unix seconds (UTC), handling "Z" and "+hh:mm" offsets. No os.date in the sandbox.
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

local function normalizeAlert(raw, hidden)
  local labels = raw.labels or {}
  local annotations = raw.annotations or {}
  local name = labels.alertname or tr("service.unnamed")

  local tags = {}
  for key, value in pairs(labels) do
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
    severity = normalizeSeverity(labels.severity),
    severityLabel = trim(tostring(labels.severity or "")),
    folder = labels.grafana_folder or "",
    summary = trim(tostring(annotations.summary or "")),
    description = trim(tostring(annotations.description or "")),
    startedAt = startedAt,
    startedText = startedAt > 0 and noctalia.formatTime("%d/%m %H:%M", startedAt) or "",
    url = raw.generatorURL or (baseUrl() .. "/alerting/list"),
    tags = tags,
  }
end

local function computeCounts(alerts)
  local counts = { total = #alerts, critical = 0, warning = 0, info = 0, other = 0 }
  for _, alert in ipairs(alerts) do
    counts[alert.severity] += 1
  end
  return counts
end

local function publish(alerts, status, errorMessage, updated)
  noctalia.state.set("alerts", alerts)
  noctalia.state.set("counts", computeCounts(alerts))
  if updated then
    noctalia.state.set("last_updated_text", noctalia.formatTime("%H:%M"))
  end
  noctalia.state.set("error_message", errorMessage or "")
  noctalia.state.set("fetch_status", status)
end

local function previousAlerts()
  return noctalia.state.get("alerts") or {}
end

local function classify(res)
  if type(res) ~= "table" then
    return nil, tr("error.network")
  end
  if res.status == 401 or res.status == 403 then
    return nil, tr("error.unauthorized")
  end
  if res.status == 0 or res.status == nil then
    local body = trim(res.body or "")
    return nil, body ~= "" and body or tr("error.network")
  end
  if not res.ok or res.status < 200 or res.status >= 300 then
    return nil, tr("error.http", { status = tostring(res.status) })
  end
  local decoded = noctalia.json.decode(res.body or "")
  if type(decoded) ~= "table" then
    return nil, tr("error.parse")
  end
  return decoded, nil
end

local function startFetch()
  generation += 1
  local myGeneration = generation

  local url = baseUrl()
  local token = trim(noctalia.getConfig("api_token") or "")
  if url == "" or token == "" then
    publish({}, "error", tr("error.not_configured"), false)
    return
  end

  noctalia.state.set("fetch_status", "loading")

  local request = {
    url = url .. ALERTS_PATH,
    method = "GET",
    follow_redirects = true,
    allow_insecure_tls = noctalia.getConfig("allow_insecure_tls") == true,
    headers = {
      "Accept: application/json",
      "Authorization: Bearer " .. token,
    },
  }

  local started = noctalia.http(request, function(res)
    if myGeneration ~= generation then
      return -- superseded by a newer fetch
    end
    local ok, err = pcall(function()
      local data, message = classify(res)
      if data == nil then
        noctalia.log(`grafana-alerts: fetch failed: {message}`)
        publish(previousAlerts(), "error", message, false)
        return
      end

      local hidden = hiddenLabelSet()
      local ignoreDatasource = noctalia.getConfig("ignore_datasource_alerts") ~= false
      local alerts = {}
      for _, raw in ipairs(data) do
        local name = (raw.labels or {}).alertname or ""
        local state = (raw.status or {}).state or "active"
        local skip = state ~= "active"
          or (ignoreDatasource and (name == "DatasourceNoData" or name == "DatasourceError"))
        if not skip then
          table.insert(alerts, normalizeAlert(raw, hidden))
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
    end)
    if not ok then
      noctalia.log(`grafana-alerts: callback error: {tostring(err)}`)
      publish(previousAlerts(), "error", tostring(err), false)
    end
  end)

  if not started then
    publish(previousAlerts(), "error", tr("error.queue"), false)
  end
end

noctalia.state.watch("refresh_requested", function(value)
  if value ~= lastRefreshNonce then
    lastRefreshNonce = value
    startFetch()
  end
end)

function update()
  noctalia.setUpdateInterval(readIntervalMs())
  startFetch()
end

function onConfigChanged()
  publishColors()
  startFetch()
end

publishColors()
startFetch()
