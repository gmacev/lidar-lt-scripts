#!/usr/bin/env bash
set -uo pipefail

# Process every sector from grid.geojson while keeping exactly one sector
# downloading/extracting ahead of the sector currently being processed.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

GRID_FILE="${GRID_FILE:-$SCRIPT_DIR/grid.geojson}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/lt-lidar-data}"
MAX_JOBS="${MAX_JOBS:-4}"
RUN_PDAL_CLEANING="${RUN_PDAL_CLEANING:-true}"
POTREE_ENCODING="${POTREE_ENCODING:-BROTLI}"
POTREE_CONVERTER="${POTREE_CONVERTER:-$HOME/PotreeConverter/build/PotreeConverter}"
if [[ -x "$HOME/miniconda3/bin/python" ]]; then
    DEFAULT_PYTHON_BIN="$HOME/miniconda3/bin/python"
else
    DEFAULT_PYTHON_BIN="python3"
fi
PYTHON_BIN="${PYTHON_BIN:-$DEFAULT_PYTHON_BIN}"
LAS_BBOX_REPAIR_SCRIPT="$SCRIPT_DIR/repair_las_bounding_box.py"
GROUND_REMAP_SCRIPT="$SCRIPT_DIR/remap_unclassified_ground.py"
MIN_FREE_GB="${MIN_FREE_GB:-15}"
MIN_FREE_BYTES=0
MAX_SECTORS=0
KEEP_LAZ=false
REPROCESS=false
SECTOR_LIST_FILE=""
REMAP_CLASS1_GROUND=false

FAILED_LOG=""
SUCCEEDED_LOG=""
EVENT_LOG=""
STORAGE_STOP_LOG=""
SKIPPED_LAZ_LOG=""
SKIPPED_LAZ_DIR=""
STATE_DIR=""
DOWNLOAD_CACHE_DIR=""
STORAGE_AVAILABLE_BYTES=0

declare -a REQUESTED_SECTORS=()
declare -A REQUESTED_URL_BY_ID=()
declare -a SECTOR_IDS=()
declare -a SECTOR_URLS=()

SELECTED_TOTAL=0
EXISTING_COMPLETE=0

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
Completed sectors with valid Potree output are skipped automatically on restart,
unless explicitly selected with --reprocess.

Options:
  --grid FILE           GeoJSON grid to read (default: script_dir/grid.geojson)
  --download-dir DIR    Data and log directory (default: $HOME/lt-lidar-data)
  --max-sectors N       Process only the first N selected sectors (testing/resume aid)
  --sector ID           Process one sector ID; may be repeated (example: --sector 35_71)
  --sector-list FILE    Select sectors from IDs, CSV rows, or archive URLs in FILE
  --max-jobs N          Parallel PDAL jobs per sector (default: 4)
  --skip-pdal           Skip PDAL cleaning, but still generate metadata with PDAL
  --keep-laz            Keep source LAZ files after successful conversion
  --reprocess           Clean and rebuild the explicitly selected sectors from scratch
                        (requires --sector or --sector-list; never reprocesses the whole grid by accident)
  -h, --help            Show this help

Environment overrides:
  GRID_FILE, DOWNLOAD_DIR, MAX_JOBS, RUN_PDAL_CLEANING, POTREE_ENCODING,
  POTREE_CONVERTER, PYTHON_BIN, MIN_FREE_GB (default: 15)

If an individual LAZ file fails PDAL cleaning, it is quarantined and omitted
from Potree conversion; the sector is marked partial in source_manifest.json
and recorded in skipped_laz_files.txt.
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
    if ! awk -v id="$sector_id" \
        '$2 == id { found=1 } END { exit(found ? 0 : 1) }' \
        "$SUCCEEDED_LOG"; then
        printf '%s\t%s\n' "$(timestamp)" "$sector_id" >> "$SUCCEEDED_LOG"
    fi
    event "sector-succeeded" "$sector_id"
}

normalize_sector_id() {
    printf '%s' "$1" | tr '/' '_'
}

