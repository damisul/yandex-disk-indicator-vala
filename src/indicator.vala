/* Индикатор: иконка в панели, меню состояния и обработка событий демона. */

namespace YD {

/* Иконка приложения (128x128) для диалогов; загружается в main() */
public class Gui {
    public static Gdk.Pixbuf? logo = null;
}

/* Иконка в панели: через StatusNotifier, если на шине сессии есть наблюдатель,
   иначе через системный лоток XEmbed. Двойной щелчок поддерживает только лоток:
   в протоколе StatusNotifier такого события нет. */
public class Tray : GLib.Object {

    public signal void double_clicked ();

    private AppIndicator.Indicator? sni = null;
    private Gtk.StatusIcon? status_icon = null;
    private unowned Gtk.Menu menu;

    public Tray (string id, string title, string icon_path, Gtk.Menu menu) {
        this.menu = menu;
        if (watcher_available ()) {
            Log.debug ("Tray backend: StatusNotifier");
            sni = new AppIndicator.Indicator (id, icon_path, AppIndicator.IndicatorCategory.APPLICATION_STATUS);
            sni.set_title (title);
            sni.set_status (AppIndicator.IndicatorStatus.ACTIVE);
            sni.set_menu (menu);
        } else {
            Log.debug ("Tray backend: XEmbed status icon");
            status_icon = new Gtk.StatusIcon.from_file (icon_path);
            status_icon.set_title (title);
            status_icon.set_tooltip_text (title);
            status_icon.button_press_event.connect ((event) => {
                if (event.button == 1 && event.type == Gdk.EventType.@2BUTTON_PRESS) {
                    double_clicked ();
                }
                return false;
            });
            status_icon.popup_menu.connect (() => {
                menu.popup_at_pointer (null);
            });
        }
    }

    public void set_icon (string path) {
        if (sni != null) {
            sni.set_icon_full (path, null);
        } else if (status_icon != null) {
            status_icon.set_from_file (path);
        }
    }

    public void set_visible (bool visible) {
        if (sni != null) {
            sni.set_status (visible ? AppIndicator.IndicatorStatus.ACTIVE
                                    : AppIndicator.IndicatorStatus.PASSIVE);
        } else if (status_icon != null) {
            status_icon.set_visible (visible);
        }
    }

    /* Имя проверяем фактически занятым: активируемая, но не запущенная служба
       наблюдателя не означает, что иконку по StatusNotifier есть кому показать */
    private static bool watcher_available () {
        try {
            var conn = GLib.Bus.get_sync (GLib.BusType.SESSION);
            var reply = conn.call_sync ("org.freedesktop.DBus", "/org/freedesktop/DBus",
                                        "org.freedesktop.DBus", "NameHasOwner",
                                        new GLib.Variant ("(s)", "org.kde.StatusNotifierWatcher"),
                                        new GLib.VariantType ("(b)"), GLib.DBusCallFlags.NONE, -1, null);
            return reply.get_child_value (0).get_boolean ();
        } catch (GLib.Error e) {
            Log.debug ("StatusNotifier watcher lookup failed: %s".printf (e.message));
            return false;
        }
    }
}

public class Indicator : YDDaemon {

    private static Indicator[] all = {};

    /* Регистрация всех индикаторов нужна меню и настройкам (общий диалог About/Preferences) */
    public static unowned Indicator[] get_all () {
        return all;
    }

    public Menu menu;

    private Tray tray;
    private Notification notifier;
    private string theme_path = "";
    private GLib.HashTable<string, string> icon =
        new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);
    private int seq_num = 2;
    private uint anim_source = 0;
    public string current_status = "unknown";

    /* ###### YDDaemon virtual methods implementations ###### */

    public override int error (string err_str, string cfg_path) {
        string text1 = _("Yandex.Disk Indicator: daemon start failed");
        string text2;
        Gtk.ButtonsType buttons;
        if (err_str == "") {
            buttons = Gtk.ButtonsType.OK;
            text2 = _("Yandex.Disk utility is not installed.\n" +
                      "Visit www.yandex.ru, download and install Yandex.Disk daemon.");
        } else {
            buttons = Gtk.ButtonsType.OK_CANCEL;
            text2 = _("Yandex.Disk daemon failed to start because it is not" +
                      " configured properly\n\n") + err_str + "\n\n" +
                    _("  To configure it up: press OK button.\n  Press Cancel to exit.");
        }
        var dialog = new Gtk.MessageDialog (null, (Gtk.DialogFlags) 0, Gtk.MessageType.INFO, buttons, "%s", text1);
        dialog.format_secondary_text (text2);
        dialog.set_icon (Gui.logo);
        var response = dialog.run ();
        int ret_code = 1;
        if (err_str != "" && response == Gtk.ResponseType.OK) {
            Log.debug ("starting configuration utility");
            ret_code = Utils.call ({ Utils.join_path (App.inst_path, "ya-setup"), cfg_path });
        }
        dialog.destroy ();
        return ret_code;
    }

