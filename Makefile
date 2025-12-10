#!/usr/bin/make -f
# Main Makefile - Multi-Distro Kernel Build Tool
# Manages distro detection and delegates to distro-specific scripts

SHELL := /bin/bash
.ONESHELL:
.PHONY: help config build test clean reset distclean

# Configuration files (stored in main directory)
DISTRO_CONFIG := .distro_config

# Directories
WORKDIR := $(shell pwd)
LOGS_DIR := $(WORKDIR)/logs
OUTPUTS_DIR := $(WORKDIR)/outputs
PATCHES_DIR := $(WORKDIR)/patches
HEAD_ID_FILE := $(WORKDIR)/.head_commit_id

# Colors
GREEN := \033[0;32m
RED := \033[0;31m
YELLOW := \033[1;33m
BLUE := \033[0;34m
NC := \033[0m

# Detect current distribution
detect_distro:
	@if [ -f /etc/os-release ]; then \
		. /etc/os-release; \
		case "$$ID" in \
			anolis) echo "anolis" ;; \
			opencloudos) echo "cloud" ;; \
			openeuler) echo "euler" ;; \
			rocky) echo "rocky" ;; \
			ubuntu) echo "ubuntu" ;; \
			velinux) echo "velinux" ;; \
			*) echo "unknown" ;; \
		esac; \
	else \
		echo "unknown"; \
	fi

# Default help
help:
	@echo "╔════════════════════════════════╗"
	@echo "║     Patch Pre-Check CI Tool    ║"
	@echo "╚════════════════════════════════╝"
	@echo ""
	@echo "Usage:"
	@echo "  make config     - Configure target distribution"
	@echo "  make build      - Build kernel (generate/apply patches)"
	@echo "  make test       - Run distro-specific tests"
	@echo "  make clean      - Remove logs/ and outputs/"
	@echo "  make reset      - Reset git repo to saved HEAD"
	@echo "  make distclean  - Remove all artifacts and configs"
	@echo ""
	@echo "Supported Distributions:"
	@echo "  - OpenAnolis (anolis/)"
	@echo "  - openEuler  (euler/)"
	@echo ""
	@DETECTED=$$($(MAKE) -s detect_distro); \
	if [ "$$DETECTED" != "unknown" ]; then \
		echo -e "$(GREEN)Detected: $$DETECTED$(NC)"; \
	fi
	@echo ""

# Configuration
config:
	@DETECTED=$$($(MAKE) -s detect_distro); \
	echo ""; \
	echo "╔══════════════════════════╗"; \
	echo "║  Distribution Selection  ║"; \
	echo "╚══════════════════════════╝"; \
	echo ""; \
	if [ "$$DETECTED" != "unknown" ]; then \
		echo -e "$(GREEN)Detected Distribution: $$DETECTED$(NC)"; \
		echo ""; \
	fi; \
	echo "Available distributions:"; \
	echo "  1) OpenAnolis"; \
	echo "  2) openEuler"; \
	echo ""; \
	read -p "Enter choice [1-2]: " choice; \
	case "$$choice" in \
		1) DISTRO="anolis"; DISTRO_DIR="anolis" ;; \
		2) DISTRO="euler"; DISTRO_DIR="euler" ;; \
		*) echo -e "$(RED)Invalid choice$(NC)"; exit 1 ;; \
	esac; \
	if [ ! -d "$$DISTRO_DIR" ]; then \
		echo -e "$(RED)Error: Distribution directory not found: $$DISTRO_DIR/$(NC)"; \
		exit 1; \
	fi; \
	if [ ! -f "$$DISTRO_DIR/configure.sh" ]; then \
		echo -e "$(RED)Error: Configuration script not found: $$DISTRO_DIR/configure.sh$(NC)"; \
		exit 1; \
	fi; \
	echo "DISTRO=$$DISTRO" > $(DISTRO_CONFIG); \
	echo "DISTRO_DIR=$$DISTRO_DIR" >> $(DISTRO_CONFIG); \
	echo ""; \
	echo -e "$(BLUE)Running $$DISTRO configuration...$(NC)"; \
	bash $$DISTRO_DIR/configure.sh

# Validate configuration exists
validate:
	@if [ ! -f $(DISTRO_CONFIG) ]; then \
		echo -e "$(RED)Error: Not configured. Run 'make config' first.$(NC)"; \
		exit 1; \
	fi

# Build (default target)
build: validate
	@. $(DISTRO_CONFIG); \
	if [ ! -f "$$DISTRO_DIR/build.sh" ]; then \
		echo -e "$(RED)Error: Build script not found: $$DISTRO_DIR/build.sh$(NC)"; \
		exit 1; \
	fi; \
	echo -e "$(BLUE)Running $$DISTRO build...$(NC)"; \
	bash $$DISTRO_DIR/build.sh

