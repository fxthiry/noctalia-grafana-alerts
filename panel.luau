--!nonstrict
-- [[panel]] entry: firing alerts rendered from the shared state published by
-- the fetch service. One card per alert: severity badge + name (click opens the
-- alert in Grafana), folder and start time, summary, then the label chips.

local MAX_ROWS = 100
-- ui.row has no wrap: chips are chunked into rows by estimated width (panel is 720 wide).
local CHIP_ROW_BUDGET = 620
local CHIP_CHAR_WIDTH = 6.3 -- ≈ px per character at fontSize 11
local CHIP_FIXED_WIDTH = 12 + 6 + 7 -- paddingH ×2, inner gaps, the "=" glyph
local AGE_REFRESH_MS = 30000 -- keep "x min ago" honest while the panel stays open
local CENTERED = { flexGrow = 1, align = "center", justify = "center", gap = 8 }
-- Theme roles used until the service has published its colors.
local FALLBACK_COLORS = { critical = "error", warning = "tertiary", info = "primary", other = "on_surface_variant" }
local SEVERITY_GLYPHS = { critical = "alert-octagon", warning = "alert-triangle", info = "info-circle", other = "bell" }

local tr = noctalia.tr

local alerts = {}
local counts = nil
local colors = nil
local fetchStatus = "loading"
local errorMessage = ""
local lastUpdatedText = ""
local isOpen = false

local render

local function syncFromState()
  alerts = noctalia.state.get("alerts") or {}
  counts = noctalia.state.get("counts")
  colors = noctalia.state.get("severity_colors")
  fetchStatus = noctalia.state.get("fetch_status") or "loading"
  errorMessage = noctalia.state.get("error_message") or ""
  lastUpdatedText = noctalia.state.get("last_updated_text") or ""
end

local function severityColor(severity)
  local color = colors and colors[severity]
  if type(color) == "string" and color ~= "" then
    return color
  end
  return FALLBACK_COLORS[severity] or FALLBACK_COLORS.other
end

local function severityStyle(severity)
  return { color = severityColor(severity), glyph = SEVERITY_GLYPHS[severity] or SEVERITY_GLYPHS.other }
end

local function requestRefresh()
  noctalia.state.set("refresh_requested", (noctalia.state.get("refresh_requested") or 0) + 1)
end

-- Theme roles take a "/alpha" suffix; hex colors get the alpha byte appended (#rrggbbaa).
local function withAlpha(color, alpha)
  if color:sub(1, 1) ~= "#" then
    return `{color}/{alpha}`
  end
  local hex = color:sub(2)
  if #hex == 3 then
    hex = hex:gsub(".", "%0%0")
  end
  if #hex ~= 6 then
    return color -- already carries an alpha byte, or unknown form: leave it alone
  end
  return string.format("#%s%02x", hex, math.floor(alpha * 255 + 0.5))
end

local function badge(text, color, fillAlpha)
  return ui.row({
    fill = withAlpha(color, fillAlpha),
    border = withAlpha(color, 0.24),
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

local function tagChip(tag)
  return ui.row({
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
  })
end

local function chipWidth(tag)
  return CHIP_FIXED_WIDTH + (#tag.key + #tag.value) * CHIP_CHAR_WIDTH
end

-- Greedy line breaking: one ui.row per line of chips.
local function tagRows(tags)
  local lines, current, used = {}, {}, 0
  local gap = 5
  for _, tag in ipairs(tags) do
    local width = chipWidth(tag)
    if #current > 0 and used + gap + width > CHIP_ROW_BUDGET then
      table.insert(lines, current)
      current, used = {}, 0
    end
    table.insert(current, tagChip(tag))
    used += (#current > 1 and gap or 0) + width
  end
  if #current > 0 then
    table.insert(lines, current)
  end

  local rows = {}
  for index, chips in ipairs(lines) do
    -- The row measures its content a few px short and clips its last child;
    -- a trailing filler label absorbs that shortfall instead of the last chip.
    table.insert(chips, ui.row({ key = "filler", minWidth = 24 }, { ui.label({ text = " " }) }))
    table.insert(rows, ui.row({ key = `tags:{index}`, gap = gap, align = "center" }, chips))
  end
  return rows
end

local function alertCard(alert)
  local style = severityStyle(alert.severity)
  local severityText = alert.severityLabel ~= "" and alert.severityLabel or tr("panel.severity." .. alert.severity)

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = style.glyph, size = 18, color = style.color }),
      ui.button({
        key = `open:{alert.id}`,
        text = alert.name,
        variant = "ghost",
        contentAlign = "start",
        flexGrow = 1,
        onClick = function()
          local url = "'" .. alert.url:gsub("'", "'\\''") .. "'"
          noctalia.runAsync("xdg-open " .. url)
        end,
      }),
      badge(severityText, style.color, 0.16),
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
    table.insert(children, ui.column({ gap = 5, align = "stretch" }, tagRows(alert.tags)))
  end

  return ui.column({
    key = `alert:{alert.id}`,
    gap = 6,
    paddingH = 12,
    paddingV = 10,
    align = "stretch",
    fill = "surface_variant/0.10",
    border = withAlpha(style.color, 0.35),
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
    table.insert(out, badge(tostring(counts.total), "primary", 0.14))
    for _, severity in ipairs({ "critical", "warning", "info", "other" }) do
      local n = counts[severity] or 0
      if n > 0 then
        table.insert(out, badge(`{n} {tr("panel.severity." .. severity)}`, severityColor(severity), 0.16))
      end
    end
  end
  return out
end

render = function()
  if not isOpen then
    return
  end

  local titleRow = { 
    ui.glyph({ name = "bell", size = 20, color = "primary" }),
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

noctalia.state.watch("severity_colors", function()
  syncFromState()
  render()
end)

function update()
  noctalia.setUpdateInterval(AGE_REFRESH_MS)
  render() -- no-op while closed; refreshes the relative ages while open
end

function onOpen(_context)
  syncFromState()
  isOpen = true
  render()
end

function onClose()
  isOpen = false
end
