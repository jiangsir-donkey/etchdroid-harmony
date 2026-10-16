#!/usr/bin/env bash
#
# EtchDroid for HarmonyOS - build helper.
#
#   ./build.sh hap            build the HAP with hvigor (unsigned)
#   ./build.sh sign           sign the HAP with the SDK's OpenHarmony test cert
#   ./build.sh all            hap, then sign
#   ./build.sh clean          remove build trees, dist/ and the ASCII mirror
#
# hvigor rejects project paths containing non-ASCII characters, and this project
# lives under "桌面", so the real build runs from an ASCII mirror in /tmp.
#
# The HarmonyOS command line tools are expected in
#   ~/downloads/commandline-tools-linux-x64-*/command-line-tools
# Override with HOS_CLI=/path/to/command-line-tools.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${HOS_CLI:-}" ]]; then
    HOS_CLI="$(ls -d "${HOME}"/downloads/commandline-tools-linux-x64-*/command-line-tools 2>/dev/null | tail -1)"
fi
if [[ -z "${HOS_CLI}" || ! -d "${HOS_CLI}" ]]; then
    echo "error: HarmonyOS command line tools not found. Set HOS_CLI=/path/to/command-line-tools" >&2
    exit 1
fi

export DEVECO_SDK_HOME="${HOS_CLI}/sdk"

BUNDLE_NAME="eu.depau.etchdroid.harmony"
KEYSTORE_DIR="${DEVECO_SDK_HOME}/default/openharmony/toolchains/lib"
KEYSTORE="${KEYSTORE_DIR}/OpenHarmony.p12"
KEYSTORE_PWD="123456"

MIRROR_ROOT="${ETCHDROID_MIRROR:-/tmp/etchdroid-harmony-hap}"
MIRROR_PROJECT="${MIRROR_ROOT}/etchdroid-harmony"
BUILD_MODE="${BUILD_MODE:-release}"

sync_mirror() {
    mkdir -p "${MIRROR_PROJECT}"
    tar -C "${PROJECT_DIR}" \
        --exclude=./build \
        --exclude=./dist \
        --exclude=./.hvigor \
        --exclude=./oh_modules \
        --exclude=./node_modules \
        --exclude=./entry/build \
        --exclude=./entry/.cxx \
        -cf - . | tar -C "${MIRROR_PROJECT}" -xf -
}

build_hap() {
    local out_dir="${PROJECT_DIR}/entry/build/default/outputs/default"
    local mirror_out="${MIRROR_PROJECT}/entry/build/default/outputs/default"

    sync_mirror
    ( cd "${MIRROR_PROJECT}" && "${HOS_CLI}/bin/hvigorw" \
        --mode module -p product=default -p buildMode="${BUILD_MODE}" \
        assembleHap --no-daemon )

    mkdir -p "${out_dir}"
    cp -f "${mirror_out}/"*.hap "${out_dir}/"
    echo "==> ${out_dir}"
}

sign_hap() {
    local unsigned="${PROJECT_DIR}/entry/build/default/outputs/default/entry-default-unsigned.hap"
    local work="${PROJECT_DIR}/build/sign"
    local dist="${PROJECT_DIR}/dist"

    if [[ ! -f "${unsigned}" ]]; then
        echo "error: ${unsigned} not found - run './build.sh hap' first" >&2
        exit 1
    fi

    rm -rf "${work}"
    mkdir -p "${work}" "${dist}"

    # The profile is the SDK's "unsigned release" template with our bundle name
    # and a widened validity window.  The leaf certificate has to come from the
    # template: the keystore entry holding the same public key is self-signed
    # and would not chain up to the OpenHarmony CA.
    ( cd "${work}" && python3 - "${KEYSTORE_DIR}" "${BUNDLE_NAME}" <<'PY'
import json, sys
keydir, bundle = sys.argv[1], sys.argv[2]
template = json.load(open(f"{keydir}/UnsgnedReleasedProfileTemplate.json"))
template["bundle-info"]["bundle-name"] = bundle
template["validity"] = {"not-before": 1577808000, "not-after": 2524608000}
json.dump(template, open("profile.json", "w"), indent=2)
open("app.cer", "w").write(template["bundle-info"]["distribution-certificate"])
PY
    )

    (
        cd "${work}"
        for alias in "openharmony application ca:ca.cer" "openharmony application root ca:root.cer"; do
            keytool -exportcert -rfc -alias "${alias%%:*}" -keystore "${KEYSTORE}" \
                -storepass "${KEYSTORE_PWD}" -storetype PKCS12 > "${alias##*:}"
        done
        cat app.cer ca.cer root.cer > app-chain.cer

        java -jar "${KEYSTORE_DIR}/hap-sign-tool.jar" sign-profile \
            -keyAlias "openharmony application profile release" -signAlg SHA256withECDSA \
            -mode localSign -profileCertFile "${KEYSTORE_DIR}/OpenHarmonyProfileRelease.pem" \
            -inFile profile.json -keystoreFile "${KEYSTORE}" -outFile etchdroid.p7b \
            -keyPwd "${KEYSTORE_PWD}" -keystorePwd "${KEYSTORE_PWD}"

        java -jar "${KEYSTORE_DIR}/hap-sign-tool.jar" sign-app \
            -keyAlias "openharmony application release" -signAlg SHA256withECDSA \
            -mode localSign -appCertFile app-chain.cer -profileFile etchdroid.p7b \
            -inFile "${unsigned}" -keystoreFile "${KEYSTORE}" \
            -outFile "${dist}/etchdroid-signed.hap" \
            -keyPwd "${KEYSTORE_PWD}" -keystorePwd "${KEYSTORE_PWD}"

        java -jar "${KEYSTORE_DIR}/hap-sign-tool.jar" verify-app \
            -inFile "${dist}/etchdroid-signed.hap" \
            -outCertChain out-chain.cer -outProfile out-profile.p7b
    )

    cp -f "${unsigned}" "${dist}/etchdroid-unsigned.hap"
    echo "==> ${dist}/etchdroid-signed.hap"
}

case "${1:-all}" in
    hap)   build_hap ;;
    sign)  sign_hap ;;
    all)   build_hap; sign_hap ;;
    clean) rm -rf "${PROJECT_DIR}/build" "${PROJECT_DIR}/dist" \
                  "${PROJECT_DIR}/entry/build" "${PROJECT_DIR}/.hvigor" "${MIRROR_ROOT}" ;;
    *)     echo "usage: $0 {hap|sign|all|clean}" >&2; exit 2 ;;
esac