# Test
test: validate
	@. $(DISTRO_CONFIG); \
	if [ ! -f "$$DISTRO_DIR/test.sh" ]; then \
		echo -e "$(YELLOW)No test script found: $$DISTRO_DIR/test.sh$(NC)"; \
		exit 0; \
	fi; \
	echo -e "$(BLUE)Running $$DISTRO tests...$(NC)"; \
	bash $$DISTRO_DIR/test.sh

# Reset git repo
reset:
	@if [ ! -f $(HEAD_ID_FILE) ]; then \
		echo -e "$(RED)Error: HEAD commit file not found$(NC)"; \
		exit 1; \
	fi; \
	if [ ! -f $(DISTRO_CONFIG) ]; then \
		echo -e "$(RED)Error: Distribution config not found$(NC)"; \
		exit 1; \
	fi; \
	. $(DISTRO_CONFIG); \
	if [ -f "$$DISTRO_DIR/.configure" ]; then \
		. $$DISTRO_DIR/.configure; \
		HEAD_ID=$$(cat $(HEAD_ID_FILE)); \
		if [ -n "$$HEAD_ID" ] && [ -d "$$LINUX_SRC_PATH/.git" ]; then \
			git -C "$$LINUX_SRC_PATH" reset --hard "$$HEAD_ID"; \
			echo -e "$(GREEN)Reset to: $$HEAD_ID$(NC)"; \
		else \
			echo -e "$(RED)Error: Invalid HEAD ID or git repo$(NC)"; \
			exit 1; \
		fi; \
	else \
		echo -e "$(RED)Error: Distro config not found$(NC)"; \
		exit 1; \
	fi

# Clean logs and outputs
clean:
	@echo -e "$(YELLOW)Cleaning logs and outputs...$(NC)"
	@if [ -f $(DISTRO_CONFIG) ]; then \
		. $(DISTRO_CONFIG); \
		if [ "$$DISTRO" = "euler" ]; then \
			echo "  → Cleaning openEuler artifacts..."; \
			rm -f euler/.commits.txt 2>/dev/null || true; \
			rm -f .dep_log .full_commits .user_log 2>/dev/null || true; \
			rm -rf $(LOGS_DIR) 2>/dev/null || true; \
			rm -rf $(PATCHES_DIR) 2>/dev/null || true; \
			if [ -f "euler/.configure" ]; then \
				LINUX_SRC=$$(grep "^LINUX_SRC_PATH=" euler/.configure | cut -d= -f2 | tr -d '"'); \
				if [ -n "$$LINUX_SRC" ] && [ -d "$$LINUX_SRC" ]; then \
					echo "  → Cleaning kernel build artifacts in $$LINUX_SRC"; \
					cd "$$LINUX_SRC" && make clean > /dev/null 2>&1 || true; \
					rm -rf "$$LINUX_SRC/openeuler/outputs" "$$LINUX_SRC/openeuler/output" 2>/dev/null || true; \
					rm -f "$$LINUX_SRC/openeuler/kernel-rpms" "$$LINUX_SRC/openeuler/.deps_installed" 2>/dev/null || true; \
					rm -rf "$$LINUX_SRC/euler/outputs" "$$LINUX_SRC/euler/output" 2>/dev/null || true; \
					rm -f "$$LINUX_SRC/euler/kernel-rpms" "$$LINUX_SRC/euler/.deps_installed" 2>/dev/null || true; \
				fi; \
			fi; \
			echo "  → openEuler cleanup complete"; \
		elif [ "$$DISTRO" = "anolis" ]; then \
			echo "  → Cleaning OpenAnolis artifacts..."; \
			rm -rf $(LOGS_DIR) 2>/dev/null || true; \
			rm -rf $(PATCHES_DIR) 2>/dev/null || true; \
			if [ -f "anolis/.configure" ]; then \
				LINUX_SRC=$$(grep "^LINUX_SRC_PATH=" anolis/.configure | cut -d= -f2 | tr -d '"'); \
				if [ -n "$$LINUX_SRC" ] && [ -d "$$LINUX_SRC" ]; then \
					echo "  → Cleaning kernel build artifacts in $$LINUX_SRC"; \
					cd "$$LINUX_SRC" && make clean > /dev/null 2>&1 || true; \
					rm -rf "$$LINUX_SRC/anolis/outputs" "$$LINUX_SRC/anolis/output" 2>/dev/null || true; \
					rm -f "$$LINUX_SRC/anolis/cloud-kernel" "$$LINUX_SRC/anolis/.deps_installed" 2>/dev/null || true; \
				fi; \
			fi; \
			echo "  → OpenAnolis cleanup complete"; \
		fi; \
	else \
		echo "  → No distribution configured, cleaning common artifacts only"; \
		rm -rf $(LOGS_DIR) $(PATCHES_DIR) 2>/dev/null || true; \
	fi
	@echo -e "$(GREEN)Clean complete$(NC)"

