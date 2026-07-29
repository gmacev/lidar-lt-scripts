#!/bin/bash
set -Ee -o pipefail

trap 'echo "❌ ERROR on line $LINENO: $BASH_COMMAND"' ERR

# ==========================================
# CONFIGURATION
# ==========================================
DOWNLOAD_DIR="/home/debian/lt-lidar-data"
MAX_JOBS=4

# Faster / safer defaults
RUN_PDAL_CLEANING=true
POTREE_ENCODING="BROTLI"
# ==========================================

SUCCESS=0
TARGET_DIR=""

cleanup() {
    echo "----------------------------------------"
    echo "🧹 Final Cleanup..."

    if [ -z "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR" ]; then
        echo "   Nothing to clean."
        return
    fi

    if [ "$SUCCESS" -eq 1 ]; then
        find "$TARGET_DIR" -type f -name "*.laz" -delete

        if [ -n "${SOURCE_MANIFEST_TMP:-}" ] && [ -f "$SOURCE_MANIFEST_TMP" ]; then
            rm -f "$SOURCE_MANIFEST_TMP"
            echo "   Removed temporary source manifest: $SOURCE_MANIFEST_TMP"
        fi

        find "$TARGET_DIR" -type d -empty -delete
        echo "   Removed temporary .laz files in $TARGET_DIR"
    else
        echo "   Conversion failed; keeping .laz files for debugging/retry."
    fi
}

trap cleanup EXIT

for arg in "$@"; do
    case "$arg" in
        --skip-pdal)
            RUN_PDAL_CLEANING=false
            ;;
        --help|-h)
            echo "Usage: $0 [--skip-pdal]"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $arg"
            echo "Usage: $0 [--skip-pdal]"
            exit 1
            ;;
    esac
done

read -rp "Enter the LiDAR ID (e.g., 35_71): " ID

if [ -z "$ID" ]; then
    echo "Error: ID cannot be empty."
    exit 1
fi

ZIP_URL="https://www.geoportal.lt/download/lidar/${ID}.zip"
ZIP_NAME="${ID}.zip"
TARGET_DIR="${DOWNLOAD_DIR}/${ID}"
OUTPUT_DIR="${TARGET_DIR}/potree_output"
SOURCE_MANIFEST_TMP="${TARGET_DIR}/source_manifest.json"
SOURCE_MANIFEST_OUT="${OUTPUT_DIR}/source_manifest.json"

mkdir -p "$DOWNLOAD_DIR"
cd "$DOWNLOAD_DIR"

echo "----------------------------------------"
echo "Processing ID: $ID"
echo "----------------------------------------"

# ==========================================
# DOWNLOAD / EXTRACT
# ==========================================
if find "$TARGET_DIR" -type f -name "*.laz" 2>/dev/null | grep -q .; then
    echo "Directory $TARGET_DIR already contains .laz files. Skipping download..."
else
    echo "No .laz files found. Downloading fresh copy..."

    rm -rf "$TARGET_DIR"
    rm -f "$ZIP_NAME"

    wget --show-progress "$ZIP_URL" -O "$ZIP_NAME"

    echo "Extracting..."
    unzip -q "$ZIP_NAME" -d .

    rm "$ZIP_NAME"
fi

LAZ_COUNT=$(find "$TARGET_DIR" -type f -name "*.laz" | wc -l)

if [ "$LAZ_COUNT" -eq 0 ]; then
    echo "ERROR: No .laz files found in $TARGET_DIR after extraction."
    exit 1
fi

echo "Found $LAZ_COUNT .laz files."

# ==========================================
# SETUP CONDA / PDAL
# ==========================================
if [ "$RUN_PDAL_CLEANING" = true ]; then
    CONDA_INIT=""

    if [ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ]; then
        CONDA_INIT="$HOME/miniconda3/etc/profile.d/conda.sh"
    elif [ -f "$HOME/anaconda3/etc/profile.d/conda.sh" ]; then
        CONDA_INIT="$HOME/anaconda3/etc/profile.d/conda.sh"
    elif [ -f "/opt/conda/etc/profile.d/conda.sh" ]; then
        CONDA_INIT="/opt/conda/etc/profile.d/conda.sh"
    fi

    if [ -n "$CONDA_INIT" ]; then
        source "$CONDA_INIT"
        conda activate base 2>/dev/null || conda activate pdal 2>/dev/null || true
    fi

    if ! command -v pdal &>/dev/null; then
        echo "ERROR: PDAL not found!"
        exit 1
    fi
fi

# ==========================================
# PARALLEL PDAL CLEANING
# ==========================================
process_laz() {
    local file="$1"
    local temp_file="${file%.laz}_clean.laz"

    echo "  [PROCESSING] $file"
    rm -f "$temp_file"

    pdal translate "$file" "$temp_file" \
        range \
        --filters.range.limits='Overlap[0:0],Classification[1:7],Z[:600]' \
        --writers.las.forward="vlr" \
        --writers.las.minor_version=2 \
        --writers.las.dataformat_id=0

    mv "$temp_file" "$file"

    echo "  [DONE] $file"
}

