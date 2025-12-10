#!/usr/bin/env bash
set -uo pipefail

# euler/test.sh - openEuler CI Test Suite

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(dirname "$SCRIPT_DIR")"

# Load configuration
CONFIG_FILE="${SCRIPT_DIR}/.configure"
DISTRO_CONFIG="${WORKDIR}/.distro_config"

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "Error: Configuration file not found: ${CONFIG_FILE}" >&2
  echo "Run 'make config' first." >&2
  exit 1
fi

# shellcheck disable=SC1090
. "${CONFIG_FILE}"

if [ -f "${DISTRO_CONFIG}" ]; then
  . "${DISTRO_CONFIG}"
fi

PATCHES_DIR="${WORKDIR}/patches"
LOGS_DIR="${WORKDIR}/logs"
TEST_LOG="${LOGS_DIR}/test_results.log"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

: "${LINUX_SRC_PATH:?missing in config}"
: "${SIGNER_NAME:?missing in config}"
: "${SIGNER_EMAIL:?missing in config}"
: "${TORVALDS_REPO:?missing in config}"

mkdir -p "${LOGS_DIR}"

echo ""

# Counters
TEST_RESULTS=()
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

if [ $(arch) == "x86_64" ]; then
  kernel_arch="x86"
elif [ $(arch) == "aarch64" ]; then
  kernel_arch="arm64"
else
  echo -e "${RED}Error: Not supported arch${NC}"
  exit 1
fi

pass() {
  local test_name="$1"
  echo -e "${GREEN}✓ PASS${NC}: ${test_name}"
  TEST_RESULTS+=("PASS:${test_name}")
  ((PASSED_TESTS++))
  ((TOTAL_TESTS++))
}

fail() {
  local test_name="$1"
  local reason="${2:-}"
  echo -e "${RED}✗ FAIL${NC}: ${test_name}"
  [ -n "$reason" ] && echo -e "  Reason: ${reason}"
  TEST_RESULTS+=("FAIL:${test_name}")
  ((FAILED_TESTS++))
  ((TOTAL_TESTS++))
}

skip() {
  local test_name="$1"
  local reason="${2:-}"
  echo -e "${YELLOW}⊘ SKIP${NC}: ${test_name}"
  [ -n "$reason" ] && echo -e "  Reason: ${reason}"
  TEST_RESULTS+=("SKIP:${test_name}")
  ((SKIPPED_TESTS++))
  ((TOTAL_TESTS++))
}

# Common function to build kernel with given config target
run_kernel_build() {
  local test_name="$1"
  local config_target="$2"
  cd "${LINUX_SRC_PATH}"

  make clean > /dev/null 2>&1
  echo "  → Building kernel with ${config_target}..."
  if make "${config_target}" > "${LOGS_DIR}/${test_name}.log" 2>&1 \
    && make -j"$(nproc)" >> "${LOGS_DIR}/${test_name}.log" 2>&1 \
    && make modules -j"$(nproc)" >> "${LOGS_DIR}/${test_name}.log" 2>&1; then
    pass "${test_name}"
  else
    fail "${test_name}" "Build failed (see ${LOGS_DIR}/${test_name}.log)"
  fi
  echo ""
}

# ---- TEST DEFINITIONS ----

