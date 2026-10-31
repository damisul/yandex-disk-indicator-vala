/* Разбор командной строки и вывод справки. */

namespace YD {

public class CliArgs : GLib.Object {
    public int level = 30;
    public string cfg = "";
    public string rcfg = "";
}

public class Cli {

    public static void print_help (string prog) {
        stdout.printf ("usage: %s [-l {10,20,30,40,50}] [-c path] [-r path] [-h] [-v]\n\n", prog);
        stdout.printf ("%s\n\n", _("Desktop indicator for yandex-disk daemon"));
        stdout.printf ("%s:\n", _("Options"));
        stdout.printf ("  -l {10,20,30,40,50}, --log {10,20,30,40,50}\n");
        stdout.printf ("                        %s\n",
            _("Sets the logging level: " +
              "10 - to show all messages (DEBUG), " +
              "20 - to show all messages except debugging messages (INFO), " +
              "30 - to show all messages except debugging and info messages (WARNING), " +
              "40 - to show only error and critical messages (ERROR), " +
              "50 - to show critical messages only (CRITICAL). Default: 30"));
        stdout.printf ("  -c path, --config path\n");
        stdout.printf ("                        %s\n",
            _("Path to configuration file of YandexDisk daemon. " +
              "This daemon will be added to daemons list" +
              " if it is not in the current configuration." +
              "Default: ''"));
        stdout.printf ("  -r path, --remove path\n");
        stdout.printf ("                        %s\n",
            _("Path to configuration file of daemon that should be removed" +
              " from daemos list. Default: ''"));
        stdout.printf ("  -h, --help            %s\n", _("Show this help message and exit"));
        stdout.printf ("  -v, --version         %s\n", _("Print version and exit"));
    }

    private static void usage_error (string prog, string message) {
        stderr.printf ("usage: %s [-l {10,20,30,40,50}] [-c path] [-r path] [-h] [-v]\n", prog);
        stderr.printf ("%s: error: %s\n", prog, message);
        GLib.Process.exit (2);
    }

    /* Значение опции может быть передано как "-l 40", "--log=40" или "--log 40" */
    private static string option_value (string arg, string name, string[] args, ref int i, string prog) {
        var eq = arg.index_of ("=");
        if (eq >= 0) {
            return arg.substring (eq + 1);
        }
        if (i + 1 >= args.length) {
            usage_error (prog, _("argument %s: expected one argument").printf (name));
        }
        i++;
        return args[i];
    }

    public static CliArgs parse (string[] args) {
        var res = new CliArgs ();
        var prog = Path.get_basename (args[0]);
        int i = 1;
        while (i < args.length) {
            var arg = args[i];
            if (arg == "-h" || arg == "--help") {
                print_help (prog);
                GLib.Process.exit (0);
            } else if (arg == "-v" || arg == "--version") {
                stdout.printf ("%s v.%s\n".printf (prog, APPVER));
                GLib.Process.exit (0);
            } else if (arg == "-l" || arg == "--log") {
                res.level = parse_level (option_value (arg, "--log", args, ref i, prog), prog);
            } else if (arg.has_prefix ("--log=")) {
                res.level = parse_level (arg.substring (6), prog);
            } else if (arg == "-c" || arg == "--config") {
                res.cfg = option_value (arg, "--config", args, ref i, prog);
            } else if (arg.has_prefix ("--config=")) {
                res.cfg = arg.substring (9);
            } else if (arg == "-r" || arg == "--remove") {
                res.rcfg = option_value (arg, "--remove", args, ref i, prog);
            } else if (arg.has_prefix ("--remove=")) {
                res.rcfg = arg.substring (9);
            } else {
                usage_error (prog, _("unrecognized arguments: %s").printf (arg));
            }
            i++;
        }
        return res;
    }

    private static int parse_level (string value, string prog) {
        int level = int.parse (value);
        if (level < 10 || level > 50 || level % 10 != 0) {
            usage_error (prog, _("argument -l/--log: invalid choice: '%s' (choose from 10, 20, 30, 40, 50)")
                            .printf (value));
        }
        return level;
    }
}

}
