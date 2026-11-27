# shellcheck shell=bash
# Ubuntu package upgrades a rebuild would install that a published image lacks.
#
# The runtime stage runs `apt-get update` and `apt-get upgrade` on every build, so
# a package fix reaches the image only when a rebuild starts. The daily scan rebuilds
# on changed inputs and on HIGH/CRITICAL findings; without this check an update with
# no such finding (a MEDIUM fix, tzdata, a bug fix) waits for the next unrelated
# rebuild. The simulation runs inside the published image and applies the same rules
# as the build's upgrade, phased updates included, so every listed upgrade is one
# the next build installs.

# Prints "<package> <installed> -> <candidate>" for each pending upgrade of IMAGE_REF,
# which must already be pulled. The index refresh goes through build/retry.sh, which
# retries it while a mirror is mid-sync. --error-on=any fails it on an unreachable source,
# which apt only warns about: the published image holds no index, so the simulation would
# otherwise list no upgrade. Fails when apt still cannot refresh its index,
# cannot simulate the upgrade, or prints a line this does not understand: an unknown
# state never passes as "up to date".
pending_package_upgrades() {
  local image_ref="$1" output helper
  helper="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/build/retry.sh"
  if ! output="$(docker run --rm --pull never --user root -v "${helper}:/mnt/retry.sh:ro" \
    --entrypoint sh "${image_ref}" \
    -c 'sh /mnt/retry.sh apt-get update -qq --error-on=any >/dev/null && apt-get -s upgrade' 2>&1)"; then
    printf 'Cannot simulate the apt upgrade of %s:\n%s\n' "${image_ref}" "${output}" >&2
    return 1
  fi
  parse_apt_upgrade_simulation <<<"${output}"
}

# Reads `apt-get -s upgrade` output and prints one line per "Inst" entry.
parse_apt_upgrade_simulation() {
  awk '
    /^Inst / {
      if (match($0, /^Inst [^ ]+ \[[^]]+\] \([^ ]+ /)) {
        split(substr($0, 1, RLENGTH), field, " ")
        installed = field[3]; gsub(/[][]/, "", installed)
        candidate = field[4]; sub(/^\(/, "", candidate)
        print field[2], installed, "->", candidate
        next
      }
      printf "Unexpected apt simulation line: %s\n", $0 > "/dev/stderr"
      failed = 1
    }
    END { exit failed }
  '
}

# Summarizes upgrade lines on one line: the count and the first five upgrades.
describe_package_upgrades() {
  awk '
    NF { count++; if (count <= 5) shown = shown (count > 1 ? ", " : "") $0 }
    END {
      if (count == 0) exit
      more = count > 5 ? sprintf(", and %d more", count - 5) : ""
      printf "%d Ubuntu package upgrades: %s%s\n", count, shown, more
    }
  '
}
