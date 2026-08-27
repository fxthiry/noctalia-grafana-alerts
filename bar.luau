--!nonstrict
-- [[widget]] entry: glyph + firing-alert count, fed by the fetch service through
-- shared state. Tint follows the worst severity (error for critical, tertiary
-- for warning, muted when all clear). Click toggles the panel — so the tree
-- contains no inline ui.button (inline controls would eat their own clicks).

local PANEL_ID = "fxthiry/grafana-alerts:panel"

local counts = noctalia.state.get("counts")
local fetchStatus = noctalia.state.get("fetch_status") or "loading"

local function countText()
  if fetchStatus == "error" and (counts == nil or counts.total == 0) then
    return "!" -- not configured / unreachable: no number to trust
  end
  if counts ~= nil then
    return tostring(counts.total)
  end
  return "…"
end

local function configuredColor(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) ~= "string" or noctalia.string.trim(value) == "" then
    return fallback
  end
  return value
end

local function tint()
  if fetchStatus == "error" then
    return "error"
  end
  if counts == nil then
    return "on_surface_variant"
  end
  if counts.critical > 0 then
    return configuredColor("critical_color", "error")
  end
  if counts.warning > 0 then
    return configuredColor("warning_color", "#f1c232")
  end
  if counts.total > 0 then
    return "on_surface"
  end
  return "on_surface_variant"
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

  if counts ~= nil then
    barWidget.setTooltip(noctalia.tr("bar.tooltip", {
      total = tostring(counts.total),
      critical = tostring(counts.critical),
      warning = tostring(counts.warning),
    }))
  end
end

noctalia.state.watch("counts", function(value)
  counts = value
  render()
end)

noctalia.state.watch("fetch_status", function(value)
  fetchStatus = value
  render()
end)

render()

function update()
  noctalia.setUpdateInterval(5000)
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onConfigChanged()
  render()
end
