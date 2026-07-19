vim.api.nvim_create_user_command("ExoReview", function()
    require("exo").review()
end, {})

vim.api.nvim_create_user_command("ExoExplain", function()
    require("exo").explain()
end, {})

vim.api.nvim_create_user_command("ExoListMarks", function()
    require("exo").list_marks()
end, {})

vim.api.nvim_create_user_command("ExoDeleteMark", function()
    require("exo").delete_mark()
end, {})

vim.api.nvim_create_user_command("ExoPrevMark", function()
    require("exo").jump_prev_mark()
end, {})

vim.api.nvim_create_user_command("ExoNextMark", function()
    require("exo").jump_next_mark()
end, {})

vim.api.nvim_create_user_command("ExoJumpToMark", function(opts)
    require("exo").jump_to_mark(opts.args)
end, { nargs = 1 })
