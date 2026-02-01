#!/usr/bin/env bash
set -euo pipefail
# euler/build.sh - openEuler Build Script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(dirname "$SCRIPT_DIR")"
# Load configuration
CONFIG_FILE="${SCRIPT_DIR}/.configure"
DISTRO_CONFIG="${WORKDIR}/.distro_config"
if [ ! -f "${CONFIG_FILE}" ]; then
  echo "Error: Configuration file not found. Run 'make config' first." >&2
  exit 1
fi
# shellcheck disable=SC1090
. "${CONFIG_FILE}"
if [ -f "${DISTRO_CONFIG}" ]; then
  . "${DISTRO_CONFIG}"
fi
# Directories
PATCHES_DIR="${WORKDIR}/patches"
BKP_DIR="${PATCHES_DIR}/.bkp"
LOGS_DIR="${WORKDIR}/logs"
HEAD_ID_FILE="${WORKDIR}/.head_commit_id"
# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
: "${LINUX_SRC_PATH:?missing in config}"
: "${SIGNER_NAME:?missing in config}"
: "${SIGNER_EMAIL:?missing in config}"
: "${BUGZILLA_ID:?missing in config}"
: "${PATCH_CATEGORY:?missing in config}"
: "${NUM_PATCHES:?missing in config}"
: "${BUILD_THREADS:=4}"
: "${TORVALDS_REPO:?missing in config}"
mkdir -p "${PATCHES_DIR}" "${BKP_DIR}" "${LOGS_DIR}"
# Validate repo
if [ ! -d "${LINUX_SRC_PATH}/.git" ]; then
  echo -e "${RED}Linux source path is not a git repo: ${LINUX_SRC_PATH}${NC}" >&2
  exit 10
fi
cd "${LINUX_SRC_PATH}"
# Handle dubious ownership issue
if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: Git detected dubious ownership in repository${NC}" >&2
        echo -e "${YELLOW}Attempting to add safe.directory exception...${NC}" >&2
        git config --global --add safe.directory "${LINUX_SRC_PATH}" 2>/dev/null || {
                echo -e "${RED}Failed to add safe.directory exception${NC}" >&2
                echo -e "${RED}Please run manually: git config --global --add safe.directory ${LINUX_SRC_PATH}${NC}" >&2
                exit 12
        }
        echo -e "${GREEN}Safe directory exception added successfully${NC}" >&2
fi
TOTAL_COMMITS="$(git rev-list --count HEAD 2>/dev/null || true)"
if [ -z "${TOTAL_COMMITS}" ] || [ "${TOTAL_COMMITS}" -lt "${NUM_PATCHES}" ]; then
  echo -e "${RED}Repo has insufficient commits (${TOTAL_COMMITS}) for NUM_PATCHES=${NUM_PATCHES}${NC}" >&2
  exit 11