append_requested_sector() {
    local sector_id="$1"
    local url="${2:-}"
    local existing

    for existing in "${REQUESTED_SECTORS[@]}"; do
        if [[ "$existing" == "$sector_id" ]]; then
            [[ -n "$url" ]] && REQUESTED_URL_BY_ID["$sector_id"]="$url"
            return 0
        fi
    done

    REQUESTED_SECTORS+=("$sector_id")
    [[ -n "$url" ]] && REQUESTED_URL_BY_ID["$sector_id"]="$url"
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
                append_requested_sector "$(normalize_sector_id "$2")"
                shift 2
                ;;
            --sector-list)
                (($# >= 2)) || die "--sector-list requires a file"
                SECTOR_LIST_FILE="$2"
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
            --reprocess)
                REPROCESS=true
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

load_sector_list() {
    local line
    local first_field
    local url
    local sector_id
    local url_pattern='(https?://[^,[:space:]]+)'
    local archive_id_pattern='/([0-9]+)[_/]([0-9]+)\.zip'

    [[ -n "$SECTOR_LIST_FILE" ]] || return 0
    [[ -f "$SECTOR_LIST_FILE" ]] || die "sector list file not found: $SECTOR_LIST_FILE"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -n "${line//[[:space:]]/}" ]] || continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        url=""
        sector_id=""
        if [[ "$line" =~ $url_pattern ]]; then
            url="${BASH_REMATCH[1]}"
        fi

        if [[ -n "$url" && "$url" =~ $archive_id_pattern ]]; then
            sector_id="${BASH_REMATCH[1]}_${BASH_REMATCH[2]}"
        else
            first_field="${line%%,*}"
            first_field="${first_field%%$'\t'*}"
            first_field="${first_field//[[:space:]]/}"
            [[ "${first_field,,}" == *indeksas* ]] && continue
            sector_id="$(normalize_sector_id "$first_field")"
        fi

        [[ "$sector_id" =~ ^[0-9]+_[0-9]+$ ]] ||
            die "invalid sector-list entry: $line"
        append_requested_sector "$sector_id" "$url"
    done < "$SECTOR_LIST_FILE"

    ((${#REQUESTED_SECTORS[@]} > 0)) ||
        die "sector list contains no sector IDs: $SECTOR_LIST_FILE"
}

preflight() {
    [[ -f "$GRID_FILE" ]] || die "grid file not found: $GRID_FILE"
    [[ "$MIN_FREE_GB" =~ ^[1-9][0-9]*$ ]] ||
        die "MIN_FREE_GB must be a positive whole number"
    MIN_FREE_BYTES=$((MIN_FREE_GB * 1024 * 1024 * 1024))

    local command_name
    for command_name in awk df jq wget unzip find xargs; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "required command not found: $command_name"
    done

    command -v "$PYTHON_BIN" >/dev/null 2>&1 ||
        die "required command not found: $PYTHON_BIN"
    [[ -f "$LAS_BBOX_REPAIR_SCRIPT" ]] ||
        die "LAS bounding-box repair helper not found: $LAS_BBOX_REPAIR_SCRIPT"
    [[ -f "$GROUND_REMAP_SCRIPT" ]] ||
        die "ground classification helper not found: $GROUND_REMAP_SCRIPT"

    if [[ "$RUN_PDAL_CLEANING" == true ]]; then
        "$PYTHON_BIN" -c 'import laspy, lazrs, numpy' >/dev/null 2>&1 ||
            die "PYTHON_BIN must provide laspy, lazrs, and numpy: $PYTHON_BIN"
    fi

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
    STORAGE_STOP_LOG="$DOWNLOAD_DIR/insufficient_storage.txt"
    SKIPPED_LAZ_LOG="$DOWNLOAD_DIR/skipped_laz_files.txt"
    SKIPPED_LAZ_DIR="$DOWNLOAD_DIR/.skipped-laz"
    STATE_DIR="$DOWNLOAD_DIR/.pipeline-state"
    DOWNLOAD_CACHE_DIR="$DOWNLOAD_DIR/.downloads"

    mkdir -p "$STATE_DIR" "$DOWNLOAD_CACHE_DIR" "$SKIPPED_LAZ_DIR"
    touch "$FAILED_LOG" "$SUCCEEDED_LOG" "$EVENT_LOG" "$STORAGE_STOP_LOG" "$SKIPPED_LAZ_LOG"
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
        local requested_url

        for requested in "${REQUESTED_SECTORS[@]}"; do
            found=false
            for index in "${!all_ids[@]}"; do
                if [[ "${all_ids[$index]}" == "$requested" ]]; then
                    SECTOR_IDS+=("${all_ids[$index]}")
                    requested_url="${REQUESTED_URL_BY_ID[$requested]:-}"
                    SECTOR_URLS+=("${requested_url:-${all_urls[$index]}}")
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

validate_selection() {
    if [[ "$REPROCESS" == true && ${#REQUESTED_SECTORS[@]} -eq 0 ]]; then
        die "--reprocess requires --sector or --sector-list; refusing to reprocess the entire grid"
    fi
}

filter_completed_sectors() {
    local -a pending_ids=()
    local -a pending_urls=()
    local index
    local sector_id

    SELECTED_TOTAL="${#SECTOR_IDS[@]}"
    EXISTING_COMPLETE=0

    if [[ "$REPROCESS" == true ]]; then
        event "reprocess-scan" "-" \
            "selected_total=$SELECTED_TOTAL; pending=$SELECTED_TOTAL; existing_complete=0"
        printf 'Clean reprocess scan: %d explicitly selected sector(s) will be rebuilt.\n' \
            "$SELECTED_TOTAL"
        return 0
    fi

    for index in "${!SECTOR_IDS[@]}"; do
        sector_id="${SECTOR_IDS[$index]}"
        if output_is_complete "$DOWNLOAD_DIR/$sector_id/potree_output"; then
            EXISTING_COMPLETE=$((EXISTING_COMPLETE + 1))
        else
            pending_ids+=("$sector_id")
            pending_urls+=("${SECTOR_URLS[$index]}")
        fi
    done

    SECTOR_IDS=("${pending_ids[@]}")
    SECTOR_URLS=("${pending_urls[@]}")

    event "resume-scan" "-" \
        "selected_total=$SELECTED_TOTAL; existing_complete=$EXISTING_COMPLETE; pending=${#SECTOR_IDS[@]}"
    printf 'Resume scan: %d complete sector(s) skipped, %d pending of %d selected.\n' \
        "$EXISTING_COMPLETE" "${#SECTOR_IDS[@]}" "$SELECTED_TOTAL"
}

write_prepare_status() {
    local status_file="$1"
    local step="$2"
    local detail="${3:-}"
    printf '%s\t%s\n' "$step" "$detail" > "$status_file"
}

sector_is_locally_prepared() {
    local sector_id="$1"
    local target_dir="$DOWNLOAD_DIR/$sector_id"

    [[ "$REPROCESS" == true ]] && return 1

    if output_is_complete "$target_dir/potree_output"; then
        return 0
    fi

    [[ -f "$target_dir/.download_complete" ]] &&
        find "$target_dir" -type f -name '*.laz' -print -quit | grep -q .
}

refresh_available_storage() {
    local available_kb

    available_kb="$(
        df -Pk "$DOWNLOAD_DIR" |
            awk 'NR == 2 { print $4; exit }'
    )"

    [[ "$available_kb" =~ ^[0-9]+$ ]] ||
        die "could not determine available storage for $DOWNLOAD_DIR"

    STORAGE_AVAILABLE_BYTES=$((available_kb * 1024))
}

storage_allows_download() {
    refresh_available_storage
    ((STORAGE_AVAILABLE_BYTES >= MIN_FREE_BYTES))
}

bytes_to_gib() {
    awk -v bytes="$1" 'BEGIN { printf "%.2f", bytes / 1073741824 }'
}

clean_reprocess_sector() {
    local sector_id="$1"
    local target_dir="$DOWNLOAD_DIR/$sector_id"
    local status_file="$STATE_DIR/$sector_id.prepare"
    local archive="$DOWNLOAD_CACHE_DIR/$sector_id.zip"

    [[ "$sector_id" =~ ^[0-9]+_[0-9]+$ ]] || return 1
    [[ "$target_dir" == "$DOWNLOAD_DIR/"* ]] || return 1

    event "reprocess-clean-start" "$sector_id" "$target_dir"
    rm -rf -- "$target_dir" || return 1
    rm -f -- "$status_file" "$archive" "$archive.part" || return 1
    event "reprocess-clean-end" "$sector_id" "old sector state removed"
}

log_storage_stop() {
    local newly_succeeded="$1"
    local failed_this_run="$2"
    local last_sector="${3:-none}"
    local stopped_before="${4:-none}"
    local available_gib
    local completed_total
    local remaining_unfinished
    local detail

    available_gib="$(bytes_to_gib "$STORAGE_AVAILABLE_BYTES")"
    completed_total=$((EXISTING_COMPLETE + newly_succeeded))
    remaining_unfinished=$((SELECTED_TOTAL - completed_total))
    detail="reason=insufficient-storage; available_bytes=$STORAGE_AVAILABLE_BYTES; available_gib=$available_gib; threshold_bytes=$MIN_FREE_BYTES; threshold_gib=$MIN_FREE_GB; selected_total=$SELECTED_TOTAL; existing_complete=$EXISTING_COMPLETE; newly_succeeded=$newly_succeeded; failed_this_run=$failed_this_run; completed_total=$completed_total; remaining_unfinished=$remaining_unfinished; last_sector=$last_sector; stopped_before=$stopped_before"

    printf '%s\t%s\n' "$(timestamp)" "$detail" >> "$STORAGE_STOP_LOG"
    event "storage-stop" "$stopped_before" "$detail"
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

    if [[ "$REPROCESS" == true ]] && ! clean_reprocess_sector "$sector_id"; then
        write_prepare_status "$status_file" "reprocess-clean" "could not remove old sector state"
        event "reprocess-clean-failed" "$sector_id" "could not remove old sector state"
        return 1
    fi

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
        ! -name '*.ground-remap.*.laz' \
        -print0
}

validate_input() {
    output_is_complete "$CURRENT_OUTPUT_DIR" && return 0
    collect_laz_files | grep -q .
}

recalculate_manifest_summary() {
    local manifest="$1"

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
    ' "$manifest" > "$manifest.next" || return 1

    mv "$manifest.next" "$manifest"
}

mark_manifest_laz_skipped() {
    local file_path="$1"
    local quarantine_path="$2"
    local file_name
    local skipped_at

    file_name="$(basename "$file_path")"
    skipped_at="$(timestamp)"

    jq \
        --arg name "$file_name" \
        --arg skippedAt "$skipped_at" \
        --arg quarantinePath "$quarantine_path" \
        '
            .sourceFileCountBeforeSkip =
                (.sourceFileCountBeforeSkip // .sourceFileCount // 0) |
            .pointCountBeforeSkip =
                (.pointCountBeforeSkip // .pointCount // 0) |
            .sourceFiles = [.sourceFiles[] | select(.name != $name)] |
            .skippedLazFiles = ((.skippedLazFiles // []) + [{
                name: $name,
                step: "pdal-cleaning",
                skippedAt: $skippedAt,
                quarantinePath: $quarantinePath
            }]) |
            .partial = true
        ' "$CURRENT_MANIFEST_TMP" > "$CURRENT_MANIFEST_TMP.next" || return 1

    mv "$CURRENT_MANIFEST_TMP.next" "$CURRENT_MANIFEST_TMP" || return 1
    recalculate_manifest_summary "$CURRENT_MANIFEST_TMP"
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

    recalculate_manifest_summary "$CURRENT_MANIFEST_TMP"
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
    local remap_file
    local input_file="$file"
    local range_limits='Overlap[0:0],Classification[1:7],Z[:600]'

    rm -f "$temp_file"

    remap_file="$(mktemp "${file%.laz}.ground-remap.XXXXXX.laz")" || return 1
    rm -f -- "$remap_file"

    if [[ "$REMAP_CLASS1_GROUND" == true ]]; then
        if ! "$PYTHON_BIN" "$GROUND_REMAP_SCRIPT" \
            --remap-only "$file" "$remap_file"; then
            rm -f -- "$remap_file"
            return 1
        fi
        input_file="$remap_file"
    else
        rm -f -- "$remap_file"
    fi

    # Older LAS point formats have no overlap flag. In that case every point is
    # implicitly non-overlap, so omitting only that unavailable predicate keeps
    # the original filtering semantics and avoids a PDAL "Invalid dimension"
    # failure.
    if ! pdal info --schema "$input_file" |
        jq -e '.schema.dimensions | any(.name == "Overlap")' >/dev/null; then
        range_limits='Classification[1:7],Z[:600]'
    fi

    if ! pdal translate "$input_file" "$temp_file" \
        range \
        --filters.range.limits="$range_limits" \
        --writers.las.forward='vlr' \
        --writers.las.minor_version=2 \
        --writers.las.dataformat_id=0; then
        rm -f -- "$temp_file" "$remap_file"
        return 1
    fi

    rm -f -- "$remap_file"
    mv "$temp_file" "$file"
}

export -f process_laz_file

clean_laz_files() {
    local pdal_failure_dir="$CURRENT_TARGET_DIR/.pdal-failures"
    local xargs_status=0
    local ground_remap_analysis
    local ground_remap_detail
    local marker
    local file
    local file_name
    local quarantine_path

    rm -rf -- "$pdal_failure_dir" || return 1
    mkdir -p -- "$pdal_failure_dir" "$SKIPPED_LAZ_DIR/$CURRENT_SECTOR" || return 1
    find "$CURRENT_TARGET_DIR" \
        -type f \
        -name '*.ground-remap.*.laz' \
        -delete || return 1

    REMAP_CLASS1_GROUND=false
    [[ "$RUN_PDAL_CLEANING" == true ]] || return 0

    PDAL_FAILURE_DIR="$pdal_failure_dir"
    export PDAL_FAILURE_DIR GROUND_REMAP_SCRIPT PYTHON_BIN EVENT_LOG CURRENT_SECTOR \
        REMAP_CLASS1_GROUND
    export -f timestamp event process_laz_file

    ground_remap_analysis="$(
        collect_laz_files |
            xargs -0 -r -n 1 -P "$MAX_JOBS" \
                bash -c '
                    if "$PYTHON_BIN" "$GROUND_REMAP_SCRIPT" --analyse-only "$1"; then
                        exit 0
                    fi
                    printf '{"analysisFailed":true}\n'
                    exit 0
                ' _ |
            jq -s -c '
                . as $reports |
                ($reports | map(select(.analysisFailed != true))) as $valid |
                ($reports | length) as $file_count |
                ($reports | map(select(.analysisFailed == true)) | length) as $analysis_failed |
                if ($valid | length) == 0 then
                    {
                        fileCount: $file_count,
                        analysisFailedFiles: $analysis_failed,
                        totalPoints: 0,
                        class0Points: 0,
                        class1Points: 0,
                        class2Points: 0,
                        class12Points: 0,
                        class1Share: 0,
                        groundLikeClass1Points: 0,
                        groundLikeFraction: 0,
                        remapped: false,
                        thresholds: {}
                    }
                else
                    def sum_field($field): $valid | map(.[$field]) | add;
                    {
                        fileCount: $file_count,
                        analysisFailedFiles: $analysis_failed,
                        totalPoints: sum_field("totalPoints"),
                        class0Points: sum_field("class0Points"),
                        class1Points: sum_field("class1Points"),
                        class2Points: sum_field("class2Points"),
                        class12Points: sum_field("class12Points"),
                        class1Share: (
                            if sum_field("totalPoints") > 0
                            then sum_field("class1Points") / sum_field("totalPoints")
                            else 0
                            end
                        ),
                        groundLikeClass1Points: sum_field("groundLikeClass1Points"),
                        groundLikeFraction: (
                            if sum_field("class1Points") > 0
                            then sum_field("groundLikeClass1Points") / sum_field("class1Points")
                            else 0
                            end
                        ),
                        remapped: (
                            sum_field("class1Points") >= $valid[0].thresholds.minClass1Points
                            and (
                                if sum_field("totalPoints") > 0
                                then sum_field("class1Points") / sum_field("totalPoints")
                                else 0
                                end
                            ) >= $valid[0].thresholds.minClass1Share
                            and (
                                if sum_field("class1Points") > 0
                                then sum_field("groundLikeClass1Points") / sum_field("class1Points")
                                else 0
                                end
                            ) >= $valid[0].thresholds.minGroundLikeFraction
                        ),
                        thresholds: $valid[0].thresholds
                    }
                end
            '
    )" || {
        unset PDAL_FAILURE_DIR
        return 1
    }

    REMAP_CLASS1_GROUND="$(jq -r '.remapped' <<< "$ground_remap_analysis")" || {
        unset PDAL_FAILURE_DIR
        return 1
    }
    [[ "$REMAP_CLASS1_GROUND" == true || "$REMAP_CLASS1_GROUND" == false ]] || {
        unset PDAL_FAILURE_DIR
        return 1
    }
    ground_remap_detail="$(
        jq -r '"scope=sector;files=\(.fileCount);analysisFailedFiles=\(.analysisFailedFiles);class1Points=\(.class1Points);class1Share=\(.class1Share);groundLikeFraction=\(.groundLikeFraction);remapped=\(.remapped)"' \
            <<< "$ground_remap_analysis"
    )" || {
        unset PDAL_FAILURE_DIR
        return 1
    }
    event "class1-ground-remap-scan" "$CURRENT_SECTOR" "$ground_remap_detail"
    if [[ "$REMAP_CLASS1_GROUND" == true ]]; then
        event "class1-ground-remap" "$CURRENT_SECTOR" "$ground_remap_detail"
    fi

    collect_laz_files |
        xargs -0 -r -n 1 -P "$MAX_JOBS" \
            bash -c '
                file="$1"
                if process_laz_file "$file"; then
                    exit 0
                fi

                rm -f -- "${file%.laz}_clean.laz"
                marker="$PDAL_FAILURE_DIR/$(basename "$file").$BASHPID.path"
                printf "%s\n" "$file" > "$marker" || exit 1
                exit 0
            ' _ || xargs_status=$?

    unset PDAL_FAILURE_DIR
    ((xargs_status == 0)) || return "$xargs_status"

    while IFS= read -r -d '' marker; do
        IFS= read -r file < "$marker" || return 1
        [[ -f "$file" ]] || return 1

        file_name="$(basename "$file")"
        quarantine_path="$SKIPPED_LAZ_DIR/$CURRENT_SECTOR/$file_name"
        mv -f -- "$file" "$quarantine_path" || return 1

        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$(timestamp)" \
            "$CURRENT_SECTOR" \
            "pdal-cleaning" \
            "$file" \
            "$quarantine_path" >> "$SKIPPED_LAZ_LOG" || return 1
        event "laz-skipped" "$CURRENT_SECTOR" \
            "step=pdal-cleaning; file=$file; quarantine=$quarantine_path"

        mark_manifest_laz_skipped "$file" "$quarantine_path" || return 1
        rm -f -- "$marker" || return 1
    done < <(find "$pdal_failure_dir" -type f -name '*.path' -print0)

    rm -rf -- "$pdal_failure_dir"
    collect_laz_files | grep -q .
}

run_potree_converter_once() {
    local -a laz_files=()
    local -a potree_args=()
    local converter_dir
    local converter_name

    mapfile -d '' laz_files < <(collect_laz_files)
    ((${#laz_files[@]} > 0)) || return 1

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

repair_bounding_box_files() {
    local converter_log="$1"
    local -a affected_files=()
    local file

    mapfile -t affected_files < <(
        awk '/^[[:space:]]*file: / {sub(/^[[:space:]]*file: /, ""); print}' "$converter_log" |
            sort -u
    )
    ((${#affected_files[@]} > 0)) || return 1

    for file in "${affected_files[@]}"; do
        [[ -f "$file" && "$file" == *.laz ]] || return 1
        event "bbox-repair-start" "$CURRENT_SECTOR" "$file"
        if "$PYTHON_BIN" "$LAS_BBOX_REPAIR_SCRIPT" "$file"; then
            event "bbox-repair-end" "$CURRENT_SECTOR" "$file"
        else
            event "bbox-repair-failed" "$CURRENT_SECTOR" "$file"
            return 1
        fi
    done
}

run_potree_converter() {
    local converter_log
    local converter_status
    local retry_status

    converter_log="$(mktemp "$STATE_DIR/potree-${CURRENT_SECTOR}.XXXXXX.log")" ||
        return 1

    rm -rf "$CURRENT_OUTPUT_DIR"
    run_potree_converter_once 2>&1 | tee "$converter_log"
    converter_status="${PIPESTATUS[0]}"
    if ((converter_status == 0)); then
        rm -f "$converter_log"
        return 0
    fi

    if [[ -f "$CURRENT_OUTPUT_DIR/log.txt" ]]; then
        cat "$CURRENT_OUTPUT_DIR/log.txt" >> "$converter_log"
    fi

    if ! grep -q 'point outside bounding box' "$converter_log"; then
        rm -f "$converter_log"
        return "$converter_status"
    fi

    event "bbox-repair-triggered" "$CURRENT_SECTOR"
    if ! repair_bounding_box_files "$converter_log"; then
        rm -f "$converter_log"
        return 1
    fi

    rm -rf "$CURRENT_OUTPUT_DIR"
    run_potree_converter_once 2>&1 | tee -a "$converter_log"
    retry_status="${PIPESTATUS[0]}"
    rm -f "$converter_log"
    return "$retry_status"
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
    local pending_total="${#SECTOR_IDS[@]}"
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
    local storage_stopped=false
    local stop_after_current=false
    local stopped_before=""
    local first_sector

    if ((pending_total == 0)); then
        printf 'All %d selected sector(s) already have complete output; nothing to process.\n' \
            "$SELECTED_TOTAL"
        printf 'Succeeded log unchanged: %s\nFailed log: %s\n' \
            "$SUCCEEDED_LOG" "$FAILED_LOG"
        return 0
    fi

    first_sector="${SECTOR_IDS[0]}"

    printf 'Processing %d pending sector(s) of %d selected. Data directory: %s\n' \
        "$pending_total" "$SELECTED_TOTAL" "$DOWNLOAD_DIR"
    printf 'Existing complete outputs skipped: %d\n' "$EXISTING_COMPLETE"
    printf 'Event evidence: %s\n' "$EVENT_LOG"
    printf 'Download storage floor: %d GiB\n' "$MIN_FREE_GB"

    if ! sector_is_locally_prepared "$first_sector" &&
       ! storage_allows_download; then
        event "storage-low-detected" "$first_sector" \
            "available_bytes=$STORAGE_AVAILABLE_BYTES; threshold_bytes=$MIN_FREE_BYTES; no download started"
        log_storage_stop 0 0 "none" "$first_sector"
        printf 'Stopped before downloading %s: %s GiB available, %d GiB required.\n' \
            "$first_sector" "$(bytes_to_gib "$STORAGE_AVAILABLE_BYTES")" "$MIN_FREE_GB"
        printf 'Storage stop report: %s\n' "$STORAGE_STOP_LOG"
        return 0
    fi

    prepare_sector "$first_sector" "${SECTOR_URLS[0]}" &
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
        stop_after_current=false
        stopped_before=""
        next_index=$((index + 1))
        if ((next_index < pending_total)); then
            stopped_before="${SECTOR_IDS[$next_index]}"
            if ! sector_is_locally_prepared "$stopped_before" &&
               ! storage_allows_download; then
                stop_after_current=true
                event "storage-low-detected" "$stopped_before" \
                    "available_bytes=$STORAGE_AVAILABLE_BYTES; threshold_bytes=$MIN_FREE_BYTES; finishing_sector=$sector_id"
            else
                prepare_sector \
                    "$stopped_before" \
                    "${SECTOR_URLS[$next_index]}" &
                next_prepare_pid=$!
                event "prepare-backgrounded" "$stopped_before" "pid=$next_prepare_pid"
            fi
        fi

        printf '[%d/%d pending] %s\n' "$((index + 1))" "$pending_total" "$sector_id"

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

        if [[ "$stop_after_current" == true ]]; then
            storage_stopped=true
            log_storage_stop "$succeeded" "$failed" "$sector_id" "$stopped_before"
            break
        fi

        current_prepare_pid="$next_prepare_pid"
    done

    trap - INT TERM
    if [[ "$storage_stopped" == true ]]; then
        printf 'Stopped safely for storage: %d existing complete, %d newly succeeded, %d failed this run, %d unfinished of %d selected.\n' \
            "$EXISTING_COMPLETE" "$succeeded" "$failed" \
            "$((SELECTED_TOTAL - EXISTING_COMPLETE - succeeded))" "$SELECTED_TOTAL"
        printf 'Storage stop report: %s\n' "$STORAGE_STOP_LOG"
    else
        printf 'Finished pending pass: %d existing complete, %d newly succeeded, %d failed, %d selected total.\n' \
            "$EXISTING_COMPLETE" "$succeeded" "$failed" "$SELECTED_TOTAL"
    fi
    printf 'Succeeded log: %s\nFailed log: %s\nSkipped LAZ log: %s\n' \
        "$SUCCEEDED_LOG" "$FAILED_LOG" "$SKIPPED_LAZ_LOG"

    # Per-sector failures are recorded and intentionally do not make the whole
    # batch exit non-zero. A non-zero exit is reserved for global/preflight errors.
    return 0
}

main() {
    parse_args "$@"
    preflight
    load_sector_list
    validate_selection
    load_sectors
    filter_completed_sectors
    run_pipeline
}

main "$@"