    /* Обработчик событий демона: опрос выполняется в основном цикле GTK, поэтому
       меню и иконка обновляются сразу, без постановки задачи в очередь. */
    public override void change (StatusVals v) {
        Log.info ("%sChange event: %s".printf (ID, v.changes ()));
        menu.update (v, config.get_string ("dir", ""));
        if (v.status != v.laststatus) {
            Log.info ("Status: %s ->  %s".printf (v.laststatus, v.status));
            update_icon (v.status);
            if (App.conf.get_bool ("notifications", true)) {
                if (v.laststatus == "none") {
                    notifier.send (_("Yandex.Disk daemon has been started"));
                }
                if (v.status == "busy") {
                    notifier.send (_("Synchronization started"));
                } else if (v.status == "idle") {
                    if (v.laststatus == "busy") {
                        notifier.send (_("Synchronization has been completed"));
                    }
                } else if (v.status == "paused") {
                    if (v.laststatus != "none" && v.laststatus != "unknown") {
                        notifier.send (_("Synchronization has been paused"));
                    }
                } else if (v.status == "none") {
                    if (v.laststatus != "unknown") {
                        notifier.send (_("Yandex.Disk daemon has been stopped"));
                    }
                } else {
                    notifier.send (_("Synchronization ERROR"));
                }
            }
        }
        current_status = v.status;
    }

    public Indicator (string path, string ID) {
        base (path, ID);
        this.ID = ID;
        notifier = new Notification (_("Yandex.Disk ") + ID);
        set_icon_theme (App.conf.get_bool ("theme", false));
        var name = "yandex-disk" + (ID == "" ? "" : "-%s".printf (ID.substring (1, ID.length - 2)));
        var title = _("Yandex.Disk Indicator") + (ID == "" ? "" : " " + ID.substring (0, ID.length - 1));
        menu = new Menu (this, ID);
        tray = new Tray (name, title, icon["paused"], menu);
        tray.double_clicked.connect (open_disk_folder);
        all += this;
        init ();
    }

    public override void exit () {
        stop_animation ();
        menu.destroy ();
        tray.set_visible (false);
        Log.debug ("Indicator destroyed");
        base.exit ();
    }

    /* Определение путей к иконкам: пользовательские из ~/.config/yd-tools/icons/<theme>,
       иначе штатные из каталога установки */
    public void set_icon_theme (bool light) {
        var theme = light ? "light" : "dark";
        var default_path = Path.build_filename (App.inst_path, "icons", theme);
        var user_path = Path.build_filename (App.conf_path, "icons", theme);
        string busy_user_icon = "";
        string[] statuses = { "idle", "error", "paused", "none", "no_net", "busy" };
        foreach (var status in statuses) {
            /* Имена файлов выбираются ветвлением, а не вложенным тернарным оператором:
               результат вложенного тернарника со строковыми ветвями освобождается
               компилятором раньше, чем копируется */
            string name;
            if (status == "paused" || status == "none" || status == "no_net") {
                name = "yd-ind-pause.png";
            } else if (status == "busy") {
                name = "yd-busy1.png";
            } else {
                name = "yd-ind-%s.png".printf (status);
            }
            var user_icon = Path.build_filename (user_path, name);
            busy_user_icon = user_icon;
            icon[status] = File.new_for_path (user_icon).query_exists () ? user_icon :
                           Path.build_filename (default_path, name);
        }
        /* Путь каталога тем берётся по наличию пользовательской иконки анимации */
        theme_path = File.new_for_path (busy_user_icon).query_exists () ? user_path : default_path;
    }

    public void update_icon (string status) {
        tray.set_icon (icon[status]);
        if (status == "busy") {
            seq_num = 2;
            start_animation ();
        } else {
            stop_animation ();
        }
    }

    /* Анимация иконки при синхронизации: 5 кадров по кругу */
    private bool animate_icon () {
        tray.set_icon (Path.build_filename (theme_path, "yd-busy%d.png".printf (seq_num)));
        seq_num = seq_num % 5 + 1;
        return true;
    }

    private void start_animation () {
        if (anim_source == 0) {
            anim_source = GLib.Timeout.add (777, animate_icon);
        }
    }

    private void stop_animation () {
        if (anim_source != 0) {
            GLib.Source.remove (anim_source);
            anim_source = 0;
        }
    }

    /* Двойной щелчок по иконке в области уведомления открывает папку синхронизации */
    public void open_disk_folder () {
        var dir = Utils.expand_user (config.get_string ("dir", ""));
        if (dir == "" || !File.new_for_path (dir).query_exists ()) {
            Log.info ("Disk folder is not configured or does not exist: '%s'".printf (dir));
            return;
        }
        Log.info ("Opening disk folder '%s'".printf (dir));
        Utils.run_async ({ "xdg-open", dir });
    }

