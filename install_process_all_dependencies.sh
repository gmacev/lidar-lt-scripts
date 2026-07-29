#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap the runtime required by process_all.sh on Ubuntu 26.04 LTS x86_64.
# Run this script as the same account that will run process_all.sh:
#
#   chmod +x install_process_all_dependencies.sh
#   ./install_process_all_dependencies.sh
#
# The script requests sudo only for Ubuntu packages and the original
# /home/debian/lt-lidar-data output directory.

MINIFORGE_VERSION="26.3.2-3"
MINIFORGE_SHA256="848194851a98903134187fbb4ab50efe87b003e0c0f808f97644b7524a62bf2c"
MINIFORGE_URL="https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VERSION}/Miniforge3-Linux-x86_64.sh"

# Keep the same PDAL version used in the passing WSL acceptance runs.
PDAL_VERSION="2.3.0"

# Keep the same PotreeConverter version used in the passing WSL and live-sector
# acceptance runs. Pinning this is important for stable output representation.
POTREE_VERSION="2.1.1"
POTREE_SHA256="6ecf70d2156be36ebeed8b6dbe457e89531e7816aaba814531527288a84294f7"
POTREE_URL="https://github.com/potree/PotreeConverter/releases/download/${POTREE_VERSION}/PotreeConverter_${POTREE_VERSION}_x64_linux.zip"

TEMP_DIR=""
TARGET_USER=""
TARGET_GROUP=""
TARGET_HOME=""
CONDA_DIR=""
PDAL_ENV_DIR=""
POTREE_ROOT=""
POTREE_BUNDLE_DIR=""
POTREE_ENTRYPOINT=""

log() {
    printf '\n[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        case "$TEMP_DIR" in
            /tmp/lidar-lt-process-all-install.*)
                rm -rf -- "$TEMP_DIR"
                ;;
            *)
                printf 'WARNING: refusing to clean unexpected temporary path: %s\n' \
                    "$TEMP_DIR" >&2
                ;;
        esac
    fi
}

on_error() {
    local exit_code=$?
    printf 'ERROR: setup failed on line %s while running: %s\n' \
        "${BASH_LINENO[0]:-unknown}" "${BASH_COMMAND:-unknown}" >&2
    exit "$exit_code"
}

trap cleanup EXIT
trap on_error ERR

require_supported_host() {
    [[ -r /etc/os-release ]] || die "/etc/os-release is missing"

    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID:-}" == "ubuntu" ]] ||
        die "this installer supports Ubuntu only; detected: ${ID:-unknown}"
    [[ "${VERSION_ID:-}" == "26.04" ]] ||
        die "this installer is pinned for Ubuntu 26.04; detected: ${VERSION_ID:-unknown}"
    [[ "$(uname -m)" == "x86_64" ]] ||
        die "this installer requires x86_64; detected: $(uname -m)"
}

