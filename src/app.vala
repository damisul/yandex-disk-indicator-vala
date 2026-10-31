/* Общие константы, пути запуска и логирование. */

namespace YD {

/* Имя приложения: домен gettext (каталоги translations/*.mo) и основа имени файла настроек */
public const string APPNAME = "yandex-disk-indicator";
public const string APPVER = "0.0.1";

/* Каталог в ~/.config: настройки приложения, пользовательские иконки и файл блокировки,
   который обеспечивает один индикатор на панель. */
public const string APPHOME = "yd-tools";

/* Каталог установки данных приложения, имя бинарника и имя файла .desktop */
public const string PACKAGE_HOME = "yd-tools-vala";
public const string BINARY_NAME = "yandex-disk-indicator-vala";
public const string DESKTOP_FILE = "Yandex.Disk-indicator-vala.desktop";

public const string LICENSE = "\nThis program is free software: you can redistribute it and/or\n" +
    "modify it under the terms of the GNU General Public License as\n" +
    "published by the Free Software Foundation, either version 3 of\n" +
    "the License, or (at your option) any later version.\n\n" +
    "This program is distributed in the hope that it will be useful,\n" +
    "but WITHOUT ANY WARRANTY; without even the implied warranty\n" +
    "of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.\n" +
    "See the GNU General Public License for more details.\n\n" +
    "You should have received a copy of the GNU General Public License\n" +
    "along with this program.  If not, see http://www.gnu.org/licenses\n";

public class App {

    public static string inst_path = "";
    public static string conf_path = "";
    public static string autostart_src = "";
    public static string autostart_dst = "";
    public static string lock_path = "";
    public static string copyright = "";
    public static string logo_path = "";
    public static unowned Config conf;

    /* Пути берутся из стандартной установки deb-пакета, но YD_ROOT позволяет запускать
       индикатор прямо из дерева проекта (для разработки и тестов, без установки в /usr). */
    public static void setup_paths () {
        var root = Environment.get_variable ("YD_ROOT");
        inst_path = (root != null && root != "") ? root : "/usr/share/" + PACKAGE_HOME;
        conf_path = Path.build_filename (Environment.get_home_dir (), ".config", APPHOME);
        autostart_src = Path.build_filename ("/usr/share/applications", DESKTOP_FILE);
        autostart_dst = Path.build_filename (Environment.get_home_dir (), ".config", "autostart", DESKTOP_FILE);
        lock_path = Path.build_filename (conf_path, APPNAME + ".lock");
        copyright = "Copyright \u00a9 2013-%d Sly_tom_cat".printf (new DateTime.now_local ().get_year ());
    }
}

/* Логгер: пишет в stderr строки вида "дата время УРОВЕНЬ сообщение".
   Уровни числовые (10..50) и совпадают со значениями ключа командной строки --log. */
public class Log {

    public static int level = 30;

    public const int DEBUG = 10;
    public const int INFO = 20;
    public const int WARNING = 30;
    public const int ERROR = 40;
    public const int CRITICAL = 50;

    private static void write (int lvl, string name, string msg) {
        if (lvl < level) {
            return;
        }
        var stamp = new DateTime.now_local ().format ("%Y-%m-%d %H:%M:%S");
        stderr.printf ("%s %-8s %s\n", stamp, name, msg);
    }

    public static void debug (string msg) { write (DEBUG, "DEBUG", msg); }
    public static void info (string msg) { write (INFO, "INFO", msg); }
    public static void warning (string msg) { write (WARNING, "WARNING", msg); }
    public static void error (string msg) { write (ERROR, "ERROR", msg); }
    public static void critical (string msg) { write (CRITICAL, "CRITICAL", msg); }
}

}
