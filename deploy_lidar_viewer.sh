#!/usr/bin/env bash
set -Eeuo pipefail

# Deploy a pre-built lidar-lt static-site archive without installing Node, npm,
# or the source repository on the web server.
#
# Expected archive layout: index.html and the other dist/ contents at the root
# of a .tar.gz/.tgz archive.

DEFAULT_DEPLOY_ROOT="/srv/www/lidar-lt"
DEFAULT_KEEP_RELEASES=3
DEFAULT_RELEASE_REPOSITORY="${VIEWER_RELEASE_REPOSITORY:-gmacev/lidar-lt}"
DEFAULT_ARTIFACT_NAME="lidar-lt-viewer.tar.gz"

DEPLOY_ROOT="$DEFAULT_DEPLOY_ROOT"
KEEP_RELEASES="$DEFAULT_KEEP_RELEASES"
RELEASE_ID=""
ARTIFACT_URL=""
ARTIFACT_FILE=""
CHECKSUM_URL=""
CHECKSUM_FILE=""
EXPECTED_SHA256=""

RELEASES_DIR=""
CHECKSUMS_DIR=""
STAGING_ROOT=""
STAGING_DIR=""

usage() {
    cat <<'EOF'
Usage:
  ./deploy_lidar_viewer.sh

Deploy a specific published release:
  ./deploy_lidar_viewer.sh --release RELEASE_TAG

Advanced/custom artifact usage:
  ./deploy_lidar_viewer.sh \
    --release COMMIT_OR_VERSION \
    --artifact-url URL \
    --checksum-url URL \
    [options]

Artifact source (choose exactly one):
  --artifact-url URL       Download the .tar.gz/.tgz artifact with curl
  --artifact-file FILE     Use a local artifact (useful for testing)

Checksum source (choose exactly one):
  --sha256 HEX             Expected SHA-256 as 64 hexadecimal characters
  --checksum-url URL       Download a sha256sum-compatible checksum file
  --checksum-file FILE     Use a local sha256sum-compatible checksum file

Options:
  --release ID             Published release tag or custom release name
  --deploy-root DIR        Deployment root (default: /srv/www/lidar-lt)
  --keep-releases N        Total releases retained, including active (default: 3)
  -h, --help               Show this help

With no artifact options, the script downloads the latest published release
from gmacev/lidar-lt. Set VIEWER_RELEASE_REPOSITORY=OWNER/REPOSITORY to override
that repository. Supplying only --release downloads that specific release.

The deployment layout is:
  DEPLOY_ROOT/releases/RELEASE_ID/
  DEPLOY_ROOT/current -> releases/RELEASE_ID

The target account must already be able to write to DEPLOY_ROOT. A typical
one-time administrator setup is:
  sudo mkdir -p /srv/www/lidar-lt/releases
  sudo chown -R uostas:uostas /srv/www/lidar-lt
  sudo chmod -R u=rwX,go=rX /srv/www/lidar-lt
EOF
}

log() {
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$STAGING_DIR" && -n "$STAGING_ROOT" && -d "$STAGING_DIR" ]]; then
        case "$STAGING_DIR" in
            "$STAGING_ROOT"/viewer-deploy.*)
                rm -rf -- "$STAGING_DIR"
                ;;
            *)
                printf 'WARNING: refusing to clean unexpected staging path: %s\n' \
                    "$STAGING_DIR" >&2
                ;;
        esac
    fi
}

on_error() {
    local exit_code=$?
    printf 'ERROR: deployment failed on line %s while running: %s\n' \
        "${BASH_LINENO[0]:-unknown}" "${BASH_COMMAND:-unknown}" >&2
    exit "$exit_code"
}

trap cleanup EXIT
trap on_error ERR

