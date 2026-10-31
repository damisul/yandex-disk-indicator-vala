/* Интерфейс демона yandex-disk: разбор его вывода, опрос с адаптивной задержкой,
   следящий за логом монитор и запуск/остановка. */

namespace YD {

/* Набор значений статуса демона, который передаётся в change() */
public class StatusVals : GLib.Object {

    public string status = "unknown";
    public string progress = "";
    public string laststatus = "unknown";
    public bool statchg = true;
    public string total = "...";
    public string used = "...";
    public string free = "...";
    public string trash = "...";
    public bool szchg = true;
    public string error = "";
    public string path = "";
    public string[] lastitems = {};
    public bool lastchg = true;

    public string changes () {
        return "%s%s%s".printf (statchg ? "stat" : "", szchg ? "size" : "", lastchg ? "last" : "");
    }
}

/* code == -1 означает, что процесс не удалось запустить */
public delegate void ResponseFunc (string output, int code);

/* Конфигурация демона: часть значений хранится в файле config.cfg в собственном представлении */
public class DConfig : Config {

    public DConfig (string file_name) { base (file_name, false); }

    public override bool load () {
        if (!base.load ()) {
            return false;
        }
        /* Демон помечает включённые опции пустым значением: read-only="" */
        var ro = val_of ("read-only");
        set_bool ("read-only", ro != null && ro.is_str () && ro.get_string () == "");
        var ow = val_of ("overwrite");
        set_bool ("overwrite", ow != null && ow.is_str () && ow.get_string () == "");
        setdefault_bool ("startonstartofindicator", true);
        setdefault_bool ("stoponexitfromindicator", false);
        var ex = val_of ("exclude-dirs");
        if (ex != null && !ex.is_none () && !ex.is_list ()) {
            /* Кавычки вокруг "dir,dir,dir" не дают base.load() разбить значение на список */
            var reparsed = parse_values (ex.get_string ());
            if (reparsed != null) {
                set_val ("exclude-dirs", reparsed);
            }
        }
        return true;
    }

    public override bool save () {
        var file_config = new Config (file_name, false);
        var ro = get_bool ("read-only", false);
        file_config.use_quotes = use_quotes;
        file_config.delimiter = delimiter;
        file_config.set_val ("read-only", ro ? Val.str_val ("") : Val.none_val ());
        file_config.set_val ("overwrite",
                             (get_bool ("overwrite", false) && ro) ? Val.str_val ("") : Val.none_val ());
        file_config.set_bool ("startonstartofindicator", get_bool ("startonstartofindicator", true));
        file_config.set_bool ("stoponexitfromindicator", get_bool ("stoponexitfromindicator", false));
        var ex = val_of ("exclude-dirs");
        file_config.set_val ("exclude-dirs",
                             ex == null || ex.is_none () ? Val.none_val () : Val.str_val (string.joinv (", ", ex.strings ())));
        var ok = file_config.save ();
        changed = false;
        return ok;
    }
}

public class YDDaemon : GLib.Object {

    private const int MAX_BACKOFF = 8;

    public string ID = "";
    public string cfg_file = "";
    public DConfig config;
    public StatusVals vals = new StatusVals ();

    private string? ydc = null;
    private string env_path = "/usr/bin/env";
    private string tmp_dir = "";
    private string log_path = "";

    private uint poll_source = 0;
    private int t_cnt = 0;
    private bool in_flight = false;
    private bool pending_watch = false;
    private bool exiting = false;

    private GLib.FileMonitor? monitor = null;
    private bool watching = false;

    /* ################### Virtual methods ################# */
    /* Реализуются GUI-частью (Indicator) */

    public virtual int error (string err_str, string cfg_path) {
        Log.debug ("%sError %s , path %s".printf (ID, err_str, cfg_path));
        return 0;
    }

    public virtual void change (StatusVals v) {
        Log.debug ("%sUpdate event: %s".printf (ID, v.status));
    }

    public YDDaemon (string cfg_file, string ID) {
        this.cfg_file = cfg_file;
        this.ID = ID;
        config = new DConfig (cfg_file);
    }

