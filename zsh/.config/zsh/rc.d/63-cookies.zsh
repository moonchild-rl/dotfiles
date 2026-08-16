# Download videos with cookies from youtube firefox profile
ytc() {
    local profile

    profile=$(find "$HOME/.mozilla/firefox" \
        -maxdepth 1 -type d -name '*.youtube' -print -quit 2>/dev/null)

    if [ -z "$profile" ]; then
        profile=$(find "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox" \
            -maxdepth 1 -type d -name '*.youtube' -print -quit 2>/dev/null)
    fi

    if [ -z "$profile" ]; then
        echo "Could not find Firefox .youtube profile" >&2
        return 1
    fi

    yt --cookies-from-browser "firefox:$profile" "$@"
}

# Run a downloader with fresh cookies from the default LibreWolf Flatpak profile.
#
# Usage:
#   lwc gallery-dl "URL"
#   lwc yt-dlp "URL"
#
# Additional downloader options work normally:
#   lwc gallery-dl -v "URL"
#   lwc yt-dlp -S "res:720" "URL"
#
# This reads LibreWolf's profiles.ini each time, so the random profile
# directory prefix does not need to be the same on every system.
#
# The downloader must support:
#   --cookies-from-browser "firefox:PROFILE_PATH"
#
# gallery-dl and yt-dlp both support this Firefox-profile syntax.
lwc() {
    local base="$HOME/.var/app/io.gitlab.librewolf-community/.librewolf"
    local ini="$base/profiles.ini"
    local profile cmd

    if [[ ! -f "$ini" ]]; then
        echo "Could not find LibreWolf profiles.ini: $ini" >&2
        return 1
    fi

    # Firefox/LibreWolf records the default profile for an installation
    # as "Default=..." inside an [Install...] section of profiles.ini.
    profile=$(
        awk '
            /^\[Install[^]]*\]$/ {
                in_install = 1
                next
            }

            /^\[/ {
                in_install = 0
            }

            in_install && /^Default=/ {
                sub(/^Default=/, "")
                sub(/\r$/, "")
                print
                exit
            }
        ' "$ini"
    )

    if [[ -z "$profile" ]]; then
        echo "Could not determine LibreWolf default profile from $ini" >&2
        return 1
    fi

    # profiles.ini normally stores the profile path relative to $base.
    if [[ "$profile" != /* ]]; then
        profile="$base/$profile"
    fi

    if [[ ! -d "$profile" ]]; then
        echo "LibreWolf profile directory does not exist: $profile" >&2
        return 1
    fi

    if (( $# == 0 )); then
        echo "Usage: lwc COMMAND [ARGS...]" >&2
        echo 'Example: lwc gallery-dl "URL"' >&2
        return 1
    fi

    cmd="$1"
    shift

    "$cmd" --cookies-from-browser "firefox:$profile" "$@"
}
