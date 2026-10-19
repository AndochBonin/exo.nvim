local AI = {}

--- @class ExoReviewResponse
--- @field comment string
--- @field quality "good"|"okay"|"poor"

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

If there are no issues, say the code looks good and rate quality "good".

Reply with ONLY a single JSON object and nothing else — no prose, no code
fences — in exactly this shape:
{"comment": "<your review>", "quality": "good"|"okay"|"poor"}
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

You are in read-only mode: never modify, create, or delete any files. Only
explain.

Reply with ONLY a single JSON object and nothing else — no prose, no code
fences — in exactly this shape:
{"title": "<3-8 word title>", "explanation": "<the full explanation as Markdown>"}
]]

--- @class ExoExplainResponse
--- @field title string
--- @field explanation string

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

-- How often (ms) to poll the message list while the agent loop runs.
AI.POLL_INTERVAL_MS = 500

local VALID_QUALITIES = { good = true, okay = true, poor = true }

local function build_headers(opts)
	local headers = { ["Content-Type"] = "application/json" }
	-- OpenCode v2 gates the HTTP API with Basic auth. The password is the same
	-- $OPENCODE_SERVER_PASSWORD the server is started with (opts.password
	-- overrides; $OPENCODE_PASSWORD accepted as the official client's alias).
	local password = (opts and opts.password) or vim.env.OPENCODE_SERVER_PASSWORD or vim.env.OPENCODE_PASSWORD
	if password then
		local username = (opts and opts.username) or vim.env.OPENCODE_SERVER_USERNAME or "opencode"
		local credentials = vim.fn.system(
			{ "printf", "%s:%s", username, password },
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

--- @param model string|{ providerID: string, id: string }|nil
--- @return { providerID: string, id: string }|nil
-- v2's Model.Ref uses `id` (not `modelID`); keep the "provider/model" string form.
local function parse_model(model)
	if model == nil or model == "" then
		return nil
	end

	if type(model) == "table" then
		return model
	end

	local provider_id, model_id = model:match("^([^/]+)/(.+)$")
	if provider_id and model_id then
		return { providerID = provider_id, id = model_id }
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

-- Pull a JSON object out of the assistant's free text. The model is asked to
-- reply with only JSON, but may wrap it in ```fences``` or add stray prose;
-- take the span from the first `{` to the last `}` and decode that.
local function parse_json_object(text)
	if type(text) ~= "string" then
		return nil
	end

	local first = text:find("{", 1, true)
	local last
	for i = #text, 1, -1 do
		if text:sub(i, i) == "}" then
			last = i
			break
		end
	end
	if not first or not last or last < first then
		return nil
	end

	local ok, obj = pcall(vim.json.decode, text:sub(first, last))
	if ok and type(obj) == "table" then
		return obj
	end
	return nil
end

--- Parse the assistant reply into an ExoReviewResponse.
--- @param text string
--- @return ExoReviewResponse|nil, string|nil, { summary: string[], body: string|nil }|nil
local function parse_review_response(text)
	local obj = parse_json_object(text)
	if
		type(obj) == "table"
		and type(obj.comment) == "string"
		and obj.comment ~= ""
		and VALID_QUALITIES[obj.quality]
	then
		return { comment = obj.comment, quality = obj.quality }, nil, nil
	end

	-- Fallback: use the whole reply as the comment.
	-- ponytail: naive, defaults quality "okay"; tighten if the model misformats often.
	local trimmed = vim.trim(text or "")
	if trimmed ~= "" then
		return { comment = trimmed, quality = "okay" }, nil, nil
	end

	return nil, "empty review response", {
		summary = {
			"OpenCode request failed",
			"",
			"Step: parse review response",
			"Error: empty response text",
		},
		body = pretty_body(text),
	}
end

--- Parse the assistant reply into an ExoExplainResponse. Prefers the JSON shape,
--- falling back to "first non-empty line = title, rest = explanation".
--- @param text string
--- @return ExoExplainResponse|nil, string|nil, { summary: string[], body: string|nil }|nil
local function parse_explain_response(text)
	local obj = parse_json_object(text)
	if
		type(obj) == "table"
		and type(obj.title) == "string"
		and obj.title ~= ""
		and type(obj.explanation) == "string"
		and obj.explanation ~= ""
	then
		return { title = obj.title, explanation = obj.explanation }, nil, nil
	end

	if type(text) ~= "string" or vim.trim(text) == "" then
		return nil, "empty explanation", {
			summary = {
				"OpenCode request failed",
				"",
				"Step: parse explain response",
				"Error: empty response text",
			},
			body = pretty_body(text),
		}
	end

	local lines = vim.split(text, "\n", { plain = true })
	local title, body_start
	for i, line in ipairs(lines) do
		if vim.trim(line) ~= "" then
			title = vim.trim(line):gsub("^#+%s*", ""):gsub("^%*+", ""):gsub("%*+$", "")
			body_start = i + 1
			break
		end
	end

	local explanation = vim.trim(table.concat(vim.list_slice(lines, body_start), "\n"))
	if explanation == "" then
		explanation = vim.trim(text)
	end

	return {
		title = (title ~= nil and title ~= "") and title or "Explanation",
		explanation = explanation,
	}, nil, nil
end

-- Newest-first scan of the message list for the latest assistant message; return
-- its concatenated text parts (v2 parts live under `content[]`, type "text").
local function assistant_text(messages)
	for _, m in ipairs(messages) do
		if m.type == "assistant" then
			local chunks = {}
			for _, part in ipairs(m.content or {}) do
				if part.type == "text" and type(part.text) == "string" then
					table.insert(chunks, part.text)
				end
			end
			return table.concat(chunks), m
		end
	end
	return nil, nil
end

-- Build an error summary/detail from a failed/interrupted run (idle.error, or the
-- assistant message's error — both are Session.StructuredError).
local function run_error(idle, assistant)
	local e = (idle and idle.error) or (assistant and assistant.error)
	if type(e) == "table" then
		local label = (e.type and (e.type .. ": ") or "") .. (e.message or "agent run failed")
		return e.message or e.type or "agent run failed", {
			summary = {
				"OpenCode request failed",
				"",
				"Step: agent run",
				"Error: " .. label,
			},
			body = pretty_body(e),
		}
	end
	local outcome = (idle and idle.outcome) or "failed"
	return "agent run " .. tostring(outcome), {
		summary = {
			"OpenCode request failed",
			"",
			"Step: agent run",
			"Outcome: " .. tostring(outcome),
		},
	}
end

--- Run one review/explain against the OpenCode v2 API:
--- create session → select agent/model → POST a prompt (async) → poll the
--- message list until the agent loop emits an `idle` message → parse the
--- assistant's reply → delete the session.
--- @param base_url string|nil
--- @param model string|{ providerID: string, id: string }|nil
--- @param prompt string
--- @param opts table|nil: may set `agent`, `system` (prepended to the prompt
---   text; defaults to the review system prompt), `title`, `directory`,
---   `timeout`, and `parse` (a `fun(text): result, err, err_detail`; defaults
---   to the review parser).
--- @param on_done fun(response: any|nil, err: string|nil)
--- @return fun() cancel|nil
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

	local api = base_url .. "/api"
	local timeout = opts.timeout or 120000
	local directory = opts.directory or vim.fn.getcwd()
	local headers = build_headers(opts)
	local system = opts.system or AI.review_system_prompt
	local text = system .. "\n\n" .. prompt

	local cancelled = false
	local callback_sent = false
	local session_id = nil
	local current_job = nil
	local cleanup_started = false

	local function stop_job(job)
		if job == nil or job.handle == nil then
			return
		end
		pcall(function()
			job.handle:kill(15) -- SIGTERM
		end)
	end

	local function delete_session(id, then_done)
		return curl.delete(with_directory(api .. "/session/" .. id, directory), {
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

	local function interrupt_session(id, then_done)
		return curl.post(with_directory(api .. "/session/" .. id .. "/interrupt", directory), {
			headers = headers,
			timeout = timeout,
			callback = function()
				then_done()
			end,
			on_error = function()
				then_done()
			end,
		})
	end

	local function cleanup_session(id, interrupt, then_done)
		if cleanup_started then
			return
		end
		cleanup_started = true

		local function delete()
			delete_session(id, then_done)
		end

		if interrupt then
			interrupt_session(id, delete)
		else
			delete()
		end
	end

	local function finish(response, err, err_detail)
		if cancelled or callback_sent then
			return
		end

		local function call_done()
			vim.schedule(function()
				if cancelled or callback_sent then
					return
				end
				callback_sent = true
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
			cleanup_session(session_id, false, call_done)
		else
			call_done()
		end
	end

	local function cleanup_cancelled_session()
		if session_id then
			cleanup_session(session_id, true, function() end)
		end
	end

	-- 5. Poll the message list until an `idle` message appears (the agent loop
	--    finished); then parse the assistant's reply or surface the run error.
	local function poll_messages()
		local deadline = vim.uv.now() + timeout

		local function do_poll()
			if cancelled then
				return
			end
			current_job = curl.get(with_directory(api .. "/session/" .. session_id .. "/message", directory), {
				headers = headers,
				timeout = timeout,
				callback = function(response)
					current_job = nil
					vim.schedule(function()
						if cancelled or callback_sent then
							return
						end

						local data = decode_response_body(response.body)
						local messages = type(data) == "table" and data.data or nil

						local idle
						if type(messages) == "table" then
							for _, m in ipairs(messages) do
								if m.type == "idle" then
									idle = m
									break
								end
							end
						end

						if idle then
							local body, assistant = assistant_text(messages)
							if idle.outcome ~= "succeeded" then
								local msg, detail = run_error(idle, assistant)
								finish(nil, msg, detail)
								return
							end
							local result, perr, pdetail = parse(body or "")
							finish(result, perr, pdetail)
							return
						end

						if vim.uv.now() >= deadline then
							finish(nil, "timed out waiting for response", {
								summary = {
									"OpenCode request failed",
									"",
									"Step: await response",
									"Error: agent did not finish in time",
								},
							})
							return
						end

						vim.defer_fn(do_poll, AI.POLL_INTERVAL_MS)
					end)
				end,
				on_error = function(err)
					current_job = nil
					vim.schedule(function()
						if cancelled or callback_sent then
							return
						end
						if vim.uv.now() >= deadline then
							finish(nil, err.message or "request failed", build_curl_error("await response", err))
						else
							vim.defer_fn(do_poll, AI.POLL_INTERVAL_MS)
						end
					end)
				end,
			})
		end

		do_poll()
	end

	-- 4. Send the prompt (async: schedules the agent loop), then poll.
	local function send_prompt()
		if cancelled then
			return
		end
		current_job = curl.post(with_directory(api .. "/session/" .. session_id .. "/prompt", directory), {
			headers = headers,
			body = vim.json.encode({ text = text }),
			timeout = timeout,
			callback = function(response)
				current_job = nil
				if cancelled then
					return
				end
				if response.status ~= 200 then
					finish(nil, "request failed with status code " .. response.status, build_http_error("send prompt", response))
					return
				end
				poll_messages()
			end,
			on_error = function(err)
				current_job = nil
				if cancelled then
					return
				end
				finish(nil, err.message or "request failed", build_curl_error("send prompt", err))
			end,
		})
	end

	-- 3. Select the model for the session (when configured).
	local function switch_model(then_next)
		if not opencode_model then
			then_next()
			return
		end
		current_job = curl.post(with_directory(api .. "/session/" .. session_id .. "/model", directory), {
			headers = headers,
			body = vim.json.encode({ model = opencode_model }),
			timeout = timeout,
			callback = function(response)
				current_job = nil
				if cancelled then
					return
				end
				if response.status ~= 200 and response.status ~= 204 then
					finish(nil, "request failed with status code " .. response.status, build_http_error("select model", response))
					return
				end
				then_next()
			end,
			on_error = function(err)
				current_job = nil
				if cancelled then
					return
				end
				finish(nil, err.message or "request failed", build_curl_error("select model", err))
			end,
		})
	end

	-- 2. Select the agent for the session (when configured).
	local function switch_agent(then_next)
		if not opts.agent then
			then_next()
			return
		end
		current_job = curl.post(with_directory(api .. "/session/" .. session_id .. "/agent", directory), {
			headers = headers,
			body = vim.json.encode({ agent = opts.agent }),
			timeout = timeout,
			callback = function(response)
				current_job = nil
				if cancelled then
					return
				end
				if response.status ~= 200 and response.status ~= 204 then
					finish(nil, "request failed with status code " .. response.status, build_http_error("select agent", response))
					return
				end
				then_next()
			end,
			on_error = function(err)
				current_job = nil
				if cancelled then
					return
				end
				finish(nil, err.message or "request failed", build_curl_error("select agent", err))
			end,
		})
	end

	-- 1. Create the session.
	current_job = curl.post(with_directory(api .. "/session", directory), {
		headers = headers,
		body = vim.json.encode({ title = opts.title or "exo-review" }),
		timeout = timeout,
		callback = function(response)
			current_job = nil
			if cancelled then
				if response.status == 200 then
					local data = decode_response_body(response.body)
					if type(data) == "table" and type(data.data) == "table" and type(data.data.id) == "string" then
						session_id = data.data.id
						cleanup_cancelled_session()
					end
				end
				return
			end

			if response.status ~= 200 then
				finish(nil, "request failed with status code " .. response.status, build_http_error("create session", response))
				return
			end

			local data = decode_response_body(response.body)
			if type(data) ~= "table" or type(data.data) ~= "table" or type(data.data.id) ~= "string" then
				finish(nil, "error creating session", {
					summary = {
						"OpenCode request failed",
						"",
						"Step: create session",
						"Error: response missing session id",
					},
					body = pretty_body(response.body),
				})
				return
			end

			session_id = data.data.id
			if cancelled then
				cleanup_cancelled_session()
				return
			end

			switch_agent(function()
				if cancelled then
					return
				end
				switch_model(function()
					if cancelled then
						return
					end
					send_prompt()
				end)
			end)
		end,
		on_error = function(err)
			current_job = nil
			if cancelled then
				return
			end
			finish(nil, err.message or "request failed", build_curl_error("create session", err))
		end,
	})

	return function()
		if cancelled or callback_sent then
			return
		end
		cancelled = true
		stop_job(current_job)
		cleanup_cancelled_session()
	end
end

--- Request a structured explanation ({ title, explanation }). Thin wrapper over
--- `get_opencode_response` that uses the explain system prompt + parser and a
--- session title of "exo-explain".
--- @param base_url string|nil
--- @param model string|{ providerID: string, id: string }|nil
--- @param prompt string
--- @param opts table|nil: may set `agent`, `directory`, `timeout`.
--- @param on_done fun(response: ExoExplainResponse|nil, err: string|nil)
AI.get_opencode_explanation = function(base_url, model, prompt, opts, on_done)
	opts = vim.tbl_extend("force", {
		system = AI.explain_system_prompt,
		title = "exo-explain",
	}, opts or {})
	opts.parse = parse_explain_response
	return AI.get_opencode_response(base_url, model, prompt, opts, on_done)
end

return AI
