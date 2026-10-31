/* Файловые утилиты, запуск внешних процессов, действия для файловых менеджеров
   и проверка автозапуска. */

namespace YD {

public class CmdResult : GLib.Object {
    public bool launched = false;
    public int code = -1;
    public string output = "";
}

public class Utils {

    /* Индекс байта, с которого начинается n-ный символ UTF-8: укорачивание пути
       считается по символам, а не по байтам */
    private static int rune_to_byte (string s, int n) {
        int byte_pos = 0;
        int chars = 0;
        unichar ch;
        while (byte_pos < s.length && chars < n) {
            if (!s.get_next_char (ref byte_pos, out ch)) {
                break;
            }
            chars++;
        }
        return byte_pos;
    }

    /* Укорачивание пути для показа в меню: первые 20 и последние 27 символов.
       Подчёркивание заменяется на U+02CD, чтобы GTK не считал его меткой ускорения. */
    public static string short_path (string path) {
        var chars = path.char_count ();
        var res = path;
        if (chars > 50) {
            res = path.substring (0, rune_to_byte (path, 20)) + "..." +
                  path.substring (rune_to_byte (path, chars - 27));
        }
        return res.replace ("_", "\u02CD");
    }

    public static string expand_user (string path) {
        if (path == "~") {
            return Environment.get_home_dir ();
        }
        if (path.has_prefix ("~/")) {
            return Path.build_filename (Environment.get_home_dir (), path.substring (2));
        }
        return path;
    }

    public static string relative_path (string path, string root) {
        var prefix = root.has_suffix ("/") ? root : root + "/";
        if (path.has_prefix (prefix)) {
            return path.substring (prefix.length);
        }
        return path;
    }

    public static bool copy_file (string src, string dst) {
        try {
            uint8[] data;
            var source = File.new_for_path (src);
            source.load_contents (null, out data, null);
            var mode = source.query_info ("unix::mode", GLib.FileQueryInfoFlags.NONE)
                           .get_attribute_uint32 ("unix::mode");
            var stream = File.new_for_path (dst).create (GLib.FileCreateFlags.NONE, null);
            stream.write_bytes (new GLib.Bytes (data), null);
            stream.close (null);
            Posix.chmod (dst, (Posix.mode_t) mode);
        } catch (GLib.Error e) {
            Log.error ("File Copy Error: from %s to %s".printf (src, dst));
            return false;
        }
        return true;
    }

    public static bool delete_file (string path) {
        if (FileUtils.remove (path) == 0) {
            return true;
        }
        Log.error ("File Deletion Error: %s".printf (path));
        return false;
    }

    public static bool make_dirs (string path) {
        var dir = File.new_for_path (path);
        if (dir.query_exists ()) {
            return true;
        }
        try {
            dir.make_directory_with_parents (null);
        } catch (GLib.Error e) {
            Log.error ("Dirs creation Error: %s".printf (path));
            return false;
        }
        return true;
    }

    public static string? which (string program) {
        return Environment.find_program_in_path (program);
    }

    /* os.path.join: пустой первый компонент не добавляет разделитель */
    public static string join_path (string parent, string child) {
        return parent == "" ? child : Path.build_filename (parent, child);
    }

    public static bool strv_has (string[] array, string value) {
        foreach (var item in array) {
            if (item == value) {
                return true;
            }
        }
        return false;
    }

    /* Возвращает массив без вхождений указанного элемента */
    public static string[] strv_remove (string[] array, string value) {
        var res = new string[] {};
        foreach (var item in array) {
            if (item != value) {
                res += item;
            }
        }
        return res;
    }

    /* Собирает содержимое указанной группы из всех совпадений в subject */
    public static string[] re_findall (string pattern, string subject, int group,
                                      GLib.RegexCompileFlags flags = 0) {
        var res = new string[] {};
        try {
            /* DOTALL задаётся при компиляции: точка начинает совпадать и с переводом строки */
            var re = new GLib.Regex (pattern, flags, 0);
            MatchInfo mi;
            /* Обход совпадений делается через match() + next(): результат match_all()
               уже смещён за последнее совпадение, и next() на нём не работает. */
            if (re.match (subject, 0, out mi)) {
                while (mi.matches ()) {
                    var found = mi.fetch (group);
                    if (found != null) {
                        res += found;
                    }
                    if (!mi.next ()) {
                        break;
                    }
                }
            }
        } catch (GLib.RegexError e) {
            Log.error ("Search error in '%s': %s".printf (pattern, e.message));
        }
        return res;
    }

    /* Блокирующий запуск процесса: результат возвращается кодом возврата, а не исключением */
    public static int call (string[] argv) {
        var res = run_sync (argv);
        return res.code;
    }

