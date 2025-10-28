#!/bin/bash

umask 022

set -o errexit
set -o nounset
set -o pipefail

CURRENT_DIR=$(cd $(dirname $0); pwd)

# Load configs and helpers when available
if [ -f "$CURRENT_DIR/config.sh" ]; then
    # shellcheck disable=SC1091
    . "$CURRENT_DIR/config.sh"
fi
if [ -f "$CURRENT_DIR/scripts/common.sh" ]; then
    # shellcheck disable=SC1091
    . "$CURRENT_DIR/scripts/common.sh"
fi
if [ -f "$CURRENT_DIR/scripts/images.sh" ]; then
    # shellcheck disable=SC1091
    . "$CURRENT_DIR/scripts/images.sh"
fi

if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
fi

run() {
    echo "=> Running: $*"
    "$@"
}

ensure_dirs() {
    mkdir -p "$CURRENT_DIR/cache" "$CURRENT_DIR/outputs/files" "$CURRENT_DIR/outputs/images"
}

cmd_precheck() {
    if [ "${docker:-podman}" != "podman" ]; then
        if ! command -v "${docker}" >/dev/null 2>&1; then
            echo "No ${docker} installed"
            exit 1
        fi
    fi

    if [ -e /etc/redhat-release ] && [[ "${VERSION_ID:-}" =~ ^7.* ]]; then
        if [ "$(getenforce)" = "Enforcing" ]; then
            echo "You must disable SELinux for RHEL7/CentOS7"
            exit 1
        fi
    fi
}

cmd_prepare_pkgs() {
    echo "==> prepare-pkgs"
    # shellcheck disable=SC1091
    . "$CURRENT_DIR/target-scripts/pyver.sh"

    if [ -e /etc/redhat-release ]; then
        echo "==> Install required packages"
        $sudo dnf check-update || true
        $sudo dnf install -y rsync gcc libffi-devel createrepo git podman || exit 1

        case "${VERSION_ID}" in
            7*)
                echo "FATAL: RHEL/CentOS 7 is not supported anymore."
                exit 1
                ;;
            8*)
                if ! command -v repo2module >/dev/null; then
                    echo "==> Install modulemd-tools"
                    $sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
                    $sudo dnf copr enable -y frostyx/modulemd-tools-epel
                    $sudo dnf install -y modulemd-tools
                fi
                ;;
            9*)
                if ! command -v repo2module >/dev/null; then
                    $sudo dnf install -y modulemd-tools
                fi
                ;;
            10*)
                if ! command -v repo2module >/dev/null; then
                    $sudo dnf install -y createrepo_c
                fi
                ;;
            *)
                echo "Unknown VERSION_ID: ${VERSION_ID}"
                exit 1
                ;;
        esac

        $sudo dnf install -y python${PY} python${PY}-pip python${PY}-devel || exit 1
    else
        $sudo apt update
        if [ "${1:-}" = "--upgrade" ]; then
            $sudo apt -y upgrade
        fi
        $sudo apt -y install lsb-release curl gpg gcc libffi-dev rsync git software-properties-common || exit 1

        case "${VERSION_ID}" in
            20.04)
                echo "deb http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/ /" | $sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
                curl -SL https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable/xUbuntu_${VERSION_ID}/Release.key | $sudo apt-key add -
                sudo add-apt-repository ppa:deadsnakes/ppa -y || exit 1
                $sudo apt update
                ;;
        esac
        $sudo apt install -y python${PY} python${PY}-venv python${PY}-dev python3-pip python3-selinux podman || exit 1
    fi
}

cmd_prepare_py() {
    echo "==> prepare-py"
    # shellcheck disable=SC1091
    . "$CURRENT_DIR/target-scripts/venv.sh"
    # shellcheck disable=SC1091
    . "$CURRENT_DIR/scripts/set-locale.sh"
    echo "==> Update pip, etc"
    pip install -U pip setuptools
    echo "==> Install python packages"
    pip install -r "$CURRENT_DIR/requirements.txt"
}

