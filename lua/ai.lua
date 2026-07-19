local AI = {}

AI.review_prompt = [[
You are an expert %s code reviewer.
Review the code below for: bugs/correctness, security, performance,
style/idioms, architecture, error handling, concurrency, maintainability.

Output format rules (strict):
- Plain text only. No markdown, no bullet points, no numbering.
- Each issue is ONE short line, written like an inline code comment.
- Use imperative, telegraphic phrasing. Drop filler words, hedges, and
  subjects. Cut "I think", "we should probably", "consider", "it seems",
  "this could potentially", "you might want to".
- Format per issue: <what to do>; <why>. Nothing else.
  Good: "Remove this; unused."
  Good: "Use == here; = is an assignment, not a comparison."
  Bad:  "A few things I would consider changing: I think we should
         probably remove this because it isn't being used anymore."
- No preamble, no summary, no sign-off. If there are multiple issues,
  output one line per issue, nothing joining them.
- Only report issues with a reasonable likelihood of being real. If there
  are no issues, output nothing.

Code:
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

--- @param on_done fun(response: string|nil, err: string|nil)
AI.get_ollama_response = function(base_url, prompt, on_done)
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

return AI
