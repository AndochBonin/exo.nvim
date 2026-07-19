local AI = {}

--- @class ExoReviewResponse
--- @field comments string[]
--- @field quality "good"|"okay"|"poor"

AI.review_response_schema = {
	type = "object",
	properties = {
		comments = {
			type = "array",
			items = { type = "string" },
			description = "One-line review issues in format: <what to do>; <why>",
		},
		quality = {
			type = "string",
			enum = { "good", "okay", "poor" },
			description = "Overall code quality assessment",
		},
	},
	required = { "comments", "quality" },
}

AI.review_system_prompt = [[
You are an expert code reviewer.
Review code for: bugs/correctness, security, performance, style/idioms,
architecture, error handling, concurrency, maintainability.

Comment style:
- Each issue is ONE short line, written like an inline code comment.
- Use imperative, telegraphic phrasing. Drop filler words, hedges, and subjects.
- Format per issue: <what to do>; <why>. Nothing else.
  Good: "Remove this; unused."
  Good: "Use == here; = is an assignment, not a comparison."
- Only report issues with a reasonable likelihood of being real.

Quality ratings:
- "good": no meaningful issues
- "okay": minor/style issues, no serious bugs
- "poor": correctness, security, or significant design problems

If there are no issues, return an empty comments array and quality "good".
]]

AI.review_prompt = [[
Review this %s code:

```
%s
```
]]

AI.explain_prompt = [[You are a senior software engineer. Provide an answer for this prompt "%s"]]
AI.explain_context_addition = [[in the context of this code ```%s```]]

AI.create_review_prompt = function(language, code)
	return string.format(AI.review_prompt, language, code)
end

local curl = require("plenary.curl")

local VALID_QUALITIES = { good = true, okay = true, poor = true }

local function build_headers(opts)
	local headers = { ["Content-Type"] = "application/json" }
	if opts and opts.password then
		local username = opts.username or "opencode"
		local credentials = vim.fn.system(
			{ "printf", "%s:%s", username, opts.password },
			""
		):gsub("\n$", "")
		headers["Authorization"] = "Basic " .. vim.base64.encode(credentials)
	end
	return headers
end

local function with_directory(url, directory)
	if directory == nil or directory == "" then
		return url
	end
	return url .. "?directory=" .. vim.uri_encode(directory)
end

local function pretty_body(body)
	if body == nil or body == "" then
		return "(empty)"
	end

	if type(body) == "table" then
		local ok, encoded = pcall(vim.json.encode, body, { indent = true })
		if ok and type(encoded) == "string" then
			return encoded
		end
		return vim.inspect(body)
	end

	if type(body) ~= "string" then
		return tostring(body) .. " (" .. type(body) .. ")"
	end

	local ok, data = pcall(vim.json.decode, body)
	if ok then
		local encoded_ok, encoded = pcall(vim.json.encode, data, { indent = true })
		if encoded_ok and type(encoded) == "string" then
			return encoded
		end
	end

	return body
end

--- @param model string|{ providerID: string, modelID: string }|nil
--- @return { providerID: string, modelID: string }|nil
local function parse_model(model)
	if model == nil or model == "" then
		return nil
	end

	if type(model) == "table" then
		return model
	end

	local provider_id, model_id = model:match("^([^/]+)/(.+)$")
	if provider_id and model_id then
		return { providerID = provider_id, modelID = model_id }
	end

	return nil
end

local function decode_response_body(body)
	if type(body) == "table" then
		return body, nil
	end

	if type(body) ~= "string" or body == "" then
		return nil, "response body is not valid JSON"
	end

	local ok, data = pcall(vim.json.decode, body)
	if not ok then
		return nil, "response body is not valid JSON"
	end

	return data, nil
end

local function show_error_buffer(lines)
	local safe_lines = vim.tbl_map(function(line)
		return type(line) == "string" and line or pretty_body(line)
	end, lines)

	vim.cmd("botright 20new")
	local buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, safe_lines)
	vim.api.nvim_buf_set_name(buf, "Exo OpenCode Error")
	vim.bo[buf].filetype = "log"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false
end

local function build_http_error(step, response)
	return {
		"OpenCode request failed",
		"",
		"Step: " .. step,
		"Status: " .. tostring(response.status),
		"",
		"Body:",
		pretty_body(response.body),
	}
end

local function build_curl_error(step, err)
	return {
		"OpenCode request failed",
		"",
		"Step: " .. step,
		"Error: " .. (err.message or "request failed"),
		"",
		"Details:",
		vim.inspect(err),
	}
end

local function structured_from_parts(parts)
	if type(parts) ~= "table" then
		return nil
	end

	for _, part in ipairs(parts) do
		if part.type == "tool" and part.tool == "StructuredOutput" then
			local input = part.state and part.state.input
			if type(input) == "table" then
				return input
			end
		end
	end

	return nil
end

local function normalize_structured(structured)
	if type(structured) ~= "table" then
		return nil
	end

	if type(structured.comments) == "string" then
		local ok, comments = pcall(vim.json.decode, structured.comments)
		if ok and type(comments) == "table" then
			structured.comments = comments
		end
	end

	return structured
end

local function extract_structured(data)
	if type(data) ~= "table" or type(data.info) ~= "table" then
		return nil
	end

	local structured = data.info.structured_output or data.info.structured
	structured = normalize_structured(structured)
	if type(structured) == "table" then
		return structured
	end

	return normalize_structured(structured_from_parts(data.parts))
end

