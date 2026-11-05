PROJECT := NVModern.xcodeproj
SCHEME := NVModern
APP_NAME := nvModern
# Must not case-fold to APP_NAME: APFS is case-insensitive, so `nvmodern`
# overwrites the GUI binary at Contents/MacOS/nvModern.
CLI_NAME := nv3
DESTINATION := platform=macOS,arch=arm64
ARCH_SETTINGS := ARCHS=arm64
LOG_DIR := /tmp/nvmodern
DIST_DIR := dist
INSTALL_DIR := /Applications
WEBEDITOR_DIR := NVModern/WebEditor

ifeq ($(shell echo $(CLI_NAME) | tr '[:upper:]' '[:lower:]'),$(shell echo $(APP_NAME) | tr '[:upper:]' '[:lower:]'))
$(error CLI_NAME '$(CLI_NAME)' collides with APP_NAME '$(APP_NAME)' on a case-insensitive filesystem)
endif

.PHONY: all setup dev web-editor typecheck-plugins typecheck-arbor typecheck-calc typecheck-help test-web test-arbor-kernel test project build cli run run-logged run-perf profile-perf package release install open clean

all: build

setup:
	@mkdir -p $(LOG_DIR)
	@echo "🔧 Checking local toolchain..."
	@if command -v xcodebuild >/dev/null 2>&1 && xcode-select -p >/dev/null 2>&1; then \
		echo "✅ Xcode / Command Line Tools present"; \
	else \
		echo "⚠️  Xcode Command Line Tools missing. Triggering installer..."; \
		xcode-select --install >/dev/null 2>&1 || true; \
		echo "ℹ️  Complete Xcode/CLT install, then re-run 'make setup'"; \
	fi
	@if command -v brew >/dev/null 2>&1; then \
		if command -v xcodegen >/dev/null 2>&1; then \
			echo "✅ xcodegen already installed"; \
		else \
			echo "⬇️  Installing xcodegen via Homebrew..."; \
			brew install xcodegen > $(LOG_DIR)/setup-xcodegen.log 2>&1; \
			echo "📝 xcodegen install log: $(LOG_DIR)/setup-xcodegen.log"; \
		fi; \
		if command -v bun >/dev/null 2>&1; then \
			echo "✅ bun already installed"; \
		else \
			echo "⬇️  Installing bun via Homebrew..."; \
			brew install bun > $(LOG_DIR)/setup-bun.log 2>&1; \
			echo "📝 bun install log: $(LOG_DIR)/setup-bun.log"; \
		fi; \
	else \
		echo "⚠️  Homebrew not found; skipping automatic installs for bun/xcodegen"; \
		echo "    Install Homebrew: https://brew.sh"; \
	fi
	@MISSING=0; \
	for tool in xcodebuild xcodegen bun hdiutil; do \
		if command -v $$tool >/dev/null 2>&1; then \
			echo "✅ $$tool"; \
		else \
			echo "❌ Missing $$tool"; \
			MISSING=1; \
		fi; \
	done; \
	if [ $$MISSING -ne 0 ]; then \
		echo "❌ Setup incomplete. Install missing dependencies and re-run make setup."; \
		exit 1; \
	fi
	@echo "✅ Setup complete"

dev:
	@if ! command -v bun >/dev/null 2>&1; then \
		echo "❌ bun is required to run the editor dev server"; \
		exit 1; \
	fi
	@cd $(WEBEDITOR_DIR) && bun install --silent 2>/dev/null
	@echo "Starting editor dev server…"
	@cd $(WEBEDITOR_DIR) && EDITOR_ROOT=$${EDITOR_ROOT:-test-files} bun --hot shell/server.ts

web-editor:
	@mkdir -p $(LOG_DIR)
	@if ! command -v bun >/dev/null 2>&1; then \
		echo "❌ bun is required to build web editor assets"; \
		exit 1; \
	fi
	@cd $(WEBEDITOR_DIR) && bun install --frozen-lockfile --silent > $(LOG_DIR)/web-editor-install.log 2>&1
	@cd $(WEBEDITOR_DIR) && bun run build > $(LOG_DIR)/web-editor-build.log 2>&1
	@echo "✅ Web Editor built"

