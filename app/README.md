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
The installer also installs a separate copy of gopls v0.20.0 for Go editing support.
It reuses a matching installed binary or builds it with Go 1.27.3.

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

Press Space, then `i` to open the instructions popup from any screen.
You can also use `:ReviewHelp`.
The popup lists every Review shortcut and common Vim editing, search, diff, and pane controls.
Use `j`, `k`, or the arrow keys to scroll.
Press Esc, Enter, or `q` to close the popup.
Press Space, then `i` again to close it.

Repositories sort alphabetically by name and show their relative paths and current branches.
Each PR shows its title, draft state, author, update date, source branch, and target branch.

The left panel groups changed files in a collapsible directory tree.
It shows file counts and colored Git status indicators.
Press Enter on a directory to expand or collapse it.
Use `h` and `l` to navigate directories.
Press Enter on a file to edit it.
The middle pane shows the read-only comparison version.
The right pane opens the actual local file.
The separate application theme preserves syntax colors.
Changed lines have red backgrounds in the old version and green backgrounds in the local version.
Stronger colors mark the exact changed words. Blank alignment rows stay neutral.
Use normal Vim editing controls and `:w` to save changes.
The file list refreshes after each save.

| Key | Action |
| --- | --- |
| Space, then `i` | Show or hide all instructions |
| Space, then `f` | Focus the file tree |
| Space, then `a` | Toggle Changes / All files |
| Space, then `o` | Find a file anywhere in the checkout |
| Space, then `g` | Expand or collapse a generated file in both panes |
| Space, then `d` (Go) | Show errors and warnings for the current line |
| Space, then `n` | Mark the current file viewed and open the next unviewed file |
| Space, then `b` | Undo the last Next step and return to that file |
| Space, then `c`, then `c` | Commit and push saved changes in the selected PR worktree |
| Space, then `p` | Return to the PR list |
| Space, then `r` | Pull latest PR updates and reload clean files |
| Space, then `q` | Quit Review |
| `q` in a list | Return to the previous list |
| `:q` or `:ReviewQuit` | Quit the whole application |

Save your edits before changing PRs.
The application blocks navigation between PRs while a buffer contains unsaved edits.
Quitting also stops if any buffer contains unsaved edits.
Use `:q!` to exit and discard unsaved edits.

Generated files start folded in both panes and show a `gen` badge in the sidebar.
Directories that contain only generated changes start collapsed.
This includes all files under a `vendor/` directory, standard lock and checksum files, and files with generated headers.
Review also reads the `linguist-generated` attribute from `.gitattributes`.
An explicit false value disables detection for that file, except under `vendor/`.
Press Space, then `g`, or use `:ReviewGenerated` to expand or collapse both panes.
Collapsing generated files does not mark them viewed. You can still open, edit, and save them.

## Browse the project

The sidebar starts with changed files. Press Space, then `a` to show the full project tree.

The tree includes tracked files and new files that Git does not ignore.
Generated directories and `vendor/` start collapsed. The path to your current review file opens automatically.
Press Space, then `a` again to return to Changes.
You can also use `:ReviewFiles`.

Open an unchanged file to edit it in a dock below both diff panes.
Press `q` in Normal mode to close the dock and return to your review position.
Unsaved edits stay in their buffer when you close the dock.
Save with `:w` to add the file to Changes.

Browsing preserves review progress. Next and Back continue through changed files.
Go files in the dock support autocomplete and documentation.
Use `:ReviewClosePeek` to close the dock from any pane.

Press Space, then `o`, or use `:ReviewFind` to search filenames across the whole checkout.
Type part of a filename or path. Use Ctrl-n, Ctrl-p, or the arrow keys to select a result.
Press Enter to open it. Press Esc to cancel.

Changed files open in the diff. Unchanged files open in the dock.
The full file list loads on demand and stays cached until a save or PR refresh.

## Go editing support

Go files provide autocomplete, documentation, function parameter hints, and error and warning markers.
Language support starts in the background when you open an editable Go file.
Files in the same Go project reuse their server.
Opening or pulling a PR reloads Go support for the checkout.
The comparison pane stays read-only and does not start a server.
Review keeps its language server separate from your normal Neovim setup.

Suggestions appear as you type. Press Ctrl-Space to request them manually.
Use Up and Down or Ctrl-n and Ctrl-p to select a suggestion.
Press Enter to accept the selected suggestion, including any required import and parameter placeholders.
If no suggestion is selected, Enter inserts a newline.
Tab indents. Esc cancels completion and returns to Normal mode.

Selected suggestions show documentation in a popup.
In Normal mode, press `K` to read documentation for the symbol under the cursor.
Function hints appear while you enter arguments. Press Ctrl-s in Insert mode to request a hint.
The active parameter is highlighted.

Errors and warnings use `E` and `W` markers beside the code.
Press Space, then `d` to read details for the current line.
Space, then `i` lists these controls.

## Review progress

Save the current file before pressing Space, then `n`.
The shortcut marks the current file viewed and opens the next unviewed file in tree order.
Viewed files show a check mark, and completed directories collapse.
The sidebar shows the viewed count for each directory and the whole PR.
After the last file, Review reports that all files are viewed.
You can also use `:ReviewNext`.

