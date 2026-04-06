--%%name:QA Dist Manager
--%%type:com.fibaro.deviceController
--%%description:Install, upgrade, downgrade, or create QuickApps from a GitHub manifest.
--%%var:manifestUrl="https://raw.githubusercontent.com/jangabrielsson/qaDist/main/dist.json"
--%%var:githubToken=""
--%%u:{label="titleLabel",text="QA Dist Manager"}
--%%u:{label="manifestStatus",text="Manifest: not loaded"}
--%%u:{select="qaSelect",text="QuickApp",value="",onToggled="onQaSelected",options={{type='option',text='(load manifest first)',value=''}}}
--%%u:{label="qaAuthor",text="Author: "}
--%%u:{label="qaDescription",text=""}
--%%u:{select="installedSelect",text="Installed",value="",onToggled="onInstalledSelected",options={{type='option',text='(select QA first)',value=''}}}
--%%u:{select="releaseSelect",text="Release",value="",onToggled="onReleaseSelected",options={{type='option',text='(select QA first)',value=''}}}
--%%u:{{button="refreshBtn",text="Refresh",onReleased="onRefresh"},{button="installBtn",text="Apply",onReleased="onApply"}}
--%%u:{label="actionStatus",text="Status: idle"}

--%%proxy:true
--%%save:QADist_v0_1_3.fqa

local VERSION = "0.1.3"

local NEW_INSTANCE = "__new__"

