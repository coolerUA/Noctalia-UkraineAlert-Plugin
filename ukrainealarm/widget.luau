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

local lastStatusText = nil -- avoid redundant notifications
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
  -- kind: "alert" | "clear" | "error" | "unconfigured" | "pending"
  noctalia.log("ukrainealarm: applyState(" .. kind .. ")")

  if kind == "alert" then
    barWidget.setGlyph("alert-triangle-filled")
    barWidget.setGlyphColor("#E5484D")
    barWidget.setColor("#E5484D")
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
    barWidget.setGlyphColor("#F5A623")
    barWidget.setColor("")
  end

  barWidget.setText(text)
  barWidget.setTooltip(tooltip)
end

local function reportAlertState(isActive, statusText)
  if isActive then
    applyState("alert", "!", statusText)
    if lastStatusText ~= "alert" then
      noctalia.notify(noctalia.tr("widget.alert_title"), statusText)
    end
    lastStatusText = "alert"
  else
    applyState("clear", "", statusText)
    if lastStatusText == "alert" then
      noctalia.notify(noctalia.tr("widget.clear_title"), statusText)
    end
    lastStatusText = "clear"
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
      local regionName = region.regionName or regionId

      if #activeAlerts > 0 then
        local kinds = {}
        for _, a in ipairs(activeAlerts) do
          kinds[a.type or "UNKNOWN"] = true
        end
        local kindList = {}
        for k, _ in pairs(kinds) do
          table.insert(kindList, k)
        end
        local statusText = noctalia.trp("widget.alert_count", #activeAlerts, { region = regionName })
        noctalia.log("ukrainealarm[" .. regionId .. "]: active=true (" .. table.concat(kindList, ", ") .. ")")
        reportAlertState(true, statusText .. "\n" .. table.concat(kindList, ", "))
      else
        noctalia.log("ukrainealarm[" .. regionId .. "]: active=false")
        reportAlertState(false, noctalia.tr("widget.clear", { region = regionName }))
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
      local isActive = false
      for _, alarm in ipairs(data.alarms) do
        if tostring(alarm.regionId) == ajaxRegionId then
          isActive = true
          break
        end
      end

      noctalia.log("ukrainealarm(ajax)[" .. ajaxRegionId .. "]: active=" .. tostring(isActive) .. " (" .. #data.alarms .. " alarms in response)")

      if isActive then
        reportAlertState(true, noctalia.trp("widget.alert_count", 1, { region = regionName }))
      else
        reportAlertState(false, noctalia.tr("widget.clear", { region = regionName }))
      end
    end)

    if not ok then
      noctalia.log("ukrainealarm(ajax)[" .. ajaxRegionId .. "]: error processing response: " .. tostring(procErr))
      applyState("error", "?", noctalia.tr("widget.parse_error"))
    end
  end)
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
  fetchStatus()
end

function onClick()
  -- Manual refresh. Still subject to the AJAX backend's rate limit above.
  fetchStatus()
end

function onRightClick()
  noctalia.openSettings()
end
