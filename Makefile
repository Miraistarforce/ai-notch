APP = AINotch
DIST = dist/$(APP).app
# Apple Development証明書があればそれで署名する（ad-hoc署名だとリビルドのたびに
# アクセシビリティ許可が無効になるため）。無ければad-hocにフォールバック。
SIGN_ID = $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $$2; exit}')

.PHONY: build app run clean install-hooks

build:
	swift build -c release

# .app バンドルを作成（アクセシビリティ許可はこのバンドルに付与する）
app: build
	rm -rf $(DIST)
	mkdir -p $(DIST)/Contents/MacOS
	cp .build/release/$(APP) $(DIST)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(DIST)/Contents/Info.plist
	mkdir -p $(DIST)/Contents/Resources
	cp -R hooks $(DIST)/Contents/Resources/hooks
	@if [ -n "$(SIGN_ID)" ]; then \
		echo "署名: $(SIGN_ID)"; \
		codesign --force --sign "$(SIGN_ID)" $(DIST); \
	else \
		echo "署名: ad-hoc（リビルド後は権限の再許可が必要）"; \
		codesign --force --sign - $(DIST); \
	fi
	@echo "作成完了: $(DIST)"

run: app
	open $(DIST)

install-hooks:
	bash hooks/install-hooks.sh

clean:
	rm -rf .build dist