typecheck-arbor:
	@mkdir -p $(LOG_DIR)
	@if ! command -v bun >/dev/null 2>&1; then \
		echo "❌ bun is required to typecheck Arbor"; \
		exit 1; \
	fi
	@cd $(WEBEDITOR_DIR) && bun install --frozen-lockfile --silent > $(LOG_DIR)/web-editor-typecheck-install.log 2>&1
	@cd $(WEBEDITOR_DIR) && bun run typecheck:arbor > $(LOG_DIR)/arbor-typecheck.log 2>&1
	@echo "✅ Arbor typecheck passed"

typecheck-calc:
	@mkdir -p $(LOG_DIR)
	@cd $(WEBEDITOR_DIR) && ./node_modules/.bin/tsc -p tsconfig.calc.json > $(LOG_DIR)/calc-typecheck.log 2>&1
	@echo "✅ Calc typecheck passed"

typecheck-help:
	@mkdir -p $(LOG_DIR)
	@cd $(WEBEDITOR_DIR) && ./node_modules/.bin/tsc -p tsconfig.help.json > $(LOG_DIR)/help-typecheck.log 2>&1
	@echo "✅ Help typecheck passed"

.PHONY: calc-reference
calc-reference:
	@cd $(WEBEDITOR_DIR) && bun scripts/calc-reference.ts
	@echo "✅ Calc reference generated"

typecheck-plugins:
	@mkdir -p $(LOG_DIR)
	@cd $(WEBEDITOR_DIR) && ./node_modules/.bin/tsc -p ../Plugins > $(LOG_DIR)/plugins-typecheck.log 2>&1
	@echo "✅ Plugin API examples typecheck passed"

test-web:
	@mkdir -p $(LOG_DIR)
	@if ! command -v bun >/dev/null 2>&1; then \
		echo "❌ bun is required to run web editor tests"; \
		exit 1; \
	fi
	@cd $(WEBEDITOR_DIR) && bun install --frozen-lockfile --silent > $(LOG_DIR)/web-editor-test-install.log 2>&1
	@TEST_LOG="$(LOG_DIR)/web-editor-test-$$(date +%Y%m%d-%H%M%S).log"; \
	TEST_ARGS="$(TEST_ARGS)"; \
	if cd $(WEBEDITOR_DIR) && bun test $$TEST_ARGS > "$$TEST_LOG" 2>&1; then \
		ln -sf "$$TEST_LOG" "$(LOG_DIR)/latest-web-editor-test.log"; \
		echo "✅ Web Editor tests passed"; \
		echo "Log: $$TEST_LOG"; \
	else \
		ln -sf "$$TEST_LOG" "$(LOG_DIR)/latest-web-editor-test.log"; \
		echo "❌ Web Editor tests failed"; \
		echo "Log: $$TEST_LOG"; \
		exit 1; \
	fi

test-arbor-kernel:
	@mkdir -p $(LOG_DIR)
	@if command -v raco >/dev/null 2>&1; then \
		LOG_FILE="$(LOG_DIR)/arbor-kernel-test-$$(date +%Y%m%d-%H%M%S).log"; \
		if raco test ArborKernel/tests > "$$LOG_FILE" 2>&1; then \
			ln -sf "$$LOG_FILE" "$(LOG_DIR)/latest-arbor-kernel-test.log"; \
			echo "✅ Arbor kernel tests passed"; \
			echo "Log: $$LOG_FILE"; \
		else \
			ln -sf "$$LOG_FILE" "$(LOG_DIR)/latest-arbor-kernel-test.log"; \
			echo "❌ Arbor kernel tests failed"; \
			echo "Log: $$LOG_FILE"; \
			exit 1; \
		fi; \
	else \
		echo "ℹ️  Racket is not installed; native missing-kernel behavior remains covered by Swift tests"; \
	fi

project: web-editor
	@mkdir -p $(LOG_DIR)
	@xcodegen generate > $(LOG_DIR)/xcodegen.log 2>&1
	@echo "✅ XCode project generated"

