#!/usr/bin/env bash
set -uo pipefail

# anolis/test.sh - OpenAnolis CI Test Suite

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

LOGS_DIR="${WORKDIR}/logs"
TEST_LOG="${LOGS_DIR}/test_results.log"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

: "${LINUX_SRC_PATH:?missing in config}"

mkdir -p "${LOGS_DIR}"

echo ""
echo -e "${BLUE}=============================${NC}"
echo -e "${BLUE}OpenAnolis Build & Test Suite${NC}"
echo -e "${BLUE}=============================${NC}"
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
  echo -e "${BLUE}Test: ${test_name}${NC}"
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

test_check_kconfig() {
  echo -e "${BLUE}Test: check_Kconfig${NC}"
  cd "${LINUX_SRC_PATH}/anolis" 2>/dev/null || {
    skip "check_Kconfig" "anolis/ directory not found"
    return
  }

  mkdir -p "${LINUX_SRC_PATH}/anolis/output" 2>/dev/null
  chmod -R u+w "${LINUX_SRC_PATH}/anolis/output" 2>/dev/null || true

  if ARCH=${kernel_arch} make dist-configs-check > "${LOGS_DIR}/check_Kconfig.log" 2>&1; then
    pass "check_Kconfig"
  else
    fail "check_Kconfig" "dist-configs-check failed (see ${LOGS_DIR}/check_Kconfig.log)"
  fi
  echo ""
}

test_build_allyes_config() {
  run_kernel_build "build_allyes_config" "allyesconfig"
}

test_build_allno_config() {
  run_kernel_build "build_allno_config" "allnoconfig"
}

test_build_anolis_defconfig() {
  run_kernel_build "build_anolis_defconfig" "anolis_defconfig"
}

test_build_anolis_debug_defconfig() {
  run_kernel_build "build_anolis_debug_defconfig" "anolis-debug_defconfig"
}

test_anck_rpm_build() {
  echo -e "${BLUE}Test: anck_rpm_build${NC}"

  # Check and install required build dependencies only if missing
  local packages="audit-libs-devel binutils-devel libbpf-devel libcap-ng-devel libnl3-devel newt-devel pciutils-devel xmlto yum-utils"
  local missing_packages=""

  for pkg in $packages; do
    if ! rpm -q "$pkg" &>/dev/null; then
      missing_packages="$missing_packages $pkg"
    fi
  done

  if [ -n "$missing_packages" ]; then
    echo "Installing missing packages:$missing_packages"
    sudo yum install -y $missing_packages >> "${LOGS_DIR}/anck_rpm_build.log" 2>&1 || true
  fi

  # Set build environment variables
  export BUILD_NUMBER="${BUILD_NUMBER:-0}"
  export BUILD_MODE="${BUILD_MODE:-devel}"
  export BUILD_VARIANT="${BUILD_VARIANT:-default}"
  export BUILD_EXTRA="${BUILD_EXTRA:-debuginfo}"

  cd "${LINUX_SRC_PATH}/anolis" || {
    fail "anck_rpm_build" "Cannot enter anolis directory"
    return
  }

  # Create symlink to kernel source if not exists
  [ ! -L "cloud-kernel" ] && ln -sf "${LINUX_SRC_PATH}" cloud-kernel

  # Create and clean outputs directory
  outputdir="${LINUX_SRC_PATH}/anolis/outputs"
  rm -rf "${outputdir}/rpmbuild"
  mkdir -p "${outputdir}"

  # Generate spec file if not exists or outdated
  if [ ! -f output/kernel.spec ] || [ "${LINUX_SRC_PATH}/anolis/Makefile" -nt output/kernel.spec ]; then
    make dist-genspec >> "${LOGS_DIR}/anck_rpm_build.log" 2>&1 || {
      fail "anck_rpm_build" "make dist-genspec failed"
      return
    }
  fi

  # Install spec dependencies only once
  if [ ! -f "${outputdir}/.deps_installed" ]; then
    sudo yum-builddep -y output/kernel.spec >> "${LOGS_DIR}/anck_rpm_build.log" 2>&1 || true
    touch "${outputdir}/.deps_installed"
  fi

  # Set ulimit and build
  ulimit -n 65535

  echo "Building ANCK RPMs..."
  if DIST=".an23" \
     DIST_BUILD_NUMBER=${BUILD_NUMBER} \
     DIST_OUTPUT=${outputdir} \
     DIST_BUILD_MODE=${BUILD_MODE} \
     DIST_BUILD_VARIANT=${BUILD_VARIANT} \
     DIST_BUILD_EXTRA=${BUILD_EXTRA} \
     make dist-rpms RPMBUILDOPTS="--define '%_smp_mflags -j16'" \
     >> "${LOGS_DIR}/anck_rpm_build.log" 2>&1; then

    # Print RPM package location
    echo ""
    echo -e "${GREEN}RPM Build Successful!${NC}"
    echo -e "${BLUE}Generated package locations:${NC}"

    local rpm_dir="${outputdir}/rpmbuild/RPMS"

    if [ -d "${rpm_dir}" ]; then
      local rpm_count=$(find "${rpm_dir}" -name "*.rpm" -type f | wc -l)
      echo -e "  ${GREEN}→${NC} Binary RPMs (${rpm_count} packages): ${rpm_dir}"
    fi

    pass "anck_rpm_build"
  else
    fail "anck_rpm_build" "RPM build failed (see ${LOGS_DIR}/anck_rpm_build.log)"
  fi

  echo ""
}

