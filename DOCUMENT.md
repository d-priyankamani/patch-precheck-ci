# Patch Pre-Check CI Tool Documentation

## Overview

The Patch Pre-Check CI Tool is an automated testing framework designed to validate Linux kernel patches across different distributions before submission. It streamlines patch validation by automating patch application, kernel builds, and distribution-specific testing.

## Features

- **Multi-Distribution Support:** OpenAnolis and openEuler
- **Automated Patch Processing:** Generates patches from git commits and applies them sequentially
- **Incremental Build Testing:** Tests each patch individually to identify build-breaking changes early
- **Comprehensive Test Suite:** Configuration validation, multiple build configurations, RPM packaging, and KAPI compatibility checks
- **Smart Configuration:** Interactive wizard with sensible defaults
- **Clean Workflow:** Automatic git state management with rollback

## Supported Distributions

| Distribution | Target Kernel         | Kernel Versions     | Architectures  |
|--------------|-----------------------|---------------------|----------------|
| OpenAnolis   | ANCK (Cloud Kernel)   | Multiple LTS        | x86_64, aarch64|
| openEuler    | openEuler Kernel      | Multiple LTS        | x86_64, aarch64|

## Installation & Setup

### Prerequisites

```bash
sudo yum install -y git make gcc flex bison elfutils-libelf-devel openssl-devel ncurses-devel bc rpm-build
```
OpenAnolis extra requirements
```bash
sudo yum install -y audit-libs-devel binutils-devel libbpf-devel libcap-ng-devel libnl3-devel newt-devel pciutils-devel xmlto yum-utils
```

### Getting Started

```bash
git clone https://github.com/SelamHemanth/patch-precheck-ci.git
cd patch-precheck-ci

make config # Run config wizard
make build # Build/test patches
make test # Execute all tests
```

### Configuration Steps

1. **Distribution Selection**

    ```
    ╔════════════════════════╗
    ║ Distribution Selection ║
    ╚════════════════════════╝
    Detected Distribution: anolis
    Available distributions:
      1) OpenAnolis
      2) openEuler
    Enter choice [1-2]:
    ```

2. **Distribution-Specific Configuration**

   **OpenAnolis:**  
     - Linux source code path
     - Signed-off-by name/email
     - Anolis Bugzilla ID (ANBZ)
     - Number of patches to apply (from HEAD)
     - Build threads (default: CPU cores)

     **Test Options:**

     | Test                        | Description                           | Purpose                                    |
     |-----------------------------|---------------------------------------|--------------------------------------------|
     | check_Kconfig               | Validate Kconfig settings             | Ensures config validity                    |
     | build_allyes_config         | Build with allyesconfig               | Compile w/ all enabled options             |
     | build_allno_config          | Build with allnoconfig                | Minimal kernel build                       |
     | build_anolis_defconfig      | Build with anolis_defconfig           | Production default config                  |
     | build_anolis_debug_defconfig| Build with debug config               | Enable debugging features                  |
     | anck_rpm_build              | Build ANCK RPM packages               | RPMs for installation                      |
     | check_kapi                  | Check KAPI compatibility              | ABI compatibility checks                   |
     | boot_kernel_rpm             | Boot test                             | Manual installation/run instructions       |

     Enable: individual (e.g. 1,3,5), all, or none.

   **openEuler:**  
   Similar options, tailored for openEuler kernel configuration, builds, packaging.

## Make Targets

| Target        | Description                            |
|---------------|----------------------------------------|
| config        | Interactive configuration wizard       |
| build         | Generate/apply patches & build         |
| test          | Run distribution-specific test suite   |
| clean         | Remove logs/build outputs              |
| reset         | Reset git to saved HEAD                |
| distclean     | Remove all artifacts/config            |
| mrproper      | Complete cleanup                       |
| help          | Display usage info                     |

## Contributing

To add a new distribution:

- Create: `newdistro/` directory
- Add: `config.sh`, `build.sh`, `test.sh`, `Makefile`
- Update: main `Makefile` with new targets
- Thoroughly test
- Submit pull request

## License

GPL-3.0 licence
This tool is provided as-is for kernel development and testing purposes.

## Support

- [Repository](https://github.com/SelamHemanth/patch-precheck-ci)
- Issues via GitHub

**OpenAnolis has full support. For openEuler, support is currently being implemented.**