build: project
	@mkdir -p $(LOG_DIR)
	@LOG_FILE="$(LOG_DIR)/build-$$(date +%Y%m%d-%H%M%S).log"; \
	if xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination '$(DESTINATION)' $(ARCH_SETTINGS) build > "$$LOG_FILE" 2>&1; then \
		ln -sf "$$LOG_FILE" "$(LOG_DIR)/latest-build.log"; \
		echo "✅ Build passed"; \
		echo "Log: $$LOG_FILE"; \
	else \
		ln -sf "$$LOG_FILE" "$(LOG_DIR)/latest-build.log"; \
		echo "❌ Build failed"; \
		echo "Log: $$LOG_FILE"; \
		exit 1; \
	fi

cli: build
	@mkdir -p $(DIST_DIR)
	@CLI_PATH="$$(find ~/Library/Developer/Xcode/DerivedData -type f -path '*/Build/Products/Debug/$(CLI_NAME)' ! -path '*.app/*' -print0 \
		| xargs -0 stat -f '%m %N' 2>/dev/null \
		| sort -nr \
		| head -n 1 \
		| cut -d' ' -f2-)"; \
	if [ -n "$$CLI_PATH" ] && [ -x "$$CLI_PATH" ]; then \
		cp "$$CLI_PATH" "$(DIST_DIR)/$(CLI_NAME)"; \
		echo "✅ CLI: $(DIST_DIR)/$(CLI_NAME)"; \
	else \
		echo "❌ Could not find $(CLI_NAME) in DerivedData"; \
		exit 1; \
	fi

test: project
	@mkdir -p $(LOG_DIR)
	@LOG_FILE="$(LOG_DIR)/test-$$(date +%Y%m%d-%H%M%S).log"; \
	if xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination '$(DESTINATION)' $(ARCH_SETTINGS) $(if $(TEST_ONLY),-only-testing:$(TEST_ONLY)) test > "$$LOG_FILE" 2>&1; then \
		ln -sf "$$LOG_FILE" "$(LOG_DIR)/latest-test.log"; \
		echo "✅ Tests passed"; \
		echo "Log: $$LOG_FILE"; \
	else \
		ln -sf "$$LOG_FILE" "$(LOG_DIR)/latest-test.log"; \
		echo "❌ Tests failed"; \
		echo "Log: $$LOG_FILE"; \
		exit 1; \
	fi

run: build
	@APP_PATH="$$(find ~/Library/Developer/Xcode/DerivedData -type d -path '*/Build/Products/Debug/$(APP_NAME).app' ! -path '*/Index.noindex/*' -print0 \
		| xargs -0 stat -f '%m %N' 2>/dev/null \
		| sort -nr \
		| head -n 1 \
		| cut -d' ' -f2-)"; \
	if [ -n "$$APP_PATH" ] && [ -x "$$APP_PATH/Contents/MacOS/$(APP_NAME)" ]; then \
		open "$$APP_PATH"; \
		echo "Opened $$APP_PATH"; \
	else \
		echo "❌ Could not find a runnable $(APP_NAME).app in DerivedData"; \
		echo "Check /tmp/nvmodern/latest-build.log"; \
		exit 1; \
	fi

try-run:
	@APP_PATH="$$(find ~/Library/Developer/Xcode/DerivedData -type d -path '*/Build/Products/Debug/$(APP_NAME).app' ! -path '*/Index.noindex/*' -print0 \
		| xargs -0 stat -f '%m %N' 2>/dev/null \
		| sort -nr \
		| head -n 1 \
		| cut -d' ' -f2-)"; \
	if [ -n "$$APP_PATH" ] && [ -x "$$APP_PATH/Contents/MacOS/$(APP_NAME)" ]; then \
		open "$$APP_PATH"; \
		echo "Opened $$APP_PATH"; \
	else \
		echo "❌ Could not find a runnable $(APP_NAME).app in DerivedData"; \
		echo "Check /tmp/nvmodern/latest-build.log"; \
		exit 1; \
	fi

