-- Ukraine Air Alert bar widget
--
-- One region per widget instance. To watch more than one region, add this
-- widget to the bar again (Settings -> Bar -> add widget -> Ukraine Air
-- Alert) and pick a different region in that instance's own settings.
--
-- Two backends, picked automatically:
--   A) api.ukrainealarm.com  - used when an API token is configured.
--      Request one via the form on https://api.ukrainealarm.com, and get
--      your region id from GET /api/v3/regions with that token.
--   B) air-save.ops.ajax.systems - the public AJAX status API, used when no
--      token is set. No key needed, but rate-limited to ~1 request/15s -
--      enforced here via noctalia.state, which is shared across every
--      instance of this widget, so adding more regions doesn't multiply the
--      effective request rate against the shared limit.
--
-- Both backends now report an alert *level* alongside the alert type:
--   red    - full air raid alert (sirens), take shelter
--   yellow - threat warning / pre-alert, be ready
-- Alerts with no level attached (artillery, urban fights, ...) are treated as
-- red; informational ones (INFO/CUSTOM) with no level are treated as yellow.

local REGION_NAMES = {
  ["3"] = "Khmelnytskyi", ["4"] = "Vinnytsia", ["5"] = "Rivne",
  ["8"] = "Volyn", ["9"] = "Dnipropetrovsk", ["10"] = "Zhytomyr",
  ["11"] = "Zakarpattia", ["12"] = "Zaporizhzhia", ["13"] = "Ivano-Frankivsk",
  ["14"] = "Kyiv", ["15"] = "Kirovohrad", ["16"] = "Luhansk",
  ["17"] = "Mykolaiv", ["18"] = "Odesa", ["19"] = "Poltava",
  ["20"] = "Sumy", ["21"] = "Ternopil", ["22"] = "Kharkiv",
  ["23"] = "Kherson", ["24"] = "Cherkasy", ["25"] = "Chernihiv",
  ["26"] = "Chernivtsi", ["27"] = "Lviv", ["28"] = "Donetsk",
  ["31"] = "Kyiv (city)", ["564"] = "Zaporizhzhia (city)",
  ["1293"] = "Kharkiv (city)", ["9999"] = "Crimea (AR)",
}

local AJAX_MIN_INTERVAL_MS = 15000 -- hard floor: public API is rate-limited
local AJAX_STATE_KEY = "ajax_last_request_ms" -- shared across every instance
local STATUS_STATE_PREFIX = "status:" -- + backend + ":" + regionId, for output mirroring
local MIRROR_STALE_MS = 5 * 60 * 1000 -- treat a mirrored status older than this as stale

-- Alert types that are advisories rather than sirens. When the API attaches
-- no explicit level to one of these, it counts as yellow instead of red.
local ADVISORY_TYPES = { INFO = true, CUSTOM = true }

-- Tiny deterministic string hash, used to jitter each instance's poll phase
-- so identically-configured instances don't stay locked in perfect sync
-- (which would let one permanently starve the other under the shared
-- AJAX rate limit above).
local function simpleHash(s)
  local h = 0
  for i = 1, #s do
    h = (h * 31 + string.byte(s, i)) % 1000000
  end
  return h
end

local lastLevel = nil -- "clear" | "red" | "yellow"; avoids redundant notifications
local hasEverRendered = false
local fetching = false
local fetchStartedAtMs = nil
local FETCH_TIMEOUT_MS = 20000 -- watchdog: treat a stuck in-flight fetch as dead after this

local function beginFetch()
  fetching = true
  fetchStartedAtMs = noctalia.nowMs()
end

local function endFetch()
  fetching = false
  fetchStartedAtMs = nil
end

local function applyState(kind, text, tooltip)
  -- kind: "red" | "yellow" | "clear" | "error" | "unconfigured" | "pending"
  noctalia.log("ukrainealarm: applyState(" .. kind .. ")")

  if kind == "red" then
    barWidget.setGlyph("alert-triangle-filled")
    barWidget.setGlyphColor("#E5484D")
    barWidget.setColor("#E5484D")
  elseif kind == "yellow" then
    barWidget.setGlyph("alert-triangle")
    barWidget.setGlyphColor("#FFC53D")
    barWidget.setColor("")
  elseif kind == "clear" then
    barWidget.setGlyph("shield-check")
    barWidget.setGlyphColor("#30A46C")
    barWidget.setColor("") -- explicit reset, not a skipped call - see notes in README
  elseif kind == "unconfigured" then
    barWidget.setGlyph("settings")
    barWidget.setGlyphColor("#8B8D98")
    barWidget.setColor("")
  elseif kind == "pending" then
    barWidget.setGlyph("hourglass")
    barWidget.setGlyphColor("#8B8D98")
    barWidget.setColor("")
  else -- error
    barWidget.setGlyph("help-circle")
    barWidget.setGlyphColor("#8B8D98")
    barWidget.setColor("")
  end

  barWidget.setText(text)
  barWidget.setTooltip(tooltip)
