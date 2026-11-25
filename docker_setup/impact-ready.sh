#!/bin/bash
# =============================================================================
# impact-ready.sh: writes the ready marker when the start-up has finished
# =============================================================================
#
# PURPOSE
#   Tells the outside world that the image's start-up scripts have all ended. It does
#   so by writing one small file, the "ready marker": /run/impact-ready.
#   The IMPACT Docker GUI waits for this file before it sets the RStudio password and
#   configures git inside the container. Without the marker the GUI could act while a
#   start-up script is still at work, and the two could overwrite each other's settings.
#
# WHEN IT RUNS
#   At every container start, as root, as the LAST of the start-up scripts.
#   The base image (Rocker, with the init system "s6-overlay") runs every file in the
#   folder /etc/cont-init.d once per start, one after the other, sorted by file name
#   byte by byte: digits first, then capital letters, then small letters.
#   The Dockerfile installs this script as /etc/cont-init.d/zz-impact-ready. The other
#   scripts are 01_set_env, 02_userconf (both from Rocker) and git-identity. A name that
#   starts with "zz" sorts after all of them.
#   Keep it last: a start-up script added later needs a name that sorts before
#   "zz-impact-ready".
#
# WHAT IT CHANGES
#   It creates or replaces the file /run/impact-ready. The file holds one line with the
#   time of writing. entrypoint.sh removes the file at the beginning of every start, so
#   a marker never survives from an earlier start of the same container.
#
# WHAT IT NEVER TOUCHES
#   Everything else. The script reads no settings and looks at no folder.
#
# WHAT THE MARKER MEANS
#   Guaranteed:      every start-up script that runs before this one has ended. That
#                    includes the user and group numbers (entrypoint.sh), the Rocker
#                    user set-up with its password, and git-identity.
#   Not guaranteed:  that those scripts succeeded. The init system continues after a
#                    failed script. The container log shows the exit code of each one.
#   Not guaranteed:  that RStudio Server already answers on its port. The init system
#                    starts RStudio Server after this script. A program that needs
#                    RStudio must test the port itself.
# =============================================================================

MARKER="/run/impact-ready"

# The line is written to a second file first and then moved into place. "mv" inside one
# folder is a rename, so the marker appears complete in a single step and a waiting
# program never reads a half-written file.
# "date -u" prints the time in UTC, the time zone used in logs. "$(command)" is replaced by
# what the command prints. "printf 'ready %s\n' TEXT" prints the word "ready", the TEXT
# and a line break; "> FILE" writes that into FILE. "a && b" runs b only when a succeeded.
# "if ...; then ... else ... fi" runs the first part when the commands succeeded and the
# second part when they failed; "exit 1" ends the script with the exit code 1 (failure).
if printf 'ready %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$MARKER.tmp" && mv -f "$MARKER.tmp" "$MARKER"; then
    echo "[impact-ready] start-up scripts finished; marker written: $MARKER"
else
    # ">&2" sends the line to the error channel of the container log.
    echo "[impact-ready] ERROR: the marker $MARKER could not be written" >&2
    exit 1
fi