cmd_kubespray_fetch() {
    echo "==> get-kubespray"
    KUBESPRAY_TARBALL="kubespray-${KUBESPRAY_VERSION}.tar.gz"
    KUBESPRAY_DIR="$CURRENT_DIR/cache/kubespray-${KUBESPRAY_VERSION}"

    ensure_dirs

    remove_kubespray_cache_dir() {
        if [ -e "${KUBESPRAY_DIR}" ]; then
            /bin/rm -rf "${KUBESPRAY_DIR}"
        fi
    }

    if [[ ${KUBESPRAY_VERSION} =~ ^[0-9a-f]{7,40}$ ]]; then
        remove_kubespray_cache_dir
        echo "===> Checkout kubespray commit: ${KUBESPRAY_VERSION}"
        git clone https://github.com/kubernetes-sigs/kubespray.git "${KUBESPRAY_DIR}"
        (cd "${KUBESPRAY_DIR}" && git checkout "${KUBESPRAY_VERSION}")
        tar czf "$CURRENT_DIR/outputs/files/${KUBESPRAY_TARBALL}" -C "$CURRENT_DIR/cache" "kubespray-${KUBESPRAY_VERSION}"
        return 0
    fi

    if [ "${KUBESPRAY_VERSION}" = "master" ] || [[ ${KUBESPRAY_VERSION} =~ ^release- ]]; then
        remove_kubespray_cache_dir
        echo "===> Checkout kubespray branch : ${KUBESPRAY_VERSION}"
        git clone -b "${KUBESPRAY_VERSION}" https://github.com/kubernetes-sigs/kubespray.git "${KUBESPRAY_DIR}"
        tar czf "$CURRENT_DIR/outputs/files/${KUBESPRAY_TARBALL}" -C "$CURRENT_DIR/cache" "kubespray-${KUBESPRAY_VERSION}"
        return 0
    fi

    if [ ! -e "$CURRENT_DIR/outputs/files/${KUBESPRAY_TARBALL}" ]; then
        echo "===> Download ${KUBESPRAY_TARBALL}"
        curl -SL "https://github.com/kubernetes-sigs/kubespray/archive/refs/tags/v${KUBESPRAY_VERSION}.tar.gz" >"$CURRENT_DIR/outputs/files/${KUBESPRAY_TARBALL}" || exit 1
        remove_kubespray_cache_dir
    fi

    if [ ! -e "${KUBESPRAY_DIR}" ]; then
        echo "===> Extract ${KUBESPRAY_TARBALL}"
        tar xzf "$CURRENT_DIR/outputs/files/${KUBESPRAY_TARBALL}"
        mv "kubespray-${KUBESPRAY_VERSION}" "${KUBESPRAY_DIR}"
        sleep 1
        patch_dir="$CURRENT_DIR/target-scripts/patches/${KUBESPRAY_VERSION}"
        if [ -d "$patch_dir" ]; then
            for patch in "$patch_dir"/*.patch; do
                echo "===> Apply patch $patch"
                (cd "$KUBESPRAY_DIR" && patch -p1 < "$patch")
            done
        fi
    fi
}

cmd_pypi_mirror() {
    echo "==> Create pypi mirror"
    if [ ! -d "$CURRENT_DIR/cache/kubespray-${KUBESPRAY_VERSION}" ]; then
        echo "No kubespray dir at $CURRENT_DIR/cache/kubespray-${KUBESPRAY_VERSION}"
        exit 1
    fi
    # shellcheck disable=SC1091
    . "$CURRENT_DIR/target-scripts/venv.sh"
    # shellcheck disable=SC1091
    . "$CURRENT_DIR/scripts/set-locale.sh"
    umask 022
    pip install -U pip python-pypi-mirror
    DEST="-d $CURRENT_DIR/outputs/pypi/files"
    PLATFORM="--platform manylinux2014_x86_64"
    REQ="$CURRENT_DIR/requirements.tmp"
    cp "$CURRENT_DIR/cache/kubespray-${KUBESPRAY_VERSION}/requirements.txt" "$REQ"
    echo "PyYAML" >> "$REQ"
    echo "ruamel.yaml" >> "$REQ"
    for pyver in 3.11 3.12; do
        echo "===> Download binary for python $pyver"
        pip download $DEST --only-binary :all: --python-version "$pyver" $PLATFORM -r "$REQ" || exit 1
    done
    /bin/rm "$REQ"
    echo "===> Download source packages"
    pip download $DEST --no-binary :all: -r "$CURRENT_DIR/cache/kubespray-${KUBESPRAY_VERSION}/requirements.txt"
    echo "===> Download pip, setuptools, wheel, etc"
    pip download $DEST pip setuptools wheel || exit 1
    pip download $DEST pip setuptools==40.9.0 || exit 1
    echo "===> Download additional packages"
    PKGS=selinux
    PKGS="$PKGS flit_core"
    PKGS="$PKGS cython<3"
    # shellcheck disable=SC2086
    pip download $DEST pip $PKGS || exit 1
    pypi-mirror create $DEST -m "$CURRENT_DIR/outputs/pypi"
}

generate_list() {
    local KDIR="$CURRENT_DIR/cache/kubespray-${KUBESPRAY_VERSION}"
    LANG=C /bin/bash "$KDIR/contrib/offline/generate_list.sh" || exit 1
}

get_url() {
    local url=$1
    local FILES_DIR="$CURRENT_DIR/outputs/files"
    local filename="${url##*/}"

    decide_relative_dir() {
        local u=$1
        local rdir
        rdir=$u
        rdir=$(echo "$rdir" | sed "s@.*/\(v[0-9.]*\)/.*/kube\(adm\|ctl\|let\)@kubernetes/\\1@g")
        rdir=$(echo "$rdir" | sed "s@.*/etcd-.*.tar.gz@kubernetes/etcd@")
        rdir=$(echo "$rdir" | sed "s@.*/cni-plugins.*.tgz@kubernetes/cni@")
        rdir=$(echo "$rdir" | sed "s@.*/crictl-.*.tar.gz@kubernetes/cri-tools@")
        rdir=$(echo "$rdir" | sed "s@.*/\(v.*\)/calicoctl-.*@kubernetes/calico/\\1@")
        rdir=$(echo "$rdir" | sed "s@.*/\(v.*\)/runc.amd64@runc/\\1@")
        rdir=$(echo "$rdir" | sed "s@.*/\(v.*\)/cilium-linux-.*@cilium-cli/\\1@")
        rdir=$(echo "$rdir" | sed "s@.*/\([^/]*\)/\([^/]*\)/runsc@gvisor/\\1/\\2@")
        rdir=$(echo "$rdir" | sed "s@.*/\([^/]*\)/\([^/]*\)/containerd-shim-runsc-v1@gvisor/\\1/\\2@")
        rdir=$(echo "$rdir" | sed "s@.*/\(v[^/]*\)/skopeo-linux-.*@skopeo/\\1@")
        rdir=$(echo "$rdir" | sed "s@.*/\(v[^/]*\)/yq_linux_*@yq/\\1@")
        if [ "$u" != "$rdir" ]; then
            echo "$rdir"
            return 0
        fi
        rdir=$(echo "$rdir" | sed "s@.*/calico/.*@kubernetes/calico@")
        if [ "$u" != "$rdir" ]; then
            echo "$rdir"
        else
            echo ""
        fi
    }

    local rdir
    rdir=$(decide_relative_dir "$url")
    if [ -n "$rdir" ]; then
        mkdir -p "$FILES_DIR/$rdir"
    else
        rdir="."
    fi

    if [ ! -e "$FILES_DIR/$rdir/$filename" ]; then
        echo "==> Download $url"
        local i
        for i in 1 2 3; do
            if curl --location --show-error --fail --output "$FILES_DIR/$rdir/$filename" "$url"; then
                return 0
            fi
            echo "curl failed. Attempt=$i"
        done
        echo "Download failed, exit : $url"
        exit 1
    else
        echo "==> Skip $url"
    fi
}

