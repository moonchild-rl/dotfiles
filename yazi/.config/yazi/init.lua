require("git"):setup {
  order = 1500,
}

require("githead"):setup({
  order = {
    "__spacer__",
    "branch",
    "__spacer__",
    "behind_ahead_remote",
    "__spacer__",
    "staged",
    "unstaged",
    "untracked",
  },
})
