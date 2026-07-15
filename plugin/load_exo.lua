vim.api.nvim_create_user_command("ExoReview", function()
    require("exo").review()
end, {})


vim.api.nvim_create_user_command("ExoExplain", function()
    require("exo").explain()
end, {})