run-logged: build
	@APP_PATH="$$(find ~/Library/Developer/Xcode/DerivedData -type d -path '*/Build/Products/Debug/$(APP_NAME).app' ! -path '*/Index.noindex/*' -print0 \
		| xargs -0 stat -f '%m %N' 2>/dev/null \
		| sort -nr \
		| head -n 1 \
		| cut -d' ' -f2-)"; \
	if pgrep -x "$(APP_NAME)" >/dev/null 2>&1; then \
		echo "❌ $(APP_NAME) is already running. Quit it before starting a logged run."; \
		exit 1; \
	elif [ -n "$$APP_PATH" ] && [ -x "$$APP_PATH/Contents/MacOS/$(APP_NAME)" ]; then \
		echo "Running $$APP_PATH with Miller diagnostics enabled"; \
		NVMODERN_MILLER_DIAGNOSTICS=1 "$$APP_PATH/Contents/MacOS/$(APP_NAME)"; \
	else \
		echo "❌ Could not find a runnable $(APP_NAME).app in DerivedData"; \
		echo "Check /tmp/nvmodern/latest-build.log"; \
		exit 1; \
	fi

run-perf: build
	@APP_PATH="$$(find ~/Library/Developer/Xcode/DerivedData -type d -path '*/Build/Products/Debug/$(APP_NAME).app' ! -path '*/Index.noindex/*' -print0 \
		| xargs -0 stat -f '%m %N' 2>/dev/null \
		| sort -nr \
		| head -n 1 \
		| cut -d' ' -f2-)"; \
	if pgrep -x "$(APP_NAME)" >/dev/null 2>&1; then \
		echo "❌ $(APP_NAME) is already running. Quit it before starting a performance trace."; \
		exit 1; \
	elif [ -n "$$APP_PATH" ] && [ -x "$$APP_PATH/Contents/MacOS/$(APP_NAME)" ]; then \
		echo "Running $$APP_PATH with performance tracing enabled"; \
		"$$APP_PATH/Contents/MacOS/$(APP_NAME)"; \
	else \
		echo "❌ Could not find a runnable $(APP_NAME).app in DerivedData"; \
		echo "Check /tmp/nvmodern/latest-build.log"; \
		exit 1; \
	fi

profile-perf: build
	@PROFILE_DIR="$(LOG_DIR)/profile-$$(date +%Y%m%d-%H%M%S)"; \
	APP_PATH="$$(find ~/Library/Developer/Xcode/DerivedData -type d -path '*/Build/Products/Debug/$(APP_NAME).app' ! -path '*/Index.noindex/*' -print0 \
		| xargs -0 stat -f '%m %N' 2>/dev/null \
		| sort -nr \
		| head -n 1 \
		| cut -d' ' -f2-)"; \
	if pgrep -x "$(APP_NAME)" >/dev/null 2>&1; then \
		echo "❌ $(APP_NAME) is already running. Quit it before profiling."; \
		exit 1; \
	elif [ -z "$$APP_PATH" ] || [ ! -x "$$APP_PATH/Contents/MacOS/$(APP_NAME)" ]; then \
		echo "❌ Could not find a runnable $(APP_NAME).app in DerivedData"; \
		exit 1; \
	fi; \
	mkdir -p "$$PROFILE_DIR"; \
	echo "Recording 30 seconds of Time Profiler data."; \
	echo "Trace: $$PROFILE_DIR/nvmodern.trace"; \
	echo "When the app appears: Cmd-Tab away/back twice, press Cmd-T once, then click + once."; \
	xcrun xctrace record \
		--template 'Time Profiler' \
		--time-limit 30s \
		--output "$$PROFILE_DIR/nvmodern.trace" \
		--target-stdout "$$PROFILE_DIR/perf.log" \
		--env NVMODERN_DISABLE_NATIVE_TOOLBAR="$${NVMODERN_DISABLE_NATIVE_TOOLBAR:-0}" \
		--launch -- /bin/zsh -c 'exec "$$1" 2>&1' _ "$$APP_PATH/Contents/MacOS/$(APP_NAME)"; \
	TRACE_STATUS=$$?; \
	if [ $$TRACE_STATUS -eq 0 ] || { [ $$TRACE_STATUS -eq 54 ] && [ -d "$$PROFILE_DIR/nvmodern.trace" ]; }; then \
		echo "✅ Performance trace saved: $$PROFILE_DIR/nvmodern.trace"; \
	else \
		exit $$TRACE_STATUS; \
	fi

