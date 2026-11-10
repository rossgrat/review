# PR Review

PR Review is a separate Neovim application for editing local GitHub PR changes.
Open a directory, select a repository, and select an open PR.
The editor shows changed files beside the comparison with the PR target.
Open draft PRs appear in the same list.

## Install

Use Neovim 0.12.6, GitHub CLI 2.103.3, and Git 2.54.0.
The tool versions are pinned in `mise.toml`.

From this project directory, install Review:

```sh
./install
```

The installer checks the required tools and starts GitHub login if needed.
If a required tool is missing, run `mise install` in this directory first.
It installs the application under `~/.local/share/pr-review/app` and the command under `~/.local/bin/review`.
It respects `XDG_DATA_HOME` for application data.
It preserves unrelated commands and leaves shell configuration files unchanged.

From any directory, launch the installed application:

```sh
review /path/to/repos
```

Run `review` without a path to open the current directory.
Run `./install` again after source changes to update the installed copy.

To launch directly from this project directory:

```sh
./review /path/to/repos
```

The launcher uses `NVIM_APPNAME=pr-review` and this project's `init.lua`.
It disables plugin loading and shared history.
It does not load or change your normal Neovim configuration.
No plugin installation is required.

## Edit

Select a repository or PR with the arrow keys or `j` and `k`.
Press Enter to open the selection.
Use `/` to search a list.

Repositories sort alphabetically by name and show their relative paths and current branches.
Each PR shows its title, draft state, author, update date, source branch, and target branch.

The left panel groups changed files in a collapsible directory tree.
It shows file counts and colored Git status indicators.
Press Enter on a directory to expand or collapse it.
Use `h` and `l` to navigate directories.
Press Enter on a file to edit it.
The middle pane shows the read-only comparison version.
The right pane opens the actual local file.
The separate application theme preserves syntax colors and uses muted backgrounds for changed lines and words.
Use normal Vim editing controls and `:w` to save changes.
The file list refreshes after each save.

| Key | Action |
| --- | --- |
| Space, then `f` | Focus the changed files |
| Space, then `p` | Return to the PR list |
| Space, then `r` | Refresh local changes |
| Space, then `q` | Quit Review |
| `q` in a list | Return to the previous list |
| `:q` or `:ReviewQuit` | Quit the whole application |

Save your edits before changing PRs.
The application blocks navigation between PRs while a buffer contains unsaved edits.
Quitting also stops if any buffer contains unsaved edits.
Use `:q!` to exit and discard unsaved edits.

## Loading

Repository discovery runs up to eight local Git commands in parallel.
The GitHub query loads repository identity and PR fields together.
Returning to a PR list reuses its result for up to 30 seconds.
Press `r` on that screen to fetch a fresh list.
Opening a PR always reads its current GitHub metadata.
The loading dialog appears before repository discovery or network requests start.

On November 9, 2026, one run over 76 repositories produced these results:

| Operation | Before | After |
| --- | --- | --- |
| Repository discovery | 3.10 seconds | 0.43 seconds |
| GitHub PR list | 1.45 seconds | 0.74 seconds |

Network timings vary between runs.

## Comparisons and worktrees

GitHub supplies each PR's source and target branches.
If both commits exist locally, the application uses them directly.
Otherwise, it fetches them into private Git references under `refs/pr-review/`.
The merge base is the commit where their histories meet.
The editor compares this commit with the local worktree, a separate checkout.
This comparison includes committed changes, staged changes, unstaged changes, and new files.
Git-ignored files stay excluded.

The application reuses an existing worktree for the source branch, including external worktrees.
It preserves existing commits and local edits.
If no worktree exists, it creates one under the separate application's data directory.
If a fork's branch name conflicts locally, it uses `pr-review/<number>`.
The status line shows when the local branch differs from the GitHub branch.
The application does not automatically pull, stash, commit, or push changes.

Repository discovery searches nested directories and groups linked worktrees by repository.
It skips hidden directories, symbolic-link directories, and `node_modules`.
Search stops inside each discovered repository.
GitHub access and fetching require a network connection.
Existing shallow clones need enough history to find the merge base.

## Tests

From this project directory, run the tests:

```sh
./test
```

The tests use temporary Git repositories and a local substitute for GitHub CLI.
They exercise stacked branches, worktrees, rename handling, local edits, pagination, and the editable interface.

The optional live test uses a temporary clone and reads GitHub.
Pass an existing local clone and an open PR number:

```sh
nvim --headless --noplugin -i NONE -u NONE -l tests/live.lua /path/to/repository 123
```

To measure loading, pass a directory and an optional local GitHub clone:

```sh
nvim --headless --noplugin -i NONE -u NONE -l tests/benchmark.lua /path/to/repos /path/to/repository
```

## References

[GitHub PR branches](https://docs.github.com/en/pull-requests/reference/branches)
describes PR targets and comparisons.
[Git worktrees](https://git-scm.com/docs/git-worktree) describes separate checkouts.
[Neovim application isolation](https://neovim.io/doc/user/starting.html#%24NVIM_APPNAME)
describes separate application directories.
