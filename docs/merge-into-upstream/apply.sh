#!/usr/bin/env bash
#
# Build a merge-ready branch of EtchDroid/EtchDroid that adds this HarmonyOS port.
#
#   git clone https://github.com/EtchDroid/EtchDroid.git /tmp/EtchDroid
#   ./apply.sh /tmp/EtchDroid
#   cd /tmp/EtchDroid && git log --oneline && git push -u origin harmonyos-port
#
# The script:
#   1. verifies the target really is a clean upstream clone
#   2. creates branch `harmonyos-port` (override with BRANCH=...)
#   3. copies this port to harmonyos/, minus build output, docs/ and LICENSE
#   4. overlays the upstream-facing harmonyos/README.md and harmonyos/NOTICE
#   5. repoints the in-app source-code URL at the upstream tree
#   6. adds the "Other platforms" section to the top-level README.md
#   7. makes atomic commits in upstream's Conventional Commits style
#
# It never modifies the Android sources, and it never pushes.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_DIR="$(cd "${HERE}/../.." && pwd)"
UPSTREAM="${1:-}"
BRANCH="${BRANCH:-harmonyos-port}"
SOURCE_URL="${SOURCE_URL:-https://github.com/EtchDroid/EtchDroid/tree/main/harmonyos}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------- 1. target
if [ -z "${UPSTREAM}" ]; then
    die "usage: $0 /path/to/EtchDroid-clone"
fi
if [ ! -d "${UPSTREAM}" ]; then
    die "not a directory: ${UPSTREAM}"
fi
UPSTREAM="$(cd "${UPSTREAM}" && pwd)"

if [ ! -d "${UPSTREAM}/.git" ]; then
    die "${UPSTREAM} is not a git clone (no .git directory). Clone the upstream repo first."
fi
for marker in app settings.gradle.kts CONTRIBUTING.md README.md LICENSE; do
    if [ ! -e "${UPSTREAM}/${marker}" ]; then
        die "${UPSTREAM} does not look like EtchDroid (missing ${marker})"
    fi
done
if [ -e "${UPSTREAM}/harmonyos" ]; then
    die "${UPSTREAM}/harmonyos already exists; start from a clean clone"
fi
if [ -n "$(git -C "${UPSTREAM}" status --porcelain)" ]; then
    die "${UPSTREAM} has uncommitted changes; commit or stash them first"
fi

# ---------------------------------------------------------------- 2. branch
step "creating branch ${BRANCH}"
git -C "${UPSTREAM}" checkout -B "${BRANCH}"

# ------------------------------------------------------------- 3. copy port
# docs/ is deliberately left behind: it holds the author's AppGallery checklist
# and permission paperwork, neither of which belongs in upstream.
# LICENSE is left behind too: it is byte-identical to the repository root one.
step "copying the port into harmonyos/"
mkdir -p "${UPSTREAM}/harmonyos"
tar -C "${PORT_DIR}" \
    --exclude=./build \
    --exclude=./dist \
    --exclude=./.git \
    --exclude=./.hvigor \
    --exclude=./oh_modules \
    --exclude=./node_modules \
    --exclude=./entry/build \
    --exclude=./entry/.cxx \
    --exclude=./docs \
    --exclude=./LICENSE \
    -cf - . | tar -xf - -C "${UPSTREAM}/harmonyos"

# ---------------------------------------------------------------- 4. overlay
step "installing the upstream-facing README.md and NOTICE"
cp "${HERE}/harmonyos/README.md" "${UPSTREAM}/harmonyos/README.md"
cp "${HERE}/harmonyos/NOTICE"    "${UPSTREAM}/harmonyos/NOTICE"

# ------------------------------------------------- 5. in-app source-code URL
step "pointing the in-app source link at ${SOURCE_URL}"
sed -i "s|^const SOURCE_REPO_URL = .*|const SOURCE_REPO_URL = '${SOURCE_URL}';|" \
    "${UPSTREAM}/harmonyos/entry/src/main/ets/pages/Index.ets"
