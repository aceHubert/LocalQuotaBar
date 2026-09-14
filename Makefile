APP_NAME := LocalQuotaBar
BUNDLE := .build/release/$(APP_NAME).app
BIN := .build/release/$(APP_NAME)
ICON := Resources/AppIcon.icns

.PHONY: build icon app run clean install

build:
	swift build -c release

icon:
	swift Tools/render-icon.swift "$(CURDIR)/Resources/AppIcon-1024.png"
	rm -rf Resources/AppIcon.iconset
	mkdir -p Resources/AppIcon.iconset
	sips -z 16 16 Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_16x16.png
	sips -z 32 32 Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_16x16@2x.png
	sips -z 32 32 Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_32x32.png
	sips -z 64 64 Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_32x32@2x.png
	sips -z 128 128 Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_128x128.png
	sips -z 256 256 Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_128x128@2x.png
	sips -z 256 256 Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_256x256.png
	sips -z 512 512 Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_256x256@2x.png
	sips -z 512 512 Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_512x512.png
	sips -z 1024 1024 Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_512x512@2x.png
	iconutil -c icns Resources/AppIcon.iconset -o "$(ICON)"

app: build icon
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	cp "$(BIN)" "$(BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp Info.plist "$(BUNDLE)/Contents/Info.plist"
	cp "$(ICON)" "$(BUNDLE)/Contents/Resources/AppIcon.icns"
	chmod +x "$(BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@echo "Built: $(BUNDLE)"

run: app
	open "$(BUNDLE)"

install: app
	ditto "$(BUNDLE)" "/Applications/$(APP_NAME).app"
	@echo "Installed to /Applications/$(APP_NAME).app"

clean:
	rm -rf .build
