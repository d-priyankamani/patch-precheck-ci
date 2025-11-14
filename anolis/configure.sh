#!/usr/bin/env bash
set -euo pipefail

# anolis/configure.sh - OpenAnolis Configuration Script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${SCRIPT_DIR}/.configure"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo "╔════════════════════════════╗"
echo "║  OpenAnolis Configuration  ║"
echo "╚════════════════════════════╝"
echo ""

# General Configuration
echo "=== General Configuration ==="
read -r -p "Linux source code path: " linux_src
LINUX_SRC_PATH="${linux_src:-/home/amd/linux}"

read -r -p "Signed-off-by name: " signer_name
SIGNER_NAME="${signer_name:-Hemanth Selam}"

read -r -p "Signed-off-by email: " signer_email
SIGNER_EMAIL="${signer_email:-Hemanth.Selam@amd.com}"

read -r -p "Anolis Bugzilla ID: " anbz_id
ANBZ_ID="${anbz_id:-12345}"

read -r -p "Number of patches to apply: " num_patches
NUM_PATCHES="${num_patches:-0}"

# Build Configuration
echo ""
echo "=== Build Configuration ==="
read -r -p "Number of build threads [$(nproc)]: " build_threads
BUILD_THREADS="${build_threads:-$(nproc)}"

# Test Configuration
echo ""
echo "=== Test Configuration ==="
echo ""
echo "Available tests:"
echo "  1) check_Kconfig              - Validate Kconfig settings"
echo "  2) build_allyes_config        - Build with allyesconfig"
echo "  3) build_allno_config         - Build with allnoconfig"
echo "  4) build_anolis_defconfig     - Build with anolis_defconfig"
echo "  5) build_anolis_debug_defconfig - Build with anolis-debug_defconfig"
echo "  6) anck_rpm_build             - Build ANCK RPM packages"
echo "  7) check_kapi                 - Check KAPI compatibility"
echo "  8) boot_kernel_rpm            - Boot test (requires remote setup)"
echo ""

read -r -p "Select tests to run (comma-separated, 'all', or 'none') [all]: " test_selection
TEST_SELECTION="${test_selection:-all}"

# Parse test selection
if [ "$TEST_SELECTION" == "all" ] || [ -z "$TEST_SELECTION" ]; then
  RUN_TESTS="yes"
  TEST_CHECK_KCONFIG="yes"
  TEST_BUILD_ALLYES="yes"
  TEST_BUILD_ALLNO="yes"
  TEST_BUILD_DEFCONFIG="yes"
  TEST_BUILD_DEBUG="yes"
  TEST_RPM_BUILD="yes"
  TEST_CHECK_KAPI="yes"
  TEST_BOOT_KERNEL="yes"
elif [ "$TEST_SELECTION" == "none" ]; then
  RUN_TESTS="no"
  TEST_CHECK_KCONFIG="no"
  TEST_BUILD_ALLYES="no"
  TEST_BUILD_ALLNO="no"
  TEST_BUILD_DEFCONFIG="no"
  TEST_BUILD_DEBUG="no"
  TEST_RPM_BUILD="no"
  TEST_CHECK_KAPI="no"
  TEST_BOOT_KERNEL="no"
else
  RUN_TESTS="yes"
  TEST_CHECK_KCONFIG="no"
  TEST_BUILD_ALLYES="no"
  TEST_BUILD_ALLNO="no"
  TEST_BUILD_DEFCONFIG="no"
  TEST_BUILD_DEBUG="no"
  TEST_RPM_BUILD="no"
  TEST_CHECK_KAPI="no"
  TEST_BOOT_KERNEL="no"
  
  # Parse comma-separated selections
  IFS=',' read -ra SELECTED <<< "$TEST_SELECTION"
  for test_num in "${SELECTED[@]}"; do
    case "${test_num// /}" in
      1) TEST_CHECK_KCONFIG="yes" ;;
      2) TEST_BUILD_ALLYES="yes" ;;
      3) TEST_BUILD_ALLNO="yes" ;;
      4) TEST_BUILD_DEFCONFIG="yes" ;;
      5) TEST_BUILD_DEBUG="yes" ;;
      6) TEST_RPM_BUILD="yes" ;;
      7) TEST_CHECK_KAPI="yes" ;;
      8) TEST_BOOT_KERNEL="yes" ;;
    esac
  done
fi

# Write configuration file
cat > "$CONFIG_FILE" <<EOF
# OpenAnolis Configuration
# Generated: $(date)

# General Configuration
LINUX_SRC_PATH="${LINUX_SRC_PATH}"
SIGNER_NAME="${SIGNER_NAME}"
SIGNER_EMAIL="${SIGNER_EMAIL}"
ANBZ_ID="${ANBZ_ID}"
NUM_PATCHES="${NUM_PATCHES}"

# Build Configuration
BUILD_THREADS="${BUILD_THREADS}"

# Test Configuration
RUN_TESTS="${RUN_TESTS}"
TEST_CHECK_KCONFIG="${TEST_CHECK_KCONFIG}"
TEST_BUILD_ALLYES="${TEST_BUILD_ALLYES}"
TEST_BUILD_ALLNO="${TEST_BUILD_ALLNO}"
TEST_BUILD_DEFCONFIG="${TEST_BUILD_DEFCONFIG}"
TEST_BUILD_DEBUG="${TEST_BUILD_DEBUG}"
TEST_RPM_BUILD="${TEST_RPM_BUILD}"
TEST_CHECK_KAPI="${TEST_CHECK_KAPI}"
TEST_BOOT_KERNEL="${TEST_BOOT_KERNEL}"
EOF

echo ""
echo "╔═══════════════════════╗"
echo "║  Configuration Saved  ║"
echo "╚═══════════════════════╝"
echo ""
echo "Configuration saved to: ${CONFIG_FILE}"
echo ""
echo "Linux source: ${LINUX_SRC_PATH}"
echo "Patches to process: ${NUM_PATCHES}"
echo "Build threads: ${BUILD_THREADS}"
echo "Tests enabled: ${RUN_TESTS}"
echo ""
echo -e "${BLUE}Next: Run 'make build' to build${NC}"
