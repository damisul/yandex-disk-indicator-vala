/* Проверки разбора вывода демона, чтения и записи конфигурационных файлов и
   строковых утилит. GUI-библиотеки не используются, тесты работают без дисплея. */

namespace YDTest {

private int checks = 0;
private int failures = 0;

private void check (bool condition, string what) {
    checks++;
    if (!condition) {
        failures++;
        stdout.printf ("FAIL: %s\n", what);
    }
}

private void check_str (string? actual, string expected, string what) {
    checks++;
    if (actual != expected) {
        failures++;
        stdout.printf ("FAIL: %s: ожидается '%s', получено '%s'\n", what, expected, actual ?? "(null)");
    }
}

private void check_int (int actual, int expected, string what) {
    checks++;
    if (actual != expected) {
        failures++;
        stdout.printf ("FAIL: %s: ожидается %d, получено %d\n", what, expected, actual);
    }
}

/* ################### Разбор вывода демона ################### */

private const string FULL_OUTPUT =
    "Synchronization core status: idle\n" +
    "Path: /home/user/Yandex.Disk\n" +
    "Total: 10.00 GB\n" +
    "Used: 2.00 GB\n" +
    "Available: 8.00 GB\n" +
    "Trash size: 100.00 MB\n" +
    "Last synchronized items:\n" +
    "\tfile: '/note.txt'\n" +
    "\tdirectory: '/photos dir'\n";

private void test_parse_full_output () {
    var dm = new YD.YDDaemon ("/nonexistent/config.cfg", "");
    var changed = dm.parse_output (FULL_OUTPUT);

    check (changed, "первый разбор сообщает об изменениях");
    check_str (dm.vals.status, "idle", "статус idle");
    check_str (dm.vals.laststatus, "unknown", "предыдущий статус неизвестен");
    check (dm.vals.statchg, "флаг изменения статуса");
    check (dm.vals.szchg, "флаг изменения размеров");
    check (dm.vals.lastchg, "флаг изменения списка файлов");
    check_str (dm.vals.total, "10.00 GB", "общий объём");
    check_str (dm.vals.used, "2.00 GB", "использовано");
    check_str (dm.vals.free, "8.00 GB", "доступно из поля Available");
    check_str (dm.vals.trash, "100.00 MB", "размер корзины");
    check_str (dm.vals.error, "...", "отсутствующее значение заменяется заполнителем");
    check_int (dm.vals.lastitems.length, 2, "число последних синхронизированных элементов");
    check_str (dm.vals.lastitems[0], "/note.txt", "первый элемент списка");
    check_str (dm.vals.lastitems[1], "/photos dir", "элемент с пробелом в имени");
}

private void test_parse_unchanged () {
    var dm = new YD.YDDaemon ("/nonexistent/config.cfg", "");
    dm.parse_output (FULL_OUTPUT);
    var changed = dm.parse_output (FULL_OUTPUT);

    check (!changed, "повторный разбор того же вывода не сообщает об изменениях");
    check (!dm.vals.statchg, "статус не изменился");
    check (!dm.vals.szchg, "размеры не изменились");
    check (!dm.vals.lastchg, "список файлов не изменился");
    check_str (dm.vals.laststatus, "idle", "предыдущий статус сохранён");
}

private void test_parse_status_conversion () {
    /* Пустой вывод означает, что демон не запущен */
    var dm = new YD.YDDaemon ("/nonexistent/config.cfg", "");
    dm.parse_output ("");
    check_str (dm.vals.status, "none", "пустой вывод даёт статус none");
    check_str (dm.vals.total, "...", "отсутствующий размер заменяется заполнителем");

    /* 'no internet access' отображается в no_net */
    var no_net = new YD.YDDaemon ("/nonexistent/config.cfg", "");
    no_net.parse_output ("Synchronization core status: no internet access\n");
    check_str (no_net.vals.status, "no_net", "отсутствие сети даёт статус no_net");

    /* Прочие сообщения демона отображаются в error */
    var broken = new YD.YDDaemon ("/nonexistent/config.cfg", "");
    broken.parse_output ("Synchronization core status: failed to connect to daemon process\n");
    check_str (broken.vals.status, "error", "нераспознанный статус даёт error");

    /* busy, idle и paused проходят без преобразования */
    foreach (var raw in new string[] { "busy", "idle", "paused" }) {
        var dm2 = new YD.YDDaemon ("/nonexistent/config.cfg", "");
        dm2.parse_output ("Synchronization core status: %s\n".printf (raw));
        check_str (dm2.vals.status, raw, "статус %s проходит без изменений".printf (raw));
    }
}

private void test_parse_index_status () {
    /* Промежуточный статус index не показывается: остаётся предыдущий */
    var dm = new YD.YDDaemon ("/nonexistent/config.cfg", "");
    dm.parse_output ("Synchronization core status: idle\n");
    var changed = dm.parse_output ("Synchronization core status: index\n");
    check_str (dm.vals.status, "idle", "index сохраняет предыдущий статус");
    check (!changed, "index без прочих изменений не порождает событие");

    /* Самый первый вывод с index трактуется как начало синхронизации */
    var fresh = new YD.YDDaemon ("/nonexistent/config.cfg", "");
    fresh.parse_output ("Synchronization core status: index\n");
    check_str (fresh.vals.status, "busy", "первый index даёт busy");
}

private void test_parse_progress_and_error () {
    var dm = new YD.YDDaemon ("/nonexistent/config.cfg", "");
    dm.parse_output ("Synchronization core status: busy\nSync progress: 42%\n");
    check_str (dm.vals.progress, "42%", "прогресс синхронизации");
    check (dm.vals.statchg, "появление прогресса меняет статусную часть");

    var same = dm.parse_output ("Synchronization core status: busy\nSync progress: 55%\n");
    check (same, "рост прогресса порождает событие");
    check_str (dm.vals.progress, "55%", "обновлённый прогресс");

    var err = new YD.YDDaemon ("/nonexistent/config.cfg", "");
    err.parse_output ("Synchronization core status: error\nError: disk is full\nPath: /home/user/f.txt\n");
    check_str (err.vals.status, "error", "статус ошибки");
    check_str (err.vals.error, "disk is full", "текст ошибки");
    check_str (err.vals.path, "/home/user/f.txt", "путь из сообщения об ошибке");
}

/* ################### Чтение конфигурации ################### */

private string make_tmp_dir () throws GLib.Error {
    return GLib.DirUtils.make_tmp ("yd-parse-test-XXXXXX");
}

private string write_tmp_config (string name, string content) throws GLib.Error {
    var dir = make_tmp_dir ();
    var path = GLib.Path.build_filename (dir, name);
    GLib.FileUtils.set_contents (path, content);
    return path;
}

private void test_config_load () throws GLib.Error {
    var path = write_tmp_config ("app.conf",
        "# комментарий\n" +
        "\n" +
        "autostart=yes\n" +
        "theme = \"no\"\n" +
        "notifications=false\n" +
        "daemons=\"~/.config/yandex-disk/config.cfg\", /tmp/second.cfg\n" +
        "\"quoted key\"=\"quoted value\"\n" +
        "строка без разделителя\n" +
        "wrong key with spaces = 1\n" +
        "empty=\n");

    var conf = new YD.Config (path);
    check (conf.read_success, "файл конфигурации прочитан");
    check (conf.get_bool ("autostart"), "yes распознаётся как истина");
    check (!conf.get_bool ("theme"), "строка \"no\" в кавычках распознаётся как ложь");
    check (!conf.get_bool ("notifications"), "false распознаётся как ложь");
    check (conf.get_bool ("missing", true), "отсутствующий ключ возвращает значение по умолчанию");
    check_str (conf.get_string ("quoted key"), "quoted value", "ключ в кавычках");
    check (!conf.has ("empty"), "ключ без значения не сохраняется");
    check (!conf.has ("wrong key with spaces"), "недопустимый ключ пропускается");

    var daemons = conf.get_strings ("daemons");
    check_int (daemons.length, 2, "число элементов списка");
    check_str (daemons[0], "~/.config/yandex-disk/config.cfg", "первый элемент списка в кавычках");
    check_str (daemons[1], "/tmp/second.cfg", "второй элемент списка без кавычек");
}

private void test_config_load_missing_file () {
    var conf = new YD.Config ("/nonexistent/app.conf");
    check (!conf.read_success, "отсутствующий файл помечается как непрочитанный");
    check (!conf.load (), "повторное чтение отсутствующего файла неуспешно");
}

private void test_parse_values () throws GLib.Error {
    var dir = make_tmp_dir ();
    var conf = new YD.Config (GLib.Path.build_filename (dir, "empty.conf"), false);

    var single = conf.parse_values ("one");
    check (single != null && single.is_str (), "одиночное значение остаётся строкой");
    check_str (single.get_string (), "one", "содержимое одиночного значения");

    var list = conf.parse_values ("a, b, \"c,d\"");
    check (list != null && list.is_list (), "значения через запятую образуют список");
    check_int (list.list_of_items ().length, 3, "число элементов списка");
    check_str (list.strings ()[2], "c,d", "запятая внутри кавычек не разделяет значение");

    var bools = conf.parse_values ("TRUE");
    check (bools != null && bools.is_bool () && bools.get_bool (), "TRUE распознаётся как истина");

    check (conf.parse_values (", leading comma") == null, "запятая перед значением - ошибка");
    check (conf.parse_values ("trailing,") == null, "запятая после значения - ошибка");
    /* Решётка исключена из набора символов значения, поэтому хвост после неё делает строку неверной */
    check (conf.parse_values ("a b # comment") == null, "хвост после решётки - ошибка");
    check_str (conf.parse_values ("a b").get_string (), "a b", "значение с пробелами сохраняется целиком");
}

private void test_config_save () throws GLib.Error {
    var path = write_tmp_config ("daemon.cfg",
        "dir=\"/home/user/Yandex.Disk\"\n" +
        "auth=\"/home/user/.config/yandex-disk/passwd\"\n" +
        "read-only=\"\"\n" +
        "# комментарий остаётся\n");

    var conf = new YD.Config (path);
    conf.set_bool ("read-only", false);
    conf.set_bool ("startonstartofindicator", true);
    conf.set_none ("auth");
    check (conf.save (), "сообщение об успешной записи");

    string saved;
    GLib.FileUtils.get_contents (path, out saved);
    check (saved.contains ("read-only=\"no\""), "булево значение записывается словом no");
    check (!saved.contains ("auth="), "значение NONE удаляет строку ключа");
    check (saved.contains ("dir=\"/home/user/Yandex.Disk\""), "незатронутый ключ сохраняется");
    check (saved.contains ("# комментарий остаётся"), "комментарий сохраняется");
    check (saved.contains ("startonstartofindicator=\"yes\""), "новый ключ дописывается в конец");

    /* Повторная запись не дублирует строки */
    conf.set_bool ("startonstartofindicator", false);
    conf.save ();
    GLib.FileUtils.get_contents (path, out saved);
    check (saved.contains ("startonstartofindicator=\"no\""), "значение перезаписывается на месте");
    var occurrences = 0;
    foreach (var line in saved.split ("\n")) {
        if (line.has_prefix ("startonstartofindicator")) {
            occurrences++;
        }
    }
    check_int (occurrences, 1, "ключ встречается в файле один раз");
}

/* ################### Конфигурация демона ################### */

private void test_dconfig () throws GLib.Error {
    var path = write_tmp_config ("ydd.cfg",
        "dir=\"/home/user/Yandex.Disk\"\n" +
        "auth=\"/home/user/.config/yandex-disk/passwd\"\n" +
        "read-only=\"\"\n" +
        "overwrite=\"\"\n" +
        "exclude-dirs=\"photos, videos, tmp\"\n");

    var conf = new YD.DConfig (path);
    check (conf.load (), "конфигурация демона прочитана");
    check (conf.get_bool ("read-only"), "пустое значение означает включённую опцию");
    check (conf.get_bool ("overwrite"), "опция overwrite включена");
    check (conf.get_bool ("startonstartofindicator", true), "значение по умолчанию для запуска");
    check (!conf.get_bool ("stoponexitfromindicator", false), "значение по умолчанию для остановки");
    var excluded = conf.get_strings ("exclude-dirs");
    check_int (excluded.length, 3, "значение в кавычках разбито на список");
    check_str (excluded[1], "videos", "второй элемент списка исключений");

    /* Выключенный read-only убирает из файла обе опции, даже если overwrite включена */
    conf.set_bool ("read-only", false);
    conf.set_val ("exclude-dirs", YD.Val.str_val ("photos, videos"));
    check (conf.save (), "конфигурация демона сохранена");

    string saved;
    GLib.FileUtils.get_contents (path, out saved);
    check (!saved.contains ("read-only"), "выключенный read-only удалён");
    check (!saved.contains ("overwrite"), "overwrite без read-only не записывается");
    check (saved.contains ("exclude-dirs=\"photos, videos\""), "список исключений записан одной строкой");
    check (saved.contains ("dir=\"/home/user/Yandex.Disk\""), "каталог синхронизации не затронут");
}

/* ################### Накопитель значений ################### */

private void test_cval () {
    var acc = new YD.CVal ();
    check (!acc.truthy (), "пустой накопитель ложен");
    check_int (acc.flat ().length, 0, "в пустом накопителе нет элементов");

    acc.add (YD.Val.str_val ("one"));
    check (acc.truthy (), "непустой накопитель истинен");
    check (!acc.get_val ().is_list (), "одно значение хранится скаляром");

    acc.add (YD.Val.str_val ("two"));
    check (acc.get_val ().is_list (), "второе значение превращает накопитель в список");
    check_int (acc.flat ().length, 2, "в накопителе два элемента");

    acc.add (YD.Val.str_val ("three"));
    check_int (acc.flat ().length, 3, "третье значение добавляется в список");
    check_str (acc.get_val ().strings ()[2], "three", "порядок элементов сохраняется");

    /* Список из одного элемента приводится к скаляру */
    var single = new YD.CVal (YD.Val.list_val ({ YD.Val.str_val ("only") }));
    check (!single.get_val ().is_list (), "список из одного элемента становится скаляром");
    check_str (single.get_val ().get_string (), "only", "содержимое единственного элемента");
}

/* ################### Строковые утилиты ################### */

private void test_short_path () {
    check_str (YD.Utils.short_path ("/short/path.txt"), "/short/path.txt", "короткий путь не меняется");
    check_str (YD.Utils.short_path ("file_name.txt"), "file\u02cdname.txt",
               "подчёркивание заменяется, чтобы меню не считало его ускорителем");

    var long_path = "/home/user/Yandex.Disk/very/long/directory/structure/report 2026.txt";
    var shortened = YD.Utils.short_path (long_path);
    check_int (shortened.char_count (), 50, "длинный путь укорачивается до 50 символов");
    check (shortened.contains ("..."), "в середине укороченного пути стоит многоточие");
    check (shortened.has_prefix (long_path.substring (0, 20)), "начало пути сохраняется");
    check (shortened.has_suffix ("report 2026.txt"), "конец пути сохраняется");

    /* Граница: ровно 50 символов не укорачиваются */
    var exact = string.nfill (50, 'x');
    check_str (YD.Utils.short_path (exact), exact, "путь из 50 символов не укорачивается");
    var longer = exact + "y";
    check_str (YD.Utils.short_path (longer),
               longer.substring (0, 20) + "..." + longer.substring (longer.char_count () - 27),
               "путь из 51 символа укорачивается");
}

private void test_paths () {
    var home = GLib.Environment.get_home_dir ();
    check_str (YD.Utils.expand_user ("~"), home, "тильда раскрывается в домашний каталог");
    check_str (YD.Utils.expand_user ("~/Yandex.Disk"), home + "/Yandex.Disk", "путь от домашнего каталога");
    check_str (YD.Utils.expand_user ("/etc/passwd"), "/etc/passwd", "абсолютный путь не меняется");
    check_str (YD.Utils.expand_user ("relative/path"), "relative/path", "относительный путь не меняется");

    check_str (YD.Utils.join_path ("", "child"), "child", "пустой родитель не добавляет разделитель");
    check_str (YD.Utils.join_path ("/parent", "child"), "/parent/child", "соединение путей");

    check_str (YD.Utils.relative_path ("/root/dir/file.txt", "/root/dir"), "file.txt",
               "путь относительно корневого каталога");
    check_str (YD.Utils.relative_path ("/root/dir/", "/root/dir"), "", "сам каталог даёт пустой путь");
    check_str (YD.Utils.relative_path ("/other/file.txt", "/root/dir"), "/other/file.txt",
               "путь вне корневого каталога не меняется");
}

private void test_strv_helpers () {
    string[] array = { "a", "b", "c", "b" };
    check (YD.Utils.strv_has (array, "b"), "элемент найден");
    check (!YD.Utils.strv_has (array, "z"), "отсутствующий элемент не найден");

    var removed = YD.Utils.strv_remove (array, "b");
    check_int (removed.length, 2, "удалены все вхождения элемента");
    check (!YD.Utils.strv_has (removed, "b"), "удалённого элемента нет в результате");
    check_str (removed[0], "a", "порядок остальных элементов сохранён");
}

private void test_re_findall () {
    var subject = "\tfile: '/one.txt'\n" +
                  "\tdirectory: '/two dir'\n";
    var found = YD.Utils.re_findall (".*: '(.*)'\n", subject, 1);
    check_int (found.length, 2, "найдены обе строки списка");
    check_str (found[1], "/two dir", "содержимое второй строки");

    var multiline = "<actions><action><name>One</name></action>" +
                    "<action><name>Two</name></action></actions>";
    var blocks = YD.Utils.re_findall ("(<action>.*?</action>)", multiline, 1,
                                      GLib.RegexCompileFlags.DOTALL);
    check_int (blocks.length, 2, "с флагом DOTALL найдены оба блока");

    var none = YD.Utils.re_findall ("nothing", subject, 0);
    check_int (none.length, 0, "при отсутствии совпадений возвращается пустой массив");
}

/* ################### Проверка автозапуска ################### */

private void test_check_autostart () throws GLib.Error {
    var dir = make_tmp_dir ();

    check (!YD.Utils.check_autostart (GLib.Path.build_filename (dir, "absent.desktop")),
           "отсутствующий файл означает выключенный автозапуск");

    var plain = GLib.Path.build_filename (dir, "plain.desktop");
    GLib.FileUtils.set_contents (plain, "[Desktop Entry]\nExec=yandex-disk-indicator-vala\n");
    check (YD.Utils.check_autostart (plain), "файл без признака скрытия включает автозапуск");

    var visible = GLib.Path.build_filename (dir, "visible.desktop");
    GLib.FileUtils.set_contents (visible, "[Desktop Entry]\nHidden=false\nExec=test\n");
    check (YD.Utils.check_autostart (visible), "Hidden=false включает автозапуск");

    var hidden = GLib.Path.build_filename (dir, "hidden.desktop");
    GLib.FileUtils.set_contents (hidden, "[Desktop Entry]\nHidden=true\nExec=test\n");
    check (!YD.Utils.check_autostart (hidden), "Hidden=true выключает автозапуск");
}

public static int main (string[] args) {
    /* Собственные сообщения тестов не должны тонуть в журнале приложения */
    YD.Log.level = YD.Log.CRITICAL;

    test_parse_full_output ();
    test_parse_unchanged ();
    test_parse_status_conversion ();
    test_parse_index_status ();
    test_parse_progress_and_error ();
    test_cval ();
    test_short_path ();
    test_paths ();
    test_strv_helpers ();
    test_re_findall ();
    try {
        test_config_load ();
        test_config_load_missing_file ();
        test_parse_values ();
        test_config_save ();
        test_dconfig ();
        test_check_autostart ();
    } catch (GLib.Error e) {
        stdout.printf ("FAIL: файловая операция завершилась ошибкой: %s\n", e.message);
        failures++;
    }

    stdout.printf ("Выполнено проверок: %d, ошибок: %d\n", checks, failures);
    return failures == 0 ? 0 : 1;
}

}