cmd_kubespray_files() {
    local KDIR="$CURRENT_DIR/cache/kubespray-${KUBESPRAY_VERSION}"
    if [ ! -e "$KDIR" ]; then
        echo "No kubespray dir at $KDIR"
        exit 1
    fi
    # shellcheck disable=SC1091
    . "$CURRENT_DIR/target-scripts/venv.sh"
    generate_list
    mkdir -p "$CURRENT_DIR/outputs/files"
    cp "$KDIR/contrib/offline/temp/files.list" "$CURRENT_DIR/outputs/files/"
    cp "$KDIR/contrib/offline/temp/images.list" "$IMAGES_DIR/"
    local f
    while read -r f; do
        [ -z "$f" ] && continue
        get_url "$f"
    done < "$CURRENT_DIR/outputs/files/files.list"
    cmd_images
}

cmd_images() {
    if [ "${SKIP_DOWNLOAD_IMAGES:-false}" = "true" ]; then
        return 0
    fi
    if [ ! -e "${IMAGES_DIR}/images.list" ]; then
        echo "${IMAGES_DIR}/images.list does not exist. Run kubespray-files first."
        exit 1
    fi
    while read -r img; do
        [ -z "$img" ] && continue
        get_image "$img"
    done < "${IMAGES_DIR}/images.list"
}

