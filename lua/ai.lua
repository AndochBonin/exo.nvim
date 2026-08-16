local AI = {}

--- @class ExoReviewResponse
--- @field comment string
--- @field quality "good"|"okay"|"poor"

AI.review_response_schema = {
	type = "object",
	properties = {
		comment = {
			type = "string",
			description = "Brief review of the highlighted code, at most one paragraph",
		},
		quality = {
			type = "string",
			enum = { "good", "okay", "poor" },
			description = "Overall code quality assessment",
		},
	},
	required = { "comment", "quality" },
}

AI.review_system_prompt = [[
You are an expert code reviewer.
Review code for: bugs/correctness, security, performance, style/idioms,
architecture, error handling, concurrency, maintainability.

You may read other files in the project to understand context (imports, callees,
types), but only report issues about the highlighted range you are asked to review.

Comment style:
- Write a SINGLE brief comment (at most one paragraph) covering the most
  important issues in the highlighted code.
- Be concrete and direct. Only report issues with a reasonable likelihood of
  being real.

Quality ratings:
- "good": no meaningful issues
- "okay": minor/style issues, no serious bugs
- "poor": correctness, security, or significant design problems

If there are no issues, return a short comment saying the code looks good and
quality "good".
]]

AI.review_prompt = [[
Review focuses on lines %d-%d of `%s`.
You may read any file in the project for context, but only report issues about
the highlighted range below.

Highlighted %s code:

```
%s
```
]]

AI.explain_system_prompt = [[
You are a senior software engineer. Explain the user's question clearly and
concisely.

When a code selection and project are provided, explain the selection in the
context of that project: you may read other files in the project (imports,
callees, types) to ground your explanation. You may also search the web for
up-to-date information when it helps.

Return a short `title` (3-8 words) summarizing the explanation, and the full
`explanation` itself formatted as Markdown.

You are in read-only mode: never modify, create, or delete any files. Only
explain.
]]

--- @class ExoExplainResponse
--- @field title string
--- @field explanation string

AI.explain_response_schema = {
	type = "object",
	properties = {
		title = {
			type = "string",
			description = "A short (3-8 word) title summarizing the explanation",
		},
		explanation = {
			type = "string",
			description = "The full explanation, formatted as Markdown",
		},
	},
	required = { "title", "explanation" },
}

-- `%s` (user question). Used on its own when there is no selection.
AI.explain_prompt = [[%s]]

-- Appended after `explain_prompt` when a selection exists.
-- Args (in order): file_path, start_line, end_line, language, code.
AI.explain_context_addition = [[

Explain in the context of lines %d-%d of `%s`.

Highlighted %s code:

```
%s
```]]

--- Build the explain prompt from the user's question plus optional code context.
--- @param user_question string
--- @param language string
--- @param code string|nil: joined selected lines, or nil when there is no selection
--- @param file_path string|nil
--- @param start_line integer|nil
--- @param end_line integer|nil
--- @return string
AI.create_explain_prompt = function(user_question, language, code, file_path, start_line, end_line)
	local prompt = string.format(AI.explain_prompt, user_question)
	if code ~= nil and code ~= "" then
		prompt = prompt .. string.format(AI.explain_context_addition, start_line, end_line, file_path, language, code)
	end
	return prompt
end

--- @param language string
--- @param code string
--- @param file_path string
--- @param start_line integer
--- @param end_line integer
AI.create_review_prompt = function(language, code, file_path, start_line, end_line)
	return string.format(AI.review_prompt, start_line, end_line, file_path, language, code)
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

-- Errors are represented as { summary = { <short lines> }, body = <raw dump|nil> }.
-- The summary is shown in the notification; the body is logged for debugging only.
local function normalize_error(err)
	if type(err) == "string" then
		return { summary = { err } }
	end
	if type(err) == "table" and err.summary == nil then
		-- Legacy: a plain array of lines.
		return { summary = err }
	end
	return err
end