end

local function isPrimaryOutput()
  local primaryOutput = noctalia.getConfig("primary_output")
  if primaryOutput == nil or primaryOutput == "" then
    return true -- not configured: no restriction, every instance fetches independently
  end
  return barWidget.outputName() == primaryOutput
end

local function statusKey(backendTag, regionId)
  return STATUS_STATE_PREFIX .. backendTag .. ":" .. regionId
end

-- level: "red" | "yellow" | nil (clear)
local function publishStatus(backendTag, regionId, level, name, detail)
  local ok, encoded = pcall(function()
    return noctalia.json.encode({
      active = level ~= nil,
      level = level,
      name = name,
      detail = detail,
      updatedAtMs = noctalia.nowMs(),
    })
  end)
  if ok then
    noctalia.state.set(statusKey(backendTag, regionId), encoded)
  end
end

-- Map an API-provided level string ("Red"/"RED"/"Yellow"/...) to our
-- canonical "red"/"yellow", or nil when absent/unknown.
local function normalizeLevel(raw)
  if type(raw) ~= "string" then
    return nil
  end
  local u = string.upper(raw)
  if u == "RED" then
    return "red"
  elseif u == "YELLOW" then
    return "yellow"
  end
  return nil
end

-- Level implied by an alert that carries no explicit level of its own.
local function impliedLevel(alertType)
  if ADVISORY_TYPES[string.upper(tostring(alertType or ""))] then
    return "yellow"
  end
  return "red"
end

-- Combine two levels, keeping the more severe one.
local function worstLevel(a, b)
  if a == "red" or b == "red" then
    return "red"
  elseif a == "yellow" or b == "yellow" then
    return "yellow"
  end
  return nil
end

local function levelLabel(level)
  if level == "red" then
    return noctalia.tr("widget.level.red")
  end
  return noctalia.tr("widget.level.yellow")
end

-- Sorted, de-duplicated list of alert type names for the tooltip.
local function kindList(kinds)
  local list = {}
  for k, _ in pairs(kinds) do
    table.insert(list, k)
  end
  table.sort(list)
  return list
end

-- level: "red" | "yellow" | nil (clear)
local function reportAlertState(level, statusText)
  if level == "red" then
    applyState("red", "!", statusText)
    if lastLevel ~= "red" then
      noctalia.notify(noctalia.tr("widget.alert_title"), statusText)
    end
    lastLevel = "red"
  elseif level == "yellow" then
    applyState("yellow", "", statusText)
    if lastLevel ~= "yellow" then
      noctalia.notify(noctalia.tr("widget.yellow_title"), statusText)
    end
    lastLevel = "yellow"
  else
    applyState("clear", "", statusText)
    if lastLevel == "red" or lastLevel == "yellow" then
      noctalia.notify(noctalia.tr("widget.clear_title"), statusText)
    end
    lastLevel = "clear"
  end
end

