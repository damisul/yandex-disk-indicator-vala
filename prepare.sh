#!/bin/bash
# Подготовка каталога данных индикатора.
#
#   TARGET - корень дерева установки, по умолчанию usr в каталоге проекта.
#            debian/rules вызывает скрипт без аргументов, `make stage` - с
#            TARGET=build/stage/usr для запуска индикатора из дерева проекта.
#
# Скрипт только создаёт и копирует файлы внутри $TARGET, ничего не удаляя.

set -e

cd "$(dirname "$0")"

SRC=.
DATA_NAME=yd-tools-vala
DOMAIN=yandex-disk-indicator
DESKTOP=Yandex.Disk-indicator-vala.desktop
TARGET=${TARGET:-usr}
DATA=$TARGET/share/$DATA_NAME

mkdir -p "$TARGET/share/applications"
mkdir -p "$DATA/icons/dark"
mkdir -p "$DATA/icons/light"
mkdir -p "$DATA/fm-actions/Nautilus_Nemo"
mkdir -p "$DATA/fm-actions/Dolphin"
mkdir -p "$DATA/fm-actions/pantheon-files"
mkdir -p "$DATA/translations"

# Файл меню; он же копируется индикатором в ~/.config/autostart
cp "$DESKTOP" "$TARGET/share/applications/"
chmod a+x "$TARGET/share/applications/$DESKTOP"

# Иконки состояний и логотип
cp $SRC/icons/readme $SRC/icons/yd-128.png $SRC/icons/yd-128_g.png "$DATA/icons/"
cp $SRC/icons/dark/*.png "$DATA/icons/dark/"
cp $SRC/icons/light/*.png "$DATA/icons/light/"

# Файлы переводов диалогов ya-setup и действий файловых менеджеров
cp $SRC/translations/*.lang "$DATA/translations/"

# Каталоги gettext размещаются в собственном каталоге данных, чтобы не занимать
# пути в /usr/share/locale
for mo in $SRC/translations/yandex-disk-indicator_*.mo; do
    lang=${mo##*_}
    lang=${lang%.mo}
    mkdir -p "$DATA/locale/$lang/LC_MESSAGES"
    cp "$mo" "$DATA/locale/$lang/LC_MESSAGES/$DOMAIN.mo"
done

# ya-setup берёт переводы из каталога рядом с собой, поэтому работает и из дерева
# проекта, и после установки
sed 's#^lang_home=.*#lang_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" \&\& pwd)/translations"#' \
    "$SRC/ya-setup" > "$DATA/ya-setup"
chmod a+x "$DATA/ya-setup"

# Действия файловых менеджеров копируются со ссылками на собственный каталог данных
rewrite() {
    sed "s#/usr/share/yd-tools/#/usr/share/$DATA_NAME/#g" "$1" > "$2"
    chmod a+x "$2"
}

rewrite "$SRC/fm-actions/Nautilus_Nemo/publish"   "$DATA/fm-actions/Nautilus_Nemo/publish"
rewrite "$SRC/fm-actions/Nautilus_Nemo/unpublish" "$DATA/fm-actions/Nautilus_Nemo/unpublish"
rewrite "$SRC/fm-actions/Dolphin/ydpublish.desktop" "$DATA/fm-actions/Dolphin/ydpublish.desktop"
rewrite "$SRC/fm-actions/pantheon-files/publish.sh"   "$DATA/fm-actions/pantheon-files/publish.sh"
rewrite "$SRC/fm-actions/pantheon-files/unpublish.sh" "$DATA/fm-actions/pantheon-files/unpublish.sh"
rewrite "$SRC/fm-actions/pantheon-files/yandex-disk-indicator-publish.contract" \
        "$DATA/fm-actions/pantheon-files/yandex-disk-indicator-publish.contract"
rewrite "$SRC/fm-actions/pantheon-files/yandex-disk-indicator-unpublish.contract" \
        "$DATA/fm-actions/pantheon-files/yandex-disk-indicator-unpublish.contract"