    /* Инициализация вынесена из конструктора: конструктор базового класса отрабатывает
       до создания GUI, а проверка конфигурации может показывать диалоги. */
    public void init () {
        ydc = Utils.which ("yandex-disk");
        if (ydc == null) {
            error ("", "");
            GLib.Process.exit (1);
        }
        check_config ();
        tmp_dir = Environment.get_tmp_dir ();
        var env = Utils.which ("env");
        if (env != null) {
            env_path = env;
        }
        var dir = Utils.expand_user (config.get_string ("dir", ""));
        log_path = Utils.join_path (dir, ".sync/cli.log");
        schedule_poll (300, false);
        if (config.get_bool ("startonstartofindicator", true)) {
            start ();
        } else {
            start_watcher ();
        }
    }

    /* Проверка конфигурации демона с повтором после запуска ya-setup */
    private void check_config () {
        while (true) {
            string error_str = "";
            if (!config.load ()) {
                error_str = "Error: the file %s is missing or has wrong structure".printf (cfg_file);
            } else {
                var d = config.get_string ("dir", "");
                var a = config.get_string ("auth", "");
                if (d == "" || a == "") {
                    error_str = "Error: " + (d == "" ? "option 'dir'" : "") +
                                (d == "" && a == "" ? " and " : "") + (a == "" ? "option 'auth'" : "") +
                                (d == "" && a == "" ? " are " : " is ") +
                                "missing in the daemon configuration file %s".printf (cfg_file);
                } else {
                    var dp = Utils.expand_user (d);
                    var ap = Utils.expand_user (a);
                    var dne = !File.new_for_path (dp).query_exists ();
                    var ane = !File.new_for_path (ap).query_exists ();
                    if (dne || ane) {
                        error_str = "Error: " + (dne ? "path %s".printf (dp) : "") +
                                    (dne && ane ? " and " : "") + (ane ? "path %s".printf (ap) : "") +
                                    (dne && ane ? " are " : " is ") + "not exist";
                    }
                }
            }
            if (error_str == "") {
                return;
            }
            if (error (error_str, cfg_file) != 0) {
                if (ID != "") {
                    config.set_string ("dir", "");
                    return;
                }
                GLib.Process.exit (1);
            }
        }
    }

    /* ################### Private methods ################# */

    private string[] status_command (bool user_lang) {
        if (user_lang || ydc == null) {
            return { ydc ?? "", "status", "-c", config.file_name };
        }
        /* env -i убирает локаль, чтобы статус всегда приходил на английском (ключи парсера) */
        return { env_path, "-i", "TMPDIR=%s".printf (tmp_dir), ydc, "status", "-c", config.file_name };
    }

    private string read_status_sync () {
        var res = Utils.run_sync (status_command (false));
        return (res.launched && res.code == 0) ? res.output : "";
    }

    /* Обёртка задачи: команда и обработчик результата. Команда выполняется в рабочем потоке,
       результат передаётся в основной цикл GTK через Idle. */
    private class Command : GLib.Object {
        public string[] argv;
        public ResponseFunc cb;

        public Command (string[] argv, owned ResponseFunc cb) {
            this.argv = argv;
            this.cb = ( owned ) cb;
        }

        public void reply (CmdResult res) {
            /* Обработчику передаётся пустой вывод, если команда не запустилась или завершилась с ошибкой */
            cb (res.launched && res.code == 0 ? res.output : "", res.launched ? res.code : -1);
        }
    }

    private void run_command (string[] argv, owned ResponseFunc callback) {
        var job = new Command (argv, ( owned ) callback);
        new GLib.Thread<int> ("yd-command", () => {
            var res = Utils.run_sync (job.argv);
            GLib.Idle.add (() => {
                job.reply (res);
                return false;
            });
            return 0;
        });
    }

    private void schedule_poll (uint delay_ms, bool from_watch) {
        if (exiting) {
            return;
        }
        if (poll_source != 0) {
            GLib.Source.remove (poll_source);
        }
        poll_source = GLib.Timeout.add (delay_ms, () => {
            poll_source = 0;
            poll (from_watch);
            return false;
        });
    }

