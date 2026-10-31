# Сборка индикатора Yandex.Disk на Vala
#
#   make            - собрать бинарник в build/
#   make test       - собрать и запустить тесты (без GUI)
#   make stage      - собрать бинарник и каталог данных в build/stage/usr
#   make run        - запустить индикатор из дерева проекта (выполняет stage)
#   make deb        - собрать пакет .deb без подписи; файлы появятся в build/deb/
#   make clean      - удалить build/ (вместе с build/deb/) и usr/
#
# Переменные:
#   INDICATOR_PKG   - binding иконки в панели: ayatana-appindicator3-0.1 (по умолчанию)
#                     или appindicator3-0.1 (тот же namespace в Vala)
#   BIN             - путь к итоговому бинарнику (используется debian/rules)
#   DEB_OUT         - каталог для собранных файлов пакета, по умолчанию build/deb

VALAC ?= valac
INDICATOR_PKG ?= ayatana-appindicator3-0.1
BINARY ?= yandex-disk-indicator-vala
APPNAME ?= yandex-disk-indicator

# Версия deb-пакета; источник истины - константа YD::APPVER в src/app.vala
APPVER := $(shell sed -n 's/.*APPVER[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' src/app.vala | head -n 1)
DEB_OUT ?= build/deb

PKGS = --pkg gtk+-3.0 --pkg gdk-pixbuf-2.0 --pkg gio-2.0 --pkg gio-unix-2.0 --pkg posix \
       --pkg $(INDICATOR_PKG)

# Макрос _() из <glib/gi18n-lib.h> раскрывается в g_dgettext (GETTEXT_PACKAGE, msgid)
XTRA = -X -DGETTEXT_PACKAGE='"$(APPNAME)"'

VALAFLAGS = --target-glib=2.56

SRC = src/app.vala src/config.vala src/utils.vala src/daemon.vala src/notification.vala \
      src/indicator.vala src/preferences.vala src/cli.vala src/main.vala

# Модули без GUI: из них собираются тесты, gtk и binding панели им не требуются
DAEMON_SRC = src/app.vala src/config.vala src/utils.vala src/daemon.vala
TEST_PKGS = --pkg gio-2.0 --pkg gio-unix-2.0 --pkg posix

BIN ?= build/$(BINARY)
STAGE ?= build/stage/usr
DATA_DIR = $(STAGE)/share/yd-tools-vala

all: $(BIN)

build:
	mkdir -p build

$(BIN): $(SRC) | build
	@mkdir -p $(dir $(BIN))
	$(VALAC) $(VALAFLAGS) $(PKGS) $(XTRA) -o $(BIN) $(SRC)

build/yd-parse-test: tests/parse_test.vala $(DAEMON_SRC) | build
	$(VALAC) $(VALAFLAGS) $(TEST_PKGS) $(XTRA) -o $@ tests/parse_test.vala $(DAEMON_SRC)

test: build/yd-parse-test
	./build/yd-parse-test

# Каталог данных и бинарник для запуска без установки в систему
stage: $(BIN)
	TARGET=$(STAGE) ./prepare.sh
	mkdir -p $(STAGE)/bin
	cp $(BIN) $(STAGE)/bin/$(BINARY)

# Данные берутся из build/stage, каталог задаётся переменной окружения YD_ROOT
run: stage
	YD_ROOT=$(abspath $(DATA_DIR)) ./$(BIN)

# Версия пакета берётся из YD::APPVER: перед сборкой она проставляется в верхнюю
# запись debian/changelog. dpkg-buildpackage всегда пишет результат в родительский
# каталог, поэтому готовые файлы переносятся в $(DEB_OUT), а дерево после сборки
# очищается от промежуточных результатов dpkg.
deb:
	@test -n '$(APPVER)' || { echo 'Не удалось прочитать YD::APPVER из src/app.vala' >&2; exit 1; }
	@old=$$(dpkg-parsechangelog -S Version); \
	if [ "$$old" != '$(APPVER)' ]; then \
	    echo "debian/changelog: версия $$old -> $(APPVER) (из YD::APPVER)"; \
	    sed -i -E '1s/\([^)]*\)/($(APPVER))/' debian/changelog; \
	fi
	TARGET=usr ./prepare.sh
	dpkg-buildpackage -b -us -uc -rfakeroot
	$(MAKE) -f debian/rules clean
	@mkdir -p $(DEB_OUT)
	@src=$$(dpkg-parsechangelog -S Source); moved=0; \
	for f in ../$$src*_$(APPVER)_*; do \
	    [ -e "$$f" ] || continue; \
	    mv -f "$$f" $(DEB_OUT)/; moved=1; \
	done; \
	[ "$$moved" = 1 ] || { echo "Файлы пакета $$src*_$(APPVER)_* не найдены" >&2; exit 1; }
	@echo 'Собрано в $(DEB_OUT)/:'; ls -1 $(DEB_OUT)

clean:
	rm -rf build usr

.PHONY: all test stage run deb clean