test_check_dependency() {
  echo -e "${BLUE}Test-1: check_dependency${NC}"

  cd "${LINUX_SRC_PATH}"

  # Get list of applied commits (those that are ahead of the reset point)
  local applied_commits=()
  mapfile -t applied_commits < <(git log --format=%H HEAD | head -n "${NUM_PATCHES:-10}")

  if [ ${#applied_commits[@]} -eq 0 ]; then
    skip "check_dependency" "No commits to check"
    echo ""
    return
  fi

  echo "  → Checking ${#applied_commits[@]} commits for dependencies..."

  local commits_file="${SCRIPT_DIR}/.commits.txt"
  local dep_log="${LOGS_DIR}/check_dependency.log"
  local checkdepend_script="${WORKDIR}/euler/checkdepend.py"

  # Check if checkdepend.py exists
  if [ ! -f "${checkdepend_script}" ]; then
    fail "check_dependency" "checkdepend.py not found at ${checkdepend_script}"
    echo ""
    return
  fi

  # Extract upstream commit IDs and save to .commits.txt
  > "${commits_file}"

  for commit in "${applied_commits[@]}"; do
    local commit_body=$(git log -1 --format=%B "${commit}")

    # Extract upstream commit ID (full 40-char hash) from commit message
    local upstream_commit=$(echo "${commit_body}" | grep -oP '(?<=^commit )[a-f0-9]{40}' | head -1)

    if [ -n "${upstream_commit}" ]; then
      # Save the full 40-character hash
      echo "${upstream_commit}" >> "${commits_file}"
    fi
  done

  # Check if we have any commits to check
  local commit_count=$(wc -l < "${commits_file}")
  if [ ${commit_count} -eq 0 ]; then
    skip "check_dependency" "No upstream commit IDs found in patches"
    echo ""
    return
  fi

  if python3 "${checkdepend_script}" "${LINUX_SRC_PATH}" "${TORVALDS_REPO}" "${commits_file}" > "${dep_log}" 2>&1; then
    # Check if there are any failures in the output
    if grep -q "FAIL" "${dep_log}"; then
      fail "check_dependency" "Some commits have unfixed dependencies (see ${dep_log})"
    else
      pass "check_dependency"
    fi
  else
    fail "check_dependency" "checkdepend.py execution failed (see ${dep_log})"
  fi

  echo ""
}

test_build_allmod() {
  echo -e "${BLUE}Test-2: build_allmod${NC}"
  run_kernel_build "build_allmod" "allmodconfig"
}

test_check_patch() {
  echo -e "${BLUE}Test-3: check_patch${NC}"
  
  # Check if checkpatch.pl exists
  local CHECKPATCH="${LINUX_SRC_PATH}/scripts/checkpatch.pl"
  if [ ! -f "${CHECKPATCH}" ]; then
    fail "check_patch" "checkpatch.pl not found at ${CHECKPATCH}"
    echo ""
    return
  fi
  
  # Check if patches directory exists
  if [ ! -d "${PATCHES_DIR}" ]; then
    fail "check_patch" "Patches directory not found at ${PATCHES_DIR}"
    echo ""
    return
  fi
  
  # Find all patch files (excluding .bkp directory)
  local patch_files=()
  mapfile -t patch_files < <(find "${PATCHES_DIR}" -maxdepth 1 -name "*.patch" -type f | sort)
  
  if [ ${#patch_files[@]} -eq 0 ]; then
    skip "check_patch" "No patches found in ${PATCHES_DIR}"
    echo ""
    return
  fi
  
  echo "  → Checking ${#patch_files[@]} patches..."
  
  local total_errors=0
  local total_warnings=0
  local failed_patches=0
  local checkpatch_log="${LOGS_DIR}/check_patch.log"
  
  > "${checkpatch_log}"  # Clear log file
  
  for patch_file in "${patch_files[@]}"; do
    local patch_name=$(basename "${patch_file}")
    echo "    Checking: ${patch_name}" >> "${checkpatch_log}"
    
    # Run checkpatch and capture output
    local output=$("${CHECKPATCH}" "${patch_file}" 2>&1)
    echo "${output}" >> "${checkpatch_log}"
    echo "" >> "${checkpatch_log}"
    
    # Filter out the specific error we want to ignore
    local filtered_output=$(echo "${output}" | grep -v "ERROR: Please use git commit description style")
    
    # Count errors and warnings from filtered output
    local errors=$(echo "${filtered_output}" | grep -c "^ERROR:" || true)
    local warnings=$(echo "${filtered_output}" | grep -c "^WARNING:" || true)
    
    total_errors=$((total_errors + errors))
    total_warnings=$((total_warnings + warnings))
    
    if [ ${errors} -gt 0 ]; then
      failed_patches=$((failed_patches + 1))
      echo "      ${patch_name}: ${errors} error(s), ${warnings} warning(s)" >> "${checkpatch_log}"
    fi
  done
  
  echo "  → Total: ${total_errors} errors, ${total_warnings} warnings across ${#patch_files[@]} patches"
  
  if [ ${total_errors} -gt 0 ]; then
    fail "check_patch" "${failed_patches} patch(es) have errors (see ${checkpatch_log})"
  else
    if [ ${total_warnings} -gt 0 ]; then
      echo -e "  ${YELLOW}→${NC} ${total_warnings} warning(s) found (non-fatal)"
    fi
    pass "check_patch"
  fi
  
  echo ""
}

test_check_format() {
  echo -e "${BLUE}Test-4: check_format${NC}"
  
  cd "${LINUX_SRC_PATH}"
  
  # Get list of applied commits (those that are ahead of the reset point)
  local applied_commits=()
  mapfile -t applied_commits < <(git log --oneline --no-merges HEAD | head -n "${NUM_PATCHES:-10}" | awk '{print $1}')
  
  if [ ${#applied_commits[@]} -eq 0 ]; then
    skip "check_format" "No commits to check"
    echo ""
    return
  fi
  
  echo "  → Checking ${#applied_commits[@]} commits for proper format..."
  
  local format_log="${LOGS_DIR}/check_format.log"
  > "${format_log}"
  
  local format_errors=0
  local expected_sob="Signed-off-by: ${SIGNER_NAME} <${SIGNER_EMAIL}>"
  
  for commit in "${applied_commits[@]}"; do
    local commit_msg=$(git log -1 --format=%B "${commit}")
    local commit_subject=$(git log -1 --format=%s "${commit}")
    
    echo "Checking commit: ${commit} - ${commit_subject}" >> "${format_log}"
    echo "---" >> "${format_log}"
    
    local has_error=0
    
    # Check for mainline inclusion header
    if ! echo "${commit_msg}" | grep -q "^mainline inclusion"; then
      echo "  ✗ Missing 'mainline inclusion' header" >> "${format_log}"
      has_error=1
    fi
    
    # Check for 'from mainline-' line
    if ! echo "${commit_msg}" | grep -q "^from mainline-"; then
      echo "  ✗ Missing 'from mainline-' line" >> "${format_log}"
      has_error=1
    fi
    
    # Check for commit line
    if ! echo "${commit_msg}" | grep -q "^commit [a-f0-9]\{40\}"; then
      echo "  ✗ Missing upstream commit ID" >> "${format_log}"
      has_error=1
    fi
    
    # Check for category line
    if ! echo "${commit_msg}" | grep -q "^category:"; then
      echo "  ✗ Missing 'category:' line" >> "${format_log}"
      has_error=1
    fi
    
    # Check for bugzilla line
    if ! echo "${commit_msg}" | grep -q "^bugzilla: https://gitee.com/openeuler/kernel/issues/"; then
      echo "  ✗ Missing or incorrect 'bugzilla:' line" >> "${format_log}"
      has_error=1
    fi
    
    # Check for CVE line
    if ! echo "${commit_msg}" | grep -q "^CVE:"; then
      echo "  ✗ Missing 'CVE:' line" >> "${format_log}"
      has_error=1
    fi
    
    # Check for Reference line
    if ! echo "${commit_msg}" | grep -q "^Reference: https://github.com/torvalds/linux/commit/"; then
      echo "  ✗ Missing 'Reference:' line" >> "${format_log}"
      has_error=1
    fi
    
    # Check for separator line
    if ! echo "${commit_msg}" | grep -q "^--------------------------------"; then
      echo "  ✗ Missing separator line '--------------------------------'" >> "${format_log}"
      has_error=1
    fi
    
    # Check for new Signed-off-by line
    if ! echo "${commit_msg}" | grep -q "^${expected_sob}"; then
      echo "  ✗ Missing expected Signed-off-by: ${expected_sob}" >> "${format_log}"
      has_error=1
    else
      # Extract upstream commit ID
      local upstream_commit=$(echo "${commit_msg}" | grep "^commit " | awk '{print $2}')
      
      if [ -n "${upstream_commit}" ]; then
        # Get the last Signed-off-by from upstream commit in Torvalds repo
        cd "${TORVALDS_REPO}"
        local upstream_last_sob=$(git log -1 --format=%B "${upstream_commit}" 2>/dev/null | grep "^Signed-off-by:" | tail -1)
        cd "${LINUX_SRC_PATH}"
        
        # Get all Signed-off-by lines from current commit
        local all_sobs=$(echo "${commit_msg}" | grep "^Signed-off-by:")
        local current_last_sob=$(echo "${all_sobs}" | tail -1)
        
        # Check if the last sob is the same as upstream (which means we didn't add our new one)
        if [ -n "${upstream_last_sob}" ] && [ "${current_last_sob}" == "${upstream_last_sob}" ]; then
          echo "  ✗ New Signed-off-by line not added (last SOB matches upstream)" >> "${format_log}"
          has_error=1
        elif [ "${current_last_sob}" != "${expected_sob}" ]; then
          echo "  ✗ Last Signed-off-by does not match expected: ${expected_sob}" >> "${format_log}"
          echo "    Found: ${current_last_sob}" >> "${format_log}"
          has_error=1
        fi
      fi
    fi
    
    if [ ${has_error} -eq 1 ]; then
      format_errors=$((format_errors + 1))
      echo "  Result: FAIL" >> "${format_log}"
    else
      echo "  Result: PASS" >> "${format_log}"
    fi
    
    echo "" >> "${format_log}"
  done
  
  if [ ${format_errors} -gt 0 ]; then
    fail "check_format" "${format_errors} commit(s) have format errors (see ${format_log})"
  else
    pass "check_format"
  fi
  
  echo ""
}

test_rpm_build() {
  echo -e "${BLUE}Test-5: rpm_build${NC}"

  cd "${LINUX_SRC_PATH}"

  local rpm_log="${LOGS_DIR}/rpm_build.log"
  local rpms_dir="$HOME/rpmbuild/RPMS/x86_64"

  > "${rpm_log}"

  echo "  → Cleaning source tree..." >> "${rpm_log}"
  if ! make distclean >> "${rpm_log}" 2>&1; then
    fail "rpm_build" "Failed to clean source tree (see ${rpm_log})"
    echo ""
    return
  fi

  echo "  → Configuring kernel with openeuler_defconfig..." >> "${rpm_log}"
  if ! make openeuler_defconfig >> "${rpm_log}" 2>&1; then
    fail "rpm_build" "Failed to configure kernel (see ${rpm_log})"
    echo ""
    return
  fi

  echo "  → Building RPM packages..." | tee -a "${rpm_log}"
  if ! make -j"${BUILD_THREADS}" rpm-pkg >> "${rpm_log}" 2>&1; then
    fail "rpm_build" "Failed to build RPM packages (see ${rpm_log})"
    echo ""
    return
  fi

  # Check if RPMs were created
  echo "  → Checking for generated RPMs..." >> "${rpm_log}"

  if [ ! -d "${rpms_dir}" ]; then
    fail "rpm_build" "RPMs directory not found: ${rpms_dir}"
    echo ""
    return
  fi

  # Find kernel and headers RPM
  local kernel_rpm=$(find "${rpms_dir}" -name "kernel-[0-9]*.rpm" ! -name "*headers*" -type f | head -n 1)
  local headers_rpm=$(find "${rpms_dir}" -name "kernel-headers-*.rpm" -type f | head -n 1)

  local rpm_count=0

  if [ -n "${kernel_rpm}" ]; then
    echo "  → Found kernel RPM: $(basename ${kernel_rpm})" >> "${rpm_log}"
    rpm_count=$((rpm_count + 1))
  else
    echo "  → Kernel RPM not found" >> "${rpm_log}"
  fi

  if [ -n "${headers_rpm}" ]; then
    echo "  → Found headers RPM: $(basename ${headers_rpm})" >> "${rpm_log}"
    rpm_count=$((rpm_count + 1))
  else
    echo "  → Headers RPM not found" >> "${rpm_log}"
  fi

  if [ ${rpm_count} -eq 2 ]; then
    echo "  → RPM build location: ${rpms_dir}" >> "${rpm_log}"
    pass "rpm_build"
  else
    fail "rpm_build" "Expected 2 RPMs (kernel + headers), found ${rpm_count} (see ${rpm_log})"
  fi

  echo ""
}

test_boot_kernel() {
  echo -e "${BLUE}Test-6: boot_kernel${NC}"

  local rpms_dir="$HOME/rpmbuild/RPMS/x86_64"
  local boot_log="${LOGS_DIR}/boot_kernel.log"

  > "${boot_log}"

  # Check if RPMs exist
  if [ ! -d "${rpms_dir}" ]; then
    fail "boot_kernel" "RPMs directory not found: ${rpms_dir}"
    echo ""
    return
  fi

  # Find kernel RPM (not headers)
  local kernel_rpm=$(find "${rpms_dir}" -name "kernel-[0-9]*.rpm" ! -name "*headers*" ! -name "*debuginfo*" ! -name "*devel*" -type f | head -n 1)

  if [ -z "${kernel_rpm}" ]; then
    fail "boot_kernel" "Kernel RPM not found in ${rpms_dir}"
    echo ""
    return
  fi

  echo "  → Booting VM with kernel RPM..." | tee -a "${boot_log}"
  echo "  → Found kernel RPM: $(basename ${kernel_rpm})" >> "${boot_log}"

  # Check VM connectivity
  echo "  → Checking VM connectivity (${VM_IP})..." >> "${boot_log}"
  if ! ping -c 2 "${VM_IP}" >> "${boot_log}" 2>&1; then
    fail "boot_kernel" "VM ${VM_IP} is not reachable"
    echo ""
    return
  fi
  echo "  → VM is reachable" >> "${boot_log}"

  # Install sshpass if not available (for password authentication)
  if ! command -v sshpass &> /dev/null; then
    echo "  → Installing sshpass..." | tee -a "${boot_log}"
    echo "${HOST_USER_PWD}" | sudo -S yum install -y sshpass >> "${boot_log}" 2>&1 || {
      fail "boot_kernel" "Failed to install sshpass"
      echo ""
      return
    }
  fi

  # Copy kernel RPM to VM
  echo "  → Copying kernel RPM to VM..." >> "${boot_log}"
  if ! sshpass -p "${VM_ROOT_PWD}" scp -o StrictHostKeyChecking=no "${kernel_rpm}" root@"${VM_IP}":/tmp/ >> "${boot_log}" 2>&1; then
    fail "boot_kernel" "Failed to copy RPM to VM"
    echo ""
    return
  fi
  echo "  → RPM copied successfully" >> "${boot_log}"

  local rpm_name=$(basename "${kernel_rpm}")

  # Install kernel RPM on VM
  echo "  → Installing kernel RPM on VM..." >> "${boot_log}"
  if ! sshpass -p "${VM_ROOT_PWD}" ssh -o StrictHostKeyChecking=no root@"${VM_IP}" "rpm -ivh --force /tmp/${rpm_name}" >> "${boot_log}" 2>&1; then
    fail "boot_kernel" "Failed to install kernel RPM"
    echo ""
    return
  fi
  echo "  → Kernel installed successfully" >> "${boot_log}"

  # Extract kernel version from RPM name
  # Expected format: kernel-<version>.rpm
  local kernel_version=$(echo "${rpm_name}" | sed -E 's/^kernel-([0-9.+]+)-[0-9]+.*/\1/')
  local vmlinuz_path="/boot/vmlinuz-${kernel_version}"
  echo "  → Expected kernel version: ${kernel_version}" >> "${boot_log}"
  echo "  → Expected vmlinuz path: ${vmlinuz_path}" >> "${boot_log}"

  # Verify kernel was installed
  echo "  → Verifying kernel installation..." >> "${boot_log}"
  if ! sshpass -p "${VM_ROOT_PWD}" ssh -o StrictHostKeyChecking=no root@"${VM_IP}" "test -f ${vmlinuz_path}" >> "${boot_log}" 2>&1; then
    fail "boot_kernel" "Kernel image not found at ${vmlinuz_path}"
    echo ""
    return
  fi

  # List all available kernels
  echo "  → Available kernels before setting default:" >> "${boot_log}"
  sshpass -p "${VM_ROOT_PWD}" ssh -o StrictHostKeyChecking=no root@"${VM_IP}" "grubby --info ALL | grep -E '^kernel='" >> "${boot_log}" 2>&1

  # Set new kernel as default using grubby
  echo "  → Setting new kernel as default boot option using grubby..." >> "${boot_log}"
  if ! sshpass -p "${VM_ROOT_PWD}" ssh -o StrictHostKeyChecking=no root@"${VM_IP}" "grubby --set-default=${vmlinuz_path}" >> "${boot_log}" 2>&1; then
    fail "boot_kernel" "Failed to set default kernel with grubby"
    echo ""
    return
  fi

  # Verify default kernel was set
  echo "  → Verifying default kernel setting..." >> "${boot_log}"
  local default_kernel=$(sshpass -p "${VM_ROOT_PWD}" ssh -o StrictHostKeyChecking=no root@"${VM_IP}" "grubby --default-kernel" 2>> "${boot_log}")
  echo "  → Default kernel set to: ${default_kernel}" >> "${boot_log}"

  if [[ "${default_kernel}" != "${vmlinuz_path}" ]]; then
    fail "boot_kernel" "Failed to set default kernel. Expected: ${vmlinuz_path}, Got: ${default_kernel}"
    echo ""
    return
  fi

  # Reboot VM
  echo "  → Rebooting VM..." >> "${boot_log}"
  sshpass -p "${VM_ROOT_PWD}" ssh -o StrictHostKeyChecking=no root@"${VM_IP}" "reboot" >> "${boot_log}" 2>&1 || true

  # Wait for VM to go down
  echo "  → Waiting for VM to shutdown..." >> "${boot_log}"
  sleep 10

  # Wait for VM to come back up (max 5 minutes)
  echo "  → Waiting for VM to boot up (max 5 minutes)..." >> "${boot_log}"
  local wait_count=0
  local max_wait=60  # 60 * 5 seconds = 5 minutes

  while [ $wait_count -lt $max_wait ]; do
    if ping -c 1 -W 1 "${VM_IP}" >> "${boot_log}" 2>&1; then
      sleep 10  # Wait a bit more for SSH to be ready
      if sshpass -p "${VM_ROOT_PWD}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"${VM_IP}" "echo 'VM is up'" >> "${boot_log}" 2>&1; then
        echo "  → VM booted successfully" >> "${boot_log}"
        break
      fi
    fi
    sleep 5
    wait_count=$((wait_count + 1))
  done

  if [ $wait_count -ge $max_wait ]; then
    fail "boot_kernel" "VM did not boot within 5 minutes"
    echo ""
    return
  fi

  # Check running kernel version
  echo "  → Checking running kernel version..." >> "${boot_log}"
  local running_kernel=$(sshpass -p "${VM_ROOT_PWD}" ssh -o StrictHostKeyChecking=no root@"${VM_IP}" "uname -r" 2>> "${boot_log}")

  echo "  → Running kernel: ${running_kernel}" >> "${boot_log}"
  echo "  → Expected kernel: ${kernel_version}" >> "${boot_log}"

  # Verify if the installed kernel is running (exact match)
  if [[ "${running_kernel}" == "${kernel_version}" ]]; then
    echo -e "  → VM booted with new kernel: ${running_kernel}" >> "${boot_log}"
    pass "boot_kernel"
  else
    fail "boot_kernel" "VM booted with different kernel. Expected: ${kernel_version}, Got: ${running_kernel}"
  fi

  echo ""
}

# ---- TEST EXECUTION ----

[ "${TEST_CHECK_DEPENDENCY:-no}" == "yes" ] && test_check_dependency
[ "$TEST_BUILD_ALLMOD" == "yes" ] && test_build_allmod
[ "$TEST_CHECK_PATCH" == "yes" ] && test_check_patch
[ "$TEST_CHECK_FORMAT" == "yes" ] && test_check_format
[ "$TEST_RPM_BUILD" == "yes" ] && test_rpm_build
[ "$TEST_BOOT_KERNEL" == "yes" ] && test_boot_kernel

# ---- SUMMARY ----
{
  echo "openEuler Test Report"
  echo "====================="
  echo "Date: $(date)"
  echo "Kernel Source: ${LINUX_SRC_PATH}"
  echo ""
  echo "Test Results:"
  echo "-------------"
  for result in "${TEST_RESULTS[@]}"; do
    echo "$result"
  done
  echo ""
  echo "Summary:"
  echo "--------"
  echo "Total Tests: ${TOTAL_TESTS}"
  echo "Passed: ${PASSED_TESTS}"
  echo "Failed: ${FAILED_TESTS}"
  echo "Skipped: ${SKIPPED_TESTS}"
} > "${TEST_LOG}"

echo -e "${GREEN}============${NC}"
echo -e "${GREEN}Test Summary${NC}"
echo -e "${GREEN}============${NC}"
echo "Total Tests: ${TOTAL_TESTS}"
echo -e "Passed:  ${GREEN}${PASSED_TESTS}${NC}"
echo -e "Failed:  ${RED}${FAILED_TESTS}${NC}"
echo -e "Skipped: ${YELLOW}${SKIPPED_TESTS}${NC}"
echo ""
echo -e "${BLUE}Full report: ${TEST_LOG}${NC}"
echo ""

if [ "${FAILED_TESTS}" -gt 0 ]; then
  echo -e "${RED}✗ Some tests failed${NC}"
  exit 1
else
  echo -e "${GREEN}✓ All tests passed or skipped${NC}"
  exit 0
fi