    private void poll (bool from_watch) {
        if (in_flight) {
            pending_watch = pending_watch || from_watch;
            return;
        }
        in_flight = true;
        run_command (status_command (false), (output, code) => {
            in_flight = false;
            if (exiting) {
                return;
            }
            if (parse_output (output)) {
                Log.debug ("%sEvent raised by %s".printf (ID, from_watch ? " Watcher" : " Timer"));
                change (vals);
            }
            if (pending_watch) {
                pending_watch = false;
                poll (true);
                return;
            }
            uint delay;
            if (from_watch || vals.status == "busy") {
                delay = 2;
                t_cnt = 0;
            } else {
                /* Задержка растёт до 10 с и дальше не увеличивается: опрос не прекращается,
                   чтобы остановка демона извне всё равно была обнаружена */
                delay = 2 + t_cnt;
                if (t_cnt < MAX_BACKOFF) {
                    t_cnt++;
                }
            }
            schedule_poll (delay * 1000, false);
        });
    }

    /* Разбор вывода 'yandex-disk status'. Возвращает true, если что-то изменилось */
    public bool parse_output (string text) {
        vals.statchg = false;
        vals.szchg = false;
        vals.lastchg = false;

        var sections = text.split ("Last synchronized items:");
        var files = sections.length == 2 ? sections[1] : "";
        /* Пустой вывод даёт массив нулевой длины, поэтому заголовок берётся только при его наличии */
        var header = sections.length > 0 ? sections[0] : "";
        var named = new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);
        try {
            var kv_re = new GLib.Regex ("\\s*(.+):\\s*(.*)");
            foreach (var line in header.split ("\n")) {
                if (!line.contains (":")) {
                    continue;
                }
                MatchInfo mi;
                if (kv_re.match (line, 0, out mi)) {
                    named[(mi.fetch (1) ?? "").strip ()] = (mi.fetch (2) ?? "").strip ();
                }
            }
        } catch (GLib.RegexError e) {
            Log.error ("Status parser error: %s".printf (e.message));
        }

        string[] search_keys = {
            "Synchronization core status", "Sync progress", "Total", "Used",
            "Available", "Trash size", "Error", "Path"
        };
        string[] value_names = { "status", "progress", "total", "used", "free", "trash", "error", "path" };
        for (int idx = 0; idx < value_names.length; idx++) {
            var key = value_names[idx];
            var val = named.contains (search_keys[idx]) ? named[search_keys[idx]] : "";
            if (key == "status") {
                vals.laststatus = vals.status;
                /* 'index' - промежуточный статус: его игнорируем, оставляя предыдущий */
                val = val == "" ? "none" :
                      (val == "index" && vals.laststatus == "unknown") ? "busy" :
                      (val == "index") ? vals.laststatus :
                      (val == "no internet access") ? "no_net" :
                      (val == "busy" || val == "idle" || val == "paused") ? val : "error";
            } else if (key != "progress" && val == "") {
                val = "...";
            }
            var current = value_of (key);
            if (current != val) {
                set_value (key, val);
                if (key == "status" || key == "progress") {
                    vals.statchg = true;
                } else {
                    vals.szchg = true;
                }
            }
        }

        var items = Utils.re_findall (".*: '(.*)'\n", files, 1);
        if (!strv_equal (vals.lastitems, items)) {
            vals.lastitems = items;
            vals.lastchg = true;
        }
        return vals.statchg || vals.szchg || vals.lastchg;
    }

    private string value_of (string key) {
        switch (key) {
        case "status": return vals.status;
        case "progress": return vals.progress;
        case "total": return vals.total;
        case "used": return vals.used;
        case "free": return vals.free;
        case "trash": return vals.trash;
        case "error": return vals.error;
        default: return vals.path;
        }
    }

    private void set_value (string key, string val) {
        switch (key) {
        case "status": vals.status = val; break;
        case "progress": vals.progress = val; break;
        case "total": vals.total = val; break;
        case "used": vals.used = val; break;
        case "free": vals.free = val; break;
        case "trash": vals.trash = val; break;
        case "error": vals.error = val; break;
        default: vals.path = val; break;
        }
    }