# Complete cleanup
distclean:
	@echo -e "$(YELLOW)Removing all artifacts and configurations...$(NC)"
	@if [ -f $(DISTRO_CONFIG) ]; then \
		. $(DISTRO_CONFIG); \
		if [ "$$DISTRO" = "euler" ]; then \
			echo "  → Complete openEuler cleanup..."; \
			rm -f euler/.commits.txt 2>/dev/null || true; \
			rm -f .distro_config .stable_log .head_commit_id 2>/dev/null || true; \
			rm -f .dep_log .full_commits .user_log 2>/dev/null || true; \
			rm -rf .torvalds-linux 2>/dev/null || true; \
			rm -rf $(LOGS_DIR) 2>/dev/null || true; \
			rm -rf $(PATCHES_DIR) 2>/dev/null || true; \
			if [ -f "euler/.configure" ]; then \
				LINUX_SRC=$$(grep "^LINUX_SRC_PATH=" euler/.configure | cut -d= -f2 | tr -d '"'); \
				if [ -n "$$LINUX_SRC" ] && [ -d "$$LINUX_SRC" ]; then \
					echo "  → Running make distclean in $$LINUX_SRC"; \
					cd "$$LINUX_SRC" && make distclean > /dev/null 2>&1 || true; \
					rm -rf "$$LINUX_SRC/openeuler/outputs" "$$LINUX_SRC/openeuler/output" 2>/dev/null || true; \
					rm -f "$$LINUX_SRC/openeuler/kernel-rpms" "$$LINUX_SRC/openeuler/.deps_installed" 2>/dev/null || true; \
					rm -rf "$$LINUX_SRC/euler/outputs" "$$LINUX_SRC/euler/output" 2>/dev/null || true; \
					rm -f "$$LINUX_SRC/euler/kernel-rpms" "$$LINUX_SRC/euler/.deps_installed" 2>/dev/null || true; \
					rm -f "$$LINUX_SRC/Module.symvers_old" 2>/dev/null || true; \
					rm -f "$$LINUX_SRC/scripts/.check-kabi-updated" 2>/dev/null || true; \
				fi; \
				rm -f euler/.configure 2>/dev/null || true; \
			fi; \
			echo "  → openEuler complete cleanup done"; \
		elif [ "$$DISTRO" = "anolis" ]; then \
			echo "  → Complete OpenAnolis cleanup..."; \
			rm -f .distro_config .head_commit_id 2>/dev/null || true; \
			rm -rf $(LOGS_DIR) 2>/dev/null || true; \
			rm -rf $(PATCHES_DIR) 2>/dev/null || true; \
			if [ -f "anolis/.configure" ]; then \
				LINUX_SRC=$$(grep "^LINUX_SRC_PATH=" anolis/.configure | cut -d= -f2 | tr -d '"'); \
				if [ -n "$$LINUX_SRC" ] && [ -d "$$LINUX_SRC" ]; then \
					echo "  → Running make distclean in $$LINUX_SRC"; \
					cd "$$LINUX_SRC" && make distclean > /dev/null 2>&1 || true; \
					rm -rf "$$LINUX_SRC/anolis/outputs" "$$LINUX_SRC/anolis/output" 2>/dev/null || true; \
					rm -f "$$LINUX_SRC/anolis/cloud-kernel" "$$LINUX_SRC/anolis/.deps_installed" 2>/dev/null || true; \
				fi; \
				rm -f anolis/.configure 2>/dev/null || true; \
			fi; \
			echo "  → OpenAnolis complete cleanup done"; \
		fi; \
	else \
		echo "  → No distribution configured, cleaning common artifacts only"; \
		rm -rf $(LOGS_DIR) $(PATCHES_DIR) 2>/dev/null || true; \
		rm -f .distro_config .head_commit_id .stable_log 2>/dev/null || true; \
		rm -f .dep_log .full_commits .user_log 2>/dev/null || true; \
		rm -rf .torvalds-linux 2>/dev/null || true; \
		rm -f euler/.configure anolis/.configure 2>/dev/null || true; \
	fi
	@echo -e "$(GREEN)Complete cleanup done$(NC)"
