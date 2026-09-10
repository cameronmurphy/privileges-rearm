APP_NAME  := PrivilegesRearm
BUNDLE_ID := com.cammurphy.privileges-rearm
APP       := $(HOME)/Applications/$(APP_NAME).app
PLIST     := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist
BUILD     := build
BIN       := $(BUILD)/$(APP_NAME)
UID_N     := $(shell id -u)

INFO_PLIST := <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleName</key><string>$(APP_NAME)</string><key>CFBundleDisplayName</key><string>$(APP_NAME)</string><key>CFBundleIdentifier</key><string>$(BUNDLE_ID)</string><key>CFBundleExecutable</key><string>$(APP_NAME)</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1.0</string><key>CFBundleShortVersionString</key><string>1.0</string><key>LSUIElement</key><true/></dict></plist>
AGENT_PLIST := <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Label</key><string>$(BUNDLE_ID)</string><key>ProgramArguments</key><array><string>$(APP)/Contents/MacOS/$(APP_NAME)</string></array><key>StartInterval</key><integer>15</integer><key>RunAtLoad</key><true/><key>StandardErrorPath</key><string>/tmp/privileges-rearm.err</string></dict></plist>

.PHONY: all build install grant status uninstall clean

all: build

build: $(BIN)

$(BIN): $(APP_NAME).swift
	@mkdir -p $(BUILD)
	swiftc -O -o $(BIN) $(APP_NAME).swift -framework CoreGraphics -framework ApplicationServices
	@echo "built $(BIN)"

## Assemble the signed .app, install it, and load the LaunchAgent.
## Rebuilding changes the binary's cdhash, so macOS may ask you to
## re-approve Accessibility afterwards.
install: build
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS"
	@cp $(BIN) "$(APP)/Contents/MacOS/$(APP_NAME)"
	@chmod +x "$(APP)/Contents/MacOS/$(APP_NAME)"
	@printf '%s' '$(INFO_PLIST)' > "$(APP)/Contents/Info.plist"
	@plutil -lint "$(APP)/Contents/Info.plist" >/dev/null
	@codesign --force --sign - "$(APP)"
	@mkdir -p "$(HOME)/Library/LaunchAgents"
	@printf '%s' '$(AGENT_PLIST)' > "$(PLIST)"
	@plutil -lint "$(PLIST)" >/dev/null
	@launchctl bootout gui/$(UID_N) "$(PLIST)" 2>/dev/null || true
	@launchctl bootstrap gui/$(UID_N) "$(PLIST)"
	@echo "installed $(APP), LaunchAgent loaded (15s interval)"
	@echo "if Accessibility is not approved yet, run: make grant"

## Launch the app standalone so it raises the Accessibility prompt in its
## own name (running it from a terminal would inherit the terminal's grant).
grant:
	@open -a "$(APP)" --args --setup
	@echo "approve $(APP_NAME) in System Settings > Privacy & Security > Accessibility"

status:
	@"$(APP)/Contents/MacOS/$(APP_NAME)" --status 2>/dev/null || echo "app not installed"
	@launchctl print gui/$(UID_N)/$(BUNDLE_ID) 2>/dev/null | grep -E "state =|program =" | head -2 || echo "agent not loaded"

uninstall:
	@launchctl bootout gui/$(UID_N) "$(PLIST)" 2>/dev/null || true
	@rm -f "$(PLIST)"
	@rm -rf "$(APP)"
	@echo "removed app and LaunchAgent"
	@echo "remove the $(APP_NAME) entry from Accessibility manually"

clean:
	@rm -rf $(BUILD)