    private static bool strv_equal (string[] a, string[] b) {
        if (a.length != b.length) {
            return false;
        }
        for (int i = 0; i < a.length; i++) {
            if (a[i] != b[i]) {
                return false;
            }
        }
        return true;
    }

    /* ################### Watcher ################# */

    private void start_watcher () {
        if (watching) {
            return;
        }
        var log_file = File.new_for_path (log_path);
        if (!log_file.query_exists ()) {
            Log.info ("Watcher was not started: path '%s' was not found.".printf (log_path));
            return;
        }
        try {
            monitor = log_file.monitor_file (GLib.FileMonitorFlags.NONE, null);
            monitor.set_rate_limit (500);
            monitor.changed.connect ((file, other_file, event) => {
                if (event != GLib.FileMonitorEvent.CHANGED && event != GLib.FileMonitorEvent.CHANGES_DONE_HINT) {
                    return;
                }
                if (in_flight || exiting) {
                    pending_watch = true;
                    return;
                }
                schedule_poll (0, true);
            });
            watching = true;
        } catch (GLib.Error e) {
            Log.info ("Watcher was not started: %s".printf (e.message));
        }
    }

    private void stop_watcher () {
        if (monitor != null) {
            monitor.cancel ();
            monitor = null;
        }
        watching = false;
    }

    /* ################### Interface methods ################# */

    public void output (owned ResponseFunc callback) {
        run_command (status_command (true), ( owned ) callback);
    }

    public void start () {
        run_command (status_command (false), (output, code) => {
            if (output != "") {
                Log.info ("Daemon is already started");
                start_watcher ();
                return;
            }
            run_command ({ ydc ?? "", "start", "-c", config.file_name }, (out_text, ret) => {
                if (ret == 0) {
                    Log.info ("Daemon started, message: %s".printf (out_text));
                    start_watcher ();
                    return;
                }
                Log.error ("Daemon start failed with code %d: %s".printf (ret, out_text));
                vals.laststatus = vals.status;
                vals.status = "error";
                vals.progress = "";
                vals.statchg = true;
                vals.szchg = true;
                vals.lastchg = true;
                var lines = out_text.split ("\n");
                vals.error = lines.length > 0 ? lines[0] : "";
                vals.path = "";
                vals.lastitems = {};
                change (vals);
            });
        });
    }

    /* Остановка выполняется без блокировки GUI-цикла; синхронный вариант нужен только при
       выходе из индикатора, когда демона следует остановить до закрытия приложения. */
    public void stop (bool wait = false) {
        if (wait) {
            do_stop ();
            return;
        }
        run_command (status_command (false), (output, code) => {
            if (output == "") {
                Log.info ("Daemon is not started");
                return;
            }
            run_command ({ ydc ?? "", "stop", "-c", config.file_name }, (out_text, ret) => {
                if (ret == 0) {
                    Log.info ("Daemon stopped, message: %s".printf (out_text));
                } else {
                    Log.info ("Daemon stop failed");
                }
            });
        });
    }

    public virtual void exit () {
        Log.debug ("Daemon interface %sexit started".printf (ID));
        exiting = true;
        stop_watcher ();
        if (poll_source != 0) {
            GLib.Source.remove (poll_source);
            poll_source = 0;
        }
        if (config.get_bool ("stoponexitfromindicator", false)) {
            do_stop ();
            Log.info ("Demon %sstopped".printf (ID));
        }
        Log.debug ("Daemon interface %sexited".printf (ID));
    }

    private void do_stop () {
        if (read_status_sync () == "") {
            Log.info ("Daemon is not started");
            return;
        }
        var res = Utils.run_sync ({ ydc ?? "", "stop", "-c", config.file_name });
        if (res.launched && res.code == 0) {
            Log.info ("Daemon stopped, message: %s".printf (res.output));
        } else {
            Log.info ("Daemon stop failed");
        }
    }
}

}
