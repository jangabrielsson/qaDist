--%%name:QA Dist Manager
--%%type:com.fibaro.deviceController
--%%description:Install, upgrade, downgrade, or create QuickApps from a GitHub manifest.
--%%var:manifestUrl="https://raw.githubusercontent.com/jangabrielsson/qaDist/main/dist.json"
--%%var:githubToken=""
--%%u:{label="manifestStatus",text="Manifest: not loaded"}
--%%u:{select="qaSelect",text="QuickApp",value="",onToggled="onQaSelected",options={{type='option',text='(load manifest first)',value=''}}}
--%%u:{select="installedSelect",text="Installed",value="",onToggled="onInstalledSelected",options={{type='option',text='(select QA first)',value=''}}}
--%%u:{select="releaseSelect",text="Release",value="",onToggled="onReleaseSelected",options={{type='option',text='(select QA first)',value=''}}}
--%%u:{{button="refreshBtn",text="Refresh",onReleased="onRefresh"},{button="installBtn",text="Apply",onReleased="onApply"}}
--%%u:{label="actionStatus",text="Status: idle"}

--%%proxy:true

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

local function safeDecodeJson(blob)
	if type(blob) ~= "string" or blob == "" then
		return nil, "empty payload"
	end
	local ok, decoded = pcall(json.decode, blob)
	if not ok or type(decoded) ~= "table" then
		return nil, "invalid json payload"
	end
	return decoded
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
	local manifestUrl = self:getVariable("manifestUrl")
	if manifestUrl == "" then
		cb(false, "manifestUrl is empty")
		return
	end

	self:httpGet(manifestUrl, self:githubHeaders(), function(httpErr, status, body)
		if httpErr then
			cb(false, "http error: " .. httpErr)
			return
		end
		if status ~= 200 then
			cb(false, "http status " .. tostring(status))
			return
		end

		local payload, parseErr = safeDecodeJson(body)
		if not payload then
			cb(false, parseErr)
			return
		end

		local normalized = {}
		local quickApps = payload.quickApps
		if type(quickApps) ~= "table" then
			cb(false, "manifest missing quickApps[]")
			return
		end

		for _, qa in ipairs(quickApps) do
			if type(qa) == "table" and qa.uid and qa.name and qa.url then
				normalized[#normalized + 1] = {
					uid = tostring(qa.uid),
					name = tostring(qa.name),
					description = tostring(qa.description or ""),
					url = trimSlash(tostring(qa.url)),
					fqa = tostring(qa.fqa or ""),
					versionFile = tostring(qa.versionFile or ""),
					versionPattern = tostring(qa.versionPattern or "")
				}
			end
		end

		if #normalized == 0 then
			cb(false, "manifest has no valid quickApps entries")
			return
		end

		self.manifest = payload
		self.catalog = normalized
		cb(true)
	end)
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
		self:updateSelectOptions("installedSelect", {
			{ type = "option", text = "(select QA first)", value = "" }
		}, "")
		self:updateSelectOptions("releaseSelect", {
			{ type = "option", text = "(select QA first)", value = "" }
		}, "")
		self:setStatus("select a QuickApp")
		return
	end

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

function QuickApp:commitReleaseOptions(uid, releases)
	self.releasesByUid[uid] = releases
	local options = {}
	for _, release in ipairs(releases) do
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

		local imported, status, err = self:apiCall("post", "/quickApp", fqaBlobOrErr)
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

function QuickApp:extractFilesFromFqa(fqaBlob)
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
			normalized[#normalized + 1] = {
				name = tostring(file.name),
				type = tostring(file.type or "lua"),
				isMain = file.isMain == true,
				isOpen = file.isOpen == true,
				content = tostring(file.content)
			}
		end
	end

	if #normalized == 0 then
		return nil, "fqa files[] empty"
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
		local wantedFiles, parseErr = self:extractFilesFromFqa(payloadOrErr)
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
			if not wantedByName[fileName] then
				self:logStep("Delete file", fileName)
				local _, deleteStatus, deleteErr = self:apiCall("delete", "/quickApp/" .. tostring(deviceId) .. "/files/" .. encodeUriComponent(fileName))
				if deleteStatus > 206 then
					cb(false, "delete file failed for " .. fileName .. ": " .. tostring(deleteErr or deleteStatus))
					return
				end
				deletedCount = deletedCount + 1
			end
		end

		self:logStep(
			"Update-existing summary",
			"created=" .. tostring(createdCount),
			"updated=" .. tostring(updatedCount),
			"deleted=" .. tostring(deletedCount)
		)

		cb(true, "applied release " .. tostring(tag) .. " to #" .. tostring(deviceId))
	end)
end