-- Backend A: api.ukrainealarm.com
local function fetchViaToken(token, regionId)
  noctalia.http({
    url = "https://api.ukrainealarm.com/api/v3/alerts/" .. noctalia.string.urlEncode(regionId),
    method = "GET",
    headers = {
      "Authorization: " .. token,
      "Accept: application/json",
    },
  }, function(res)
    endFetch()

    if not res.ok or res.status ~= 200 then
      noctalia.log("ukrainealarm: request failed, status " .. tostring(res.status))
      applyState("error", "?", noctalia.tr("widget.error", { status = tostring(res.status) }))
      return
    end

    local ok, procErr = pcall(function()
      local data, err = noctalia.json.decode(res.body)
      if data == nil or type(data) ~= "table" or data[1] == nil then
        noctalia.log("ukrainealarm: bad response body: " .. tostring(err))
        applyState("error", "?", noctalia.tr("widget.parse_error"))
        return
      end

      local region = data[1]
      local activeAlerts = region.activeAlerts or {}
      local regionName = region.regionEngName or region.regionName or regionId

      if #activeAlerts > 0 then
        local kinds = {}
        local reasons = {}
        local level = nil
        for _, a in ipairs(activeAlerts) do
          kinds[a.type or "UNKNOWN"] = true
          -- v3 attaches zero or more {alertLevel, reason, createdAt} entries
          -- per alert; take the worst one. No entries -> level implied by type.
          local alertLevel = nil
          for _, l in ipairs(a.activeAlertLevels or {}) do
            alertLevel = worstLevel(alertLevel, normalizeLevel(l.alertLevel))
            if l.reason ~= nil and l.reason ~= "" then
              reasons[l.reason] = true
            end
          end
          if alertLevel == nil then
            alertLevel = impliedLevel(a.type)
          end
          level = worstLevel(level, alertLevel)
        end

        local statusText = noctalia.trp("widget.alert_count", #activeAlerts, { region = regionName })
        local lines = { levelLabel(level), statusText, table.concat(kindList(kinds), ", ") }
        local reasonList = kindList(reasons)
        if #reasonList > 0 then
          table.insert(lines, table.concat(reasonList, "; "))
        end
        local detail = table.concat(lines, "\n")
        noctalia.log("ukrainealarm[" .. regionId .. "]: level=" .. level .. " (" .. table.concat(kindList(kinds), ", ") .. ")")
        reportAlertState(level, detail)
        publishStatus("token", regionId, level, regionName, detail)
      else
        local detail = noctalia.tr("widget.clear", { region = regionName })
        noctalia.log("ukrainealarm[" .. regionId .. "]: level=clear")
        reportAlertState(nil, detail)
        publishStatus("token", regionId, nil, regionName, detail)
      end
    end)

    if not ok then
      noctalia.log("ukrainealarm[" .. regionId .. "]: error processing response: " .. tostring(procErr))
      applyState("error", "?", noctalia.tr("widget.parse_error"))
    end
  end)
end

-- Backend B: public AJAX status API (no token; rate-limited across every
-- instance of this widget via noctalia.state)
local function fetchViaAjax(ajaxRegionId)
  local nowMs = noctalia.nowMs()
  local lastRequestAtMs = noctalia.state.get(AJAX_STATE_KEY)
  local elapsedMs = (lastRequestAtMs ~= nil) and (nowMs - lastRequestAtMs) or nil
  -- elapsedMs < 0 means the clock moved backward since the last recorded
  -- request (e.g. suspend/resume) - don't let that block requests forever.
  if elapsedMs ~= nil and elapsedMs >= 0 and elapsedMs < AJAX_MIN_INTERVAL_MS then
    endFetch()
    return -- another instance (or this one) requested recently; skip this tick
  end
  noctalia.state.set(AJAX_STATE_KEY, nowMs)

  noctalia.http({
    url = "https://air-save.ops.ajax.systems/api/mobile/status/regions/v2?regions=" .. noctalia.string.urlEncode(ajaxRegionId),
    method = "GET",
  }, function(res)
    endFetch()

    if not res.ok or res.status ~= 200 then
      noctalia.log("ukrainealarm(ajax): request failed, status " .. tostring(res.status))
      applyState("error", "?", noctalia.tr("widget.error", { status = tostring(res.status) }))
      return
    end

    local ok, procErr = pcall(function()
      local data, err = noctalia.json.decode(res.body)
      if data == nil or type(data) ~= "table" or data.alarms == nil then
        noctalia.log("ukrainealarm(ajax): bad response body: " .. tostring(err))
        applyState("error", "?", noctalia.tr("widget.parse_error"))
        return
      end

      local regionName = REGION_NAMES[ajaxRegionId] or ("Region " .. ajaxRegionId)
      local includeChildren = noctalia.getConfig("alert_scope") == "children"

      -- The response is already scoped to the requested region: an alarm
      -- whose regionId matches is region-wide; any other id is a district /
      -- community inside it (only counted with alert_scope = "children").
      local level, kinds = nil, {}
      local ownCount, childCount = 0, 0
      for _, alarm in ipairs(data.alarms) do
        local isOwn = tostring(alarm.regionId) == ajaxRegionId
        if isOwn or includeChildren then
          local alarmLevel = normalizeLevel(alarm.alertLevel) or impliedLevel(alarm.alarmType)
          level = worstLevel(level, alarmLevel)
          kinds[alarm.alarmType or "UNKNOWN"] = true
          if isOwn then
            ownCount = ownCount + 1
          else
            childCount = childCount + 1
          end
        end
      end

      noctalia.log("ukrainealarm(ajax)[" .. ajaxRegionId .. "]: level=" .. tostring(level) .. " own=" .. ownCount .. " children=" .. childCount .. " (" .. #data.alarms .. " alarms in response)")

      if level ~= nil then
        local lines = { levelLabel(level) }
        if ownCount > 0 then
          table.insert(lines, noctalia.trp("widget.alert_count", ownCount, { region = regionName }))
        end
        if childCount > 0 then
          table.insert(lines, noctalia.trp("widget.child_alert_count", childCount, { region = regionName }))
        end
        table.insert(lines, table.concat(kindList(kinds), ", "))
        local detail = table.concat(lines, "\n")
        reportAlertState(level, detail)
        publishStatus("ajax", ajaxRegionId, level, regionName, detail)
      else
        local detail = noctalia.tr("widget.clear", { region = regionName })
        reportAlertState(nil, detail)
        publishStatus("ajax", ajaxRegionId, nil, regionName, detail)
      end
    end)

    if not ok then
      noctalia.log("ukrainealarm(ajax)[" .. ajaxRegionId .. "]: error processing response: " .. tostring(procErr))
      applyState("error", "?", noctalia.tr("widget.parse_error"))
    end
  end)
end

local function mirrorStatus()
  local token = noctalia.getConfig("api_token")
  local hasToken = token ~= nil and token ~= ""
  local backendTag, regionId

  if hasToken then
    regionId = noctalia.getConfig("region_id")
    backendTag = "token"
    if regionId == nil or regionId == "" then
      applyState("unconfigured", "", noctalia.tr("widget.unconfigured_region_id"))
      return
    end
  else
    regionId = noctalia.getConfig("ajax_region")
    backendTag = "ajax"
    if regionId == nil or regionId == "" or regionId == "0" then
      applyState("unconfigured", "", noctalia.tr("widget.unconfigured_ajax_region"))
      return
    end
  end

  local raw = noctalia.state.get(statusKey(backendTag, regionId))
  if raw == nil then
    applyState("pending", "", noctalia.tr("widget.mirror_waiting"))
    return
  end

  local ok, data = pcall(function()
    return noctalia.json.decode(raw)
  end)
  if not ok or data == nil or type(data) ~= "table" then
    applyState("pending", "", noctalia.tr("widget.mirror_waiting"))
    return
  end

  local ageMs = noctalia.nowMs() - (data.updatedAtMs or 0)
  if ageMs > MIRROR_STALE_MS then
    applyState("error", "?", noctalia.tr("widget.mirror_stale"))
    return
  end

  -- Status published by an older version has `active` but no `level`.
  local level = normalizeLevel(data.level)
  if level == nil and data.active then
    level = "red"
  end

  if level == "red" then
    applyState("red", "!", data.detail or "")
  elseif level == "yellow" then
    applyState("yellow", "", data.detail or "")
  else
    applyState("clear", "", data.detail or "")
  end
end

local function fetchStatus()
  if fetching then
    local stuckForMs = fetchStartedAtMs ~= nil and (noctalia.nowMs() - fetchStartedAtMs) or 0
    if stuckForMs < FETCH_TIMEOUT_MS then
      return
    end
    noctalia.log("ukrainealarm: previous fetch never completed (" .. tostring(stuckForMs) .. "ms) - retrying")
    endFetch()
  end

  local token = noctalia.getConfig("api_token")
  local hasToken = token ~= nil and token ~= ""

  if hasToken then
    local regionId = noctalia.getConfig("region_id")
    if regionId == nil or regionId == "" then
      applyState("unconfigured", "", noctalia.tr("widget.unconfigured_region_id"))
      return
    end
    beginFetch()
    fetchViaToken(token, regionId)
  else
    local ajaxRegion = noctalia.getConfig("ajax_region")
    if ajaxRegion == nil or ajaxRegion == "" or ajaxRegion == "0" then
      applyState("unconfigured", "", noctalia.tr("widget.unconfigured_ajax_region"))
      return
    end
    beginFetch()
    fetchViaAjax(ajaxRegion)
  end
end

function update()
  if not hasEverRendered then
    applyState("pending", "", noctalia.tr("widget.pending"))
    hasEverRendered = true
  end

  local token = noctalia.getConfig("api_token")
  local hasToken = token ~= nil and token ~= ""
  local pollSeconds = noctalia.getConfig("poll_seconds") or 30
  local minInterval = hasToken and 10 or 15 -- AJAX backend is rate-limited

  -- Jitter (0-4999ms), stable for this instance's config but different from
  -- a sibling instance's, so two widgets with identical settings don't tick
  -- in perfect lockstep forever.
  local jitterSeed = tostring(token) .. "|" .. tostring(noctalia.getConfig("region_id")) .. "|" .. tostring(noctalia.getConfig("ajax_region"))
  local jitterMs = simpleHash(jitterSeed) % 5000

  noctalia.setUpdateInterval(math.max(pollSeconds, minInterval) * 1000 + jitterMs)

  if isPrimaryOutput() then
    fetchStatus()
  else
    mirrorStatus() -- no network request; just reflect the primary output's last result
  end
end

function onClick()
  -- Manual refresh. Mirror instances re-read the shared state instead of
  -- fetching (only the primary output ever hits the network); still subject
  -- to the AJAX backend's rate limit when this is the primary.
  if isPrimaryOutput() then
    fetchStatus()
  else
    mirrorStatus()
  end
end

function onRightClick()
  noctalia.openSettings()
end