--- @param response table
--- @return ExoReviewResponse|nil, string|nil, string[]|nil
local function parse_review_response(response)
	local data, decode_err = decode_response_body(response.body)
	if data == nil then
		return nil, decode_err, {
			"OpenCode request failed",
			"",
			"Step: parse review response",
			"Error: " .. decode_err,
			"",
			"Body:",
			pretty_body(response.body),
		}
	end

	if data.info and data.info.error and data.info.error.name == "StructuredOutputError" then
		return nil, data.info.error.message or "structured output error", {
			"OpenCode request failed",
			"",
			"Step: parse review response",
			"Error: " .. (data.info.error.message or "structured output error"),
			"Retries: " .. tostring(data.info.error.retries or "?"),
			"",
			"Response:",
			pretty_body(response.body),
		}
	end

	local structured = extract_structured(data)
	if type(structured) ~= "table" then
		return nil, "invalid structured response", {
			"OpenCode request failed",
			"",
			"Step: parse review response",
			"Error: missing structured review output",
			"",
			"Response:",
			pretty_body(response.body),
		}
	end

	if type(structured.comments) ~= "table" then
		return nil, "invalid structured response", {
			"OpenCode request failed",
			"",
			"Step: parse review response",
			"Error: structured comments is not an array",
			"",
			"structured:",
			pretty_body(structured),
		}
	end

	if not VALID_QUALITIES[structured.quality] then
		return nil, "invalid quality value", {
			"OpenCode request failed",
			"",
			"Step: parse review response",
			"Error: invalid quality value: " .. tostring(structured.quality),
			"",
			"structured:",
			pretty_body(structured),
		}
	end

	return {
		comments = structured.comments,
		quality = structured.quality,
	}, nil, nil
end

--- @param on_done fun(response: string|nil, err: string|nil)
AI.get_ollama_response = function(base_url, model, prompt, on_done)
	base_url = base_url or "http://localhost:11434"

	if prompt == nil or prompt == "" then
		on_done(nil, "empty prompt")
		return
	end

	curl.post(base_url .. "/api/generate", {
		headers = {
			["Content-Type"] = "application/json",
		},
		body = vim.json.encode({
			model = "qwen2.5-coder:3b",
			prompt = prompt,
			stream = false,
		}),
		timeout = 120000,
		callback = function(response)
			vim.schedule(function()
				if response.status ~= 200 then
					on_done(nil, "Request failed with status code " .. response.status .. ": " .. response.body)
					return
				end

				local ok, data = pcall(vim.json.decode, response.body)
				if not ok then
					on_done(nil, "Error parsing JSON")
					return
				end

				on_done(data.response, nil)
			end)
		end,
		on_error = function(err)
			vim.schedule(function()
				on_done(nil, err.message or "request failed")
			end)
		end,
	})
end

--- @param base_url string|nil
--- @param model string|{ providerID: string, modelID: string }|nil
--- @param prompt string
--- @param opts table|nil
--- @param on_done fun(response: ExoReviewResponse|nil, err: string|nil)
AI.get_opencode_response = function(base_url, model, prompt, opts, on_done)
	base_url = base_url or "http://localhost:4096"
	opts = opts or {}

	if prompt == nil or prompt == "" then
		on_done(nil, "empty prompt")
		return
	end

	local opencode_model = parse_model(model)
	if model ~= nil and model ~= "" and opencode_model == nil then
		on_done(nil, "invalid model format (expected provider/model)")
		return
	end

	local timeout = opts.timeout or 120000
	local directory = opts.directory or vim.fn.getcwd()
	local headers = build_headers(opts)

	local function delete_session(session_id, then_done)
		curl.delete(with_directory(base_url .. "/session/" .. session_id, directory), {
			headers = headers,
			timeout = timeout,
			callback = function()
				if then_done then
					then_done()
				end
			end,
			on_error = function()
				if then_done then
					then_done()
				end
			end,
		})
	end

	local function finish(response, err, err_detail, session_id)
		local function call_done()
			vim.schedule(function()
				if err then
					show_error_buffer(err_detail or { err })
				end
				on_done(response, err)
			end)
		end

		if session_id then
			delete_session(session_id, call_done)
		else
			call_done()
		end
	end

	curl.post(with_directory(base_url .. "/session", directory), {
		headers = headers,
		body = vim.json.encode({ title = "exo-review" }),
		timeout = timeout,
		callback = function(session_response)
			if session_response.status ~= 200 then
				finish(
					nil,
					"request failed with status code " .. session_response.status,
					build_http_error("create session", session_response)
				)
				return
			end

			local ok, session_data = pcall(vim.json.decode, session_response.body)
			if not ok or type(session_data.id) ~= "string" then
				finish(nil, "error creating session", {
					"OpenCode request failed",
					"",
					"Step: create session",
					"Error: response missing session id",
					"",
					"Body:",
					pretty_body(session_response.body),
				})
				return
			end

			local session_id = session_data.id
			local message_body = {
				system = opts.system or AI.review_system_prompt,
				parts = { { type = "text", text = prompt } },
				format = {
					type = "json_schema",
					schema = AI.review_response_schema,
					retryCount = 2,
				},
			}

			if opencode_model then
				message_body.model = opencode_model
			end

			curl.post(with_directory(base_url .. "/session/" .. session_id .. "/message", directory), {
				headers = headers,
				body = vim.json.encode(message_body),
				timeout = timeout,
				callback = function(message_response)
					if message_response.status ~= 200 then
						finish(
							nil,
							"request failed with status code " .. message_response.status,
							build_http_error("send message", message_response),
							session_id
						)
						return
					end

					local review_response, err, err_detail = parse_review_response(message_response)
					finish(review_response, err, err_detail, session_id)
				end,
				on_error = function(err)
					finish(nil, err.message or "request failed", build_curl_error("send message", err), session_id)
				end,
			})
		end,
		on_error = function(err)
			finish(nil, err.message or "request failed", build_curl_error("create session", err))
		end,
	})
end

return AI