export -f process_laz

mapfile -d '' LAZ_FILES < <(
    find "$TARGET_DIR" -type f -name "*.laz" ! -name "*_clean.laz" -print0
)

if [ "${#LAZ_FILES[@]}" -eq 0 ]; then
    echo "ERROR: No LAZ files found."
    exit 1
fi

# ==========================================
# SOURCE METADATA MANIFEST
# ==========================================
generate_source_manifest() {
    local manifest_file="$1"

    echo "Generating source metadata manifest..."

    jq -n \
        --arg sectorId "$ID" \
        --arg generatedAt "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
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
                minx: null,
                miny: null,
                minz: null,
                maxx: null,
                maxy: null,
                maxz: null
            },
            sourceFiles: []
        }' > "$manifest_file"

    for file in "${LAZ_FILES[@]}"; do
        echo "  [METADATA] $file"

        local file_metadata
        file_metadata=$(pdal info --metadata "$file")

        local creation_year
        local creation_doy
        local creation_date
        creation_year=$(echo "$file_metadata" | jq -r '.metadata.creation_year // empty')
        creation_doy=$(echo "$file_metadata" | jq -r '.metadata.creation_doy // empty')
        creation_date=""

        if [ -n "$creation_year" ] && [ -n "$creation_doy" ]; then
            creation_date=$(date -u -d "$creation_year-01-01 +$((creation_doy - 1)) days" +"%Y-%m-%d")
        fi

        local entry
        entry=$(echo "$file_metadata" | jq \
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
                    if (.metadata.major_version != null and .metadata.minor_version != null) then
                        ((.metadata.major_version | tostring) + "." + (.metadata.minor_version | tostring))
                    else
                        null
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
            }')

        jq --argjson entry "$entry" \
            '.sourceFiles += [$entry]' \
            "$manifest_file" > "$manifest_file.tmp"

        mv "$manifest_file.tmp" "$manifest_file"
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
    ' "$manifest_file" > "$manifest_file.tmp"

    mv "$manifest_file.tmp" "$manifest_file"
    echo "Source metadata manifest generated: $manifest_file"
}

if [ -s "$SOURCE_MANIFEST_TMP" ]; then
    echo "Source metadata manifest already exists. Skipping generation: $SOURCE_MANIFEST_TMP"
else
    generate_source_manifest "$SOURCE_MANIFEST_TMP"
fi

if [ "$RUN_PDAL_CLEANING" = true ]; then
    echo "Starting Parallel PDAL Processing..."
    echo "  - Max Parallel Jobs: $MAX_JOBS"

    printf '%s\0' "${LAZ_FILES[@]}" |
        xargs -0 -r -n 1 -P "$MAX_JOBS" \
            bash -c 'process_laz "$1"' _

    echo "PDAL processing complete."
else
    echo "Skipping PDAL cleaning."
fi

# ==========================================
# POTREE CONVERTER
# ==========================================
echo "Running PotreeConverter..."

rm -rf "$OUTPUT_DIR"

POTREE_ARGS=(
    "${LAZ_FILES[@]}"
    -o "$OUTPUT_DIR"
    --attributes intensity classification
)

if [ -n "$POTREE_ENCODING" ]; then
    POTREE_ARGS+=(--encoding "$POTREE_ENCODING")
fi

"$HOME/PotreeConverter/build/PotreeConverter" "${POTREE_ARGS[@]}"

if [ ! -s "$OUTPUT_DIR/metadata.json" ] ||
   [ ! -s "$OUTPUT_DIR/octree.bin" ] ||
   [ ! -s "$OUTPUT_DIR/hierarchy.bin" ]; then
    echo "ERROR: PotreeConverter output is incomplete."
    exit 1
fi

if [ -s "$SOURCE_MANIFEST_TMP" ]; then
    cp "$SOURCE_MANIFEST_TMP" "$SOURCE_MANIFEST_OUT"
    echo "Source metadata manifest saved: $SOURCE_MANIFEST_OUT"
else
    echo "ERROR: Source metadata manifest was not generated."
    exit 1
fi

ACTUAL_ATTRIBUTES=$(
    jq -r '.attributes[].name' "$OUTPUT_DIR/metadata.json" |
        sort |
        tr '\n' ' '
)

EXPECTED_ATTRIBUTES="classification intensity position "

if [ "$ACTUAL_ATTRIBUTES" != "$EXPECTED_ATTRIBUTES" ]; then
    echo "ERROR: Unexpected Potree attributes:"
    jq -r '.attributes[].name' "$OUTPUT_DIR/metadata.json"
    exit 1
fi

SUCCESS=1

echo "----------------------------------------"
echo "Done! Output is in: $OUTPUT_DIR"
echo "----------------------------------------"