Press Space, then `b` to undo the last Next step for the current PR.
You can also use `:ReviewBack`.
Back restores the previous file, cursor position, and viewed state, and reopens its directory.
Unsaved edits in the file you leave stay in their buffer.
Repeated Back presses undo earlier steps.
Steps remain available while switching PRs in this Review session.

Viewed marks remain local for the current Review session and survive switching PRs.
Saving a viewed file makes it unviewed again and reopens its completed directories.
Changing the comparison base also clears affected marks.

## Commit and push

Save all edits before pressing Space, then `c`, then `c`.
You can also use `:ReviewCommitPush`.
Enter a commit message.
Approve the confirmation that shows the changed file count, commit message, and push destination.
Cancel the prompt to leave the index and commit history unchanged.

The command includes all saved, uncommitted changes in the selected PR worktree, including existing staged changes.
It stages explicit file paths and pushes to the PR source repository and branch.
The command uses a normal push and stops if Git rejects it.
It refuses unresolved merge conflicts or a changed worktree branch.

If the push fails, the local commit remains available.
Resolve the push error before using the shortcut again.
If no uncommitted changes remain, the shortcut asks for approval and pushes existing commits.
It does not create another commit.

## Loading

Repository discovery reads standard Git metadata directly.
Other layouts use Git, with up to eight commands in parallel.
The GitHub query loads repository identity and PR fields together.
Returning to a PR list reuses its result for up to 30 seconds.
Press `r` on that screen to fetch a fresh list.

Opening a PR reads its current GitHub metadata and updates a clean checkout to the latest source commit.
Press Space, then `r`, or use `:ReviewPull` to pull again while reviewing code.
This preserves the selected file, cursor position, and sidebar selection where possible.
Saving a file refreshes the local diff without a GitHub request.
The loading dialog appears before repository discovery or network requests start.

Read-only base content is cached by commit and file path for the open PR.
The cache holds up to 8 MiB of base content.
Reopening files and refreshing saved edits can reuse this content without another Git process.

On November 9, 2026, one run over 76 repositories produced these results:

| Operation | Before | After |
| --- | --- | --- |
| Repository discovery | 3.10 seconds | 0.43 seconds |
| GitHub PR list | 1.45 seconds | 0.74 seconds |

Network timings vary between runs.

On November 10, 2026, another pass over 73 repositories produced these results:

| Operation | Before this pass | After this pass |
| --- | --- | --- |
| Repository discovery | 361 ms | 35–74 ms |
| Git processes for discovery | 173 | 7 |
| 30 repeated base-file reads | 489 ms | Less than 1 ms |

The discovered repositories and branch labels matched the previous implementation.
Fresh GitHub requests still took about 0.6–1 second in these runs.

## Comparisons and worktrees

GitHub supplies each PR's source and target branches.
If both commits exist locally, the application uses them directly.
Otherwise, it fetches them into private Git references under `refs/pr-review/`.
The merge base is the commit where their histories meet.
The editor compares this commit with the local worktree, a separate checkout.
This comparison includes committed changes, staged changes, unstaged changes, and new files.
Git-ignored files stay excluded.

The application searches the selected repository's registered worktrees, including checkouts outside the opened directory.
It prefers an existing source checkout, including a local branch that tracks the PR source branch.
If Git still reserves the PR branch for a deleted worktree, Review removes that stale registration automatically.
It preserves the branch, commits, and unrelated worktree registrations.
Locked or inaccessible checkouts and directories that still contain files require repair before Review can use that branch.
If the branch is not checked out, it switches the selected clean checkout to that branch.
It does not switch unrelated worktrees to another branch.
If no clean checkout is available, it offers to create a worktree and requires your choice.
It never creates one silently.

Use `:pwd` to see the active checkout directory.

Updates use a fast-forward, which advances a branch without dropping commits.
If clean histories diverge, Review saves the local tip on a backup branch and follows GitHub automatically.
The update message names that backup branch.
Use `:messages` to read recent update messages and backup branch names.
Local uncommitted edits block updates and produce an explanation.
Resolve the reported issue before pulling again.

If a fork's branch name conflicts locally, it uses `pr-review/<number>`.
The status line shows when the local branch differs from the GitHub branch.
The application does not automatically stash changes or rewrite branch history.
Commits and pushes require the shortcut and its confirmation.

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
Language-support tests use a local server fixture to test completion, imports, parameter placeholders, documentation, and diagnostics.

To test the installed Go server against a temporary module:

```sh
nvim --headless --noplugin -i NONE -u NONE -l tests/lsp_live.lua "${XDG_DATA_HOME:-$HOME/.local/share}/pr-review/bin/gopls"
```

This test blocks Go module downloads.

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
[Git repository layout](https://git-scm.com/docs/gitrepository-layout) describes the metadata used for repository discovery.
[Neovim application isolation](https://neovim.io/doc/user/starting.html#%24NVIM_APPNAME)
describes separate application directories.
[Neovim LSP completion](https://neovim.io/doc/user/lsp.html#lsp-completion) describes completion and import edits.
[gopls](https://go.dev/gopls/) provides Go language support.