resolve_target_account() {
    if [[ "$EUID" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        TARGET_USER="$SUDO_USER"
    else
        TARGET_USER="$(id -un)"
    fi

    TARGET_GROUP="$(id -gn "$TARGET_USER")"
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

    [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] ||
        die "could not resolve a home directory for $TARGET_USER"

    CONDA_DIR="$TARGET_HOME/miniconda3"
    PDAL_ENV_DIR="$CONDA_DIR/envs/pdal"
    POTREE_ROOT="$TARGET_HOME/PotreeConverter"
    POTREE_BUNDLE_DIR="$POTREE_ROOT/releases/$POTREE_VERSION/PotreeConverter_linux_x64"
    POTREE_ENTRYPOINT="$POTREE_ROOT/build/PotreeConverter"
}

as_root() {
    if [[ "$EUID" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

as_target() {
    if [[ "$EUID" -eq 0 && "$TARGET_USER" != "root" ]]; then
        sudo -H -u "$TARGET_USER" env HOME="$TARGET_HOME" "$@"
    else
        env HOME="$TARGET_HOME" "$@"
    fi
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual

    actual="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] ||
        die "checksum mismatch for $file (expected $expected, got $actual)"
}

install_ubuntu_packages() {
    log "Installing Ubuntu runtime packages"

    if [[ "$EUID" -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 ||
            die "sudo is required when the installer is not run as root"
    fi

    as_root apt-get update
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        bash \
        bzip2 \
        ca-certificates \
        coreutils \
        curl \
        findutils \
        gawk \
        grep \
        jq \
        libstdc++6 \
        sed \
        unzip \
        wget \
        xz-utils
}

install_miniforge() {
    local installer="$TEMP_DIR/Miniforge3-Linux-x86_64.sh"

    if [[ -x "$CONDA_DIR/bin/conda" ]]; then
        log "Miniforge/Conda already present at $CONDA_DIR"
        return
    fi

    [[ ! -e "$CONDA_DIR" ]] ||
        die "$CONDA_DIR exists but does not contain an executable conda"

    log "Downloading pinned Miniforge $MINIFORGE_VERSION"
    curl --fail --location --retry 3 --output "$installer" "$MINIFORGE_URL"
    verify_sha256 "$installer" "$MINIFORGE_SHA256"
    chmod 755 "$installer"

    log "Installing Miniforge for $TARGET_USER"
    as_target bash "$installer" -b -p "$CONDA_DIR"
}

install_pdal() {
    local wrapper="$CONDA_DIR/bin/pdal"
    local wrapper_tmp="$TEMP_DIR/pdal-wrapper"

    if [[ ! -x "$PDAL_ENV_DIR/bin/pdal" ]]; then
        log "Installing pinned PDAL $PDAL_VERSION from Conda Forge"
        as_target "$CONDA_DIR/bin/conda" create \
            --yes \
            --name pdal \
            --channel conda-forge \
            --strict-channel-priority \
            "pdal=$PDAL_VERSION"
    else
        log "PDAL environment already present at $PDAL_ENV_DIR"
    fi

    [[ -x "$PDAL_ENV_DIR/bin/pdal" ]] ||
        die "PDAL was not installed at $PDAL_ENV_DIR/bin/pdal"

    if [[ -e "$wrapper" ]] &&
       ! grep -q 'Managed by install_process_all_dependencies.sh' "$wrapper"; then
        local existing_version
        existing_version="$("$wrapper" --version 2>/dev/null || true)"
        [[ "$existing_version" == *"$PDAL_VERSION"* ]] ||
            die "refusing to replace existing $wrapper ($existing_version)"
        log "Compatible PDAL already exposed in the Conda base bin directory"
        return
    fi

    cat > "$wrapper_tmp" <<'EOF'
#!/usr/bin/env bash
# Managed by install_process_all_dependencies.sh
set -uo pipefail

base_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
pdal_env="$base_dir/envs/pdal"

export PATH="$pdal_env/bin:$PATH"
export LD_LIBRARY_PATH="$pdal_env/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$pdal_env/bin/pdal" "$@"
EOF

    chmod 755 "$wrapper_tmp"
    as_target install -m 755 "$wrapper_tmp" "$wrapper"
}

install_potree_converter() {
    local archive="$TEMP_DIR/PotreeConverter_${POTREE_VERSION}_x64_linux.zip"
    local extract_dir="$TEMP_DIR/potree-extract"
    local entrypoint_tmp="$TEMP_DIR/PotreeConverter-wrapper"

    if [[ ! -x "$POTREE_BUNDLE_DIR/PotreeConverter" ]]; then
        log "Downloading pinned PotreeConverter $POTREE_VERSION"
        curl --fail --location --retry 3 --output "$archive" "$POTREE_URL"
        verify_sha256 "$archive" "$POTREE_SHA256"

        mkdir -p "$extract_dir"
        unzip -q "$archive" -d "$extract_dir"

        # GitHub's ZIP does not reliably restore the executable permission,
        # so validate the payload as a regular file and set the mode below.
        [[ -f "$extract_dir/PotreeConverter_linux_x64/PotreeConverter" ]] ||
            die "PotreeConverter archive has an unexpected layout"

        as_target mkdir -p "$POTREE_ROOT/releases/$POTREE_VERSION"
        [[ ! -e "$POTREE_BUNDLE_DIR" ]] ||
            die "incomplete PotreeConverter directory already exists: $POTREE_BUNDLE_DIR"

        as_root mv \
            "$extract_dir/PotreeConverter_linux_x64" \
            "$POTREE_BUNDLE_DIR"
        as_root chown -R "$TARGET_USER:$TARGET_GROUP" \
            "$POTREE_ROOT/releases/$POTREE_VERSION"
        as_target chmod 755 "$POTREE_BUNDLE_DIR/PotreeConverter"
    else
        log "PotreeConverter bundle already present at $POTREE_BUNDLE_DIR"
    fi

    if [[ -e "$POTREE_ENTRYPOINT" ]] &&
       ! grep -q 'Managed by install_process_all_dependencies.sh' \
           "$POTREE_ENTRYPOINT"; then
        die "refusing to replace existing PotreeConverter entrypoint: $POTREE_ENTRYPOINT"
    fi

    cat > "$entrypoint_tmp" <<EOF
#!/usr/bin/env bash
# Managed by install_process_all_dependencies.sh
set -uo pipefail

bundle_dir="$POTREE_BUNDLE_DIR"
export LD_LIBRARY_PATH="\$bundle_dir\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
cd "\$bundle_dir"
exec ./PotreeConverter "\$@"
EOF

    chmod 755 "$entrypoint_tmp"
    as_target mkdir -p "$POTREE_ROOT/build"
    as_target install -m 755 "$entrypoint_tmp" "$POTREE_ENTRYPOINT"
}

prepare_default_output_directory() {
    # process_all.sh intentionally retains process_one.sh's original default.
    if [[ ! -d /home/debian ]]; then
        as_root install -d -m 755 -o "$TARGET_USER" -g "$TARGET_GROUP" \
            /home/debian
    fi

    as_root install -d -m 755 -o "$TARGET_USER" -g "$TARGET_GROUP" \
        /home/debian/lt-lidar-data
}

verify_installation() {
    local pdal_version
    local potree_help="$TEMP_DIR/potree-help.txt"
    local command_name

    log "Verifying installed runtime"

    for command_name in bash curl find grep jq sort tr unzip wget xargs; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "required command is unavailable after installation: $command_name"
    done

    pdal_version="$(as_target "$CONDA_DIR/bin/pdal" --version)"
    [[ "$pdal_version" == *"$PDAL_VERSION"* ]] ||
        die "unexpected PDAL version: $pdal_version"

    as_target "$POTREE_ENTRYPOINT" --help > "$potree_help" 2>&1
    grep -q 'PotreeConverter <source> -o <outdir>' "$potree_help" ||
        die "PotreeConverter verification failed"

    [[ -w /home/debian/lt-lidar-data ]] ||
        die "default output directory is not writable"

    printf '\nInstalled and verified:\n'
    printf '  PDAL:            %s\n' "$pdal_version"
    printf '  PotreeConverter: %s\n' "$POTREE_ENTRYPOINT"
    printf '  Output directory: /home/debian/lt-lidar-data\n'
}

main() {
    require_supported_host
    resolve_target_account

    TEMP_DIR="$(mktemp -d /tmp/lidar-lt-process-all-install.XXXXXX)"
    chmod 755 "$TEMP_DIR"

    log "Target account: $TARGET_USER ($TARGET_HOME)"
    install_ubuntu_packages
    install_miniforge
    install_pdal
    install_potree_converter
    prepare_default_output_directory
    verify_installation

    printf '\nSetup complete. Run process_all.sh as %s.\n' "$TARGET_USER"
}

main "$@"