fi
# Function to extract and expand upstream commit ID from patch
extract_upstream_commit() {
  local patch_file="$1"
  local auto_update="${2:-true}"  # Auto-update patch file by default

  # Look for "commit <hash> upstream" pattern or just "commit <hash>"
  local commit_id=$(grep -oP '(?<=commit )[a-f0-9]{7,40}(?= upstream)' "$patch_file" 2>/dev/null | head -1)
  if [ -z "$commit_id" ]; then
    commit_id=$(grep -oP '(?<=^commit )[a-f0-9]{7,40}' "$patch_file" 2>/dev/null | head -1)
  fi

  # If commit ID found and it's less than 40 characters, expand it
  if [ -n "$commit_id" ] && [ ${#commit_id} -lt 40 ]; then
    local short_id="$commit_id"
    local full_commit_id

    cd "$TORVALDS_REPO" || return 1
    full_commit_id=$(git rev-parse --verify "${commit_id}^{commit}" 2>/dev/null)
    local git_exit_code=$?
    cd - >/dev/null || return 1

    if [ $git_exit_code -eq 0 ] && [ -n "$full_commit_id" ] && [ ${#full_commit_id} -eq 40 ]; then
      commit_id="$full_commit_id"

      # Update the patch file with full commit ID
      if [ "$auto_update" = "true" ]; then
        sed -i "s/${short_id}/${full_commit_id}/g" "$patch_file"
      fi
    else
      echo -e "${YELLOW}  Warning: Could not expand short commit ID ${short_id} to full SHA${NC}" >&2
    fi
  fi

  echo "$commit_id"
}

# Function to get tag version from commit
get_tag_version() {
  local commit_id="$1"
  cd "$TORVALDS_REPO"
  local tag=$(git describe --contains "$commit_id" 2>/dev/null | sed 's/~.*//' | sed 's/\^.*//')
  if [ -z "$tag" ]; then
    tag=$(git describe --tags "$commit_id" 2>/dev/null | sed 's/-.*//')
  fi
  if [ -z "$tag" ]; then
    echo "mainline"
  else
    echo "$tag"
  fi
  cd - >/dev/null
}

# Function to check if patch is KABI fix
is_kabi_fix_patch() {
  local patch_file="$1"
  local upstream_commit=$(extract_upstream_commit "${patch_file}" "false")
  local subject=$(grep "^Subject:" "${patch_file}" | head -1 | sed 's/^Subject: //')
  # Check if no upstream commit and subject contains KABI/kabi
  if [ -z "${upstream_commit}" ] && [[ "${subject}" =~ KABI|kabi|KAPI|kapi ]]; then
    return 0  # Is KABI fix
  fi
  return 1  # Not KABI fix
}

# Function to update check-kabi script (one-time operation)
update_check_kabi_script() {
  local check_kabi_script="${LINUX_SRC_PATH}/scripts/check-kabi"
  local update_kabi_py="${SCRIPT_DIR}/update-kabi.py"
  local kabi_marker="${LINUX_SRC_PATH}/scripts/.check-kabi-updated"
  # Check if already updated
  if [ -f "${kabi_marker}" ]; then
    return 0
  fi
  # Check if update script exists
  if [ ! -f "${update_kabi_py}" ]; then
    echo -e "${RED}Error: update-kabi.py not found at ${update_kabi_py}${NC}"
    return 1
  fi
  echo -e "${BLUE}Updating check-kabi script for Python 3 (one-time operation)...${NC}"
  # Run 2to3
  2to3 -w -n -f print "${check_kabi_script}" > /dev/null 2>&1
  # Run update script
  python3 "${update_kabi_py}" "${check_kabi_script}" > /dev/null 2>&1
  # Create marker file
  touch "${kabi_marker}"
  echo -e "${GREEN}✓ check-kabi script updated${NC}"
}

# Function to perform KABI check
check_kabi() {
  local patch_file="$1"
  local patch_name=$(basename "${patch_file}")
  local kabi_log="${LOGS_DIR}/kabi_check.log"
  local check_kabi_script="${LINUX_SRC_PATH}/scripts/check-kabi"
  cd "${LINUX_SRC_PATH}"
  # Check if Module.symvers_old exists (baseline)
  if [ ! -f "Module.symvers_old" ]; then
    echo "  → No baseline Module.symvers_old found, skipping KABI check" >> "${kabi_log}"
    return 0
  fi
  # Check if check-kabi script exists
  if [ ! -f "${check_kabi_script}" ]; then
    echo "  → check-kabi script not found, skipping KABI check" >> "${kabi_log}"
    return 0
  fi
  # Run KABI check
  echo "" >> "${kabi_log}"
  echo "KABI Check for: ${patch_name}" >> "${kabi_log}"
  echo "----------------------------------------" >> "${kabi_log}"
  local kabi_output=$(python3 "${check_kabi_script}" -k Module.symvers_old -s Module.symvers 2>&1)
  echo "${kabi_output}" >> "${kabi_log}"
  # Check for ABI breakage
  if echo "${kabi_output}" | grep -q "ERROR - ABI BREAKAGE WAS DETECTED"; then
    echo "  → KABI breakage detected!" >> "${kabi_log}"
    return 1
  else
    echo "  → No KABI breakage" >> "${kabi_log}"
    return 0
  fi
}

# Save current HEAD id for later reset (full SHA)
cd "${LINUX_SRC_PATH}"
HEAD_ID="$(git rev-parse --verify HEAD)"
printf "%s\n" "${HEAD_ID}" > "${HEAD_ID_FILE}"
echo -e "${BLUE}Saved HEAD commit: ${HEAD_ID}${NC}"
TMP_FORMAT_DIR="$(mktemp -d "${WORKDIR}/formatpatches.XXXX")"
echo -e "${BLUE}Generating ${NUM_PATCHES} patches...${NC}"
git -c core.quiet=true format-patch -${NUM_PATCHES} -o "${TMP_FORMAT_DIR}" "HEAD~${NUM_PATCHES}..HEAD" >/dev/null 2>&1 || {
  git format-patch -${NUM_PATCHES} -o "${TMP_FORMAT_DIR}" "HEAD~${NUM_PATCHES}..HEAD"
}

# Backup existing patches and move new ones
mkdir -p "${BKP_DIR}"
for ex in "${PATCHES_DIR}"/*.patch; do
  [ -f "${ex}" ] || continue
  cp -f "${ex}" "${BKP_DIR}/$(basename "${ex}").bak-$(date +%s)"
done
rm -f "${PATCHES_DIR}"/*.patch || true
mv "${TMP_FORMAT_DIR}"/*.patch "${PATCHES_DIR}/" 2>/dev/null || true
rm -rf "${TMP_FORMAT_DIR}"

# Reset repo back by NUM_PATCHES commits so we can re-apply
git reset --hard "HEAD~${NUM_PATCHES}" >/dev/null 2>&1 || true
echo -e "${YELLOW}HEAD is now at $(git rev-parse --short HEAD) $(git log -1 --pretty=%s)${NC}"
echo -e "${BLUE}Modifying patches with openEuler metadata and Signed-off-by tags...${NC}"

# Modify patches in-place with required formatting
for p in "${PATCHES_DIR}"/*.patch; do
  [ -f "${p}" ] || continue
  cp -f "${p}" "${BKP_DIR}/$(basename "${p}")"
  # Check if this is a KABI fix patch
  if is_kabi_fix_patch "${p}"; then
    # Insert KABI fix header after Subject
    awk -v CAT="$PATCH_CATEGORY" -v BZ="$BUGZILLA_ID" '
      BEGIN { in_sub=0; printed_header=0 }
      {
        if (!in_sub) {
          print $0
          if ($0 ~ /^Subject:/) { in_sub=1; next }
        } else if (in_sub && !printed_header) {
          if ($0 ~ /^$/) {
            print ""
            print "virt inclusion"
            print "category: " CAT
            print "bugzilla: https://atomgit.com/openeuler/kernel/issues/" BZ
            print ""
            print "--------------------------------"
            print ""
            printed_header=1
            next
          } else {
            print $0
            next
          }
        } else {
          print $0
        }
      }
      END {
        if (in_sub && !printed_header) {
          print ""
          print "virt inclusion"
          print "category: " CAT
          print "bugzilla: https://atomgit.com/openeuler/kernel/issues/" BZ
          print ""
          print "--------------------------------"
          print ""
        }
      }' "${p}" > "${p}.tmp" && mv "${p}.tmp" "${p}"
  else
    # Extract upstream commit from patch content and expand if needed
    upstream_commit=$(extract_upstream_commit "${p}")
    if [ -n "$upstream_commit" ]; then
      # Get tag version from Torvalds repo
      tag_version=$(get_tag_version "$upstream_commit")
      # Insert openEuler header after Subject
      awk -v TAG="$tag_version" -v COMMIT="$upstream_commit" -v CAT="$PATCH_CATEGORY" -v BZ="$BUGZILLA_ID" '
        BEGIN { in_sub=0; printed_header=0 }
        {
          if (!in_sub) {
            print $0
            if ($0 ~ /^Subject:/) { in_sub=1; next }
          } else if (in_sub && !printed_header) {
            if ($0 ~ /^$/) {
              print ""
              print "mainline inclusion"
              print "from mainline-" TAG
              print "commit " COMMIT
              print "category: " CAT
              print "bugzilla: https://atomgit.com/openeuler/kernel/issues/" BZ
              print "CVE: NA"
              print ""
              print "Reference: https://github.com/torvalds/linux/commit/" COMMIT
              print ""
              print "--------------------------------"
              print ""
              printed_header=1
              next
            } else {
              print $0
              next
            }
          } else {
            print $0
          }
        }
        END {
          if (in_sub && !printed_header) {
            print ""
            print "mainline inclusion"
            print "from mainline-" TAG
            print "commit " COMMIT
            print "category: " CAT
            print "bugzilla: https://atomgit.com/openeuler/kernel/issues/" BZ
            print "CVE: NA"
            print ""
            print "Reference: https://github.com/torvalds/linux/commit/" COMMIT
            print ""
            print "--------------------------------"
            print ""
          }
        }' "${p}" > "${p}.tmp" && mv "${p}.tmp" "${p}"
    fi
  fi
  # Insert Signed-off-by before first '---'
  SOB_LINE="Signed-off-by: ${SIGNER_NAME} <${SIGNER_EMAIL}>"
  if ! grep -qF "${SOB_LINE}" "${p}"; then
  awk -v SOB="Signed-off-by: ${SIGNER_NAME} <${SIGNER_EMAIL}>" '
    BEGIN { inserted=0 }
    {
      if (!inserted && $0 ~ /^---$/) {
        print SOB
        inserted=1
      }
      print $0
    }
    END {
      if (!inserted) {
        print ""
        print SOB
      }
    }' "${p}" > "${p}.tmp" && mv "${p}.tmp" "${p}"
  fi
done

# Ensure repo clean
if [ -n "$(git status --porcelain)" ]; then
  echo -e "${RED}Linux source tree is not clean. Commit or stash changes before running.${NC}" >&2
  exit 12
fi

git config user.name "${SIGNER_NAME}"
git config user.email "${SIGNER_EMAIL}"

# Collect patch filenames in lexical order
mapfile -t PATCH_LIST < <(ls -1 "${PATCHES_DIR}"/*.patch 2>/dev/null || true)
TOTAL_SELECTED="${#PATCH_LIST[@]}"
if [ "${TOTAL_SELECTED}" -eq 0 ]; then
  echo -e "${RED}No patches found in ${PATCHES_DIR}${NC}" >&2
  exit 13
fi
echo ""
echo -e "Total patches to process: ${TOTAL_SELECTED}"
echo -e "Build threads: ${BUILD_THREADS}"
echo ""
# Build baseline for KABI checking
echo -e "${BLUE}Building baseline for KABI check...${NC}"
cd "${LINUX_SRC_PATH}"
make clean > /dev/null 2>&1
if make openeuler_defconfig > /dev/null 2>&1 && make -j"${BUILD_THREADS}" modules > /dev/null 2>&1; then
  if [ -f "Module.symvers" ]; then
    cp Module.symvers Module.symvers_old
    echo -e "${GREEN}✓ Baseline Module.symvers created${NC}"
    # Update check-kabi script (one-time)
    update_check_kabi_script
  else
    echo -e "${YELLOW}⚠ Module.symvers not created, KABI checks will be skipped${NC}"
  fi
else
  echo -e "${YELLOW}⚠ Baseline build failed, KABI checks will be skipped${NC}"
fi
echo ""

# Apply all patches and check KABI for each
summary=()
kabi_summary=()
idx=0
kabi_failed=0
for pf in "${PATCH_LIST[@]}"; do
  idx=$((idx+1))
  name="$(basename "${pf}")"
  echo -e "${BLUE}[${idx}/${TOTAL_SELECTED}] Processing: ${name}${NC}"
  # Apply patch
  if git -C "${LINUX_SRC_PATH}" am --3way "${pf}" >/dev/null 2>&1; then
    echo -e "  Applying   : ${GREEN}✓ PASS${NC}"
    summary+=( "${name}:PASS" )
  else
    git -C "${LINUX_SRC_PATH}" am --abort >/dev/null 2>&1 || true
    echo -e "  Applying   : ${RED}✗ FAIL${NC}"
    echo ""
    echo -e "${RED}Error: git am failed for ${name}${NC}"
    exit 20
  fi
  # Build modules for KABI check (quick module build only)
  if [ -f "${LINUX_SRC_PATH}/Module.symvers_old" ]; then
    echo -e "  Building modules for KABI check..."
    cd "${LINUX_SRC_PATH}"
    if make modules -j"${BUILD_THREADS}" > /dev/null 2>&1; then
      # KABI check
      if check_kabi "${pf}"; then
        echo -e "  KABI Check : ${GREEN}✓ PASS${NC}"
        kabi_summary+=( "${name}:PASS" )
      else
        # Check if this is a KABI fix patch
        if is_kabi_fix_patch "${pf}"; then
          echo -e "  KABI Check : ${YELLOW}⚠ KABI Fix Patch${NC}"
          kabi_summary+=( "${name}:KABI_FIX" )
        else
          # Check if next patch is KABI fix
          next_idx=${idx}
          if [ ${next_idx} -lt ${TOTAL_SELECTED} ]; then
            next_pf="${PATCH_LIST[$next_idx]}"
            if is_kabi_fix_patch "${next_pf}"; then
              echo -e "  KABI Check : ${YELLOW}⚠ WARN (Next patch is KABI fix)${NC}"
              kabi_summary+=( "${name}:WARN_HAS_FIX" )
            else
              echo -e "  KABI Check : ${RED}✗ FAIL${NC}"
              kabi_summary+=( "${name}:FAIL" )
              kabi_failed=1
            fi
          else
            echo -e "  KABI Check : ${RED}✗ FAIL${NC}"
            kabi_summary+=( "${name}:FAIL" )
            kabi_failed=1
          fi
        fi
      fi
      # Update baseline for next iteration
      cp "${LINUX_SRC_PATH}/Module.symvers" "${LINUX_SRC_PATH}/Module.symvers_old"
    else
      echo -e "  KABI Check : ${YELLOW}⚠ SKIP (module build failed)${NC}"
    fi
  fi
  echo ""
done

# Final full build after all patches are applied
echo ""
echo -e "${YELLOW}All patches applied. Starting final build...${NC}"
cd "${LINUX_SRC_PATH}"
logfile="${LOGS_DIR}/final_build.log"
echo "openEuler Final Build Log" > "${logfile}"
echo "Build started at: $(date)" >> "${logfile}"
echo "" >> "${logfile}"
echo -e "${BLUE}Running: make clean${NC}" >> "${logfile}"
make clean >> "${logfile}" 2>&1
echo -e "${BLUE}Running: make openeuler_defconfig${NC}" >> "${logfile}"
if ! make openeuler_defconfig >> "${logfile}" 2>&1; then
  echo -e "${RED}✗ Configuration failed${NC}"
  echo -e "${YELLOW}Refer to the log: ${logfile}${NC}"
  exit 21
fi
echo -e "${BLUE}Running: make -j${BUILD_THREADS}${NC}" >> "${logfile}"
if ! make -j"${BUILD_THREADS}" >> "${logfile}" 2>&1; then
  echo -e "${RED}✗ Kernel build failed${NC}"
  echo -e "${YELLOW}Refer to the log: ${logfile}${NC}"
  exit 21
fi
echo -e "${BLUE}Running: make modules -j${BUILD_THREADS}${NC}" >> "${logfile}"
if ! make modules -j"${BUILD_THREADS}" >> "${logfile}" 2>&1; then
  echo -e "${RED}✗ Module build failed${NC}"
  echo -e "${YELLOW}Refer to the log: ${logfile}${NC}"
  exit 21
fi
echo ""
echo -e "${GREEN}✓ Final build completed successfully${NC}"
echo ""

# Final summary
if [ ${kabi_failed} -eq 1 ]; then
  echo -e "${RED}⚠ Build completed but with KABI failures${NC}"
  echo -e "${YELLOW}Review KABI log: ${LOGS_DIR}/kabi_check.log${NC}"
  exit 22
else
  echo -e "${GREEN}✓ openEuler build process completed successfully${NC}"
  echo -e "Run ${YELLOW}'make test'${NC} to execute openEuler-specific tests"
  exit 0
fi