local function format_error(err)
	err = normalize_error(err)
	local parts = {}
	for _, line in ipairs(err.summary or {}) do
		table.insert(parts, type(line) == "string" and line or pretty_body(line))
	end
	return table.concat(parts, "\n")
end

-- Write the full error (summary + raw body) to :messages history without popping a
-- notification, so the detail stays retrievable while the notification stays concise.
local function log_full(err)
	err = normalize_error(err)
	if err.body == nil then
		return
	end
	local text = format_error(err) .. "\n\n" .. (type(err.body) == "string" and err.body or pretty_body(err.body))
	vim.schedule(function()
		vim.api.nvim_echo({ { text } }, true, {})
	end)
end

local function build_http_error(step, response)
	return {
		summary = {
			"OpenCode request failed",
			"",
			"Step: " .. step,
			"Status: " .. tostring(response.status),
		},
		body = pretty_body(response.body),
	}
end

local function build_curl_error(step, err)
	return {
		summary = {
			"OpenCode request failed",
			"",
			"Step: " .. step,
			"Error: " .. (err.message or "request failed"),
		},
		body = vim.inspect(err),
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
--- @return ExoReviewResponse|nil, string|nil, { summary: string[], body: string|nil }|nil
local function parse_review_response(response)
	local data, decode_err = decode_response_body(response.body)
	if data == nil then
		return nil, decode_err, {
			summary = {
				"OpenCode request failed",
				"",
				"Step: parse review response",
				"Error: " .. decode_err,
			},
			body = pretty_body(response.body),
		}
	end

	-- Any nested error carries the real cause (e.g. an APIError from the model backend).
	-- Surface its name/message instead of falling through to the generic body dump.
	if data.info and data.info.error then
		local error = data.info.error
		local message = error.message or "structured output error"
		local label = error.name and (error.name .. ": " .. message) or message
		local summary = {
			"OpenCode request failed",
			"",
			"Step: parse review response",
			"Error: " .. label,
		}
		if error.retries ~= nil then
			table.insert(summary, "Retries: " .. tostring(error.retries))
		end
		return nil, message, {
			summary = summary,
			body = pretty_body(response.body),
		}
	end

	local structured = extract_structured(data)
	if type(structured) ~= "table" then
		return nil, "invalid structured response", {
			summary = {
				"OpenCode request failed",
				"",
				"Step: parse review response",
				"Error: missing structured review output",
			},
			body = pretty_body(response.body),
		}
	end

	if type(structured.comment) ~= "string" or structured.comment == "" then
		return nil, "invalid structured response", {
			summary = {
				"OpenCode request failed",
				"",
				"Step: parse review response",
				"Error: structured comment is not a non-empty string",
			},
			body = pretty_body(structured),
		}
	end

	if not VALID_QUALITIES[structured.quality] then
		return nil, "invalid quality value", {
			summary = {
				"OpenCode request failed",
				"",
				"Step: parse review response",
				"Error: invalid quality value: " .. tostring(structured.quality),
			},
			body = pretty_body(structured),
		}
	end

	return {
		comment = structured.comment,
		quality = structured.quality,
	}, nil, nil
end

--- Parse a structured explain response ({ title, explanation }).
--- @param response table
--- @return ExoExplainResponse|nil, string|nil, { summary: string[], body: string|nil }|nil
local function parse_explain_response(response)
	local data, decode_err = decode_response_body(response.body)
	if data == nil then
		return nil, decode_err, {
			summary = {
				"OpenCode request failed",
				"",
				"Step: parse explain response",
				"Error: " .. decode_err,
			},
			body = pretty_body(response.body),
		}
	end

	-- Surface any nested backend error (e.g. an APIError from the model backend).
	if data.info and data.info.error then
		local error = data.info.error
		local message = error.message or "explain error"
		local label = error.name and (error.name .. ": " .. message) or message
		local summary = {
			"OpenCode request failed",
			"",
			"Step: parse explain response",
			"Error: " .. label,
		}
		if error.retries ~= nil then
			table.insert(summary, "Retries: " .. tostring(error.retries))
		end
		return nil, message, {
			summary = summary,
			body = pretty_body(response.body),
		}
	end

	local structured = extract_structured(data)
	if type(structured) ~= "table" then
		return nil, "invalid structured response", {
			summary = {
				"OpenCode request failed",
				"",
				"Step: parse explain response",
				"Error: missing structured explain output",
			},
			body = pretty_body(response.body),
		}
	end

	if type(structured.title) ~= "string" or structured.title == "" then
		return nil, "invalid structured response", {
			summary = {
				"OpenCode request failed",
				"",
				"Step: parse explain response",
				"Error: structured title is not a non-empty string",
			},
			body = pretty_body(structured),
		}
	end

	if type(structured.explanation) ~= "string" or structured.explanation == "" then
		return nil, "invalid structured response", {
			summary = {
				"OpenCode request failed",
				"",
				"Step: parse explain response",
				"Error: structured explanation is not a non-empty string",
			},
			body = pretty_body(structured),
		}
	end

	return {
		title = structured.title,
		explanation = structured.explanation,
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
--- @param opts table|nil: may set `agent`, `system`, `title`, `directory`,
---   `timeout`, plus `format` (json_schema table, or `false` to omit and get free
---   text) and `parse` (a `fun(response): result, err, err_detail`). Defaults keep
---   the review json_schema + parser for backward compatibility.
--- @param on_done fun(response: any|nil, err: string|nil)
AI.get_opencode_response = function(base_url, model, prompt, opts, on_done)
	base_url = base_url or "http://localhost:4096"
	opts = opts or {}

	if prompt == nil or prompt == "" then
		on_done(nil, "empty prompt")
		return
	end

	local parse = opts.parse or parse_review_response

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
					local detail = err_detail or { summary = { err } }
					log_full(detail)
					on_done(response, format_error(detail))
					return
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
		body = vim.json.encode({ title = opts.title or "exo-review" }),
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
					summary = {
						"OpenCode request failed",
						"",
						"Step: create session",
						"Error: response missing session id",
					},
					body = pretty_body(session_response.body),
				})
				return
			end

			local session_id = session_data.id
			local message_body = {
				system = opts.system or AI.review_system_prompt,
				parts = { { type = "text", text = prompt } },
			}

			-- `opts.format == false` omits the json_schema (free-text reply); an
			-- explicit table overrides; nil keeps the default review schema.
			if opts.format ~= nil then
				message_body.format = opts.format or nil
			else
				message_body.format = {
					type = "json_schema",
					schema = AI.review_response_schema,
					retryCount = 2,
				}
			end

			if opencode_model then
				message_body.model = opencode_model
			end

			if opts.agent then
				message_body.agent = opts.agent
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

					local parsed, err, err_detail = parse(message_response)
					finish(parsed, err, err_detail, session_id)
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

--- Request a structured explanation ({ title, explanation }). Thin wrapper over
--- `get_opencode_response` that uses the explain json_schema and parser,
--- defaulting the system prompt to `AI.explain_system_prompt` and the session
--- title to "exo-explain".
--- @param base_url string|nil
--- @param model string|{ providerID: string, modelID: string }|nil
--- @param prompt string
--- @param opts table|nil: may set `agent`, `system`, `directory`, `timeout`.
--- @param on_done fun(response: ExoExplainResponse|nil, err: string|nil)
AI.get_opencode_explanation = function(base_url, model, prompt, opts, on_done)
	opts = vim.tbl_extend("force", {
		system = AI.explain_system_prompt,
		title = "exo-explain",
	}, opts or {})
	opts.format = {
		type = "json_schema",
		schema = AI.explain_response_schema,
		retryCount = 2,
	}
	opts.parse = parse_explain_response
	AI.get_opencode_response(base_url, model, prompt, opts, on_done)
end

return AI
