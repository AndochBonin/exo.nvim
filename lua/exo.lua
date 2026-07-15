local M = {}

M.setup = function()
	NS = vim.api.nvim_create_namespace("exoskeleton")
	vim.keymap.set({ "n", "v" }, "<leader>er", "<CMD>ExoReview<CR>", { silent = true })
	vim.keymap.set({ "n", "v" }, "<leader>ee", "<CMD>ExoExplain<CR>", { silent = true })
end

local function get_visual_selection()
	local selection_start = vim.fn.getpos("'<")
	local selection_end = vim.fn.getpos("'>")
	local mode = vim.fn.visualmode()

	return vim.fn.getregion(selection_start, selection_end, { type = mode })
end

--- @param code string[]: A list of lines to be reviewed.
--- @return string[]
local review_code = function(code)
	-- pass the code and file type (to determine the language) to the llm by making a provider call -> we need something to abstract this
	-- get the output and store in review_comments
    local file_type = vim.bo.filetype
    local formatted_prompt =  
	return { file_type }
end

--- @param selection string[]: A list of lines that were selected for a comment.
--- @return string[]
local explain_selection = function(selection)
	--
	local explanation = { "this", "is", "an", "explanation" } -- this will be the comments returned from the llm
	return explanation
end

M.review = function()
	local mode = vim.fn.mode()
	local is_visual = mode == "v" or mode == "V" or mode == "\22" -- \22 is CTRL-V (blockwise)

	if not is_visual then
		vim.notify("No visual selection", vim.log.levels.WARN, { title = "Exoskeleton" })
		return
	end

	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
	local text_selection = get_visual_selection()
	local review_comments = review_code(text_selection)

	local output_string = ""
	for _, line in ipairs(review_comments) do
		output_string = output_string .. line .. "\n"
	end

	output_string = output_string .. "\n"
	vim.notify(output_string, vim.log.levels.INFO, { title = "Exoskeleton" })
end

M.explain = function()
	local mode = vim.fn.mode()
	local is_visual = mode == "v" or mode == "V" or mode == "\22" -- \22 is CTRL-V (blockwise)

	local output_string = ""
	if is_visual then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
		local text_selection = get_visual_selection()
		output_string = "" .. text_selection[1][2] .. ":" .. text_selection[1][3] .. " to " -- start of selection
		output_string = output_string .. "" .. text_selection[2][2] .. ":" .. text_selection[2][3] .. "\n" -- end of selection
	end

	local explanation_lines = explain_selection(nil)
	for _, comment in ipairs(explanation_lines) do
		output_string = output_string .. "- " .. comment .. "\n"
	end

	output_string = output_string .. "\n"
	vim.notify(output_string, vim.log.levels.INFO, { title = "Exoskeleton" })
end

return M
