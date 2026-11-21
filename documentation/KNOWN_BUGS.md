# Known bugs and limitations

Problems we know about in the current version, with a workaround where there is one. The IDs in brackets refer to the internal review (findings `F..`, review items `B..-R..`); remove an entry here when it is fixed.

## Design limitations (need a decision by the maintainer)

- **Your GitHub key is stored in the shared workstation account (F03).** In remote mode the private key (no passphrase) is copied to `/home/php-workstation/.ssh/id_ed25519_<user>` and stays there. Everyone who can use that account can read it and act as you on GitHub. See [Your GitHub key on the shared workstation](IMPACT_Docker_GUI_v2_User.md#your-github-key-on-the-shared-workstation) for what this means and how to remove the key from GitHub. A real fix needs one Linux account per colleague or a different credential model.
- **The RStudio password of a running remote container can be read by colleagues** who use the same account (`docker inspect`). Always choose a new password for RStudio.
- **The same user on two PCs (F28):** each PC's first remote login removes the other PC's login key from the workstation (both use the comment `IMPACT_<user>`), so the other PC asks for the workstation password again.
- **Two clones with the same folder name (F84):** a running container is found by its name only, so Stop may run the git check on the wrong clone.
- **Commit e-mail (F104):** commits use `<user>@users.noreply.github.com`. GitHub links newer accounts by `<id>+<user>@users.noreply.github.com`, so such commits may not show your avatar.
- **No pinning of the workstation's SSH host key (F24):** the first connection trusts whatever key the workstation presents.

## Bugs

- If the folder paths in `sim_design_local.yaml` are set to folders inside the repository with other names (for example `...output_local` and `...synthpop_local`), the container shows them twice: once at their own place in the repository and once as `outputs` and `inputs/synthpop`.
- **"All done" after a failed commit or push (B3-R3, B5-R1):** the status line after Stop says "All done" even when the git commit or push failed or the git status could not be read. Always read the git message box.
- **Remote folder names with spaces or special characters (B1-R1, B2-R1):** local folders are converted to a Docker-safe name, remote ones are not. A remote repository folder such as `IMPACTncd_Germany (2)` makes Start fail with a generic Docker error. Workaround: rename the folder on the workstation (letters, digits, `-`, `_`, `.`).
- **Profile folder with a space (B4-R1):** the `IdentityFile` line that IMPACT writes to `~/.ssh/config` is not quoted. With a Windows user folder such as `C:\Users\Max Mustermann` this breaks every ssh call ("bad configuration options"). Quoting the line by hand does not help for long, because IMPACT rewrites the entry at the next start. Please report it to the maintainer.
- **Keys created by an old IMPACT under PowerShell 7.0-7.2 (B6a-R1):** they may have the accidental passphrase `-q`. IMPACT then seems to hang at the SSH step or keeps asking for the workstation password. Workaround: `ssh-keygen -p -P "-q" -N "" -f $HOME\.ssh\id_ed25519_<user>` removes it (the public key stays the same).
- **Docker not reachable when the Container Manager opens (B2-R2, B4-R3):** if you click Cancel in "Docker Not Reachable", the manager shows STOPPED and Start treats the failing image check as "image missing" and starts a full build.
- **Closing the window during a build (C4-R4):** the build runs on the window's thread, so Windows shows IMPACT as "Not Responding" and the "Please wait" protection cannot run. If Windows asks whether to close IMPACT, choose **Wait**; "Close the program" stops IMPACT in the middle of the build.
- **The console window closes after some early errors (C4-R3):** when one of the first steps fails without a message box (for example "SSH key generation failed"), the GUI script ends with exit code 0, so `IMPACT.bat` does not pause. The reason is in the log file. Possible fix in `IMPACT_Docker_GUI_v2.ps1`: exit with code 1 when a wizard step fails.
- **Long automatic build retries (B4-R2):** every build uses `--no-cache`, and a failed build automatically runs up to three more full builds. The window stays busy meanwhile.
- **Leftover Docker volumes (B3-R1):** volumes left over from an earlier session are only detected when **Use Docker Volumes** is ticked, and copying them back overwrites files on disk that differ, even newer ones.
- **Square brackets in a local repository path (B2-R3):** a folder such as `IMPACTncd_Germany [v2]` passes the folder check, but Start then reports "docker_setup folder not found" or "YAML file not found".
- **Network folders in the YAML file (B2-R6):** a UNC or mapped network path in `output_dir`/`synthpop_dir` in local mode fails only at `docker run`, after the image build.
- **Detached HEAD (B5-R3):** the commit dialog still commits; only the push is refused. Create a branch in RStudio before committing.
- **Branch never pushed (B5-R4):** commits on a branch without an upstream are not offered for push when the working tree is clean.
- **File names with umlauts in the commit dialog (B5-R5)** are shown as octal escapes (for example `M\303\274ller.csv`).
- **Local mode changes the global Docker context to `local` (B2-R8).** Other Docker tools on the PC then also use that context.
- **Fatal error box (B6a-R2):** it shows a literal `\n` and always names the default log path.
- **All ports 8787-8799 in use (F93):** the Port box still suggests 8787; Start then reports the conflict.
- **IP address check (F23):** octets above 255 (for example `300.1.1.1`) are not rejected in the location dialog.
