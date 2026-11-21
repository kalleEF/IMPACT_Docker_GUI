# Known bugs and limitations

Problems we know about in the current version, with a workaround where there is one. The IDs in brackets refer to the internal review (findings `F..`, review items `B..-R..` and `C..-R..`); remove an entry here when it is fixed.

## Design limitations (need a decision by the maintainer)

- **Your GitHub key is stored in the shared workstation account (F03).** In remote mode the private key (no passphrase) is copied to `/home/php-workstation/.ssh/id_ed25519_<user>` and stays there. Everyone who can use that account can read it and act as you on GitHub. See [Your GitHub key on the shared workstation](IMPACT_Docker_GUI_v2_User.md#your-github-key-on-the-shared-workstation) for what this means and how to remove the key from GitHub. A real fix needs one Linux account per colleague or a different credential model.
- **The RStudio password of a running remote container can be read by colleagues** who use the same account (`docker inspect`). Always choose a new password for RStudio.
- **The same user on two PCs (F28):** each PC's first remote login removes the other PC's login key from the workstation (both use the comment `IMPACT_<user>`), so the other PC asks for the workstation password again.
- **Two clones with the same folder name (F84):** both get the same container name `<repo>_<user>`, so only one of them can run at a time. Containers started by this version record their folder (label `impact.repo_path`), and Stop uses that folder. For a container started by an older version, which has no such label, Stop may still copy results and run the git check in the wrong clone.
- **Commit e-mail (F104):** commits use `<user>@users.noreply.github.com`. GitHub links newer accounts by `<id>+<user>@users.noreply.github.com`, so such commits may not show your avatar.
- **No pinning of the workstation's SSH host key (F24):** the first connection trusts whatever key the workstation presents.
- **The first image build does not use Docker's build cache (B4-R2):** the first build of the main image, the prerequisite build and every build with **Rebuild image** run with `--no-cache`, so they always start from scratch. (Retries after a failed build reuse the cache.) Using the cache unless **Rebuild image** is ticked would save a lot of time; whether every build needs fresh package installs is the maintainer's decision.
- **Mixed IMPACT versions:** the session files that this version writes to `/tmp/impactncd` on the workstation have no `password` key. If the same user opens an **older** IMPACT version while a container started by this version is still running, the older version can fail when it reconnects to that container. Everyone should update to a new IMPACT version at the same time. (A fix would be to write an empty `password` value; that needs a decision and a change to one Integration test.)

## Bugs

- If the folder paths in `sim_design_local.yaml` are set to folders inside the repository with other names (for example `...output_local` and `...synthpop_local`), the container shows them twice: once at their own place in the repository and once as `outputs` and `inputs/synthpop`.
- **Closing the window during a build (C4-R4):** the build runs on the window's thread, so Windows shows IMPACT as "Not Responding" and the "Please wait" protection cannot run. If Windows asks whether to close IMPACT, choose **Wait**; "Close the program" stops IMPACT in the middle of the build.

## Not verified yet

- **`DOCKER_SSH_OPTS`:** `Set-DockerSSHEnvironment` sets this variable with the IMPACT key, but it is not certain that the docker command-line program reads it. Docker over ssh (the `remote-<ip>` context and the `DOCKER_HOST=ssh://...` fallback) therefore relies on the IMPACT entry in `~/.ssh/config` to find the key. If that entry is missing or points to another key, remote Docker fails while IMPACT's own ssh calls still work.
- **Not yet tested on real Windows and Docker** (checked only by reading the code and with stand-ins on Linux): RStudio's Git pane using the IMPACT key through `core.sshCommand` in the container's `~/.gitconfig`; the Posh-SSH texts for a changed host key and for "password login not allowed"; plink with several `-hostkey` values; the network-drive check for mapped drives; Docker Desktop's error for a missing copy-back folder (`--mount`); the error dialog for unexpected errors in window handlers.
