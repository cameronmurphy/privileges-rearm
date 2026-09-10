APP_NAME  := PrivilegesRearm
BUNDLE_ID := com.cammurphy.privileges-rearm
BUILD     := build
BIN       := $(BUILD)/$(APP_NAME)
APP_BUILT := $(BUILD)/$(APP_NAME).app
APP       := $(HOME)/Applications/$(APP_NAME).app
PLIST     := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist
UID_N     := $(shell id -u)
NOTARY_PROFILE ?= privileges-rearm

# Prefer a Developer ID identity. TCC keys a Developer ID app's Accessibility
# grant to the signing identity, so it survives rebuilds; an ad-hoc signature
# is keyed to the cdhash and every rebuild forces re-approval.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $$2; exit}')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

# Hardened runtime + secure timestamp are required for notarization, but are
# not valid for ad-hoc signing.
ifeq ($(SIGN_ID),-)
CODESIGN_EXTRA :=
else
CODESIGN_EXTRA := --options runtime --timestamp
endif

INFO_PLIST := <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleName</key><string>$(APP_NAME)</string><key>CFBundleDisplayName</key><string>$(APP_NAME)</string><key>CFBundleIdentifier</key><string>$(BUNDLE_ID)</string><key>CFBundleExecutable</key><string>$(APP_NAME)</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1.0</string><key>CFBundleShortVersionString</key><string>1.0</string><key>LSUIElement</key><true/></dict></plist>
AGENT_PLIST := <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Label</key><string>$(BUNDLE_ID)</string><key>ProgramArguments</key><array><string>$(APP)/Contents/MacOS/$(APP_NAME)</string></array><key>StartInterval</key><integer>15</integer><key>RunAtLoad</key><true/><key>StandardOutPath</key><string>/tmp/privileges-rearm.out</string><key>StandardErrorPath</key><string>/tmp/privileges-rearm.err</string></dict></plist>

.PHONY: all build app sign-info install grant status uninstall notarize clean

all: app

sign-info:
	@echo "signing identity: $(SIGN_ID)"

build: $(BIN)

$(BIN): $(APP_NAME).swift
	@mkdir -p $(BUILD)
	swiftc -O -o $(BIN) $(APP_NAME).swift -framework CoreGraphics -framework ApplicationServices
	@echo "built $(BIN)"

## Assemble and sign the bundle under build/. Does not touch ~/Applications,
## so CI can run this on a machine that has no Privileges.app.
app: build
	@rm -rf "$(APP_BUILT)"
	@mkdir -p "$(APP_BUILT)/Contents/MacOS"
	@cp $(BIN) "$(APP_BUILT)/Contents/MacOS/$(APP_NAME)"
	@chmod +x "$(APP_BUILT)/Contents/MacOS/$(APP_NAME)"
	@printf '%s' '$(INFO_PLIST)' > "$(APP_BUILT)/Contents/Info.plist"
	@plutil -lint "$(APP_BUILT)/Contents/Info.plist" >/dev/null
	codesign --force --sign "$(SIGN_ID)" $(CODESIGN_EXTRA) "$(APP_BUILT)"
	@codesign -dv "$(APP_BUILT)" 2>&1 | grep -E "Identifier|Authority|Signature" || true
	@echo "assembled $(APP_BUILT)"

## Zip, submit to Apple, staple the ticket. Only needed if the app will be
## downloaded (a download gets quarantined; a local build does not).
## Set up once with: xcrun notarytool store-credentials $(NOTARY_PROFILE)
notarize: app
	@ditto -c -k --keepParent "$(APP_BUILT)" "$(BUILD)/$(APP_NAME).zip"
	xcrun notarytool submit "$(BUILD)/$(APP_NAME).zip" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(APP_BUILT)"
	@echo "notarized and stapled"

## The app installs itself: it copies to ~/Applications, writes and loads the
## LaunchAgent, and raises the Accessibility prompt from the installed copy.
## Equivalent to just double-clicking the .app.
install: app
	@"$(APP_BUILT)/Contents/MacOS/$(APP_NAME)" --install

## Only needed to re-raise the Accessibility prompt on an already-installed app.
grant:
	@open -a "$(APP)" --args --setup
	@echo "approve $(APP_NAME) in System Settings > Privacy & Security > Accessibility"

status:
	@"$(APP)/Contents/MacOS/$(APP_NAME)" --status 2>/dev/null || echo "app not installed"
	@launchctl print gui/$(UID_N)/$(BUNDLE_ID) 2>/dev/null | grep -E "state =|program =" | head -2 || echo "agent not loaded"
	@tail -5 "$(HOME)/Library/Application Support/privileges-rearm/rearm.log" 2>/dev/null || true

uninstall:
	@launchctl bootout gui/$(UID_N) "$(PLIST)" 2>/dev/null || true
	@rm -f "$(PLIST)"
	@rm -rf "$(APP)"
	@echo "removed app and LaunchAgent"
	@echo "remove the $(APP_NAME) entry from Accessibility manually"

clean:
	@rm -rf $(BUILD)
