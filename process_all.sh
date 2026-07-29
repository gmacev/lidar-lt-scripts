#!/usr/bin/env bash
set -uo pipefail

# Process every sector from grid.geojson while keeping exactly one sector
# downloading/extracting ahead of the sector currently being processed.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

GRID_FILE="${GRID_FILE:-$SCRIPT_DIR/grid.geojson}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/home/debian/lt-lidar-data}"
MAX_JOBS="${MAX_JOBS:-4}"
RUN_PDAL_CLEANING="${RUN_PDAL_CLEANING:-true}"
POTREE_ENCODING="${POTREE_ENCODING:-BROTLI}"
POTREE_CONVERTER="${POTREE_CONVERTER:-$HOME/PotreeConverter/build/PotreeConverter}"
MAX_SECTORS=0
KEEP_LAZ=false

FAILED_LOG=""
SUCCEEDED_LOG=""
EVENT_LOG=""
STATE_DIR=""
DOWNLOAD_CACHE_DIR=""

declare -a REQUESTED_SECTORS=()
declare -a SECTOR_IDS=()
declare -a SECTOR_URLS=()

CURRENT_SECTOR=""
CURRENT_TARGET_DIR=""
CURRENT_OUTPUT_DIR=""
CURRENT_MANIFEST_TMP=""
CURRENT_MANIFEST_OUT=""
FAILED_STEP=""