require_value() {
    local option="$1"
    local remaining="$2"
    (( remaining >= 2 )) || die "$option requires a value"
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --release)
                require_value "$1" "$#"
                RELEASE_ID="$2"
                shift 2
                ;;
            --artifact-url)
                require_value "$1" "$#"
                ARTIFACT_URL="$2"
                shift 2
                ;;
            --artifact-file)
                require_value "$1" "$#"
                ARTIFACT_FILE="$2"
                shift 2
                ;;
            --sha256)
                require_value "$1" "$#"
                EXPECTED_SHA256="${2,,}"
                shift 2
                ;;
            --checksum-url)
                require_value "$1" "$#"
                CHECKSUM_URL="$2"
                shift 2
                ;;
            --checksum-file)
                require_value "$1" "$#"
                CHECKSUM_FILE="$2"
                shift 2
                ;;
            --deploy-root)
                require_value "$1" "$#"
                DEPLOY_ROOT="$2"
                shift 2
                ;;
            --keep-releases)
                require_value "$1" "$#"
                KEEP_RELEASES="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown option: $1"
                ;;
        esac
    done
}

configure_published_release() {
    local artifact_sources=0
    local checksum_sources=0
    local latest_url

    [[ -n "$ARTIFACT_URL" ]] && (( artifact_sources += 1 ))
    [[ -n "$ARTIFACT_FILE" ]] && (( artifact_sources += 1 ))
    [[ -n "$EXPECTED_SHA256" ]] && (( checksum_sources += 1 ))
    [[ -n "$CHECKSUM_URL" ]] && (( checksum_sources += 1 ))
    [[ -n "$CHECKSUM_FILE" ]] && (( checksum_sources += 1 ))

    if (( artifact_sources > 0 || checksum_sources > 0 )); then
        return
    fi

    [[ "$DEFAULT_RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
        die "invalid VIEWER_RELEASE_REPOSITORY: $DEFAULT_RELEASE_REPOSITORY"
    command -v curl >/dev/null 2>&1 || die "required command not found: curl"

    if [[ -z "$RELEASE_ID" ]]; then
        log "Resolving latest viewer release from $DEFAULT_RELEASE_REPOSITORY"
        latest_url="$(
            curl --fail --location --silent --show-error \
                --output /dev/null --write-out '%{url_effective}' \
                "https://github.com/$DEFAULT_RELEASE_REPOSITORY/releases/latest"
        )"
        RELEASE_ID="${latest_url##*/}"
        [[ "$latest_url" == "https://github.com/$DEFAULT_RELEASE_REPOSITORY/releases/tag/$RELEASE_ID" ]] ||
            die "could not resolve the latest published release"
    fi

    ARTIFACT_URL="https://github.com/$DEFAULT_RELEASE_REPOSITORY/releases/download/$RELEASE_ID/$DEFAULT_ARTIFACT_NAME"
    CHECKSUM_URL="$ARTIFACT_URL.sha256"
    log "Selected viewer release: $RELEASE_ID"
}

preflight() {
    local command_name
    local artifact_sources=0
    local checksum_sources=0

    [[ -n "$RELEASE_ID" ]] || die "--release is required"
    [[ "$RELEASE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] ||
        die "invalid release ID: $RELEASE_ID"
    [[ "$RELEASE_ID" != "." && "$RELEASE_ID" != ".." ]] ||
        die "invalid release ID: $RELEASE_ID"

    [[ -n "$ARTIFACT_URL" ]] && (( artifact_sources += 1 ))
    [[ -n "$ARTIFACT_FILE" ]] && (( artifact_sources += 1 ))
    (( artifact_sources == 1 )) ||
        die "choose exactly one of --artifact-url or --artifact-file"

    [[ -n "$EXPECTED_SHA256" ]] && (( checksum_sources += 1 ))
    [[ -n "$CHECKSUM_URL" ]] && (( checksum_sources += 1 ))
    [[ -n "$CHECKSUM_FILE" ]] && (( checksum_sources += 1 ))
    (( checksum_sources == 1 )) ||
        die "choose exactly one checksum source"

    [[ "$KEEP_RELEASES" =~ ^[1-9][0-9]*$ ]] ||
        die "--keep-releases must be a positive integer"

    [[ "$DEPLOY_ROOT" == /* ]] || die "--deploy-root must be an absolute path"
    [[ "$DEPLOY_ROOT" != "/" ]] || die "refusing to use / as the deployment root"
    DEPLOY_ROOT="${DEPLOY_ROOT%/}"

    [[ -z "$ARTIFACT_FILE" || -f "$ARTIFACT_FILE" ]] ||
        die "artifact file not found: $ARTIFACT_FILE"
    [[ -z "$CHECKSUM_FILE" || -f "$CHECKSUM_FILE" ]] ||
        die "checksum file not found: $CHECKSUM_FILE"

    if [[ -n "$EXPECTED_SHA256" ]]; then
        [[ "$EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
            die "--sha256 must contain exactly 64 hexadecimal characters"
    fi

    for command_name in awk basename cp curl date find ln mktemp mv readlink \
        rm sha256sum sort tar; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "required command not found: $command_name"
    done

    RELEASES_DIR="$DEPLOY_ROOT/releases"
    CHECKSUMS_DIR="$DEPLOY_ROOT/.release-checksums"
    STAGING_ROOT="$DEPLOY_ROOT/.staging"

    mkdir -p -- "$RELEASES_DIR" "$CHECKSUMS_DIR" "$STAGING_ROOT" ||
        die "cannot create deployment directories under $DEPLOY_ROOT; ask an administrator to create and assign them first"

    [[ -w "$DEPLOY_ROOT" && -w "$RELEASES_DIR" && -w "$STAGING_ROOT" ]] ||
        die "current user cannot write to $DEPLOY_ROOT"

    if [[ -e "$DEPLOY_ROOT/current" && ! -L "$DEPLOY_ROOT/current" ]]; then
        die "$DEPLOY_ROOT/current exists but is not a symbolic link"
    fi
}

artifact_name_from_source() {
    local source_path

    if [[ -n "$ARTIFACT_URL" ]]; then
        source_path="${ARTIFACT_URL%%\?*}"
    else
        source_path="$ARTIFACT_FILE"
    fi

    basename -- "$source_path"
}

load_expected_checksum() {
    local artifact_name="$1"
    local checksum_path="$2"
    local candidate

    if [[ -n "$EXPECTED_SHA256" ]]; then
        printf '%s\n' "$EXPECTED_SHA256"
        return
    fi

    candidate="$(awk -v wanted="$artifact_name" '
        NF >= 2 {
            filename = $2
            sub(/^\*/, "", filename)
            if (filename == wanted) {
                print tolower($1)
                exit
            }
        }
    ' "$checksum_path")"

    [[ "$candidate" =~ ^[0-9a-f]{64}$ ]] ||
        die "checksum file has no valid entry for $artifact_name"

    printf '%s\n' "$candidate"
}

validate_archive() {
    local archive="$1"
    local members_file="$2"
    local listing_file="$3"
    local member clean_member

    tar -tzf "$archive" > "$members_file"
    [[ -s "$members_file" ]] || die "artifact archive is empty"

    while IFS= read -r member; do
        clean_member="${member#./}"
        [[ -n "$clean_member" ]] || continue

        [[ "$clean_member" != /* ]] ||
            die "artifact contains an absolute path: $member"
        case "/$clean_member/" in
            */../*) die "artifact contains parent-directory traversal: $member" ;;
        esac
    done < "$members_file"

    tar -tvzf "$archive" > "$listing_file"
    if awk '$1 ~ /^[lh]/ { found = 1 } END { exit(found ? 0 : 1) }' "$listing_file"; then
        die "artifact contains symbolic or hard links"
    fi
}

activate_release() {
    local release_dir="$1"
    local current_link="$DEPLOY_ROOT/current"
    local next_link="$DEPLOY_ROOT/.current.$$.tmp"

    rm -f -- "$next_link"
    ln -s "releases/$RELEASE_ID" "$next_link"
    mv -Tf -- "$next_link" "$current_link"

    [[ "$(readlink -f -- "$current_link")" == "$(readlink -f -- "$release_dir")" ]] ||
        die "current symlink did not resolve to the requested release"
}

prune_old_releases() {
    local current_target candidate record
    local -a release_records=()
    local release_count

    current_target="$(readlink -f -- "$DEPLOY_ROOT/current")"
    mapfile -d '' release_records < <(
        find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d \
            -printf '%T@ %p\0' | sort -z -n
    )
    release_count="${#release_records[@]}"

    for record in "${release_records[@]}"; do
        (( release_count > KEEP_RELEASES )) || break
        candidate="${record#* }"

        [[ "$(readlink -f -- "$candidate")" != "$current_target" ]] || continue
        case "$candidate" in
            "$RELEASES_DIR"/*)
                log "Removing old release $(basename -- "$candidate")"
                rm -rf -- "$candidate"
                rm -f -- "$CHECKSUMS_DIR/$(basename -- "$candidate").sha256"
                (( release_count -= 1 ))
                ;;
            *)
                die "refusing to remove unexpected release path: $candidate"
                ;;
        esac
    done
}

deploy() {
    local artifact_name archive checksum_path expected_sha actual_sha
    local extract_dir release_dir stored_checksum

    artifact_name="$(artifact_name_from_source)"
    case "$artifact_name" in
        *.tar.gz|*.tgz) ;;
        *) die "artifact must have a .tar.gz or .tgz filename: $artifact_name" ;;
    esac

    STAGING_DIR="$(mktemp -d "$STAGING_ROOT/viewer-deploy.XXXXXXXX")"
    archive="$STAGING_DIR/$artifact_name"
    checksum_path="$STAGING_DIR/$artifact_name.sha256"
    extract_dir="$STAGING_DIR/extracted"
    release_dir="$RELEASES_DIR/$RELEASE_ID"
    stored_checksum="$CHECKSUMS_DIR/$RELEASE_ID.sha256"

    if [[ -n "$ARTIFACT_URL" ]]; then
        log "Downloading viewer artifact"
        curl --fail --location --retry 3 --retry-all-errors \
            --output "$archive" "$ARTIFACT_URL"
    else
        log "Copying local viewer artifact"
        cp -- "$ARTIFACT_FILE" "$archive"
    fi

    if [[ -n "$CHECKSUM_URL" ]]; then
        log "Downloading checksum"
        curl --fail --location --retry 3 --retry-all-errors \
            --output "$checksum_path" "$CHECKSUM_URL"
    elif [[ -n "$CHECKSUM_FILE" ]]; then
        cp -- "$CHECKSUM_FILE" "$checksum_path"
    fi

    expected_sha="$(load_expected_checksum "$artifact_name" "$checksum_path")"
    actual_sha="$(sha256sum "$archive" | awk '{print tolower($1)}')"
    [[ "$actual_sha" == "$expected_sha" ]] ||
        die "artifact checksum mismatch (expected $expected_sha, got $actual_sha)"
    log "Artifact checksum verified: $actual_sha"

    if [[ -d "$release_dir" ]]; then
        [[ -f "$release_dir/index.html" ]] ||
            die "release directory already exists but is incomplete: $release_dir"
        [[ -f "$stored_checksum" ]] ||
            die "release directory already exists without checksum metadata: $release_dir"
        [[ "$(<"$stored_checksum")" == "$actual_sha" ]] ||
            die "release ID $RELEASE_ID already exists with a different artifact"

        log "Release $RELEASE_ID is already installed; activating it"
        activate_release "$release_dir"
        prune_old_releases
        log "Active viewer release: $RELEASE_ID"
        return
    fi

    log "Validating and extracting release $RELEASE_ID"
    validate_archive "$archive" "$STAGING_DIR/members.txt" "$STAGING_DIR/listing.txt"
    mkdir -p -- "$extract_dir"
    tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$extract_dir"

    [[ -f "$extract_dir/index.html" ]] ||
        die "artifact must contain index.html at its root (archive dist contents, not the dist directory)"
    [[ ! -e "$extract_dir/.git" && ! -e "$extract_dir/node_modules" ]] ||
        die "artifact unexpectedly contains source-control or dependency directories"

    chmod -R u=rwX,go=rX "$extract_dir"
    mv -- "$extract_dir" "$release_dir"
    printf '%s\n' "$actual_sha" > "$stored_checksum"

    activate_release "$release_dir"
    prune_old_releases

    log "Deployment complete"
    log "Active viewer release: $RELEASE_ID"
    log "Caddy root: $DEPLOY_ROOT/current"
}

main() {
    parse_args "$@"
    configure_published_release
    preflight
    deploy
}

main "$@"
