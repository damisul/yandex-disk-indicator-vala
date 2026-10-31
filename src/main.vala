/* Точка входа: блокировка единственного экземпляра, конфигурация приложения,
   список демонов и запуск цикла GTK. */

namespace YD {

/* flock(2) используется для защиты от второго экземпляра индикатора.
   Значения LOCK_EX/LOCK_NB заданы числами: в Vala нельзя привязать const к C-макросу. */
namespace Fs {

    [CCode (cname = "flock", cheader_filename = "sys/file.h")]
    public extern int flock (int fd, int operation);

    public const int LOCK_EX = 2;
    public const int LOCK_NB = 4;
}

private int lock_fd = -1;

private void fatal (string message) {
    stderr.printf ("%s\n", message);
    GLib.Process.exit (1);
}

/* Блокировка удерживается открытым дескриптором до выхода процесса: ядро снимает её
   даже при аварийном завершении, поэтому оставшийся файл не мешает следующему запуску. */
private void acquire_single_instance_lock () {
    Utils.make_dirs (App.conf_path);
    lock_fd = Posix.open (App.lock_path, Posix.O_RDWR | Posix.O_CREAT, (Posix.mode_t) 0644);
    if (lock_fd == -1) {
        fatal (_("Can't create the lock file %s: %s").printf (App.lock_path, Posix.strerror (Posix.errno)));
    }
    if (Fs.flock (lock_fd, Fs.LOCK_EX | Fs.LOCK_NB) != 0) {
        string content = "";
        try {
            FileUtils.get_contents (App.lock_path, out content);
        } catch (GLib.Error e) {
            content = "";
        }
        Log.error ("Another instance of the indicator is already running (PID %s)".printf (content.strip ()));
        fatal (_("The indicator instance is already running."));
    }
    Posix.ftruncate (lock_fd, 0);
    var pid_text = "%d\n".printf (Posix.getpid ());
    try {
        var stream = new GLib.UnixOutputStream (lock_fd, false);
        stream.write_bytes (new GLib.Bytes (pid_text.data));
        stream.flush (null);
    } catch (GLib.Error e) {
        Log.error ("Can't update the lock file %s".printf (App.lock_path));
    }
    Log.debug ("Single instance lock is acquired: %s".printf (App.lock_path));
}

private void first_run_setup (Config conf) {
    Utils.make_dirs (App.conf_path);
    Utils.make_dirs (Path.build_filename (App.conf_path, "icons", "light"));
    Utils.make_dirs (Path.build_filename (App.conf_path, "icons", "dark"));
    if (!Utils.copy_file (Path.build_filename (App.inst_path, "icons", "readme"),
                          Path.build_filename (App.conf_path, "icons", "readme"))) {
        fatal (_("Can't create configuration files in %s").printf (App.conf_path));
    }
    if (!File.new_for_path (App.autostart_dst).query_exists ()) {
        Utils.make_dirs (Path.get_dirname (App.autostart_dst));
        if (Utils.copy_file (App.autostart_src, App.autostart_dst)) {
            conf.set_bool ("autostart", true);
        } else {
            Log.error ("Can't activate indicator automatic start on system start-up");
        }
    }
    Utils.activate_actions (conf.get_bool ("fmextensions", true), App.inst_path);
    conf.changed = true;
}

public static void app_exit () {
    Log.debug ("Quit is initialized");
    foreach (var i in Indicator.get_all ()) {
        i.exit ();
    }
    Gtk.main_quit ();
}

public static int main (string[] args) {
    App.setup_paths ();

    Intl.setlocale (GLib.LocaleCategory.ALL, "");
    /* Каталоги переводов: путь из переменной окружения, затем каталог locale
       в каталоге данных приложения, затем системный каталог */
    var locale_dir = Environment.get_variable ("YD_LOCALEDIR");
    if (locale_dir == null || locale_dir == "") {
        var bundled = Path.build_filename (App.inst_path, "locale");
        locale_dir = File.new_for_path (bundled).query_exists () ? bundled : "/usr/share/locale";
    }
    Intl.bindtextdomain (APPNAME, locale_dir);
    Intl.bind_textdomain_codeset (APPNAME, "UTF-8");
    Intl.textdomain (APPNAME);

    var cli = Cli.parse (args);
    Log.level = cli.level;
    Log.info ("%s v.%s".printf (APPNAME, APPVER));
    Log.debug ("Logging level: %d".printf (cli.level));

    /* Инициализация выполняется до создания виджетов: она устанавливает соединение
       с дисплеем и разбирает собственные ключи GTK, извлекая их из args */
    Gtk.init (ref args);

    App.logo_path = Path.build_filename (App.inst_path, "icons", "yd-128.png");
    try {
        Gui.logo = new Gdk.Pixbuf.from_file (App.logo_path);
    } catch (GLib.Error e) {
        stderr.printf ("Can't read the application logo %s\n", App.logo_path);
        return 1;
    }

    acquire_single_instance_lock ();

    /* Конфигурация приложения: ~/.config/yd-tools/yandex-disk-indicator.conf */
    var conf = new Config (Path.build_filename (App.conf_path, APPNAME + ".conf"));
    App.conf = conf;
    conf.set_val ("autostart", Val.bool_val (Utils.check_autostart (App.autostart_dst)));
    conf.setdefault_bool ("notifications", true);
    conf.setdefault_bool ("theme", false);
    conf.setdefault_bool ("fmextensions", true);
    if (!conf.has ("daemons")) {
        conf.set_string ("daemons", "~/.config/yandex-disk/config.cfg");
    }

    if (!conf.read_success) {
        Log.info ("No config, probably it is a first run.");
        first_run_setup (conf);
    }

    string[] daemons = {};
    foreach (var daemon in conf.get_strings ("daemons")) {
        daemons += Utils.expand_user (daemon);
    }
    if (cli.cfg != "") {
        var path = Utils.expand_user (cli.cfg);
        if (!Utils.strv_has (daemons, path)) {
            daemons += path;
            conf.changed = true;
        }
    }
    if (cli.rcfg != "") {
        var path = Utils.expand_user (cli.rcfg);
        if (Utils.strv_has (daemons, path)) {
            daemons = Utils.strv_remove (daemons, path);
            conf.changed = true;
        }
    }
    if (daemons.length == 0) {
        fatal (_("No daemons specified.\nCheck correctness of -r and -c options."));
        return 1;
    }
    if (conf.changed) {
        var list = new CVal ();
        foreach (var daemon in daemons) {
            list.add (Val.str_val (daemon));
        }
        conf.set_val ("daemons", list.get_val ());
        conf.save ();
    }

    for (int i = 0; i < daemons.length; i++) {
        new Indicator (daemons[i], daemons.length > 1 ? _("#%d ").printf (i) : "");
    }

    GLib.Unix.signal_add (Posix.Signal.INT, () => { app_exit (); return false; }, GLib.Priority.HIGH);
    GLib.Unix.signal_add (Posix.Signal.TERM, () => { app_exit (); return false; }, GLib.Priority.HIGH);
    Gtk.main ();
    return 0;
}

}