    public static CmdResult run_sync (string[] argv, string[]? envp = null) {
        var res = new CmdResult ();
        int status;
        string stdout_text;
        try {
            GLib.Process.spawn_sync (null, argv, envp, GLib.SpawnFlags.SEARCH_PATH, null,
                              out stdout_text, null, out status);
        } catch (GLib.SpawnError e) {
            Log.debug ("Failed to start '%s': %s".printf (argv[0], e.message));
            return res;
        }
        res.launched = GLib.Process.if_exited (status);
        res.code = res.launched ? GLib.Process.exit_status (status) : -1;
        res.output = stdout_text ?? "";
        return res;
    }

    /* Запуск «и забудь» (открытие каталога/ссылки) */
    public static void run_async (string[] argv) {
        try {
            GLib.Pid pid;
            GLib.Process.spawn_async (null, argv, null, GLib.SpawnFlags.SEARCH_PATH, null, out pid);
        } catch (GLib.SpawnError e) {
            Log.error ("Start of '%s' failed".printf (argv[0]));
        }
    }

    /* Проверяет, включён ли автозапуск в ~/.config/autostart/<file>.desktop */
    public static bool check_autostart (string path) {
        if (!File.new_for_path (path).query_exists ()) {
            return false;
        }
        string content;
        try {
            FileUtils.get_contents (path, out content);
        } catch (GLib.Error e) {
            return false;
        }
        /* В Unity/Pantheon состояние хранит X-GNOME-Autostart-enabled, в остальных DE - Hidden */
        var xdg = Environment.get_variable ("XDG_CURRENT_DESKTOP");
        bool enabled_attr = (xdg == "Unity" || xdg == "Pantheon");
        string attr = enabled_attr ? "X-GNOME-Autostart-enabled" : "Hidden";
        try {
            var re = new GLib.Regex ("\\n" + GLib.Regex.escape_string (attr) + "=(.+)");
            MatchInfo mi;
            if (re.match (content, 0, out mi)) {
                var value = mi.fetch (1) ?? "";
                return value == (enabled_attr ? "true" : "false");
            }
        } catch (GLib.RegexError e) {
            Log.error ("Autostart check error: %s".printf (e.message));
            return false;
        }
        return true;
    }

