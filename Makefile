APP = AINotch
DIST = dist/$(APP).app
# Apple Development証明書があればそれで署名する（ad-hoc署名だとリビルドのたびに
# アクセシビリティ許可が無効になるため）。無ければad-hocにフォールバック。
SIGN_ID = $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $$2; exit}')

# 常駐はlaunchdに任せる（KeepAliveでクラッシュしても自動復帰する）
LABEL = jp.miraistarforce.ainotch
PLIST = $(HOME)/Library/LaunchAgents/$(LABEL).plist
DOMAIN = gui/$(shell id -u)

.PHONY: build app run restart clean install-hooks install-agent uninstall-agent agent-status

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

# LaunchAgent が登録済みなら launchd 経由で起動し直す（そちらが常駐の正）。
# 未登録なら従来どおり open で起動する。
run: app
	@if [ -f "$(PLIST)" ]; then \
		$(MAKE) --no-print-directory restart; \
	else \
		pkill -x $(APP) 2>/dev/null || true; \
		open $(DIST); \
		echo "通常起動しました（make install-agent で落ちても自動復帰するようになります）"; \
	fi

# launchd に読み込み直させる。アプリ自身は bootout を実行できない
# （自分が管理対象だと bootout で殺されて続きが走らない）ので、ここから行う。
restart:
	@pkill -x $(APP) 2>/dev/null || true
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	@launchctl enable $(DOMAIN)/$(LABEL) 2>/dev/null || true
	@launchctl bootstrap $(DOMAIN) "$(PLIST)"
	@echo "launchd管理で起動しました（クラッシュしても自動復帰します）"

# 自動起動＋自動復帰を有効にする。plistの生成はアプリ側（LoginItem）に任せ、
# 生成後に launchd 管理下で起動し直す。
install-agent: app
	open $(DIST) --args --enable-login-item
	@sleep 2
	@test -f "$(PLIST)" || (echo "plistが作られませんでした: $(PLIST)"; exit 1)
	@$(MAKE) --no-print-directory restart

uninstall-agent:
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	@launchctl disable $(DOMAIN)/$(LABEL) 2>/dev/null || true
	@rm -f "$(PLIST)"
	@echo "自動起動を解除しました"

agent-status:
	@echo "plist: $(PLIST)"; test -f "$(PLIST)" && echo "  → あり" || echo "  → なし"
	@launchctl print $(DOMAIN)/$(LABEL) 2>/dev/null | grep -E "^\s+(state|pid|last exit code|path) " || echo "  → 未読み込み"

install-hooks:
	bash hooks/install-hooks.sh

clean:
	rm -rf .build dist
