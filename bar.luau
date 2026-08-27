--!nonstrict
-- [[widget]] entry: glyph + firing-alert count, fed by the fetch service through
-- shared state. Tint follows the worst severity (configured critical/warning
-- colors published by the service as `severity_colors`, muted when all clear).
-- Click toggles the panel, right click opens the settings — so the tree contains
-- no inline ui.button (inline controls would eat their own clicks).

local PANEL_ID = "fxthiry/grafana-alerts:panel"
-- Theme roles used until the service has published its colors.
local FALLBACK_COLORS = { critical = "error", warning = "tertiary" }

local tr = noctalia.tr

local counts = noctalia.state.get("counts")
local fetchStatus = noctalia.state.get("fetch_status") or "loading"
local errorMessage = noctalia.state.get("error_message") or ""
local colors = noctalia.state.get("severity_colors")

local function severityColor(severity)
  local color = colors and colors[severity]
  if type(color) == "string" and color ~= "" then
    return color
  end
  return FALLBACK_COLORS[severity]
end

local function countText()
  if fetchStatus == "error" and (counts == nil or counts.total == 0) then
    return "!" -- not configured / unreachable: no number to trust
  end
  if counts ~= nil then
    return tostring(counts.total)
  end
  return "…"
end

local function tint()
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
  if counts ~= nil then
    table.insert(parts, tr("bar.tooltip", {
      total = tostring(counts.total),
      critical = tostring(counts.critical),
      warning = tostring(counts.warning),
    }))
  end
  -- Fetch failed: say why, even when stale counts are still displayed.
  if fetchStatus == "error" and errorMessage ~= "" then
    table.insert(parts, errorMessage)
  end
  return table.concat(parts, "\n")
end

local function render()
  local hideWhenZero = noctalia.getConfig("hide_when_zero") == true
  if hideWhenZero and fetchStatus == "ok" and counts ~= nil and counts.total == 0 then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local glyph = noctalia.getConfig("glyph")
  if type(glyph) ~= "string" or glyph == "" then
    glyph = "alert-triangle"
  end
  if fetchStatus == "ok" and counts ~= nil and counts.total == 0 then
    glyph = "circle-check"
  end

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
