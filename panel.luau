--!nonstrict
-- [[panel]] entry: firing alerts rendered from the shared state published by
-- the fetch service. One card per alert: severity badge + name (click opens the
-- alert in Grafana), folder and start time, summary, then the label chips.

local MAX_ROWS = 100
local CENTERED = { flexGrow = 1, align = "center", justify = "center", gap = 8 }

local SEVERITY_STYLE = {
  critical = { color = "error", glyph = "alert-octagon" },
  warning = { color = "tertiary", glyph = "alert-triangle" },
  info = { color = "primary", glyph = "info-circle" },
  other = { color = "on_surface_variant", glyph = "bell" },
}

local tr = noctalia.tr

local alerts = {}
local counts = nil
local fetchStatus = "loading"
local errorMessage = ""
local lastUpdatedText = ""
local isOpen = false

local render

local function syncFromState()
  alerts = noctalia.state.get("alerts") or {}
  counts = noctalia.state.get("counts")
  fetchStatus = noctalia.state.get("fetch_status") or "loading"
  errorMessage = noctalia.state.get("error_message") or ""
  lastUpdatedText = noctalia.state.get("last_updated_text") or ""
end

local function requestRefresh()
  noctalia.state.set("refresh_requested", (noctalia.state.get("refresh_requested") or 0) + 1)
end

local function badge(text, color, fillAlpha)
  return ui.row({
    fill = `{color}/{fillAlpha}`,
    border = color .. "/0.24",
    borderWidth = 1,
    radius = 8,
    paddingH = 7,
    paddingV = 2,
    align = "center",
  }, {
    ui.label({ text = text, fontSize = 12, fontWeight = "medium", color = color }),
  })
end

local function ageText(startedAt)
  if startedAt == nil or startedAt <= 0 then
    return ""
  end
  local seconds = math.max(0, math.floor(noctalia.nowMs() / 1000) - startedAt)
  if seconds < 60 then
    return tr("panel.age.now")
  end
  local minutes = math.floor(seconds / 60)
  if minutes < 60 then
    return tr("panel.age.minutes", { count = tostring(minutes) })
  end
  local hours = math.floor(minutes / 60)
  if hours < 48 then
    return tr("panel.age.hours", { hours = tostring(hours), minutes = tostring(minutes % 60) })
  end
  return tr("panel.age.days", { count = tostring(math.floor(hours / 24)) })
end

local function tagChips(tags)
  local chips = {}
  for _, tag in ipairs(tags) do
    table.insert(chips, ui.row({
      key = `tag:{tag.key}`,
      fill = "surface_variant/0.6",
      border = "outline/0.3",
      borderWidth = 1,
      radius = 6,
      paddingH = 6,
      paddingV = 2,
      gap = 3,
      align = "center",
    }, {
      ui.label({ text = tag.key, fontSize = 11, color = "on_surface_variant" }),
      ui.label({ text = "=", fontSize = 11, color = "outline" }),
      ui.label({ text = tag.value, fontSize = 11, fontWeight = "medium", color = "on_surface" }),
    }))
  end
  return chips
end

local function alertCard(alert)
  local style = SEVERITY_STYLE[alert.severity] or SEVERITY_STYLE.other
  local severityText = alert.severityLabel ~= "" and alert.severityLabel or tr("panel.severity." .. alert.severity)

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = style.glyph, size = 18, color = style.color }),
      ui.button({
        key = `open:{alert.id}`,
        text = alert.name,
        fontWeight = "bold",
        variant = "ghost",
        contentAlign = "start",
        flexGrow = 1,
        onClick = function()
          local url = "'" .. alert.url:gsub("'", "'\\''") .. "'"
          noctalia.runAsync("xdg-open " .. url)
        end,
      }),
      badge(severityText, style.color, "0.16"),
    }),
  }

  local metaParts = {}
  if alert.folder ~= "" then
    table.insert(metaParts, alert.folder)
  end
  if alert.startedText ~= "" then
    table.insert(metaParts, tr("panel.since", { time = alert.startedText, age = ageText(alert.startedAt) }))
  end
  if #metaParts > 0 then
    table.insert(children, ui.label({
      text = table.concat(metaParts, "  ·  "),
      fontSize = 12,
      color = "on_surface_variant",
      maxLines = 1,
    }))
  end

  local text = alert.summary ~= "" and alert.summary or alert.description
  if text ~= "" then
    table.insert(children, ui.label({ text = text, fontSize = 13, color = "on_surface", maxLines = 3 }))
  end

  if #alert.tags > 0 then
    table.insert(children, ui.row({ gap = 5, wrap = true, align = "center" }, tagChips(alert.tags)))
  end

  return ui.column({
    key = `alert:{alert.id}`,
    gap = 6,
    paddingH = 12,
    paddingV = 10,
    align = "stretch",
    fill = "surface_variant/0.10",
    border = style.color .. "/0.35",
    borderWidth = 1,
    radius = 11,
  }, children)