usage() {
    cat <<'EOF'
Usage: ./process_all.sh [options]

Processes all sectors in grid.geojson by default.

Options:
  --grid FILE           GeoJSON grid to read (default: script_dir/grid.geojson)
  --download-dir DIR    Data and log directory (default: $HOME/lt-lidar-data)
  --max-sectors N       Process only the first N selected sectors (testing/resume aid)
  --sector ID           Process one sector ID; may be repeated (example: --sector 35_71)
  --max-jobs N          Parallel PDAL jobs per sector (default: 4)
  --skip-pdal           Skip PDAL cleaning, but still generate metadata with PDAL
  --keep-laz            Keep source LAZ files after successful conversion
  -h, --help            Show this help

Environment overrides:
  GRID_FILE, DOWNLOAD_DIR, MAX_JOBS, RUN_PDAL_CLEANING, POTREE_ENCODING,
  POTREE_CONVERTER
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

event() {
    local event_name="$1"
    local sector_id="$2"
    local detail="${3:-}"
    printf '%s\t%s\t%s\t%s\n' "$(timestamp)" "$event_name" "$sector_id" "$detail" >> "$EVENT_LOG"
}

log_failure() {
    local sector_id="$1"
    local step="$2"
    local detail="${3:-step returned a non-zero exit code}"
    printf '%s\t%s\t%s\t%s\n' "$(timestamp)" "$sector_id" "$step" "$detail" >> "$FAILED_LOG"
    event "sector-failed" "$sector_id" "step=$step; $detail"
}

log_success() {
    local sector_id="$1"
    printf '%s\t%s\n' "$(timestamp)" "$sector_id" >> "$SUCCEEDED_LOG"
    event "sector-succeeded" "$sector_id"
}

normalize_sector_id() {
    printf '%s' "$1" | tr '/' '_'
}

output_is_complete() {
    local output_dir="$1"
    [[ -s "$output_dir/metadata.json" &&
       -s "$output_dir/octree.bin" &&
       -s "$output_dir/hierarchy.bin" &&
       -s "$output_dir/source_manifest.json" ]]
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --grid)
                (($# >= 2)) || die "--grid requires a file"
                GRID_FILE="$2"
                shift 2
                ;;
            --download-dir)
                (($# >= 2)) || die "--download-dir requires a directory"
                DOWNLOAD_DIR="$2"
                shift 2
                ;;
            --max-sectors)
                (($# >= 2)) || die "--max-sectors requires a positive integer"
                [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--max-sectors must be a positive integer"
                MAX_SECTORS="$2"
                shift 2
                ;;
            --sector)
                (($# >= 2)) || die "--sector requires an ID"
                REQUESTED_SECTORS+=("$(normalize_sector_id "$2")")
                shift 2
                ;;
            --max-jobs)
                (($# >= 2)) || die "--max-jobs requires a positive integer"
                [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--max-jobs must be a positive integer"
                MAX_JOBS="$2"
                shift 2
                ;;
            --skip-pdal)
                RUN_PDAL_CLEANING=false
                shift
                ;;
            --keep-laz)
                KEEP_LAZ=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done
}

preflight() {
    [[ -f "$GRID_FILE" ]] || die "grid file not found: $GRID_FILE"

    local command_name
    for command_name in jq wget unzip find xargs; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "required command not found: $command_name"
    done

    local conda_init=""
    if [[ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ]]; then
        conda_init="$HOME/miniconda3/etc/profile.d/conda.sh"
    elif [[ -f "$HOME/anaconda3/etc/profile.d/conda.sh" ]]; then
        conda_init="$HOME/anaconda3/etc/profile.d/conda.sh"
    elif [[ -f "/opt/conda/etc/profile.d/conda.sh" ]]; then
        conda_init="/opt/conda/etc/profile.d/conda.sh"
    fi

    if [[ -n "$conda_init" ]]; then
        # Match process_one.sh: prefer base, then pdal, and tolerate an already
        # active environment.
        source "$conda_init"
        conda activate base 2>/dev/null || conda activate pdal 2>/dev/null || true
    fi

    command -v pdal >/dev/null 2>&1 ||
        die "PDAL is required for source metadata and cleaning"

    [[ -x "$POTREE_CONVERTER" ]] ||
        die "PotreeConverter is not executable: $POTREE_CONVERTER"

    mkdir -p "$DOWNLOAD_DIR"
    DOWNLOAD_DIR="$(cd "$DOWNLOAD_DIR" && pwd)"

    FAILED_LOG="$DOWNLOAD_DIR/failed_sectors.txt"
    SUCCEEDED_LOG="$DOWNLOAD_DIR/succeded_sectors.txt"
    EVENT_LOG="$DOWNLOAD_DIR/pipeline_events.log"
    STATE_DIR="$DOWNLOAD_DIR/.pipeline-state"
    DOWNLOAD_CACHE_DIR="$DOWNLOAD_DIR/.downloads"

    mkdir -p "$STATE_DIR" "$DOWNLOAD_CACHE_DIR"
    touch "$FAILED_LOG" "$SUCCEEDED_LOG" "$EVENT_LOG"
}

load_sectors() {
    local -a all_ids=()
    local -a all_urls=()
    local id
    local url

    while IFS=$'\t' read -r id url; do
        [[ -n "$id" && -n "$url" ]] || continue
        all_ids+=("$(normalize_sector_id "$id")")
        all_urls+=("$url")
    done < <(
        jq -r '
            .features[]
            | select(.properties.url != null)
            | [
                (
                    .properties.id
                    // (.properties.url | split("/")[-1] | sub("\\.zip$"; ""))
                ),
                .properties.url
            ]
            | @tsv
        ' "$GRID_FILE"
    )

    ((${#all_ids[@]} > 0)) || die "no sectors with URLs found in $GRID_FILE"

    if ((${#REQUESTED_SECTORS[@]} == 0)); then
        SECTOR_IDS=("${all_ids[@]}")
        SECTOR_URLS=("${all_urls[@]}")
    else
        local requested
        local found
        local index

        for requested in "${REQUESTED_SECTORS[@]}"; do
            found=false
            for index in "${!all_ids[@]}"; do
                if [[ "${all_ids[$index]}" == "$requested" ]]; then
                    SECTOR_IDS+=("${all_ids[$index]}")
                    SECTOR_URLS+=("${all_urls[$index]}")
                    found=true
                    break
                fi
            done
            [[ "$found" == true ]] || die "sector not found in grid: $requested"
        done
    fi

    if ((MAX_SECTORS > 0 && ${#SECTOR_IDS[@]} > MAX_SECTORS)); then
        SECTOR_IDS=("${SECTOR_IDS[@]:0:MAX_SECTORS}")
        SECTOR_URLS=("${SECTOR_URLS[@]:0:MAX_SECTORS}")
    fi
}

write_prepare_status() {
    local status_file="$1"
    local step="$2"
    local detail="${3:-}"
    printf '%s\t%s\n' "$step" "$detail" > "$status_file"
}

prepare_sector() {
    local sector_id="$1"
    local url="$2"
    local target_dir="$DOWNLOAD_DIR/$sector_id"
    local output_dir="$target_dir/potree_output"
    local status_file="$STATE_DIR/$sector_id.prepare"
    local archive="$DOWNLOAD_CACHE_DIR/$sector_id.zip"
    local partial_archive="$archive.part"

    event "prepare-start" "$sector_id" "$url"

    if output_is_complete "$output_dir"; then
        write_prepare_status "$status_file" "ready" "existing complete output"
        event "prepare-end" "$sector_id" "existing complete output"
        return 0
    fi

    if [[ -f "$target_dir/.download_complete" ]] &&
       find "$target_dir" -type f -name '*.laz' -print -quit | grep -q .; then
        write_prepare_status "$status_file" "ready" "existing extracted LAZ files"
        event "prepare-end" "$sector_id" "existing extracted LAZ files"
        return 0
    fi

    write_prepare_status "$status_file" "download" "$url"
    event "download-start" "$sector_id" "$url"

    if ! wget \
        --continue \
        --tries=3 \
        --timeout=30 \
        --progress=dot:giga \
        "$url" \
        -O "$partial_archive"; then
        write_prepare_status "$status_file" "download" "wget failed: $url"
        event "download-failed" "$sector_id" "$url"
        return 1
    fi

    if ! mv -f "$partial_archive" "$archive"; then
        write_prepare_status "$status_file" "download" "could not finalize archive"
        event "download-failed" "$sector_id" "could not finalize archive"
        return 1
    fi
    event "download-end" "$sector_id" "$archive"

    write_prepare_status "$status_file" "extract" "$archive"
    event "extract-start" "$sector_id" "$archive"

    rm -rf "$target_dir"
    mkdir -p "$target_dir"

    if ! unzip -q "$archive" -d "$target_dir"; then
        write_prepare_status "$status_file" "extract" "unzip failed: $archive"
        event "extract-failed" "$sector_id" "$archive"
        return 1
    fi

    if ! find "$target_dir" -type f -name '*.laz' -print -quit | grep -q .; then
        write_prepare_status "$status_file" "extract-validation" "archive contains no LAZ files"
        event "extract-validation-failed" "$sector_id" "archive contains no LAZ files"
        return 1
    fi

    touch "$target_dir/.download_complete"
    rm -f "$archive"
    write_prepare_status "$status_file" "ready" "download and extraction complete"
    event "extract-end" "$sector_id" "$target_dir"
    event "prepare-end" "$sector_id" "download and extraction complete"
}

read_prepare_failure() {
    local sector_id="$1"
    local status_file="$STATE_DIR/$sector_id.prepare"
    local step="prepare"
    local detail="background preparation failed"

    if [[ -s "$status_file" ]]; then
        IFS=$'\t' read -r step detail < "$status_file"
    fi

    printf '%s\t%s\n' "$step" "$detail"
}

set_current_sector() {
    CURRENT_SECTOR="$1"
    CURRENT_TARGET_DIR="$DOWNLOAD_DIR/$CURRENT_SECTOR"
    CURRENT_OUTPUT_DIR="$CURRENT_TARGET_DIR/potree_output"
    CURRENT_MANIFEST_TMP="$CURRENT_TARGET_DIR/source_manifest.json"
    CURRENT_MANIFEST_OUT="$CURRENT_OUTPUT_DIR/source_manifest.json"
    FAILED_STEP=""
}

collect_laz_files() {
    find "$CURRENT_TARGET_DIR" \
        -type f \
        -name '*.laz' \
        ! -name '*_clean.laz' \
        -print0
}

validate_input() {
    output_is_complete "$CURRENT_OUTPUT_DIR" && return 0
    collect_laz_files | grep -q .
}

generate_source_manifest() {
    local -a laz_files=()
    local file
    local file_metadata
    local creation_year
    local creation_doy
    local creation_date
    local entry

    mapfile -d '' laz_files < <(collect_laz_files)
    ((${#laz_files[@]} > 0)) || return 1

    jq -n \
        --arg sectorId "$CURRENT_SECTOR" \
        --arg generatedAt "$(timestamp)" \
        '{
            sectorId: $sectorId,
            generatedAt: $generatedAt,
            sourceFileCount: 0,
            pointCount: 0,
            sourceFileDateRange: { from: null, to: null },
            creationYearRange: { from: null, to: null },
            software: [],
            pointFormats: [],
            bounds: {
                minx: null, miny: null, minz: null,
                maxx: null, maxy: null, maxz: null
            },
            sourceFiles: []
        }' > "$CURRENT_MANIFEST_TMP" || return 1

    for file in "${laz_files[@]}"; do
        file_metadata="$(pdal info --metadata "$file")" || return 1
        creation_year="$(jq -r '.metadata.creation_year // empty' <<< "$file_metadata")"
        creation_doy="$(jq -r '.metadata.creation_doy // empty' <<< "$file_metadata")"
        creation_date=""

        if [[ -n "$creation_year" && -n "$creation_doy" ]]; then
            creation_date="$(
                date -u -d "$creation_year-01-01 +$((creation_doy - 1)) days" '+%Y-%m-%d'
            )" || return 1
        fi

        entry="$(
            jq \
                --arg name "$(basename "$file")" \
                --arg creationDate "$creation_date" \
                '{
                    name: $name,
                    pointCount: (.metadata.count // null),
                    creationYear: (.metadata.creation_year // null),
                    creationDayOfYear: (.metadata.creation_doy // null),
                    creationDate: (if $creationDate == "" then null else $creationDate end),
                    software: (.metadata.software_id // null),
                    pointFormat: (.metadata.dataformat_id // null),
                    lasVersion: (
                        if (.metadata.major_version != null and .metadata.minor_version != null)
                        then ((.metadata.major_version | tostring) + "." + (.metadata.minor_version | tostring))
                        else null
                        end
                    ),
                    fileSourceId: (.metadata.filesource_id // null),
                    scale: {
                        x: (.metadata.scale_x // null),
                        y: (.metadata.scale_y // null),
                        z: (.metadata.scale_z // null)
                    },
                    bounds: {
                        minx: (.metadata.minx // null),
                        miny: (.metadata.miny // null),
                        minz: (.metadata.minz // null),
                        maxx: (.metadata.maxx // null),
                        maxy: (.metadata.maxy // null),
                        maxz: (.metadata.maxz // null)
                    }
                }' <<< "$file_metadata"
        )" || return 1

        jq --argjson entry "$entry" \
            '.sourceFiles += [$entry]' \
            "$CURRENT_MANIFEST_TMP" > "$CURRENT_MANIFEST_TMP.next" || return 1
        mv "$CURRENT_MANIFEST_TMP.next" "$CURRENT_MANIFEST_TMP" || return 1
    done

    jq '
        .sourceFileCount = (.sourceFiles | length) |
        .pointCount = ([.sourceFiles[].pointCount // 0] | add // 0) |
        .software = ([.sourceFiles[].software | select(. != null and . != "")] | unique) |
        .pointFormats = ([.sourceFiles[].pointFormat | select(. != null)] | unique | sort) |
        .sourceFileDateRange = {
            from: ([.sourceFiles[].creationDate | select(. != null)] | min // null),
            to: ([.sourceFiles[].creationDate | select(. != null)] | max // null)
        } |
        .creationYearRange = {
            from: ([.sourceFiles[].creationYear | select(. != null)] | min // null),
            to: ([.sourceFiles[].creationYear | select(. != null)] | max // null)
        } |
        .bounds = {
            minx: ([.sourceFiles[].bounds.minx | select(. != null)] | min // null),
            miny: ([.sourceFiles[].bounds.miny | select(. != null)] | min // null),
            minz: ([.sourceFiles[].bounds.minz | select(. != null)] | min // null),
            maxx: ([.sourceFiles[].bounds.maxx | select(. != null)] | max // null),
            maxy: ([.sourceFiles[].bounds.maxy | select(. != null)] | max // null),
            maxz: ([.sourceFiles[].bounds.maxz | select(. != null)] | max // null)
        }
    ' "$CURRENT_MANIFEST_TMP" > "$CURRENT_MANIFEST_TMP.next" || return 1

    mv "$CURRENT_MANIFEST_TMP.next" "$CURRENT_MANIFEST_TMP"
}

ensure_source_manifest() {
    if [[ -s "$CURRENT_MANIFEST_TMP" ]]; then
        return 0
    fi

    generate_source_manifest
}

process_laz_file() {
    local file="$1"
    local temp_file="${file%.laz}_clean.laz"
    local range_limits='Overlap[0:0],Classification[1:7],Z[:600]'

    rm -f "$temp_file"

    # Older LAS point formats have no overlap flag. In that case every point is
    # implicitly non-overlap, so omitting only that unavailable predicate keeps
    # the original filtering semantics and avoids a PDAL "Invalid dimension"
    # failure.
    if ! pdal info --schema "$file" |
        jq -e '.schema.dimensions | any(.name == "Overlap")' >/dev/null; then
        range_limits='Classification[1:7],Z[:600]'
    fi

    pdal translate "$file" "$temp_file" \
        range \
        --filters.range.limits="$range_limits" \
        --writers.las.forward='vlr' \
        --writers.las.minor_version=2 \
        --writers.las.dataformat_id=0 &&
        mv "$temp_file" "$file"
}

export -f process_laz_file

clean_laz_files() {
    [[ "$RUN_PDAL_CLEANING" == true ]] || return 0

    collect_laz_files |
        xargs -0 -r -n 1 -P "$MAX_JOBS" \
            bash -c 'process_laz_file "$1"' _
}

run_potree_converter() {
    local -a laz_files=()
    local -a potree_args=()
    local converter_dir
    local converter_name

    mapfile -d '' laz_files < <(collect_laz_files)
    ((${#laz_files[@]} > 0)) || return 1

    rm -rf "$CURRENT_OUTPUT_DIR"
    potree_args=(
        "${laz_files[@]}"
        -o "$CURRENT_OUTPUT_DIR"
        --attributes intensity classification
    )

    if [[ -n "$POTREE_ENCODING" ]]; then
        potree_args+=(--encoding "$POTREE_ENCODING")
    fi

    converter_dir="$(cd -- "$(dirname -- "$POTREE_CONVERTER")" && pwd)" || return 1
    converter_name="./$(basename -- "$POTREE_CONVERTER")"

    (
        cd "$converter_dir" &&
        "$converter_name" "${potree_args[@]}"
    )
}

validate_potree_output() {
    local actual_attributes
    local expected_attributes="classification intensity position "

    [[ -s "$CURRENT_OUTPUT_DIR/metadata.json" &&
       -s "$CURRENT_OUTPUT_DIR/octree.bin" &&
       -s "$CURRENT_OUTPUT_DIR/hierarchy.bin" ]] || return 1

    actual_attributes="$(
        jq -r '.attributes[].name' "$CURRENT_OUTPUT_DIR/metadata.json" |
            sort |
            tr '\n' ' '
    )" || return 1

    [[ "$actual_attributes" == "$expected_attributes" ]]
}

copy_manifest() {
    [[ -s "$CURRENT_MANIFEST_TMP" ]] || return 1
    cp "$CURRENT_MANIFEST_TMP" "$CURRENT_MANIFEST_OUT"
}

cleanup_successful_sector() {
    [[ "$KEEP_LAZ" == true ]] && return 0

    find "$CURRENT_TARGET_DIR" -type f -name '*.laz' -delete || return 1
    rm -f "$CURRENT_MANIFEST_TMP" "$CURRENT_TARGET_DIR/.download_complete"
    find "$CURRENT_TARGET_DIR" -depth -type d -empty -delete
}

run_step() {
    local step="$1"
    shift

    event "step-start" "$CURRENT_SECTOR" "$step"
    if "$@"; then
        event "step-end" "$CURRENT_SECTOR" "$step"
        return 0
    fi

    FAILED_STEP="$step"
    event "step-failed" "$CURRENT_SECTOR" "$step"
    return 1
}

process_sector() {
    local sector_id="$1"

    set_current_sector "$sector_id"
    event "processing-start" "$sector_id"

    if output_is_complete "$CURRENT_OUTPUT_DIR"; then
        event "processing-end" "$sector_id" "existing complete output"
        return 0
    fi

    run_step "input-validation" validate_input || return 1
    run_step "source-manifest" ensure_source_manifest || return 1
    run_step "pdal-cleaning" clean_laz_files || return 1
    run_step "potree-conversion" run_potree_converter || return 1
    run_step "potree-validation" validate_potree_output || return 1
    run_step "manifest-copy" copy_manifest || return 1
    run_step "cleanup" cleanup_successful_sector || return 1

    event "processing-end" "$sector_id"
}

terminate_background_prepare() {
    local pid="${1:-}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

run_pipeline() {
    local total="${#SECTOR_IDS[@]}"
    local current_prepare_pid=""
    local next_prepare_pid=""
    local current_prepare_ok=false
    local index
    local sector_id
    local next_index
    local prepare_failure
    local prepare_step
    local prepare_detail
    local succeeded=0
    local failed=0

    printf 'Processing %d sector(s). Data directory: %s\n' "$total" "$DOWNLOAD_DIR"
    printf 'Event evidence: %s\n' "$EVENT_LOG"

    prepare_sector "${SECTOR_IDS[0]}" "${SECTOR_URLS[0]}" &
    current_prepare_pid=$!
    trap 'terminate_background_prepare "$current_prepare_pid"; terminate_background_prepare "$next_prepare_pid"; exit 130' INT TERM

    for index in "${!SECTOR_IDS[@]}"; do
        sector_id="${SECTOR_IDS[$index]}"
        current_prepare_ok=false

        event "prepare-wait-start" "$sector_id" "pid=$current_prepare_pid"
        if wait "$current_prepare_pid"; then
            current_prepare_ok=true
            event "prepare-wait-end" "$sector_id" "ready"
        else
            event "prepare-wait-end" "$sector_id" "failed"
        fi

        next_prepare_pid=""
        next_index=$((index + 1))
        if ((next_index < total)); then
            prepare_sector \
                "${SECTOR_IDS[$next_index]}" \
                "${SECTOR_URLS[$next_index]}" &
            next_prepare_pid=$!
            event "prepare-backgrounded" "${SECTOR_IDS[$next_index]}" "pid=$next_prepare_pid"
        fi

        printf '[%d/%d] %s\n' "$((index + 1))" "$total" "$sector_id"

        if [[ "$current_prepare_ok" == true ]]; then
            if process_sector "$sector_id"; then
                log_success "$sector_id"
                ((succeeded += 1))
            else
                log_failure "$sector_id" "${FAILED_STEP:-processing}" \
                    "processing step returned a non-zero exit code"
                ((failed += 1))
            fi
        else
            prepare_failure="$(read_prepare_failure "$sector_id")"
            IFS=$'\t' read -r prepare_step prepare_detail <<< "$prepare_failure"
            log_failure "$sector_id" "${prepare_step:-prepare}" \
                "${prepare_detail:-background preparation failed}"
            ((failed += 1))
        fi

        current_prepare_pid="$next_prepare_pid"
    done

    trap - INT TERM
    printf 'Finished: %d succeeded, %d failed, %d total.\n' "$succeeded" "$failed" "$total"
    printf 'Succeeded log: %s\nFailed log: %s\n' "$SUCCEEDED_LOG" "$FAILED_LOG"

    # Per-sector failures are recorded and intentionally do not make the whole
    # batch exit non-zero. A non-zero exit is reserved for global/preflight errors.
    return 0
}

main() {
    parse_args "$@"
    preflight
    load_sectors
    run_pipeline
}

main "$@"