local function startsWith(value, prefix)
	return type(value) == "string" and value:sub(1, #prefix) == prefix
end

local function trimSlash(value)
	if type(value) ~= "string" then
		return ""
	end
	return (value:gsub("/+$", ""))
end

local function splitRepoSlug(repoApiBase)
	if type(repoApiBase) ~= "string" then
		return nil, nil
	end
	local owner, repo = repoApiBase:match("github%.com/repos/([^/]+)/([^/]+)/?$")
	return owner, repo
end

local function encodeUriComponent(value)
	return (tostring(value):gsub("([^%w%-_%.~])", function(ch)
		return string.format("%%%02X", string.byte(ch))
	end))
end

local function matchesIgnore(fileName, ignoreList)
	if type(ignoreList) ~= "table" then return false end
	for _, pattern in ipairs(ignoreList) do
		local ok, matched = pcall(string.match, fileName, "^" .. tostring(pattern) .. "$")
		if ok and matched then return true end
	end
	return false
end

local function parseVer(v)
	local a, b, c = tostring(v):match("^v?(%d+)%.(%d+)%.?(%d*)")
	return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0
end

local function versionAtLeast(have, need)
	local hMaj, hMin, hPat = parseVer(have)
	local nMaj, nMin, nPat = parseVer(need)
	if hMaj ~= nMaj then return hMaj > nMaj end
	if hMin ~= nMin then return hMin > nMin end
	return hPat >= nPat
end

-- Escape literal control characters in a JSON blob so strict parsers accept it.
-- Safe to call on compact (non-pretty-printed) JSON where control chars only
-- appear inside string values (e.g. FQA files with embedded Lua source code).
local function sanitizeJsonControlChars(blob)
	return (blob:gsub("%c", function(c)
		local n = string.byte(c)
		if n == 10 then return "\\n"
		elseif n == 13 then return "\\r"
		elseif n == 9 then return "\\t"
		elseif n == 8 then return "\\b"
		elseif n == 12 then return "\\f"
		else return string.format("\\u%04x", n)
		end
	end))
end

local function safeDecodeJson(blob)
	if type(blob) ~= "string" or blob == "" then
		return nil, "empty payload"
	end
	local ok, decoded = pcall(json.decode, blob)
	if not ok or type(decoded) ~= "table" then
		-- Retry after escaping any bare control characters (e.g. unescaped
		-- newlines in Lua source embedded in FQA JSON files).
		local sanitized = sanitizeJsonControlChars(blob)
		ok, decoded = pcall(json.decode, sanitized)
		if not ok or type(decoded) ~= "table" then
			return nil, "invalid json payload"
		end
	end
	return decoded
end

local function markArray(t) if type(t)=='table' then json.initArray(t) end end

local arrProps = {values=true, options=true, args=true, actions=true}
local function markRec(t)
  if type(t)=='table' then
    for k,v in pairs(t) do
      if type(v)=='table' and next(v)==nil then
        if arrProps[k] then
          json.initArray(v)
        else
          --print("Prop with empty table value treated as object:", k)
        end
      else markRec(v)
      end
    end
  end
end

local function arrayifyFqa(fqa)
  markArray(fqa.initialInterfaces)
  local props = fqa.initialProperties
  if type(props) == "table" then
    markArray(props.quickAppVariables)
    markArray(props.uiView)
    markArray(props.uiCallbacks)
    markArray(props.supportedDeviceRoles)
    markRec(props.uiView)
    markRec(props.viewLayout)
  end
  return fqa
end

function QuickApp:onInit()
	self.manifest = {}
	self.catalog = {}
	self.selectedUid = ""
	self.selectedInstalledId = ""
	self.selectedRelease = ""
	self.installBusy = false
	self.releasesByUid = {}
	self.installedByUid = {}

	self:updateView("titleLabel", "text", "QA Dist Manager v" .. VERSION)
	self:refreshAll()
end

function QuickApp:setStatus(text)
	self:updateView("actionStatus", "text", "Status: " .. tostring(text or ""))
end

function QuickApp:setManifestStatus(text)
	self:updateView("manifestStatus", "text", "Manifest: " .. tostring(text or ""))
end

function QuickApp:logStep(...)
	self:debug("[qaDist]", ...)
end

function QuickApp:logWarn(...)
	self:warning("[qaDist]", ...)
end

function QuickApp:apiCall(method, path, data)
	local fn = api[method]
	if type(fn) ~= "function" then
		return nil, 500, "unsupported api method " .. tostring(method)
	end

	local result, status = fn(path, data)
	if status and status > 206 then
		local detail = ""
		if type(result) == "table" then
			detail = tostring(result.message or result.error or result.reason or "")
		elseif type(result) == "string" then
			detail = result
		end
		self:logWarn("HC3 api failed", method:upper(), path, "status=" .. tostring(status), detail)
		return nil, status, detail ~= "" and detail or ("status " .. tostring(status))
	end
	return result, status or 200, nil
	end

function QuickApp:updateSelectOptions(selectId, options, selectedValue)
	self:updateView(selectId, "options", options)
	self:updateView(selectId, "selectedItem", selectedValue or "")
end

function QuickApp:githubHeaders(extra)
	local headers = {
		["Accept"] = "application/vnd.github+json",
		["User-Agent"] = "qaDist-manager"
	}
	local token = self:getVariable("githubToken")
	if token ~= "" then
		headers["Authorization"] = "Bearer " .. token
	end
	if extra then
		for key, value in pairs(extra) do
			headers[key] = value
		end
	end
	return headers
end

function QuickApp:httpGet(url, headers, cb)
	local client = net.HTTPClient({ timeout = 15000 })
	client:request(url, {
		options = {
			method = "GET",
			headers = headers or {}
		},
		success = function(response)
			cb(nil, response.status, response.data)
		end,
		error = function(err)
			cb(tostring(err), nil, nil)
		end
	})
end

function QuickApp:refreshAll()
	self:setStatus("loading manifest")
	self:fetchManifest(function(ok, err)
		if not ok then
			self:setManifestStatus(err)
			self:setStatus("manifest load failed")
			return
		end

		self:setManifestStatus("loaded " .. tostring(#self.catalog) .. " quickapps")
		if self.selectedUid == "" and #self.catalog > 0 then
			self.selectedUid = self.catalog[1].uid
		end
		self:populateQaSelect()
		self:refreshInstalledAndReleases()
	end)
end

function QuickApp:fetchManifest(cb)
	-- Collect all QA variables whose name starts with "manifest"
	local vars = self.properties.quickAppVariables or {}
	local manifestUrls = {}
	for _, v in ipairs(vars) do
		if type(v.name) == "string" and v.name:sub(1, 8):lower() == "manifest"
		   and type(v.value) == "string" and v.value ~= "" then
			manifestUrls[#manifestUrls + 1] = v.value
			self:logStep("Found manifest var", v.name, "=", v.value)
		end
	end

	if #manifestUrls == 0 then
		cb(false, "no variables starting with 'manifest' found")
		return
	end

	-- Fetch all manifest URLs sequentially and merge results, deduplicating by uid
	local allNormalized = {}
	local seenUids = {}
	local lastErr = nil

	local function fetchNext(index)
		if index > #manifestUrls then
			if #allNormalized == 0 then
				cb(false, lastErr or "no valid quickApps entries found in any manifest")
				return
			end
			self.manifest = { quickApps = allNormalized }
			self.catalog = allNormalized
			cb(true)
			return
		end

		local url = manifestUrls[index]
		self:httpGet(url, self:githubHeaders(), function(httpErr, status, body)
			if httpErr then
				self:logWarn("Manifest fetch error", url, httpErr)
				lastErr = "http error: " .. httpErr
				fetchNext(index + 1)
				return
			end
			if status ~= 200 then
				self:logWarn("Manifest fetch bad status", url, tostring(status))
				lastErr = "http status " .. tostring(status)
				fetchNext(index + 1)
				return
			end

			local payload, parseErr = safeDecodeJson(body)
			if not payload then
				self:logWarn("Manifest parse failed", url, parseErr)
				lastErr = parseErr
				fetchNext(index + 1)
				return
			end

			if type(payload.minVersion) == "string" and payload.minVersion ~= "" then
				if not versionAtLeast(VERSION, payload.minVersion) then
					self:logWarn("Manifest", url, "requires QADist v" .. payload.minVersion ..
						" but installed is v" .. VERSION .. " — skipping")
					lastErr = "requires QADist v" .. payload.minVersion
					fetchNext(index + 1)
					return
				end
			end

			local quickApps = payload.quickApps
			local added = 0
			if type(quickApps) == "table" then
				for _, qa in ipairs(quickApps) do
					if type(qa) == "table" and qa.uid and qa.name and qa.url then
						local uid = tostring(qa.uid)
						if not seenUids[uid] then
							seenUids[uid] = true
							allNormalized[#allNormalized + 1] = {
								uid = uid,
								name = tostring(qa.name),
								description = tostring(qa.description or ""),
								author = tostring(payload.author or ""),
								url = trimSlash(tostring(qa.url)),
								fqa = tostring(qa.fqa or ""),
								versionFile = tostring(qa.versionFile or ""),
								versionPattern = tostring(qa.versionPattern or ""),
								ignore = qa.ignore or {}
							}
							added = added + 1
						else
							self:logStep("Skipping duplicate uid", uid, "from", url)
						end
					end
				end
			end
			self:logStep("Loaded manifest", url, "added=" .. tostring(added))
			fetchNext(index + 1)
		end)
	end

	fetchNext(1)
end

function QuickApp:selectedCatalogEntry()
	for _, entry in ipairs(self.catalog) do
		if entry.uid == self.selectedUid then
			return entry
		end
	end
	return nil
end

function QuickApp:populateQaSelect()
	local options = {}
	for _, entry in ipairs(self.catalog) do
		options[#options + 1] = {
			type = "option",
			text = entry.name,
			value = entry.uid
		}
	end
	if #options == 0 then
		options = {
			{ type = "option", text = "(no quickapps)", value = "" }
		}
	end
	self:updateSelectOptions("qaSelect", options, self.selectedUid)
end

function QuickApp:refreshInstalledAndReleases()
	local entry = self:selectedCatalogEntry()
	if not entry then
		self:updateView("qaAuthor", "text", "Author: ")
		self:updateView("qaDescription", "text", "")
		self:updateSelectOptions("installedSelect", {
			{ type = "option", text = "(select QA first)", value = "" }
		}, "")
		self:updateSelectOptions("releaseSelect", {
			{ type = "option", text = "(select QA first)", value = "" }
		}, "")
		self:setStatus("select a QuickApp")
		return
	end

	self:updateView("qaAuthor", "text", "Author: " .. (entry.author or ""))
	self:updateView("qaDescription", "text", entry.description)

	self:loadInstalledForUid(entry.uid)
	self:fetchReleasesForEntry(entry, function(ok, err)
		if not ok then
			self:setStatus("release fetch failed: " .. tostring(err))
			return
		end
		self:setStatus("ready")
	end)
end

function QuickApp:loadInstalledForUid(uid)
	local devices, status, err = self:apiCall("get", "/devices?interface=quickApp")
	if not devices then
		self:logWarn("Failed to load installed QAs", "status=" .. tostring(status), err)
		devices = {}
	end
	local found = {}
	for _, dev in ipairs(devices) do
		local props = dev.properties or {}
		if tostring(props.quickAppUuid or "") == tostring(uid) then
			found[#found + 1] = dev
		end
	end
	self.installedByUid[uid] = found

	local entry = self:selectedCatalogEntry()
	local hasVersionInfo = entry and entry.versionFile ~= "" and entry.versionPattern ~= ""

	-- Build options with optional version prepend
	local options = {
		{ type = "option", text = "Create new instance", value = NEW_INSTANCE }
	}

	if hasVersionInfo then
		-- Fetch versions for each installed QA
		for _, dev in ipairs(found) do
			local version = self:extractVersionFromQa(dev.id, entry.versionFile, entry.versionPattern)
			local displayName = tostring(dev.name) .. " (#" .. tostring(dev.id) .. ")"
			if version then
				displayName = "[" .. version .. "] " .. displayName
				self:logStep("Version detected", displayName)
			end
			options[#options + 1] = {
				type = "option",
				text = displayName,
				value = tostring(dev.id)
			}
		end
	else
		-- No version info, just show device names
		for _, dev in ipairs(found) do
			options[#options + 1] = {
				type = "option",
				text = tostring(dev.name) .. " (#" .. tostring(dev.id) .. ")",
				value = tostring(dev.id)
			}
		end
	end

	if self.selectedInstalledId == "" then
		self.selectedInstalledId = NEW_INSTANCE
	end
	self:updateSelectOptions("installedSelect", options, self.selectedInstalledId)
end

function QuickApp:extractVersionFromQa(deviceId, versionFile, versionPattern)
	if not versionFile or versionFile == "" or not versionPattern or versionPattern == "" then
		return nil
	end

	local url = "/quickApp/" .. tostring(deviceId) .. "/files/" .. encodeUriComponent(versionFile)
	local fileData, status, err = self:apiCall("get", url)
	if not fileData then
		self:logWarn("Failed to fetch version file", versionFile, "status=" .. tostring(status))
		return nil
	end

	if type(fileData) == "table" and fileData.content then
		fileData = fileData.content
	end

	if type(fileData) ~= "string" then
		return nil
	end

	-- Extract version using the pattern
	-- Pattern like 'local VERSION = "%-."' should extract the quoted version string
	local version = string.match(fileData, versionPattern)
	if version then
		return version
	end

	-- If pattern didn't work, try to be more forgiving
	-- Look for quoted strings after VERSION assignment
	version = string.match(fileData, 'VERSION%s*=%s*"([^"]+)"')
	return version
end

function QuickApp:fetchReleasesForEntry(entry, cb)
	local releasesUrl = entry.url .. "/releases"
	self:httpGet(releasesUrl, self:githubHeaders(), function(httpErr, status, body)
		if httpErr then
			cb(false, httpErr)
			return
		end
		if status ~= 200 then
			cb(false, "http status " .. tostring(status))
			return
		end

		local payload, decodeErr = safeDecodeJson(body)
		if not payload then
			cb(false, decodeErr)
			return
		end

		local releases = {}
		for _, rel in ipairs(payload) do
			local tag = tostring(rel.tag_name or "")
			if tag ~= "" then
				releases[#releases + 1] = {
					tag = tag,
					name = tostring(rel.name or tag)
				}
			end
		end

		if #releases == 0 then
			local tagsUrl = entry.url .. "/tags"
			self:httpGet(tagsUrl, self:githubHeaders(), function(tagErr, tagStatus, tagBody)
				if tagErr then
					cb(false, tagErr)
					return
				end
				if tagStatus ~= 200 then
					cb(false, "tags http status " .. tostring(tagStatus))
					return
				end
				local tagsPayload, tagsDecodeErr = safeDecodeJson(tagBody)
				if not tagsPayload then
					cb(false, tagsDecodeErr)
					return
				end
				local tags = {}
				for _, item in ipairs(tagsPayload) do
					local tag = tostring(item.name or "")
					if tag ~= "" then
						tags[#tags + 1] = { tag = tag, name = tag }
					end
				end
				self:commitReleaseOptions(entry.uid, tags)
				cb(true)
			end)
			return
		end

		self:commitReleaseOptions(entry.uid, releases)
		cb(true)
	end)
end

local MAX_RELEASES = 5

function QuickApp:commitReleaseOptions(uid, releases)
	self.releasesByUid[uid] = releases
	local options = {}
	for i, release in ipairs(releases) do
		if i > MAX_RELEASES then break end
		options[#options + 1] = {
			type = "option",
			text = release.name,
			value = release.tag
		}
	end
	if #options == 0 then
		options = { { type = "option", text = "(no releases)", value = "" } }
		self.selectedRelease = ""
	else
		if self.selectedRelease == "" then
			self.selectedRelease = options[1].value
		end
	end
	self:updateSelectOptions("releaseSelect", options, self.selectedRelease)
end

function QuickApp:resolveFqaRawUrl(entry, tag)
	if entry.fqa == "" then
		return nil, "manifest fqa is empty"
	end
	if startsWith(entry.fqa, "http://") or startsWith(entry.fqa, "https://") then
		if tag and tag ~= "" and entry.fqa:find("{tag}", 1, true) then
			return entry.fqa:gsub("{tag}", tag)
		end
		return entry.fqa
	end

	local owner, repo = splitRepoSlug(entry.url)
	if not owner or not repo then
		return nil, "cannot parse owner/repo from url"
	end
	if not tag or tag == "" then
		return nil, "release tag not selected"
	end

	local path = tostring(entry.fqa):gsub("^/", "")
	return "https://raw.githubusercontent.com/" .. owner .. "/" .. repo .. "/" .. encodeUriComponent(tag) .. "/" .. path
end

function QuickApp:onRefresh(_event)
	if self.installBusy then
		self:setStatus("install in progress")
		return
	end
	self.selectedRelease = ""
	self:refreshAll()
end

function QuickApp:onQaSelected(event)
	local value = tostring((event.values and event.values[1]) or "")
	self.selectedUid = value
	self.selectedInstalledId = NEW_INSTANCE
	self.selectedRelease = ""
	self:refreshInstalledAndReleases()
end

function QuickApp:onInstalledSelected(event)
	local value = tostring((event.values and event.values[1]) or "")
	self.selectedInstalledId = value
	if value == NEW_INSTANCE then
		self:setStatus("mode: create new instance")
	else
		self:setStatus("mode: update installed #" .. value)
	end
end

function QuickApp:onReleaseSelected(event)
	local value = tostring((event.values and event.values[1]) or "")
	self.selectedRelease = value
	self:setStatus("release selected: " .. value)
end

function QuickApp:onApply(_event)
	if self.installBusy then
		self:logWarn("Apply ignored: install already running")
		self:setStatus("already running")
		return
	end

	local entry = self:selectedCatalogEntry()
	if not entry then
		self:logWarn("Apply aborted: no QuickApp selected")
		self:setStatus("select a QuickApp")
		return
	end

	if self.selectedRelease == "" then
		self:logWarn("Apply aborted: no release selected")
		self:setStatus("select a release")
		return
	end

	self:logStep(
		"Apply started",
		"qaUid=" .. tostring(entry.uid),
		"qaName=" .. tostring(entry.name),
		"release=" .. tostring(self.selectedRelease),
		"target=" .. tostring(self.selectedInstalledId)
	)

	self.installBusy = true
	if self.selectedInstalledId == NEW_INSTANCE then
		self:logStep("Mode=create-new", "tag=" .. tostring(self.selectedRelease))
		self:createNewInstance(entry, self.selectedRelease, function(ok, msg)
			self.installBusy = false
			if ok then
				self:logStep("Create-new completed", msg)
			else
				self:logWarn("Create-new failed", msg)
			end
			self:setStatus(msg)
			if ok then
				self:loadInstalledForUid(entry.uid)
			end
		end)
		return
	end

	local targetId = tonumber(self.selectedInstalledId)
	if not targetId then
		self.installBusy = false
		self:logWarn("Apply aborted: invalid target id", tostring(self.selectedInstalledId))
		self:setStatus("invalid installed selection")
		return
	end

	self:logStep("Mode=update-existing", "deviceId=" .. tostring(targetId), "tag=" .. tostring(self.selectedRelease))

	self:updateInstalledInstance(targetId, entry, self.selectedRelease, function(ok, msg)
		self.installBusy = false
		if ok then
			self:logStep("Update-existing completed", msg)
		else
			self:logWarn("Update-existing failed", msg)
		end
		self:setStatus(msg)
		if ok then
			self:loadInstalledForUid(entry.uid)
		end
	end)
end

function QuickApp:downloadFqa(entry, tag, cb)
	local url, urlErr = self:resolveFqaRawUrl(entry, tag)
	if not url then
		self:logWarn("Resolve fqa url failed", urlErr)
		cb(false, urlErr)
		return
	end

	self:logStep("Downloading fqa", url)

	self:httpGet(url, self:githubHeaders(), function(httpErr, status, body)
		if httpErr then
			self:logWarn("Fqa download error", httpErr)
			cb(false, "fqa download failed: " .. httpErr)
			return
		end
		if status ~= 200 then
			self:logWarn("Fqa download bad status", tostring(status))
			cb(false, "fqa status " .. tostring(status))
			return
		end
		self:logStep("Fqa downloaded", "bytes=" .. tostring(#body))
		cb(true, body)
	end)
end

function QuickApp:createNewInstance(entry, tag, cb)
	self:logStep("Create-new start", "qa=" .. tostring(entry.name), "tag=" .. tostring(tag))
	self:setStatus("creating new instance")
	self:downloadFqa(entry, tag, function(ok, fqaBlobOrErr)
		if not ok then
			self:logWarn("Create-new download failed", fqaBlobOrErr)
			cb(false, fqaBlobOrErr)
			return
		end

		local fqa, decodeErr = safeDecodeJson(fqaBlobOrErr)
		if not fqa then
			self:logWarn("Create-new decode failed", decodeErr)
			cb(false, decodeErr)
			return
		end

		self:logStep("Posting full fqa object", "endpoint=/quickApp", "payloadBytes=" .. tostring(#fqaBlobOrErr))

    local fqa = safeDecodeJson(fqaBlobOrErr)
    arrayifyFqa(fqa)

		local imported, status, err = self:apiCall("post", "/quickApp", fqa)
		if not imported then
			cb(false, "create failed: " .. tostring(err or status))
			return
		end
		local importedId = imported and (imported.id or imported.deviceId)
		if importedId then
			self:logStep("Create response", "deviceId=" .. tostring(importedId), "mode=whole-fqa")
			cb(true, "new instance created #" .. tostring(importedId))
		else
			self:logStep("Create response", "no device id in body", "mode=whole-fqa")
			cb(true, "new instance imported")
		end
	end)
end

function QuickApp:extractFilesFromFqa(fqaBlob, ignoreList)
	local decoded, err = safeDecodeJson(fqaBlob)
	if not decoded then
		return nil, err
	end

	local files = decoded.files
	if type(files) ~= "table" then
		return nil, "fqa missing files[]"
	end

	local normalized = {}
	for _, file in ipairs(files) do
		if type(file) == "table" and file.name and file.content then
			local fileName = tostring(file.name)
			if not matchesIgnore(fileName, ignoreList) then
				normalized[#normalized + 1] = {
					name = fileName,
					type = tostring(file.type or "lua"),
					isMain = file.isMain == true,
					isOpen = file.isOpen == true,
					content = tostring(file.content)
				}
			else
				self:logStep("Ignored file in fqa", fileName)
			end
		end
	end

	if #normalized == 0 then
		return nil, "fqa files[] empty or all files ignored"
	end

	return normalized
end

function QuickApp:updateInstalledInstance(deviceId, entry, tag, cb)
	self:logStep("Update-existing start", "deviceId=" .. tostring(deviceId), "qa=" .. tostring(entry.name), "tag=" .. tostring(tag))
	self:setStatus("downloading " .. tag)
	self:downloadFqa(entry, tag, function(ok, payloadOrErr)
		if not ok then
			self:logWarn("Update-existing download failed", payloadOrErr)
			cb(false, payloadOrErr)
			return
		end

		self:logStep("Parsing fqa for update")
		local ignoreList = entry.ignore or {}
		local wantedFiles, parseErr = self:extractFilesFromFqa(payloadOrErr, ignoreList)
		if not wantedFiles then
			self:logWarn("Update-existing parse failed", parseErr)
			cb(false, parseErr)
			return
		end

		local existing, status, err = self:apiCall("get", "/quickApp/" .. tostring(deviceId) .. "/files")
		if not existing then
			cb(false, "failed to list existing files: " .. tostring(err or status))
			return
		end
		self:logStep("Loaded existing files", "count=" .. tostring(#existing), "incoming=" .. tostring(#wantedFiles))
		
		
		local existingByName = {}
		for _, file in ipairs(existing) do
			existingByName[tostring(file.name)] = true
		end

		local wantedByName = {}
		local createdCount = 0
		local updatedCount = 0
		local deletedCount = 0
		for _, file in ipairs(wantedFiles) do
			wantedByName[file.name] = true
			if not existingByName[file.name] then
				self:logStep("Create file", file.name)
				local _, createStatus, createErr = self:apiCall("post", "/quickApp/" .. tostring(deviceId) .. "/files", {
					name = file.name,
					type = file.type,
					isOpen = file.isOpen,
					isMain = file.isMain
				})
				if createStatus > 206 then
					cb(false, "create file failed for " .. file.name .. ": " .. tostring(createErr or createStatus))
					return
				end
				createdCount = createdCount + 1
			end
			self:logStep("Update file", file.name)
			local _, updateStatus, updateErr = self:apiCall("put", "/quickApp/" .. tostring(deviceId) .. "/files/" .. encodeUriComponent(file.name), {
				name = file.name,
				type = file.type,
				isOpen = file.isOpen,
				isMain = file.isMain,
				content = file.content
			})
			if updateStatus > 206 then
				cb(false, "update file failed for " .. file.name .. ": " .. tostring(updateErr or updateStatus))
				return
			end
			updatedCount = updatedCount + 1
		end

		for _, file in ipairs(existing) do
			local fileName = tostring(file.name)
			if not wantedByName[fileName] and not matchesIgnore(fileName, ignoreList) then
				self:logStep("Delete file", fileName)
				local _, deleteStatus, deleteErr = self:apiCall("delete", "/quickApp/" .. tostring(deviceId) .. "/files/" .. encodeUriComponent(fileName))
				if deleteStatus > 206 then
					cb(false, "delete file failed for " .. fileName .. ": " .. tostring(deleteErr or deleteStatus))
					return
				end
				deletedCount = deletedCount + 1
			elseif matchesIgnore(fileName, ignoreList) then
				self:logStep("Skipping delete of ignored file", fileName)
			end
		end

		self:logStep(
			"Update-existing summary",
			"created=" .. tostring(createdCount),
			"updated=" .. tostring(updatedCount),
			"deleted=" .. tostring(deletedCount)
		)

    local fqa, fqaErr = safeDecodeJson(payloadOrErr)
    if not fqa then
      self:logWarn("UI/interface update skipped: fqa decode failed", fqaErr)
    else
      arrayifyFqa(fqa)

      -- Sync interfaces
      local wantedInterfaces = {}
      if type(fqa.initialInterfaces) == "table" then
        for _, iface in ipairs(fqa.initialInterfaces) do
          wantedInterfaces[tostring(iface)] = true
        end
      end
      local currentDev = self:apiCall("get", "/devices/" .. tostring(deviceId))
      local currentInterfaces = {}
      if type(currentDev) == "table" and type(currentDev.interfaces) == "table" then
        for _, iface in ipairs(currentDev.interfaces) do
          currentInterfaces[tostring(iface)] = true
        end
      end

      local toAdd = {}
      for iface in pairs(wantedInterfaces) do
        if not currentInterfaces[iface] then
          toAdd[#toAdd + 1] = iface
        end
      end
      -- "quickApp" is a system-managed interface added by HC3 to all QAs; never remove it
      local systemInterfaces = { quickApp = true }
      local toRemove = {}
      for iface in pairs(currentInterfaces) do
        if not wantedInterfaces[iface] and not systemInterfaces[iface] then
          toRemove[#toRemove + 1] = iface
        end
      end

      if #toAdd > 0 then
        self:logStep("Adding interfaces", table.concat(toAdd, ", "))
        local _, addStatus, addErr = self:apiCall("post", "/devices/addInterface", { devicesId = {deviceId}, interfaces = toAdd })
        if addStatus > 206 then
          self:logWarn("Add interfaces failed", "status=" .. tostring(addStatus), tostring(addErr))
        end
      end
      if #toRemove > 0 then
        self:logStep("Removing interfaces", table.concat(toRemove, ", "))
        local _, remStatus, remErr = self:apiCall("post", "/devices/deleteInterface", { devicesId = {deviceId}, interfaces = toRemove })
        if remStatus > 206 then
          self:logWarn("Remove interfaces failed", "status=" .. tostring(remStatus), tostring(remErr))
        end
      end

      -- Sync UI properties
      local uiProps = {
        "useUiView",
        "useEmbededView",
        "uiView",
        "uiCallbacks",
        "viewLayout"
      }
      local props = {}
      for _, prop in ipairs(uiProps) do
        if fqa.initialProperties and fqa.initialProperties[prop] ~= nil then
          props[prop] = fqa.initialProperties[prop]
        end
      end
      if next(props) then
        self:logStep("Updating UI properties", "deviceId=" .. tostring(deviceId))
        local _, uiStatus, uiErr = self:apiCall("put", "/devices/" .. tostring(deviceId), { properties = props })
        if uiStatus > 206 then
          self:logWarn("UI properties update failed", "status=" .. tostring(uiStatus), tostring(uiErr))
        else
          self:logStep("UI properties updated")
        end
      end
    end

		cb(true, "applied release " .. tostring(tag) .. " to #" .. tostring(deviceId))
	end)
end
