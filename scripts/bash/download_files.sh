#!/usr/bin/env bash
# =============================================================================
# download_files.sh
#
# Download every URL in a list into a directory, several at a time, with an
# optional on-disk cache.
#
# Usage:
#   bash download_files.sh <url-list-file> <dest-dir>
#
# Environment:
#   DOWNLOAD_JOBS  parallel downloads (default 8)
#   NWM_CACHE_DIR  cache directory. Unset or empty means no cache. Files are
#                  stored at <cache>/<URL path>, e.g.
#                  <cache>/national-water-model/nwm.20260430/short_range/nwm.t00z...nc
#                  Published NWM files never change, so a cached copy is
#                  reused as-is. Only complete downloads are cached (written to
#                  a .part file, then renamed).
#
# Each file is saved under its URL basename, the same name `wget -P` used.
# Exits non-zero if any download fails, so the caller can stop.
# =============================================================================
set -euo pipefail

LIST="$1"
DEST="$2"
JOBS="${DOWNLOAD_JOBS:-8}"
CACHE="${NWM_CACHE_DIR:-}"

mkdir -p "${DEST}"
[[ -n "${CACHE}" ]] && mkdir -p "${CACHE}"

# Prints "hit" or "downloaded"; returns non-zero on failure.
fetch_one() {
    local url="$1" name tmp cached rel
    name="$(basename "${url}")"
    if [[ -n "${CACHE}" ]]; then
        rel="${url#*://}"   # drop scheme
        rel="${rel#*/}"     # drop host
        cached="${CACHE}/${rel}"
        if [[ ! -s "${cached}" ]]; then
            mkdir -p "$(dirname "${cached}")"
            tmp="$(mktemp "${cached}.part.XXXXXX")"
            if ! wget -q -O "${tmp}" "${url}"; then
                rm -f "${tmp}"
                echo "FAILED: ${url}" >&2
                return 1
            fi
            chmod 644 "${tmp}"   # mktemp makes 600; keep files readable like wget's
            mv -f "${tmp}" "${cached}"
            cp "${cached}" "${DEST}/${name}"
            echo "downloaded"
            return 0
        fi
        cp "${cached}" "${DEST}/${name}"
        echo "hit"
    else
        tmp="$(mktemp "${DEST}/${name}.part.XXXXXX")"
        if ! wget -q -O "${tmp}" "${url}"; then
            rm -f "${tmp}"
            echo "FAILED: ${url}" >&2
            return 1
        fi
        chmod 644 "${tmp}"   # mktemp makes 600; keep files readable like wget's
        mv -f "${tmp}" "${DEST}/${name}"
        echo "downloaded"
    fi
}

# Run up to JOBS downloads at once with plain bash jobs (no xargs in the
# runtime image). Each job's result goes to its own file in a scratch dir.
results="$(mktemp -d)"
trap 'rm -rf "${results}"' EXIT
n=0
while IFS= read -r url || [[ -n "${url}" ]]; do
    [[ -z "${url//[[:space:]]/}" ]] && continue
    while (( $(jobs -rp | wc -l) >= JOBS )); do wait -n || true; done
    n=$((n + 1))
    ( fetch_one "${url}" > "${results}/${n}.ok" 2> "${results}/${n}.err" \
        || mv "${results}/${n}.ok" "${results}/${n}.failed" ) &
done < "${LIST}"
wait

hits=$(cat "${results}"/*.ok 2>/dev/null | grep -c '^hit$' || true)
downloaded=$(cat "${results}"/*.ok 2>/dev/null | grep -c '^downloaded$' || true)
shopt -s nullglob   # no find/xargs in the runtime image; count with a glob
failed_files=("${results}"/*.failed)
failed=${#failed_files[@]}
cache_note=""
[[ -n "${CACHE}" ]] && cache_note=", ${hits} from cache"
echo "download_files: ${n} file(s) into ${DEST}: ${downloaded} downloaded${cache_note}, ${failed} failed (${JOBS} parallel)"
if (( failed > 0 )); then
    cat "${results}"/*.err >&2
    exit 1
fi