    /* ################# Меню индикатора ################# */
    public class Menu : Gtk.Menu {

        private unowned Indicator dm;
        private string ID;
        private string folder = "";
        private bool daemon_started = false;

        private Gtk.MenuItem yddir_item;
        private Gtk.MenuItem status_item;
        private Gtk.MenuItem used_item;
        private Gtk.MenuItem free_item;
        private Gtk.MenuItem last_item;
        private Gtk.Menu last_items_menu;
        private Gtk.MenuItem daemon_ss;
        private Gtk.MenuItem open_folder;
        public Gtk.MenuItem preferences_item;
        public Gtk.MenuItem about_item;

        private GLib.HashTable<string, string> yd_status =
            new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);

        public Menu (Indicator dm, string ID) {
            this.dm = dm;
            this.ID = ID;
            if (ID != "") {
                yddir_item = new Gtk.MenuItem.with_label ("");
                yddir_item.set_sensitive (false);
                append (yddir_item);
            }
            status_item = new Gtk.MenuItem.with_label ("");
            status_item.activate.connect (() => { show_output (status_item); });
            append (status_item);
            used_item = new Gtk.MenuItem.with_label ("");
            used_item.set_sensitive (false);
            append (used_item);
            free_item = new Gtk.MenuItem.with_label ("");
            free_item.set_sensitive (false);
            append (free_item);
            last_item = new Gtk.MenuItem.with_label (_("Last synchronized items"));
            last_item.set_sensitive (false);
            last_items_menu = new Gtk.Menu ();
            last_item.set_submenu (last_items_menu);
            append (last_item);
            append (new Gtk.SeparatorMenuItem ());
            daemon_ss = new Gtk.MenuItem.with_label ("");
            daemon_ss.activate.connect (start_stop_daemon);
            append (daemon_ss);
            open_folder = new Gtk.MenuItem.with_label (_("Open Yandex.Disk Folder"));
            open_folder.activate.connect (() => { open_path (folder); });
            append (open_folder);
            var open_web = new Gtk.MenuItem.with_label (_("Open Yandex.Disk on the web"));
            open_web.activate.connect (() => { open_in_browser (_("https://disk.yandex.com")); });
            append (open_web);
            append (new Gtk.SeparatorMenuItem ());
            preferences_item = new Gtk.MenuItem.with_label (_("Preferences"));
            preferences_item.activate.connect (open_preferences);
            append (preferences_item);
            var open_help = new Gtk.MenuItem.with_label (_("Help"));
            var help_menu = new Gtk.Menu ();
            var help1 = new Gtk.MenuItem.with_label (_("Yandex.Disk daemon"));
            help1.activate.connect (() => { open_in_browser (_("https://yandex.com/support/disk/")); });
            help_menu.append (help1);
            var help2 = new Gtk.MenuItem.with_label (_("Yandex.Disk Indicator"));
            help2.activate.connect (() => {
                open_in_browser (_("https://github.com/slytomcat/yandex-disk-indicator/wiki/Yandex-disk-indicator"));
            });
            help_menu.append (help2);
            open_help.set_submenu (help_menu);
            append (open_help);
            about_item = new Gtk.MenuItem.with_label (_("About"));
            about_item.activate.connect (open_about);
            append (about_item);
            append (new Gtk.SeparatorMenuItem ());
            var close = new Gtk.MenuItem.with_label (_("Quit"));
            close.activate.connect (() => { app_exit (); });
            append (close);
            show_all ();
            yd_status["idle"] = _("Synchronized");
            yd_status["busy"] = _("Sync.: ");
            yd_status["none"] = _("Not started");
            yd_status["paused"] = _("Paused");
            yd_status["no_net"] = _("Not connected");
            yd_status["error"] = _("Error");
        }