# Signed, notarized release + Sparkle appcast. Never publishes; see docs/releasing.md.
# Usually run by .github/workflows/release.yml on a `v*` tag. Locally:
#   make release VERSION=2.1.0 DEVELOPER_ID="Developer ID Application: Name (TEAMID)" \
#                NOTARY_PROFILE=nvmodern-notary
release: project
	@LOG_DIR="$(LOG_DIR)" bash Tools/release.sh

package: project
	@mkdir -p $(LOG_DIR) $(DIST_DIR)
	@BUILD_LOG="$(LOG_DIR)/package-build-$$(date +%Y%m%d-%H%M%S).log"; \
	if xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -destination '$(DESTINATION)' $(ARCH_SETTINGS) build > "$$BUILD_LOG" 2>&1; then \
		ln -sf "$$BUILD_LOG" "$(LOG_DIR)/latest-package-build.log"; \
		echo "✅ Release build passed"; \
		echo "Log: $$BUILD_LOG"; \
	else \
		ln -sf "$$BUILD_LOG" "$(LOG_DIR)/latest-package-build.log"; \
		echo "❌ Release build failed"; \
		echo "Log: $$BUILD_LOG"; \
		exit 1; \
	fi; \
	APP_PATH="$$(find ~/Library/Developer/Xcode/DerivedData -type d -path '*/Build/Products/Release/$(APP_NAME).app' ! -path '*/Index.noindex/*' -print0 \
		| xargs -0 stat -f '%m %N' 2>/dev/null \
		| sort -nr \
		| head -n 1 \
		| cut -d' ' -f2-)"; \
	if [ -z "$$APP_PATH" ] || [ ! -x "$$APP_PATH/Contents/MacOS/$(APP_NAME)" ]; then \
		echo "❌ Could not find Release $(APP_NAME).app in DerivedData"; \
		exit 1; \
	fi; \
	CLI_PATH="$$(find ~/Library/Developer/Xcode/DerivedData -type f -path '*/Build/Products/Release/$(CLI_NAME)' ! -path '*.app/*' -print0 \
		| xargs -0 stat -f '%m %N' 2>/dev/null \
		| sort -nr \
		| head -n 1 \
		| cut -d' ' -f2-)"; \
	if [ -n "$$CLI_PATH" ] && [ -x "$$CLI_PATH" ]; then \
		cp "$$CLI_PATH" "$(DIST_DIR)/$(CLI_NAME)"; \
		cp "$$CLI_PATH" "$$APP_PATH/Contents/MacOS/$(CLI_NAME)"; \
	fi; \
	STAGE_DIR="$(LOG_DIR)/package-stage"; \
	rm -rf "$$STAGE_DIR"; \
	mkdir -p "$$STAGE_DIR"; \
	rm -rf "$(DIST_DIR)/$(APP_NAME).app"; \
	cp -R "$$APP_PATH" "$(DIST_DIR)/$(APP_NAME).app"; \
	cp -R "$$APP_PATH" "$$STAGE_DIR/$(APP_NAME).app"; \
	ln -s /Applications "$$STAGE_DIR/Applications"; \
	DMG_NAME="$(APP_NAME)-$$(date +%Y%m%d-%H%M%S).dmg"; \
	DMG_PATH="$(DIST_DIR)/$$DMG_NAME"; \
	DMG_LOG="$(LOG_DIR)/package-dmg-$$(date +%Y%m%d-%H%M%S).log"; \
	rm -f "$$DMG_PATH"; \
	if hdiutil create -volname "$(APP_NAME)" -srcfolder "$$STAGE_DIR" -format UDZO -ov "$$DMG_PATH" > "$$DMG_LOG" 2>&1; then \
		ln -sf "$$DMG_LOG" "$(LOG_DIR)/latest-package-dmg.log"; \
		ln -sf "$$DMG_NAME" "$(DIST_DIR)/$(APP_NAME)-latest.dmg"; \
		echo "✅ Package created"; \
		echo "App: $(DIST_DIR)/$(APP_NAME).app"; \
		echo "DMG: $$DMG_PATH"; \
	else \
		ln -sf "$$DMG_LOG" "$(LOG_DIR)/latest-package-dmg.log"; \
		echo "❌ Failed to create DMG"; \
		echo "Log: $$DMG_LOG"; \
		exit 1; \
	fi

