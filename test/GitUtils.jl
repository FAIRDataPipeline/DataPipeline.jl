# SPDX-License-Identifier: LGPL-3.0-or-later

# What the repository checks share: whether the git working tree is clean.
# `include`d by each `clean_*.jl`; not named `test_*.jl`, `extras_*.jl` or
# `clean_*.jl`, so nothing runs it as a set of its own.

module GitUtils

using Git

export is_repo_clean

"""
    is_repo_clean(repo_path; strict = false)

Return whether the git repository at `repo_path` is clean, reporting its state.

Each entry of `git status -s` is staged (a change recorded in the index),
unstaged (a change to a tracked file not yet staged, including one staged and
then changed again) or untracked. By default only unstaged changes make the
repository dirty, which suits a check that rewrites files: it fails when what
it wrote has not been staged. With `strict = true` any change does, as on a
CI runner, whose checkout must be exactly the commit.

An `@info` gives the number of dirty files and lists the untracked ones; the
dirty files are listed in an `@error`.
"""
function is_repo_clean(repo_path; strict = false)
    # Each entry is "XY path": X the index's status, Y the working tree's
    statuses = readlines(`$(Git.git()) status -s $repo_path`)
    untracked = filter(s -> startswith(s, "??"), statuses)
    unstaged = filter(s -> !startswith(s, "??") && s[2] != ' ', statuses)
    dirty = strict ? statuses : unstaged

    message = "Repository $repo_path: $(length(dirty)) file(s) dirty, " *
              "$(length(untracked)) untracked"
    isempty(untracked) ||
        (message *= "\nUntracked files:\n" * join(untracked, "\n"))
    @info message
    clean = isempty(dirty)
    clean || @error "Repository not clean:\n" * join(dirty, "\n")
    return clean
end

end
