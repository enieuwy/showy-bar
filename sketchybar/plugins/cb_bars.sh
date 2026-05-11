#!/usr/bin/env bash
# codexbar-bars — SketchyBar plugin: render per-provider icon + bar PNGs
# and update each provider's items.
#
# Invoked by the cb_bars.trigger item every CB_BARS_SKETCHYBAR_UPDATE_FREQ
# seconds. Reads the shared codexbar JSON cache, generates a small PNG
# strip per provider (track + primary + secondary [+ tertiary]), and
# writes it to the user's image cache. SketchyBar then reads the PNG by
# absolute path.

set -uo pipefail

# When this script is symlinked into the user's plugins dir, follow the
# chain to the original repo. Iterates because dotfile managers commonly
# create relative or chained symlinks.
resolve_repo_root() {
    local self="${BASH_SOURCE[0]}"
    while [[ -L "${self}" ]]; do
        local link
        link=$(readlink "${self}")
        if [[ "${link}" == /* ]]; then
            self="${link}"
        else
            self="$(cd -- "$(dirname -- "${self}")" && pwd -P)/${link}"
        fi
    done
    local dir
    dir=$(cd -- "$(dirname -- "${self}")" && pwd -P)
    cd -- "${dir}/../.." && pwd -P
}
REPO_ROOT="$(resolve_repo_root)"

# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/strip.sh"

FETCH="${CB_BARS_FETCH_BIN:-${REPO_ROOT}/bin/cb-bars-fetch}"
CACHE_DIR="${CB_BARS_SKETCHYBAR_IMAGE_CACHE}"
mkdir -p "${CACHE_DIR}" || exit 0
STATE_FILE="${CACHE_DIR}/providers.txt"
CLICK="${CB_BARS_SKETCHYBAR_CLICK}"

read_state_providers() {
    [[ -f "${STATE_FILE}" ]] || return 0
    while IFS= read -r pid || [[ -n "${pid}" ]]; do
        [[ -n "${pid}" ]] || continue
        printf '%s\n' "${pid}"
    done < "${STATE_FILE}"
}

provider_list_contains() {
    local list="${1-}" pid="$2"
    case $'\n'"${list}"$'\n' in
        *$'\n'"${pid}"$'\n'*) return 0 ;;
        *) return 1 ;;
    esac
}

write_state_providers() {
    local providers="${1-}" state_tmp
    state_tmp=$(mktemp "${CACHE_DIR}/.providers.XXXXXX") || return 1
    if [[ -n "${providers}" ]]; then
        printf '%s\n' "${providers}" > "${state_tmp}"
    else
        : > "${state_tmp}"
    fi
    mv -f "${state_tmp}" "${STATE_FILE}"
}

remove_provider_items() {
    local pid="$1"
    sketchybar \
        --remove "cb_bars.${pid}.icon" \
        --remove "cb_bars.${pid}.bar" \
        --remove "cb_bars.${pid}.label" >/dev/null 2>&1 || true
}

declare_provider_items() {
    local pid="$1"
    sketchybar --add item "cb_bars.${pid}.icon" left \
               --set "cb_bars.${pid}.icon" \
                   icon.drawing=off \
                   label.drawing=off \
                   background.image="cb_bars.${pid}.icon" \
                   background.image.drawing=on \
                   background.image.scale="${CB_BARS_SKETCHYBAR_ICON_SCALE}" \
                   background.color=0x00000000 \
                   background.height=0 \
                   padding_left="${CB_BARS_SKETCHYBAR_ICON_PADDING_LEFT}" \
                   padding_right=0 \
                   width="${CB_BARS_SKETCHYBAR_ICON_WIDTH}" \
                   click_script="${CLICK}" >/dev/null 2>&1 || true

    sketchybar --add item "cb_bars.${pid}.bar" left \
               --set "cb_bars.${pid}.bar" \
                   icon.drawing=off \
                   label.drawing=off \
                   background.image="cb_bars.${pid}.bar" \
                   background.image.drawing=on \
                   background.image.scale=1.0 \
                   background.color=0x00000000 \
                   background.height=0 \
                   padding_left=2 \
                   padding_right=2 \
                   width="${CB_BARS_SKETCHYBAR_BAR_WIDTH}" \
                   click_script="${CLICK}" >/dev/null 2>&1 || true

    sketchybar --add item "cb_bars.${pid}.label" left \
               --set "cb_bars.${pid}.label" \
                   icon.drawing=off \
                   label.font.size=11 \
                   label.padding_left=0 \
                   label.padding_right=4 \
                   background.color=0x00000000 \
                   background.height=0 \
                   click_script="${CLICK}" >/dev/null 2>&1 || true
}

recreate_bracket() {
    local providers="${1-}" pid
    local bracket_items=()
    sketchybar --remove cb_bars_bracket >/dev/null 2>&1 || true

    while IFS= read -r pid; do
        [[ -n "${pid}" ]] || continue
        bracket_items+=("cb_bars.${pid}.icon" "cb_bars.${pid}.bar" "cb_bars.${pid}.label")
    done <<< "${providers}"

    (( ${#bracket_items[@]} > 0 )) || return 0
    sketchybar --add bracket cb_bars_bracket "${bracket_items[@]}" \
               --set cb_bars_bracket \
                   background.color="${CB_BARS_SKETCHYBAR_PILL_COLOR}" \
                   background.corner_radius="${CB_BARS_SKETCHYBAR_PILL_RADIUS}" \
                   background.height="${CB_BARS_SKETCHYBAR_PILL_HEIGHT}" >/dev/null 2>&1 || true
}

clear_declared_items() {
    local declared pid
    declared="$(read_state_providers)"
    while IFS= read -r pid; do
        [[ -n "${pid}" ]] || continue
        remove_provider_items "${pid}"
    done <<< "${declared}"
    sketchybar --remove cb_bars_bracket >/dev/null 2>&1 || true
    write_state_providers "" || cb_bars_log "failed to clear sketchybar provider state"
}

cb_bars_have jq || {
    cb_bars_log "jq required for sketchybar plugin"
    clear_declared_items
    exit 0
}
cb_bars_have magick || {
    cb_bars_log "magick (ImageMagick 7+) required for sketchybar plugin"
    clear_declared_items
    exit 0
}

# Bar geometry. Bars sit inside SketchyBar's pill; tweak via env.
: "${CB_BARS_PNG_BAR_W:=80}"
: "${CB_BARS_PNG_BAR_H:=18}"

# ── ARGB helpers ─────────────────────────────────────────────────────

# 6-char hex (no '#') → 0xff RRGGBB SketchyBar literal.
argb_from_hex() { printf '0xff%s' "$1"; }

# 6-char hex → '#RRGGBB' for ImageMagick.
mhex() { printf '#%s' "$1"; }

GOOD_HEX="$(cb_bars_palette good)"
WARN_HEX="$(cb_bars_palette warn)"
BAD_HEX="$(cb_bars_palette bad)"
UNKNOWN_HEX="$(cb_bars_palette unknown)"
TRACK_HEX="$(cb_bars_palette track)"
TEXT_HEX="$(cb_bars_palette text)"
TEXT_ARGB="$(argb_from_hex "${TEXT_HEX}")"
ELAPSED_HEX="$(cb_bars_palette elapsed)"

color_for_remaining() {
    local rem="$1"
    case "$(cb_bars_color_key "${rem}")" in
        good) printf '%s' "${GOOD_HEX}" ;;
        warn) printf '%s' "${WARN_HEX}" ;;
        bad)  printf '%s' "${BAD_HEX}" ;;
        *)    printf '%s' "${UNKNOWN_HEX}" ;;
    esac
}

status_color_for_indicator() {
    case "${1:-none}" in
        minor|maintenance) printf '%s' "${WARN_HEX}" ;;
        major|critical)    printf '%s' "${BAD_HEX}" ;;
        unknown)           printf '%s' "${UNKNOWN_HEX}" ;;
        *)                 return 1 ;;
    esac
}

shell_quote() {
    local raw="$1"
    printf "'"
    while [[ "${raw}" == *"'"* ]]; do
        printf '%s' "${raw%%\'*}"
        printf "'\\''"
        raw="${raw#*\'}"
    done
    printf "%s'" "${raw}"
}

status_url_is_openable() {
    case "${1:-}" in
        http://*|https://*) return 0 ;;
        *)                  return 1 ;;
    esac
}

click_script_for_status() {
    local status="${1:-none}" url="${2:-}"
    case "${status}" in
        minor|maintenance|major|critical)
            if status_url_is_openable "${url}"; then
                printf 'open %s' "$(shell_quote "${url}")"
                return
            fi
            ;;
    esac
    printf '%s' "${CLICK}"
}

# Bump when icon rendering semantics change so stale cached PNGs are replaced
# on the next plugin tick.
ICON_CACHE_VERSION="2"

# ── provider icon: lazily render SVG → PNG ───────────────────────────
render_fallback_icon_png() {
    local pid="$1" tmp="$2"
    local sigil
    sigil=$(cb_bars_provider_sigil "${pid}")
    magick -size 64x64 xc:none \
        -fill "$(mhex "${UNKNOWN_HEX}")" \
        -draw "circle 32,32 32,4" \
        -fill "$(mhex "$(cb_bars_palette text)")" \
        -gravity center -pointsize 28 -annotate 0 "${sigil}" \
        "PNG32:${tmp}" >/dev/null 2>&1
}

recolor_icon_png() {
    local src="$1" hex="$2" out="$3"
    magick "${src}" -alpha extract \
        -background "$(mhex "${hex}")" -alpha shape \
        "PNG32:${out}" >/dev/null 2>&1
}

should_tint_dark_icon_png() {
    local png="$1" stats r g b
    stats=$(magick "${png}" txt:- 2>/dev/null | awk -F '[(), ]+' '
        BEGIN { r = 0; g = 0; b = 0; n = 0 }
        /^#/ { next }
        ($6 + 0) <= 0 { next }
        { r += $3; g += $4; b += $5; n++ }
        END {
            if (n == 0) exit 1
            printf "%.6f %.6f %.6f\n", r / (255 * n), g / (255 * n), b / (255 * n)
        }'
    ) || return 1
    read -r r g b <<< "${stats}"
    awk -v r="${r}" -v g="${g}" -v b="${b}" 'BEGIN {
        mean = (r + g + b) / 3;
        min = r; max = r;
        if (g < min) min = g; if (b < min) min = b;
        if (g > max) max = g; if (b > max) max = b;
        exit ! (mean < 0.15 && (max - min) < 0.03);
    }'
}


provider_icon_png() {
    local pid="$1" status="${2:-none}"
    local status_color="" tint_color="" suffix="" out
    if status_color=$(status_color_for_indicator "${status}"); then
        suffix="-${status}"
    fi
    out="${CACHE_DIR}/icon-v${ICON_CACHE_VERSION}-${pid}${suffix}.png"
    [[ -s "${out}" ]] && { printf '%s\n' "${out}"; return 0; }

    # Per-process tmp files in the same directory so `mv` is atomic.
    local tmp normal_tmp
    normal_tmp=$(mktemp "${CACHE_DIR}/.icon-${pid}.normal.XXXXXX") || return 1

    local svg="${CB_BARS_CODEXBAR_RESOURCES}/ProviderIcon-${pid}.svg"
    if [[ ! -r "${svg}" ]]; then
        if ! render_fallback_icon_png "${pid}" "${normal_tmp}"; then
            rm -f "${normal_tmp}"; return 1
        fi
    else
        if ! magick -background none -density 300 "${svg}" \
                    -resize 64x64 "PNG32:${normal_tmp}" >/dev/null 2>&1; then
            if ! render_fallback_icon_png "${pid}" "${normal_tmp}"; then
                rm -f "${normal_tmp}"; return 1
            fi
        fi
    fi

    if [[ -n "${status_color}" ]]; then
        tint_color="${status_color}"
    elif should_tint_dark_icon_png "${normal_tmp}"; then
        tint_color="${TEXT_HEX}"
    fi

    if [[ -n "${tint_color}" ]]; then
        tmp=$(mktemp "${CACHE_DIR}/.icon-${pid}.tint.XXXXXX") || { rm -f "${normal_tmp}"; return 1; }
        if ! recolor_icon_png "${normal_tmp}" "${tint_color}" "${tmp}"; then
            rm -f "${tmp}"
            tmp="${normal_tmp}"
        else
            rm -f "${normal_tmp}"
        fi
    else
        tmp="${normal_tmp}"
    fi

    mv -f "${tmp}" "${out}"
    printf '%s\n' "${out}"
}

# ── stacked-bar PNG ──────────────────────────────────────────────────

# Args: provider primary_remaining secondary_remaining tertiary_remaining
#       secondary_elapsed_x tertiary_elapsed_x
# Pass '' (empty) for missing windows/markers. Echoes path on success.
render_bar_png() {
    local pid="$1" rem_p="$2" rem_s="$3" rem_t="$4" marker_s="${5:-}" marker_t="${6:-}"
    local out="${CACHE_DIR}/bar-${pid}.png"

    local has_t=0
    [[ -n "${rem_t}" ]] && has_t=1

    local rows=2
    (( has_t )) && rows=3

    local image_h="${CB_BARS_PNG_BAR_H}"
    if (( rows == 3 )); then
        # Allow a slightly taller image when stacking three rows. 22 px gives
        # us three 6 px bars with a 1 px gap between each row.
        image_h=22
    fi

    # Row boundaries (top..bottom inclusive) per row count.
    local r1_top r1_bot r2_top r2_bot r3_top r3_bot
    if (( rows == 2 )); then
        r1_top=2; r1_bot=8
        r2_top=10; r2_bot=$(( image_h - 2 ))
    else
        r1_top=1; r1_bot=6
        r2_top=8; r2_bot=13
        r3_top=15; r3_bot=20
    fi

    # Width fill (round half-up; never blank for nonzero remaining).
    fill_w() {
        local pct="${1:-0}"
        local w="${CB_BARS_PNG_BAR_W}"
        awk -v p="${pct}" -v w="${w}" 'BEGIN {
            f = int((p / 100.0) * w + 0.5);
            if (p > 0 && f == 0) f = 1;
            if (f < 0) f = 0; if (f > w) f = w;
            print f;
        }'
    }

    local f1 f2 f3
    f1=$(fill_w "${rem_p}")
    f2=$(fill_w "${rem_s}")
    (( has_t )) && f3=$(fill_w "${rem_t}")

    local c1 c2 c3
    c1=$(color_for_remaining "${rem_p}")
    c2=$(color_for_remaining "${rem_s}")
    (( has_t )) && c3=$(color_for_remaining "${rem_t}")

    local args=( -size "${CB_BARS_PNG_BAR_W}x${image_h}" xc:none )

    add_track() {
        args+=( -fill "$(mhex "${TRACK_HEX}")"
                -draw "roundrectangle 0,$1 $((CB_BARS_PNG_BAR_W - 1)),$2 3,3" )
    }
    add_fill() {
        local fill="$1" top="$2" bot="$3" hex="$4"
        (( fill > 0 )) || return 0
        args+=( -fill "$(mhex "${hex}")"
                -draw "roundrectangle 0,${top} $((fill - 1)),${bot} 3,3" )
    }
    add_marker() {
        local marker="$1" top="$2" bot="$3"
        [[ "${marker}" =~ ^[0-9]+$ ]] || return 0
        (( marker < 0 )) && marker=0
        (( marker >= CB_BARS_PNG_BAR_W )) && marker=$((CB_BARS_PNG_BAR_W - 1))
        args+=( -fill "$(mhex "${ELAPSED_HEX}")"
                -draw "rectangle ${marker},${top} ${marker},${bot}" )
    }


    add_track "${r1_top}" "${r1_bot}"
    add_fill "${f1}" "${r1_top}" "${r1_bot}" "${c1}"
    add_track "${r2_top}" "${r2_bot}"
    add_fill "${f2}" "${r2_top}" "${r2_bot}" "${c2}"
    if (( has_t )); then
        add_track "${r3_top}" "${r3_bot}"
        add_fill "${f3}" "${r3_top}" "${r3_bot}" "${c3}"
    fi
    add_marker "${marker_s}" "${r2_top}" "${r2_bot}"
    if (( has_t )); then
        add_marker "${marker_t}" "${r3_top}" "${r3_bot}"
    fi

    local tmp
    tmp=$(mktemp "${CACHE_DIR}/.bar-${pid}.XXXXXX") || return 1
    if magick "${args[@]}" "PNG32:${tmp}" >/dev/null 2>&1; then
        if [[ ! -f "${out}" ]] || ! cmp -s "${tmp}" "${out}"; then
            mv -f "${tmp}" "${out}"
        else
            rm -f "${tmp}"
        fi
        printf '%s\n' "${out}"
        return 0
    fi
    rm -f "${tmp}"
    return 1
}

# ── label rendering ──────────────────────────────────────────────────

label_for_minutes() {
    local minutes="$1" remaining="$2" reset_value="${3:-}"
    local label
    label=$(cb_bars_primary_label "${minutes}" "${remaining}" "${reset_value}")
    local color="${TEXT_ARGB}"
    if [[ -n "${minutes}" && "${minutes}" -lt "${CB_BARS_TIME_WARN_MINUTES}" ]] 2>/dev/null; then
        color=$(argb_from_hex "${BAD_HEX}")
    fi
    printf '%s\n%s\n' "${label}" "${color}"
}

# ── main ─────────────────────────────────────────────────────────────

data=$("${FETCH}" 2>/dev/null || printf '[]')

elapsed_marker_x() {
    local reset_at="$1" window_minutes="$2"
    [[ -n "${reset_at}" && "${window_minutes}" =~ ^[0-9]+$ ]] || return 1
    (( window_minutes > 0 )) || return 1

    local reset_epoch duration start_epoch now elapsed marker
    reset_epoch=$(cb_bars_reset_epoch "${reset_at}") || return 1
    duration=$((window_minutes * 60))
    start_epoch=$((reset_epoch - duration))
    now=$(date +%s)
    elapsed=$((now - start_epoch))
    (( elapsed < 0 )) && elapsed=0
    (( elapsed > duration )) && elapsed="${duration}"
    marker=$(( (duration - elapsed) * CB_BARS_PNG_BAR_W / duration ))
    (( marker < 0 )) && marker=0
    (( marker >= CB_BARS_PNG_BAR_W )) && marker=$((CB_BARS_PNG_BAR_W - 1))
    printf '%s\n' "${marker}"
}
filtered=$(printf '%s' "${data}" | cb_bars_filter_renderable)
desired_providers=$(printf '%s' "${filtered}" | jq -r '.[].provider')
declared_providers="$(read_state_providers)"
declared_item_providers="${declared_providers}"
force_redeclare=0
if [[ "${CB_BARS_SKETCHYBAR_FORCE_REDECLARE:-0}" == "1" ]]; then
    force_redeclare=1
    declared_item_providers=""
fi

if (( force_redeclare )) || [[ "${desired_providers}" != "${declared_providers}" ]]; then
    while IFS= read -r pid; do
        [[ -n "${pid}" ]] || continue
        provider_list_contains "${desired_providers}" "${pid}" || remove_provider_items "${pid}"
    done <<< "${declared_providers}"

    while IFS= read -r pid; do
        [[ -n "${pid}" ]] || continue
        provider_list_contains "${declared_item_providers}" "${pid}" || declare_provider_items "${pid}"
    done <<< "${desired_providers}"

    recreate_bracket "${desired_providers}"
    write_state_providers "${desired_providers}" || cb_bars_log "failed to update sketchybar provider state"
fi

rows=$(printf '%s' "${filtered}" | jq -r '
    def pct(x): if x == null then 0 else ([0, ([100, (x|tonumber|floor)] | min)] | max) end;
    .[] | [
        .provider,
        (100 - pct(.usage.primary.usedPercent)),
        (.usage.primary.resetsAt // .usage.primary.resetDescription // ""),
        (if .usage.secondary then (100 - pct(.usage.secondary.usedPercent)) else "" end),
        (.usage.secondary.resetsAt // .usage.secondary.resetDescription // ""),
        (.usage.secondary.windowMinutes // ""),
        (if .usage.tertiary  then (100 - pct(.usage.tertiary.usedPercent))  else "" end),
        (.usage.tertiary.resetsAt // .usage.tertiary.resetDescription // ""),
        (.usage.tertiary.windowMinutes // ""),
        (.status.indicator // "none"),
        (.status.url // "")
    ] | map(tostring) | join("\u001f")')

while IFS=$'\x1f' read -r pid rem_p p_reset rem_s s_reset s_window rem_t t_reset t_window status status_url; do
    [[ -n "${pid}" ]] || continue

    icon=$(provider_icon_png "${pid}" "${status}" || true)
    marker_s=$(elapsed_marker_x "${s_reset}" "${s_window}" || true)
    marker_t=$(elapsed_marker_x "${t_reset}" "${t_window}" || true)
    bar=$(render_bar_png "${pid}" "${rem_p}" "${rem_s}" "${rem_t}" "${marker_s}" "${marker_t}" || true)

    minutes=""
    if [[ -n "${p_reset}" ]]; then
        minutes=$(cb_bars_minutes_until "${p_reset}" || true)
    fi
    label=""; color=""
    icon_click=$(click_script_for_status "${status}" "${status_url}")
    { IFS= read -r label; IFS= read -r color; } < <(label_for_minutes "${minutes}" "${rem_p}" "${p_reset}") || true
    [[ -n "${color}" ]] || color="${TEXT_ARGB}"

    args=(
        --set "cb_bars.${pid}.label" drawing=on label="${label}" label.color="${color}" background.color=0x00000000 background.height=0
    )
    if [[ -n "${icon}" && -s "${icon}" ]]; then
        args+=( --set "cb_bars.${pid}.icon" drawing=on background.image="${icon}" background.image.drawing=on background.image.scale="${CB_BARS_SKETCHYBAR_ICON_SCALE}" background.color=0x00000000 background.height=0 padding_left="${CB_BARS_SKETCHYBAR_ICON_PADDING_LEFT}" padding_right=0 width="${CB_BARS_SKETCHYBAR_ICON_WIDTH}" click_script="${icon_click}" )
    else
        args+=( --set "cb_bars.${pid}.icon" drawing=off click_script="${CLICK}" )
    fi
    if [[ -n "${bar}" && -s "${bar}" ]]; then
        args+=( --set "cb_bars.${pid}.bar" drawing=on background.image="${bar}" background.image.drawing=on background.image.scale=1.0 background.color=0x00000000 background.height=0 padding_left=2 padding_right=2 width="${CB_BARS_SKETCHYBAR_BAR_WIDTH}" )
    else
        args+=( --set "cb_bars.${pid}.bar" drawing=off )
    fi

    if (( ${#args[@]} > 0 )); then
        sketchybar "${args[@]}" >/dev/null 2>&1 || true
    fi
done <<< "${rows}"