install: project
	@mkdir -p $(LOG_DIR)
	@if pgrep -x "$(APP_NAME)" >/dev/null 2>&1; then \
		echo "❌ $(APP_NAME) is running. Quit it first — replacing the bundle underneath a running process leaves it in a broken state."; \
		exit 1; \
	fi
	@BUILD_LOG="$(LOG_DIR)/install-build-$$(date +%Y%m%d-%H%M%S).log"; \
	if xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -destination '$(DESTINATION)' $(ARCH_SETTINGS) build > "$$BUILD_LOG" 2>&1; then \
		ln -sf "$$BUILD_LOG" "$(LOG_DIR)/latest-install-build.log"; \
		echo "✅ Release build passed"; \
		echo "Log: $$BUILD_LOG"; \
	else \
		ln -sf "$$BUILD_LOG" "$(LOG_DIR)/latest-install-build.log"; \
		echo "❌ Release build failed"; \
		echo "Log: $$BUILD_LOG"; \
		exit 1; \
	fi; \
	APP_PATH="$$(find ~/Library/Developer/Xcode/DerivedData -type d -path '*/Build/Products/Release/$(APP_NAME).app' ! -path '*/Index.noindex/*' -print0 \
		| xargs -0 stat -f '%m %N' 2>/dev/null \
		| sort -nr \
		| head -n 1 \
		| cut -d' ' -f2-)"; \
	if [ -z "$$APP_PATH" ] || [ ! -x "$$APP_PATH/Contents/MacOS/$(APP_NAME)" ]; then \
		echo "❌ Could not find Release $(APP_NAME).app in DerivedData"; \
		exit 1; \
	fi; \
	CLI_PATH="$$(find ~/Library/Developer/Xcode/DerivedData -type f -path '*/Build/Products/Release/$(CLI_NAME)' ! -path '*.app/*' -print0 \
		| xargs -0 stat -f '%m %N' 2>/dev/null \
		| sort -nr \
		| head -n 1 \
		| cut -d' ' -f2-)"; \
	if [ -n "$$CLI_PATH" ] && [ -x "$$CLI_PATH" ]; then \
		cp "$$CLI_PATH" "$$APP_PATH/Contents/MacOS/$(CLI_NAME)"; \
	fi; \
	if [ ! -w "$(INSTALL_DIR)" ]; then \
		echo "❌ $(INSTALL_DIR) is not writable by $$(whoami)"; \
		exit 1; \
	fi; \
	STAGE_PATH="$(INSTALL_DIR)/.$(APP_NAME).app.installing"; \
	rm -rf "$$STAGE_PATH"; \
	if ! cp -R "$$APP_PATH" "$$STAGE_PATH"; then \
		rm -rf "$$STAGE_PATH"; \
		echo "❌ Failed to copy $(APP_NAME).app into $(INSTALL_DIR)"; \
		exit 1; \
	fi; \
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"; \
	mv "$$STAGE_PATH" "$(INSTALL_DIR)/$(APP_NAME).app"; \
	echo "✅ Installed"; \
	echo "App: $(INSTALL_DIR)/$(APP_NAME).app"

open: project
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -resolvePackageDependencies > $(LOG_DIR)/resolve-packages.log 2>&1
	@open $(PROJECT)
	@echo "Opened $(PROJECT)"

clean:
	@mkdir -p $(LOG_DIR)
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug clean > $(LOG_DIR)/xcode-clean-debug.log 2>&1 || true
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release clean > $(LOG_DIR)/xcode-clean-release.log 2>&1 || true
	@rm -rf $(DIST_DIR)
	@echo "Removed $(DIST_DIR)"
	@rm -rf NVModern/Resources/WebEditor
	@echo "Removed NVModern/Resources/WebEditor"
	@rm -rf $(LOG_DIR)/package-stage
	@echo "Removed $(LOG_DIR)/package-stage"
	@rm -rf ~/Library/Developer/Xcode/DerivedData/NVModern-*
	@echo "Removed DerivedData artifact"
	@rm -rf /tmp/nvmodern