        public void update (StatusVals vals, string yddir) {
            folder = yddir;
            if (vals.statchg || vals.laststatus == "unknown") {
                var extra = vals.status == "error"
                            ? ": %s %s".printf (vals.error, Utils.short_path (vals.path)) : "";
                status_item.set_label (_("Status: ") + yd_status[vals.status] +
                                       (vals.status == "busy" ? vals.progress : extra));
                if (vals.status == "none" || vals.laststatus == "none" || vals.laststatus == "unknown") {
                    daemon_started = vals.status != "none";
                    status_item.set_sensitive (daemon_started);
                    daemon_ss.set_label (daemon_started ? _("Stop Yandex.Disk daemon")
                                                       : _("Start Yandex.Disk daemon"));
                    if (ID != "") {
                        yddir_item.set_label (ID + _("  Folder: ") +
                                              (yddir != "" ? Utils.short_path (yddir) : "< NOT CONFIGURED >"));
                    }
                    open_folder.set_sensitive (yddir != "");
                }
            }
            if (vals.szchg || vals.laststatus == "unknown") {
                used_item.set_label (_("Used: ") + vals.used + "/" + vals.total);
                free_item.set_label (_("Free: ") + vals.free + _(", trash: ") + vals.trash);
            }
            if (vals.lastchg || vals.laststatus == "unknown") {
                last_items_menu.destroy ();
                last_items_menu = new Gtk.Menu ();
                foreach (var file_path in vals.lastitems) {
                    var widget = new Gtk.MenuItem.with_label (Utils.short_path (file_path));
                    var full_path = Utils.join_path (yddir, file_path);
                    if (File.new_for_path (full_path).query_exists ()) {
                        widget.set_sensitive (true);
                        widget.activate.connect (() => { open_path (full_path); });
                    } else {
                        widget.set_sensitive (false);
                    }
                    last_items_menu.append (widget);
                }
                last_item.set_submenu (last_items_menu);
                last_item.set_sensitive (vals.lastitems.length > 0);
                Log.debug ("Sub-menu 'Last synchronized' has %d items".printf (vals.lastitems.length));
            }
            show_all ();
        }

        private void open_about () {
            foreach (var i in Indicator.get_all ()) {
                i.menu.about_item.set_sensitive (false);
            }
            var about_window = new Gtk.AboutDialog ();
            about_window.set_logo (Gui.logo);
            about_window.set_icon (Gui.logo);
            about_window.set_program_name (_("Yandex.Disk indicator"));
            about_window.set_version (_("Version ") + APPVER);
            about_window.set_copyright (App.copyright);
            about_window.set_license (LICENSE);
            about_window.set_authors ({
                _("Sly_tom_cat <slytomcat@mail.ru> "),
                _("\nSpecial thanks to:"),
                _(" - Snow Dimon https://habrahabr.ru/users/Snowdimon/ - author of ya-setup utility"),
                _(" - Christiaan Diedericks https://www.thefanclub.co.za/ - author of Grive tools"),
                _(" - ryukusu_luminarius <my-faios@ya.ru> - icons designer"),
                _(" - metallcorn <metallcorn@jabber.ru> - icons designer"),
                _(" - Chibiko <zenogears@jabber.ru> - deb package creation assistance"),
                _(" - RingOV <ringov@mail.ru> - localization assistance"),
                _(" - GreekLUG team https://launchpad.net/~greeklug - Greek translation"),
                _(" - Peyu Yovev <spacy00001@gmail.com> - Bulgarian translation"),
                _(" - Eldar Fahreev <fahreeve@yandex.ru> - FM actions for Pantheon-files"),
                _(" - Ace Of Snakes <aceofsnakesmain@gmail.com> - optimization of FM actions for Dolphin"),
                _(" - Ivan Burmin https://github.com/Zirrald - ya-setup multilingual support"),
                _("And to all other people who contributed to this project via"),
                _(" - Ubuntu.ru forum http://forum.ubuntu.ru/index.php?topic=241992"),
                _(" - github.com https://github.com/slytomcat/yandex-disk-indicator")
            });
            about_window.set_resizable (false);
            about_window.run ();
            about_window.destroy ();
            foreach (var i in Indicator.get_all ()) {
                i.menu.about_item.set_sensitive (true);
            }
        }

        /* Запрос вывода демона (в пользовательской локали) и его показ в диалоге */
        private void show_output (Gtk.MenuItem item) {
            item.set_sensitive (false);
            dm.output ((out_text, code) => {
                var status_window = new Gtk.Dialog ();
                status_window.set_title (_("Yandex.Disk daemon output message"));
                status_window.set_icon (Gui.logo);
                status_window.set_border_width (6);
                status_window.add_button (_("Close"), Gtk.ResponseType.CLOSE);
                var text_box = new Gtk.TextView ();
                text_box.get_buffer ().set_text (out_text);
                text_box.set_editable (false);
                status_window.get_content_area ().pack_start (text_box, true, true, 6);
                status_window.show_all ();
                status_window.run ();
                status_window.destroy ();
                item.set_sensitive (true);
            });
        }

        private void open_in_browser (string url) {
            Utils.run_async ({ "xdg-open", url });
        }

        private void start_stop_daemon () {
            if (daemon_started) {
                dm.stop ();
            } else {
                dm.start ();
            }
        }

        private void open_path (string path) {
            Log.info ("Opening '%s'".printf (path));
            if (File.new_for_path (path).query_exists ()) {
                Utils.run_async ({ "xdg-open", path });
            }
        }

        private void open_preferences () {
            new Preferences (preferences_item);
        }
    }
}

}