cmd_images_extra() {
    echo "==> Pull additional container images"
    umask 022
    cat "$CURRENT_DIR/imagelists"/*.txt | sed "s/#.*$//g" | sort -u > "$IMAGES_DIR/additional-images.list"
    cat "$IMAGES_DIR/additional-images.list"
    while read -r image; do
        [ -z "$image" ] && continue
        image=$(expand_image_repo "$image")
        get_image "$image"
    done < "$IMAGES_DIR/additional-images.list"
}

cmd_repo() {
    if [ -e /etc/redhat-release ]; then
        umask 022
        local REQUIRE_MODULE=false
        local VERSION_MAJOR=$VERSION_ID
        case "$VERSION_MAJOR" in
            8*) REQUIRE_MODULE=true; VERSION_MAJOR=8;;
            9*) REQUIRE_MODULE=true; VERSION_MAJOR=9;;
            10*) VERSION_MAJOR=10;;
            *) echo "Unsupported version: $VERSION_MAJOR" ;;
        esac
        local PKGS
        # shellcheck disable=SC2046
        PKGS=$(cat "$CURRENT_DIR/pkglist/rhel"/*.txt "$CURRENT_DIR/pkglist/rhel/${VERSION_MAJOR}"/*.txt | grep -v "^#" | sort | uniq)
        local CACHEDIR="$CURRENT_DIR/cache/cache-rpms"
        mkdir -p "$CACHEDIR"
        local RT="sudo dnf download --resolve --alldeps --downloaddir $CACHEDIR"
        echo "==> Downloading: $PKGS"
        # shellcheck disable=SC2086
        $RT $PKGS || { echo "Download error"; exit 1; }
        local RPMDIR="$CURRENT_DIR/outputs/rpms/local"
        if [ -e "$RPMDIR" ]; then /bin/rm -rf "$RPMDIR" || exit 1; fi
        mkdir -p "$RPMDIR"
        /bin/cp "$CACHEDIR"/*.rpm "$RPMDIR/"
        /bin/rm "$RPMDIR"/*.i686.rpm || true
        echo "==> createrepo"
        createrepo "$RPMDIR" || exit 1
        sleep 1
        if $REQUIRE_MODULE; then
            (cd "$RPMDIR" && LANG=C repo2module -s stable . modules.yaml && modifyrepo_c --mdtype=modules modules.yaml repodata/) || exit 1
        fi
        echo "create-repo done."
    else
        umask 022
        echo "===> Install prereqs"
        sudo apt update
        sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release apt-utils
        local PKGS
        # shellcheck disable=SC2046
        PKGS=$(cat "$CURRENT_DIR/pkglist/ubuntu"/*.txt "$CURRENT_DIR/pkglist/ubuntu/${VERSION_ID}"/*.txt | grep -v "^#" | sort | uniq)
        local CACHEDIR="$CURRENT_DIR/cache/cache-debs"
        mkdir -p "$CACHEDIR"
        echo "===> Update apt cache"
        sudo apt update
        echo "===> Resolving dependencies"
        # shellcheck disable=SC2086
        DEPS=$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances --no-pre-depends $PKGS | grep "^\w" | sort | uniq)
        echo "===> Downloading packages: $PKGS $DEPS"
        (cd "$CACHEDIR" && apt download $PKGS $DEPS)
        echo "===> Creating repo"
        local DEBDIR="$CURRENT_DIR/outputs/debs/local"
        if [ -e "$DEBDIR" ]; then /bin/rm -rf "$DEBDIR"; fi
        mkdir -p "$DEBDIR/pkgs"
        /bin/cp "$CACHEDIR"/* "$DEBDIR/pkgs" || true
        /bin/rm "$DEBDIR"/pkgs/*i386.deb || true
        pushd "$DEBDIR" >/dev/null || exit 1
        apt-ftparchive sources . > Sources && gzip -c9 Sources > Sources.gz
        apt-ftparchive packages . > Packages && gzip -c9 Packages > Packages.gz
        apt-ftparchive contents . > Contents-amd64 && gzip -c9 Contents-amd64 > Contents-amd64.gz
        apt-ftparchive release . > Release
        popd >/dev/null
        echo "Done."
    fi
}

cmd_copy_target() {
    echo "==> Copy target scripts"
    /bin/cp -f -r "$CURRENT_DIR/target-scripts/"* "$CURRENT_DIR/outputs/"
}

cmd_all() {
    run cmd_precheck
    run cmd_prepare_pkgs
    run cmd_prepare_py
    run cmd_kubespray_fetch
    if ${ansible_in_container:-false}; then
        run "$CURRENT_DIR/build-ansible-container.sh"
    else
        run cmd_pypi_mirror
    fi
    run cmd_kubespray_files
    run cmd_images_extra
    run cmd_repo
    run cmd_copy_target
    echo "Done."
}

usage() {
    cat <<'USAGE'
Usage: ./offline.sh <command> [args]

Commands:
  precheck            Run environment prechecks
  prepare-pkgs        Install required system packages
  prepare-py          Create venv and install Python deps
  kubespray-fetch     Download/checkout Kubespray and apply patches
  pypi-mirror         Build PyPI mirror artifacts for Kubespray
  kubespray-files     Generate and download files/images lists and artifacts
  images              Download images from images.list
  images-extra        Download images from imagelists/*.txt
  repo                Build local RPM/DEB repos
  copy-target         Copy target scripts to outputs/
  all                 Execute the full offline workflow
  help                Show this help
USAGE
}

main() {
    ensure_dirs
    local cmd=${1:-help}
    shift || true
    case "$cmd" in
        precheck)           cmd_precheck "$@";;
        prepare-pkgs)       cmd_prepare_pkgs "$@";;
        prepare-py)         cmd_prepare_py "$@";;
        kubespray-fetch)    cmd_kubespray_fetch "$@";;
        pypi-mirror)        cmd_pypi_mirror "$@";;
        kubespray-files)    cmd_kubespray_files "$@";;
        images)             cmd_images "$@";;
        images-extra)       cmd_images_extra "$@";;
        repo)               cmd_repo "$@";;
        copy-target)        cmd_copy_target "$@";;
        all)                cmd_all "$@";;
        help|-h|--help)     usage;;
        *)                  echo "Unknown command: $cmd"; echo; usage; exit 1;;
    esac
}

main "$@"