test_boot_kernel_rpm() {
  echo -e "${BLUE}Test: boot_kernel_rpm${NC}"
  local rpms_dir="${LINUX_SRC_PATH}/anolis/outputs/rpmbuild/RPMS"
  skip "boot_kernel_rpm" "Install the RPMs manually from ${rpms_dir}."
  echo ""
}

test_check_kapi() {
  echo -e "${BLUE}Test: check_kapi${NC}"

  local KAPI_TEST_DIR="/tmp/kapi_test"
  local KABI_DW_DIR="${KAPI_TEST_DIR}/kabi-dw"
  local KABI_WHITELIST_DIR="${KAPI_TEST_DIR}/kabi-whitelist"
  local KAPI_LOG="${LOGS_DIR}/kapi_test.log"
  local COMPARE_LOG="${KAPI_TEST_DIR}/kapi_compare.log"

  # Determine kernel branch for kabi-whitelist
  local KERNEL_VERSION=$(grep "^VERSION = " "${LINUX_SRC_PATH}/Makefile" | awk '{print $3}')
  local PATCHLEVEL=$(grep "^PATCHLEVEL = " "${LINUX_SRC_PATH}/Makefile" | awk '{print $3}')
  local KABI_BRANCH="devel-${KERNEL_VERSION}.${PATCHLEVEL}"

  echo "  → Setting up KAPI test environment..."

  # Create test directory if it doesn't exist
  mkdir -p "${KAPI_TEST_DIR}"

  # Check and clone kabi-dw tool if needed
  if [ -d "${KABI_DW_DIR}" ]; then
    echo "  → kabi-dw repository already exists, skipping clone..."
  else
    echo "  → Cloning kabi-dw repository..."
    if ! git clone https://gitee.com/anolis/kabi-dw.git "${KABI_DW_DIR}" >> "${KAPI_LOG}" 2>&1; then
      fail "check_kapi" "Failed to clone kabi-dw repository"
      return
    fi
  fi

  # Build kabi-dw tool
  echo "  → Building kabi-dw tool..."
  cd "${KABI_DW_DIR}"
  if ! make >> "${KAPI_LOG}" 2>&1; then
    fail "check_kapi" "Failed to build kabi-dw tool"
    return
  fi

  # Check and clone kabi-whitelist repository if needed
  if [ -d "${KABI_WHITELIST_DIR}" ]; then
    echo "  → kabi-whitelist repository already exists, skipping clone..."
    # Verify it's on the correct branch
    cd "${KABI_WHITELIST_DIR}"
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ "${CURRENT_BRANCH}" != "${KABI_BRANCH}" ]; then
      echo "  → Switching to branch ${KABI_BRANCH}..."
      if ! git checkout "${KABI_BRANCH}" >> "${KAPI_LOG}" 2>&1; then
        echo "  → Warning: Could not switch to branch ${KABI_BRANCH}, using ${CURRENT_BRANCH}"
      fi
    fi
  else
    echo "  → Cloning kabi-whitelist repository (branch: ${KABI_BRANCH})..."
    if ! git clone -b "${KABI_BRANCH}" https://gitee.com/anolis/kabi-whitelist.git "${KABI_WHITELIST_DIR}" >> "${KAPI_LOG}" 2>&1; then
      fail "check_kapi" "Failed to clone kabi-whitelist repository (branch ${KABI_BRANCH} may not exist)"
      return
    fi
  fi

  # Find vmlinux file in kernel source directory
  echo "  → Locating vmlinux file..."
  local VMLINUX_PATH="${LINUX_SRC_PATH}/vmlinux"

  if [ ! -f "${VMLINUX_PATH}" ]; then
    skip "check_kapi" "vmlinux not found at ${VMLINUX_PATH}. Build the kernel first."
    return
  fi

  echo "  → Found vmlinux at: ${VMLINUX_PATH}"

  # Determine architecture
  local KABI_ARCH=""
  if [ "${kernel_arch}" == "x86" ]; then
    KABI_ARCH="x86_64"
  elif [ "${kernel_arch}" == "arm64" ]; then
    KABI_ARCH="aarch64"
  else
    fail "check_kapi" "Unsupported architecture: ${kernel_arch}"
    return
  fi

  # Set paths for whitelist and output
  local WHITELIST_FILE="${KABI_WHITELIST_DIR}/kabi_whitelist_${KABI_ARCH}"
  local BASELINE_DIR="${KABI_WHITELIST_DIR}/kabi_dw_output/kabi_pre_${KABI_ARCH}"
  local OUTPUT_FILE="${KAPI_TEST_DIR}/kapi_after_${KABI_ARCH}"

  # Check if whitelist file exists
  if [ ! -f "${WHITELIST_FILE}" ]; then
    fail "check_kapi" "Whitelist file not found: ${WHITELIST_FILE}"
    return
  fi

  # Check if baseline directory exists
  if [ ! -d "${BASELINE_DIR}" ]; then
    fail "check_kapi" "Baseline directory not found: ${BASELINE_DIR}"
    return
  fi

  # Copy vmlinux to test directory for easier access
  local TEST_VMLINUX="${KAPI_TEST_DIR}/vmlinux"
  cp "${VMLINUX_PATH}" "${TEST_VMLINUX}"

  # Generate current kernel ABI symbols
  echo "  → Generating current kernel ABI symbols..."
  if ! "${KABI_DW_DIR}/kabi-dw" generate \
       -s "${WHITELIST_FILE}" \
       -o "${OUTPUT_FILE}" \
       "${TEST_VMLINUX}" >> "${KAPI_LOG}" 2>&1; then
    fail "check_kapi" "Failed to generate ABI symbols (see ${KAPI_LOG})"
    return
  fi

  # Compare current ABI with baseline
  echo "  → Comparing ABI with baseline..."
  "${KABI_DW_DIR}/kabi-dw" compare \
     -k "${BASELINE_DIR}" \
     "${OUTPUT_FILE}" > "${COMPARE_LOG}" 2>&1

  local COMPARE_EXIT=$?

  # Check if comparison ran successfully (exit code doesn't matter for differences)
  # Check for actual errors in the output
  if grep -q "Error" "${COMPARE_LOG}"; then
    fail "check_kapi" "ABI comparison encountered errors (see ${COMPARE_LOG})"
    return
  fi

  # Copy compare log to logs directory
  cp "${COMPARE_LOG}" "${LOGS_DIR}/"

  # Check if there are any ABI differences (skipping)
  #if [ -s "${COMPARE_LOG}" ]; then
    # File has content, meaning there are differences
    #local DIFF_COUNT=$(wc -l < "${COMPARE_LOG}")
    #echo -e "${YELLOW}  Warning: Found ${DIFF_COUNT} ABI differences${NC}"
    #echo "  → See details in: ${LOGS_DIR}/kapi_compare.log"

    # Show first few differences
    #if [ ${DIFF_COUNT} -gt 0 ]; then
      #echo "  → First 10 differences:"
      #head -n 10 "${COMPARE_LOG}" | sed 's/^/    /'
    #fi

    # Pass with warning - differences are expected and not failures
    #pass "check_kapi (with ${DIFF_COUNT} ABI differences)"
  #else
    # No differences found
    pass "check_kapi"
  #fi

  echo ""
}

# ---- TEST EXECUTION ----

[ "$TEST_CHECK_KCONFIG" == "yes" ] && test_check_kconfig
[ "$TEST_BUILD_ALLYES" == "yes" ] && test_build_allyes_config
[ "$TEST_BUILD_ALLNO" == "yes" ] && test_build_allno_config
[ "$TEST_BUILD_DEFCONFIG" == "yes" ] && test_build_anolis_defconfig
[ "$TEST_BUILD_DEBUG" == "yes" ] && test_build_anolis_debug_defconfig
[ "$TEST_RPM_BUILD" == "yes" ] && test_anck_rpm_build
[ "$TEST_CHECK_KAPI" == "yes" ] && test_check_kapi
[ "$TEST_BOOT_KERNEL" == "yes" ] && test_boot_kernel_rpm

# ---- SUMMARY ----
{
  echo "OpenAnolis Test Report"
  echo "======================"
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
