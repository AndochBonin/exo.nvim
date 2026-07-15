local http_request = require("http.request")

local review_prompt = [[You are an expert %s code reviewer.

Review the provided code as if you were performing a professional pull request review. Focus on correctness, maintainability, readability, performance, security, and adherence to common %s best practices and idioms.

review the following areas (where applicable):

1. Bugs and correctness issues
2. Security vulnerabilities
3. Performance concerns
4. Code style and readability (prefer idiomatic code)
5. Architecture and design
6. Error handling and edge cases
7. Concurrency/thread-safety issues
8. Maintainability and technical debt

Output a concise final assessment and the highest-priority actions to take.
Be specific and actionable. Avoid generic comments. Only report issues that have a reasonable likelihood of being real.]]

local explain_prompt = [[You are a senior software engineer. Provide an answer for this prompt "%s"]]
local explain_context_addition = [[in the context of this code ```%s```]]

local get_review_ollama_response = function(code)
	return get_ollama_response(nil, review_prompt```]]

local curl = require("plenary.curl")

local get_ollama_response = function(base_url, prompt)
	base_url = base_url or "http://localhost:11434"

	if prompt == nil or prompt == "" then
		return
	end

	local response = curl.post(base_url .. "/api/generate", {
		headers = {
			["Content-Type"] = "application/json",
		},
		body = vim.json.encode({
			model = "qwen2.5:coder",
			prompt = prompt,
			stream = false,
		}),
	})

	if response.status ~= 200 then
		error("Request failed with status code " .. response.status .. ": " .. response.body)
	end

	return response.body
end
