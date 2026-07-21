APP = AINotch
DIST = dist/$(APP).app

.PHONY: build app run clean install-hooks

build:
	swift build -c release

# .app バンドルを作成（アクセシビリティ許可はこのバンドルに付与する）
app: build
	rm -rf $(DIST)
	mkdir -p $(DIST)/Contents/MacOS
	cp .build/release/$(APP) $(DIST)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(DIST)/Contents/Info.plist
	codesign --force --sign - $(DIST) 2>/dev/null || true
	@echo "作成完了: $(DIST)"

run: app
	open $(DIST)

install-hooks:
	bash hooks/install-hooks.sh

clean:
	rm -rf .build dist