if ! grep -q "SOURCE_REPO_URL = '${SOURCE_URL}';" \
        "${UPSTREAM}/harmonyos/entry/src/main/ets/pages/Index.ets"; then
    die "could not rewrite SOURCE_REPO_URL in Index.ets"
fi

# ---------------------------------------------------------- 6. root README
step "adding the \"Other platforms\" section to the top-level README.md"
python3 - "${UPSTREAM}/README.md" "${HERE}/README.section.md" <<'PY'
import sys

readme_path, section_path = sys.argv[1], sys.argv[2]
with open(readme_path, encoding="utf-8") as fh:
    lines = fh.readlines()
with open(section_path, encoding="utf-8") as fh:
    section = fh.read().rstrip("\n") + "\n"

if "Other platforms" in "".join(lines):
    sys.exit("upstream README already has an \"Other platforms\" section")

anchor = next(
    (i for i, line in enumerate(lines) if line.startswith("## Support the project")),
    None,
)
if anchor is None:
    sys.exit("could not find the \"## Support the project\" anchor in README.md")

lines[anchor:anchor] = [section, "\n"]
with open(readme_path, "w", encoding="utf-8") as fh:
    fh.writelines(lines)
print("inserted before line", anchor + 1)
PY

# ------------------------------------------------------------- 7. commits
step "committing"
gitc() {
    local msg="$1"
    shift
    git -C "${UPSTREAM}" add -- "$@"
    git -C "${UPSTREAM}" commit -q -m "${msg}"
    printf '  %s\n' "${msg}"
}

gitc "chore(harmonyos): add hvigor project scaffolding" \
    harmonyos/.gitignore harmonyos/build.sh harmonyos/build-profile.json5 \
    harmonyos/hvigorfile.ts harmonyos/hvigor harmonyos/oh-package.json5 \
    harmonyos/entry/build-profile.json5 harmonyos/entry/hvigorfile.ts \
    harmonyos/entry/oh-package.json5 \
    harmonyos/AppScope/app.json5 harmonyos/AppScope/resources/base/element

gitc "feat(harmonyos): implement SCSI bulk-only transport mass storage stack" \
    harmonyos/entry/src/main/ets/massstorage harmonyos/entry/src/main/ets/exceptions

gitc "feat(harmonyos): add image writer UI, worker and background task" \
    harmonyos/entry/src/main/ets harmonyos/entry/src/main/module.json5 \
    harmonyos/entry/src/main/resources/base/element \
    harmonyos/entry/src/main/resources/base/profile

gitc "feat(harmonyos): add a Simplified Chinese localization" \
    harmonyos/AppScope/resources/zh_CN harmonyos/entry/src/main/resources/zh_CN

gitc "docs(harmonyos): document the port and its provenance" \
    harmonyos/README.md harmonyos/NOTICE harmonyos/design

gitc "chore(harmonyos): ship the upstream app icon with the HarmonyOS port" \
    harmonyos/AppScope/resources/base/media harmonyos/entry/src/main/resources/base/media

gitc "docs(readme): mention the unofficial HarmonyOS port" README.md

# ------------------------------------------------------------- 8. checks
step "verifying the branch"
stray="$(git -C "${UPSTREAM}" status --porcelain)"
if [ -n "${stray}" ]; then
    printf '%s\n' "${stray}"
    die "files were left uncommitted (see above)"
fi

tracked_build="$(git -C "${UPSTREAM}" ls-files harmonyos | grep -E '(^|/)(build|dist)/' || true)"
if [ -n "${tracked_build}" ]; then
    printf '%s\n' "${tracked_build}"
    die "build output was committed (see above)"
fi

count="$(git -C "${UPSTREAM}" ls-files harmonyos | wc -l)"
printf '\n  %s files under harmonyos/, none of them build output\n' "${count}"
git -C "${UPSTREAM}" log --oneline -7

cat <<EOF

Done. Next:

  cd ${UPSTREAM}
  git push -u origin ${BRANCH}

Then open a pull request and paste the body from:
  ${HERE}/PR.md

Remember to fill in the issue number and your GitHub username in PR.md and in
harmonyos/README.md before pushing.
EOF
