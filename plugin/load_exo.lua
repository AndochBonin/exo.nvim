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