end

local function rows()
  local out = {}
  for index, alert in ipairs(alerts) do
    if index > MAX_ROWS then
      table.insert(out, ui.label({
        key = "more_rows",
        text = tr("panel.more_rows", { count = tostring(#alerts - MAX_ROWS) }),
        fontSize = 11,
        color = "on_surface_variant",
      }))
      break
    end
    table.insert(out, alertCard(alert))
  end
  return out
end

local function body()
  if #alerts == 0 then
    if fetchStatus == "loading" then
      return ui.column(CENTERED, {
        ui.label({ text = tr("panel.loading"), color = "on_surface_variant" }),
      })
    end
    if fetchStatus == "error" then
      return ui.column(CENTERED, {
        ui.label({ text = tr("panel.error_title"), fontWeight = "bold", color = "error" }),
        ui.label({ text = errorMessage, color = "on_surface_variant", maxLines = 4, textAlign = "center" }),
        ui.row({ gap = 8 }, {
          ui.button({ text = tr("panel.retry"), variant = "primary", onClick = requestRefresh }),
          ui.button({
            text = tr("panel.settings"),
            variant = "ghost",
            onClick = function()
              noctalia.openSettings()
            end,
          }),
        }),
      })
    end
    return ui.column(CENTERED, {
      ui.glyph({ name = "circle-check", size = 32, color = "primary" }),
      ui.label({ text = tr("panel.empty"), color = "on_surface_variant", textAlign = "center" }),
    })
  end
  return ui.scroll({ flexGrow = 1, gap = 10, align = "stretch" }, rows())
end

local function headerBadges()
  local out = {}
  if counts ~= nil then
    table.insert(out, badge(tostring(counts.total), "primary", "0.14"))
    if counts.critical > 0 then
      table.insert(out, badge(`{counts.critical} {tr("panel.severity.critical")}`, "error", "0.16"))
    end
    if counts.warning > 0 then
      table.insert(out, badge(`{counts.warning} {tr("panel.severity.warning")}`, "tertiary", "0.16"))
    end
  end
  return out
end

render = function()
  if not isOpen then
    return
  end

  local titleRow = { 
    ui.glyph({ name = "brand-grafana", size = 20, color = "primary" }),
    ui.label({ text = tr("title"), fontSize = 17, fontWeight = "bold", color = "on_surface" }),
  }
  for _, node in ipairs(headerBadges()) do
    table.insert(titleRow, node)
  end

  local children = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ gap = 8, align = "center", flexGrow = 1 }, titleRow),
      ui.label({
        text = lastUpdatedText ~= "" and tr("panel.updated_at", { time = lastUpdatedText }) or "",
        fontSize = 11,
        color = "on_surface_variant",
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        enabled = fetchStatus ~= "loading",
        onClick = requestRefresh,
      }),
      ui.button({ glyph = "close", onClick = panel.close }),
    }),
  }

  -- Stale data: keep showing the last good list but warn.
  if errorMessage ~= "" and #alerts > 0 then
    table.insert(children, ui.label({ text = errorMessage, fontSize = 11, color = "error", maxLines = 2 }))
  end

  table.insert(children, body())
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

noctalia.state.watch("fetch_status", function()
  syncFromState()
  render()
end)

function onOpen(_context)
  syncFromState()
  isOpen = true
  render()
end

function onClose()
  isOpen = false
end
