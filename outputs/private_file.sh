#!/usr/bin/env bash
# Shared by the output generators: generated files hold secret values, so
# they must be readable by their owner only.

# Make sure a file exists with mode 0600 before secrets are written into it.
# A missing file is created under umask 077, so it is never readable by
# others, not even briefly; an existing one (e.g. 0644 from an older
# version) is tightened. The caller then writes with a plain `>`, which
# truncates in place and keeps the mode.
#
# Arguments:
#   $1 - file path (its directory must exist)
output_prepare_private_file() {
    local target="$1"
    ( umask 077 && : >> "$target" ) && chmod 600 "$target"
}