    /* Установка/снятие действий для обнаруженных файловых менеджеров */
    public static bool activate_actions (bool activate, string inst_path) {
        var home = Environment.get_home_dir ();
        var result = false;
        var publish_name = _("Publish via Yandex.Disk");
        var unpublish_name = _("Unpublish from Yandex.disk");
        var scripts_src = Path.build_filename (inst_path, "fm-actions", "Nautilus_Nemo");

        /* --- Actions for Nautilus --- */
        if (which ("nautilus") != null) {
            Log.info ("Nautilus installed");
            {
                var dir = ".local/share/nautilus/scripts";
                var lsb = which ("lsb_release");
                if (lsb != null) {
                    var ver = run_sync ({ lsb, "-rs" }).output.strip ();
                    if (ver != "" && double.parse (ver) < 12.10) {
                        dir = ".gnome2/nautilus-scripts/";
                    }
                }
                var target = Path.build_filename (home, dir);
                if (activate) {
                    make_dirs (target);
                    copy_file (Path.build_filename (scripts_src, "publish"), Path.build_filename (target, publish_name));
                    copy_file (Path.build_filename (scripts_src, "unpublish"), Path.build_filename (target, unpublish_name));
                } else {
                    delete_file (Path.build_filename (target, publish_name));
                    delete_file (Path.build_filename (target, unpublish_name));
                }
                result = true;
            }
        }

        /* --- Actions for Nemo --- */
        if (which ("nemo") != null) {
            Log.info ("Nemo installed");
            var target = Path.build_filename (home, ".local/share/nemo/scripts");
            if (activate) {
                make_dirs (target);
                copy_file (Path.build_filename (scripts_src, "publish"), Path.build_filename (target, publish_name));
                copy_file (Path.build_filename (scripts_src, "unpublish"), Path.build_filename (target, unpublish_name));
            } else {
                delete_file (Path.build_filename (home, ".gnome2/nemo-scripts", publish_name));
                delete_file (Path.build_filename (home, ".gnome2/nemo-scripts", unpublish_name));
            }
            result = true;
        }

        /* --- Actions for Caja --- */
        if (which ("caja") != null) {
            Log.info ("Caja installed");
            var target = Path.build_filename (home, ".config/caja/scripts");
            if (activate) {
                make_dirs (target);
                copy_file (Path.build_filename (scripts_src, "publish"), Path.build_filename (target, publish_name));
                copy_file (Path.build_filename (scripts_src, "unpublish"), Path.build_filename (target, unpublish_name));
            } else {
                delete_file (Path.build_filename (target, publish_name));
                delete_file (Path.build_filename (target, unpublish_name));
            }
            result = true;
        }

        /* --- Actions for Thunar --- */
        if (which ("thunar") != null) {
            Log.info ("Thunar installed");
            try {
                var uca_path = Path.build_filename (home, ".config/Thunar/uca.xml");
                string content;
                FileUtils.get_contents (uca_path, out content);
                var head_re = new GLib.Regex ("(^.*<actions>)(.*)(</actions>)",
                                              GLib.RegexCompileFlags.DOTALL, 0);
                MatchInfo hi;
                if (!head_re.match (content, 0, out hi)) {
                    Log.error ("Cannot enable actions for Thunar: no <actions> section in %s".printf (uca_path));
                } else {
                    var head = hi.fetch (1) ?? "";
                    var body = hi.fetch (2) ?? "";
                    var tail = hi.fetch (3) ?? "";
                    var names = new string[] {};
                    var blocks = new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);
                    foreach (var block in re_findall ("(<action>.*?</action>)", body, 1,
                                                      GLib.RegexCompileFlags.DOTALL)) {
                        var found = re_findall ("<name>(.+?)</name>", block, 1, GLib.RegexCompileFlags.DOTALL);
                        var name = found.length > 0 ? found[0] : "";
                        if (!blocks.contains (name)) {
                            names += name;
                        }
                        blocks[name] = block;
                    }
                    if (activate) {
                        if (!blocks.contains (publish_name)) {
                            blocks[publish_name] = ("<action><icon>folder-publicshare</icon><name>" + publish_name +
                                "</name><command>yandex-disk publish %f | xclip -filter -selection clipboard;" +
                                " zenity --info --window-icon=" + inst_path + "/icons/yd-128.png" +
                                " --title=\"Yandex.Disk\" --ok-label=\"" + _("Close") + "\" --text=\"" +
                                _("URL to file: %f was copied into clipboard.") +
                                "\"</command><description/><patterns>*</patterns><directories/><audio-files/>" +
                                "<image-files/><other-files/><text-files/><video-files/></action>");
                            names += publish_name;
                        }
                        if (!blocks.contains (unpublish_name)) {
                            blocks[unpublish_name] = ("<action><icon>folder</icon><name>" + unpublish_name +
                                "</name><command>zenity --info --window-icon=" + inst_path +
                                "/icons/yd-128_g.png --ok-label=\"" + _("Close") + "\" --title=\"Yandex.Disk\" --text=\"" +
                                unpublish_name + ": `yandex-disk unpublish %f`\"</command><description/>" +
                                "<patterns>*</patterns><directories/><audio-files/><image-files/><other-files/>" +
                                "<text-files/><video-files/></action>");
                            names += unpublish_name;
                        }
                    } else {
                        string[] yd_actions = { publish_name, unpublish_name };
                        foreach (var name in yd_actions) {
                            if (blocks.contains (name)) {
                                blocks.remove (name);
                                names = strv_remove (names, name);
                            }
                        }
                    }
                    var body_buf = new GLib.StringBuilder ();
                    foreach (var name in names) {
                        body_buf.append (blocks[name]);
                    }
                    FileUtils.set_contents (uca_path, head + body_buf.str + tail);
                    result = true;
                }
            } catch (GLib.Error e) {
                Log.error ("Cannot handle Thunar actions: %s".printf (e.message));
            }
        }

        /* --- Actions for Dolphin --- */
        if (which ("dolphin") != null) {
            Log.info ("Dolphin installed");
            var target = Path.build_filename (home, ".local/share/kservices5/ServiceMenus", "ydpublish.desktop");
            if (activate) {
                make_dirs (Path.get_dirname (target));
                copy_file (Path.build_filename (inst_path, "fm-actions", "Dolphin", "ydpublish.desktop"), target);
            } else {
                delete_file (target);
            }
            result = true;
        }

        /* --- Actions for Pantheon-files --- */
        if (which ("pantheon-files") != null) {
            Log.info ("Pantheon-files installed");
            var ctrs_path = "/usr/share/contractor/";
            var gksudo = which ("gksudo");
            if (gksudo == null) {
                Log.error ("Cannot enable actions for Pantheon-files: gksudo is not installed");
            } else {
                var src_path = Path.build_filename (inst_path, "fm-actions", "pantheon-files");
                var ctr_pub = Path.build_filename (src_path, "yandex-disk-indicator-publish.contract");
                var ctr_unpub = Path.build_filename (src_path, "yandex-disk-indicator-unpublish.contract");
                int res;
                if (activate) {
                    res = call ({ gksudo, "-D", "yd-tools", "cp", ctr_pub, ctr_unpub, ctrs_path });
                } else {
                    res = call ({ gksudo, "-D", "yd-tools", "rm",
                                  Path.build_filename (ctrs_path, "yandex-disk-indicator-publish.contract"),
                                  Path.build_filename (ctrs_path, "yandex-disk-indicator-unpublish.contract") });
                }
                if (res == 0) {
                    result = true;
                } else {
                    Log.error ("Cannot %s actions for Pantheon-files".printf (activate ? "enable" : "disable"));
                }
            }
        }

        return result;
    }
}

}
