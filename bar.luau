--!nonstrict
-- [[widget]] entry: glyph + firing-alert count, fed by the fetch service through
-- shared state. Tint and (by default) glyph follow the worst severity: configured
-- critical/warning colors published by the service as `severity_colors`, octagon /
-- triangle / bell glyphs, check mark and muted tint when all clear.
-- Click toggles the panel, right click opens the settings — so the tree contains
-- no inline ui.button (inline controls would eat their own clicks).

local PANEL_ID = "fxthiry/grafana-alerts:panel"
-- Theme roles used until the service has published its colors.
local FALLBACK_COLORS = { critical = "error", warning = "tertiary" }
local DEFAULT_GLYPH = "alert-triangle"
local SEVERITY_GLYPHS = { critical = "alert-octagon", warning = "alert-triangle", other = "bell" }

local tr = noctalia.tr

local counts = noctalia.state.get("counts")
local fetchStatus = noctalia.state.get("fetch_status") or "loading"
local errorMessage = noctalia.state.get("error_message") or ""
local errorKind = noctalia.state.get("error_kind") or ""
local offlineSinceText = noctalia.state.get("offline_since_text") or ""
local lastUpdatedText = noctalia.state.get("last_updated_text") or ""
local colors = noctalia.state.get("severity_colors")
local OFFLINE_GLYPH = "cloud-off"

-- Grafana unreachable (laptop off-site, VPN down): a quiet state, not an alarm.
local function isOffline()
  return fetchStatus == "error" and errorKind == "network"
end

local function severityColor(severity)
  local color = colors and colors[severity]
  if type(color) == "string" and color ~= "" then
    return color
  end
  return FALLBACK_COLORS[severity]
end

local function countText()
  if isOffline() then
    return tr("bar.offline")
  end
  if fetchStatus == "error" and (counts == nil or counts.total == 0) then
    return "!" -- not configured / unreachable: no number to trust
  end
  if counts ~= nil then
    return tostring(counts.total)
  end
  return "…"
end

local function tint()
  if isOffline() then
    return "on_surface_variant"
  end
  if fetchStatus == "error" then
    return "error"
  end
  if counts == nil then
    return "on_surface_variant"
  end
  if counts.critical > 0 then
    return severityColor("critical")
  end
  if counts.warning > 0 then
    return severityColor("warning")
  end
  if counts.total > 0 then
    return "on_surface"
  end
  return "on_surface_variant"
end

local function tooltipText()
  local parts = {}
  if isOffline() then
    table.insert(parts, tr("bar.tooltip_offline", { since = offlineSinceText, last = lastUpdatedText ~= "" and lastUpdatedText or "—" }))
  end
  if counts ~= nil then
    table.insert(parts, tr("bar.tooltip", {
      total = tostring(counts.total),
      critical = tostring(counts.critical),
      warning = tostring(counts.warning),
    }))
  end
  -- Fetch failed: say why, even when stale counts are still displayed.
  if fetchStatus == "error" and errorMessage ~= "" and not isOffline() then
    table.insert(parts, errorMessage)
  end
  return table.concat(parts, "\n")
end

local function configuredGlyph()
  local glyph = noctalia.getConfig("glyph")
  if type(glyph) ~= "string" or glyph == "" then
    return DEFAULT_GLYPH
  end
  return glyph
end

-- All clear → check mark; otherwise the worst firing severity picks the glyph,
-- unless the user turned that off (then the configured glyph is used as is).
local function glyphName()
  if isOffline() then
    return OFFLINE_GLYPH
  end
  if fetchStatus == "ok" and counts ~= nil and counts.total == 0 then
    return "circle-check"
  end
  if counts ~= nil and counts.total > 0 and noctalia.getConfig("glyph_by_severity") ~= false then
    if counts.critical > 0 then
      return SEVERITY_GLYPHS.critical
    end
    if counts.warning > 0 then
      return SEVERITY_GLYPHS.warning
    end
    return SEVERITY_GLYPHS.other
  end
  return configuredGlyph()
end

local function render()
  local hideWhenZero = noctalia.getConfig("hide_when_zero") == true
  if hideWhenZero and fetchStatus == "ok" and counts ~= nil and counts.total == 0 then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local glyph = glyphName()
  local color = tint()
  local isVertical = barWidget.isVertical()
  local container = isVertical and ui.column or ui.row
  local layout = { gap = 4, align = "center" }
  if isVertical then
    layout.paddingV = 4
  else
    layout.paddingH = 4
  end
  barWidget.render(container(layout, {
    ui.glyph({ name = glyph, size = 16, color = color }),
    ui.label({ text = countText(), color = color }),
  }))

  barWidget.setTooltip(tooltipText())
end

noctalia.state.watch("counts", function(value)
  counts = value
  render()
end)

-- fetch_status is published last by the service, so error_message is already current here.
noctalia.state.watch("fetch_status", function(value)
  fetchStatus = value
  errorMessage = noctalia.state.get("error_message") or ""
  errorKind = noctalia.state.get("error_kind") or ""
  offlineSinceText = noctalia.state.get("offline_since_text") or ""
  lastUpdatedText = noctalia.state.get("last_updated_text") or ""
  render()
end)

noctalia.state.watch("severity_colors", function(value)
  colors = value
  render()
end)

render()

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  noctalia.openSettings()
end

function onConfigChanged()
  render()
end
