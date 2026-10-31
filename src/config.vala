/* Классы конфигурации: значение ключа (Val), накопитель значений (CVal)
   и файл настроек в формате key=value (Config). */

namespace YD {

/* Значение ключа конфигурационного файла: отсутствующее (NONE - удаляется из файла),
   булево, строка или список. */
public class Val : GLib.Object {

    public enum Kind { NONE, BOOL, STR, LIST }

    public Kind kind = Kind.NONE;
    private bool flag = false;
    private string text = "";
    private Val[] items = {};

    public static Val none_val () { return new Val (); }

    public static Val bool_val (bool value) {
        var res = new Val ();
        res.kind = Kind.BOOL;
        res.flag = value;
        return res;
    }

    public static Val str_val (string value) {
        var res = new Val ();
        res.kind = Kind.STR;
        res.text = value;
        return res;
    }

    public static Val list_val (owned Val[] values) {
        var res = new Val ();
        res.kind = Kind.LIST;
        res.items = ( owned ) values;
        return res;
    }

    public bool is_none () { return kind == Kind.NONE; }
    public bool is_bool () { return kind == Kind.BOOL; }
    public bool is_str () { return kind == Kind.STR; }
    public bool is_list () { return kind == Kind.LIST; }

    public bool get_bool (bool dflt = false) { return kind == Kind.BOOL ? flag : dflt; }
    public string get_string (string dflt = "") { return kind == Kind.STR ? text : dflt; }
    public Val[] get_items () { return items; }

    /* Список скалярных значений: одиночное значение ведёт себя как список из одного элемента */
    public Val[] list_of_items () {
        if (kind == Kind.LIST) {
            return items;
        }
        if (kind == Kind.NONE) {
            return {};
        }
        return { this };
    }

    public string[] strings () {
        var res = new string[] {};
        foreach (var item in list_of_items ()) {
            res += item.is_bool () ? (item.get_bool () ? "yes" : "no") : item.get_string ();
        }
        return res;
    }

    public bool truthy () { return kind != Kind.NONE; }

    public string to_display () {
        switch (kind) {
        case Kind.NONE:
            return "None";
        case Kind.BOOL:
            return flag ? "True" : "False";
        case Kind.STR:
            return "'" + text + "'";
        default:
            var parts = new string[] {};
            foreach (var item in items) {
                parts += item.to_display ();
            }
            return "[" + string.joinv (", ", parts) + "]";
        }
    }
}

/* Накопитель значений: первое добавленное значение хранится скаляром, второе превращает его в список */
public class CVal {

    private Val val;

    public CVal (Val? initial = null) { set_val (initial != null ? initial : Val.none_val ()); }

    public Val get_val () { return val; }

    public Val set_val (Val value) {
        var items = value.get_items ();
        val = (value.is_list () && items.length == 1) ? items[0] : value;
        return val;
    }

    public Val add (Val item) {
        if (val.is_list ()) {
            var items = val.get_items ();
            items += item;
            val = Val.list_val (( owned ) items);
        } else if (val.is_none ()) {
            val = item;
        } else {
            val = Val.list_val ({ val, item });
        }
        return val;
    }

    public bool truthy () { return val.truthy (); }
    public Val[] flat () { return val.list_of_items (); }
}

public class Config : GLib.Object {

    public string file_name;
    public bool changed = false;
    public bool read_success = false;
    public bool use_quotes = true;
    public string delimiter = "=";
    public string[] bools_true = { "true", "yes", "y" };
    public string[] bools_false = { "false", "no", "n" };
    public string[] bools_write = { "yes", "no" };

    protected GLib.HashTable<string, Val> map =
        new GLib.HashTable<string, Val> (GLib.str_hash, GLib.str_equal);
    private string[] order = {};

    public Config (string file_name, bool do_load = true) {
        this.file_name = file_name;
        if (do_load) {
            load ();
        }
    }

    public bool has (string key) { return map.contains (key); }

    public Val? val_of (string key) { return map[key]; }

    public bool get_bool (string key, bool dflt = false) {
        var v = map[key];
        return v == null ? dflt : v.get_bool (dflt);
    }

    public string get_string (string key, string dflt = "") {
        var v = map[key];
        return v == null ? dflt : v.get_string (dflt);
    }

    public string[] get_strings (string key) {
        var v = map[key];
        return v == null ? new string[] {} : v.strings ();
    }

    public void set_val (string key, Val value) {
        if (!map.contains (key)) {
            order += key;
        }
        map[key] = value;
    }

    public void set_bool (string key, bool value) { set_val (key, Val.bool_val (value)); }
    public void set_string (string key, string value) { set_val (key, Val.str_val (value)); }
    public void set_none (string key) { set_val (key, Val.none_val ()); }

    public void setdefault_bool (string key, bool dflt) {
        if (!has (key)) {
            set_bool (key, dflt);
        }
    }

    public string[] keys_list () {
        var res = new string[] {};
        foreach (var key in order) {
            res += key;
        }
        return res;
    }

    /* Определение типа значения по его строковому представлению: true/yes/y и false/no/n
       становятся булевыми, всё остальное остаётся строкой */
    private Val decode (string value) {
        var lower = value.down ();
        foreach (var t in bools_true) {
            if (lower == t) {
                return Val.bool_val (true);
            }
        }
        foreach (var f in bools_false) {
            if (lower == f) {
                return Val.bool_val (false);
            }
        }
        return Val.str_val (value);
    }

    private string encode (Val value) {
        var text = value.is_bool () ? (value.get_bool () ? bools_write[0] : bools_write[1]) : value.get_string ();
        return use_quotes ? "\"" + text + "\"" : text;
    }

    /* Разбор части строки после '=': одно значение или список через запятую, кавычки необязательны */
    public Val? parse_values (string st) {
        var acc = new CVal ();
        string rest = st.strip ();
        if (rest.has_prefix (",")) {
            return null;
        }
        try {
            var re = new GLib.Regex ("^(\"[^\"]*\")|^([^\",#]+)");
            while (true) {
                MatchInfo mi;
                if (!re.match (rest, 0, out mi)) {
                    return null;
                }
                var matched = mi.fetch (0) ?? "";
                /* Группа, не участвовавшая в совпадении, возвращается пустой строкой,
                   а не null: значение в кавычках берётся, только если оно действительно найдено */
                var quoted = mi.fetch (1);
                var found = quoted != null && quoted != "" ? quoted : mi.fetch (2);
                if (found.has_prefix ("\"")) {
                    found = found.substring (1, found.length - 2);
                }
                acc.add (decode (found.strip ()));
                rest = rest.substring (matched.length).strip ();
                if (rest == "") {
                    return acc.get_val ();
                }
                if (rest.has_prefix (",")) {
                    rest = rest.substring (1).strip ();
                    if (rest != "") {
                        continue;
                    }
                }
                return null;
            }
        } catch (GLib.RegexError e) {
            Log.error ("Value parser error: %s".printf (e.message));
            return null;
        }
    }

    public virtual bool load () {
        string content;
        try {
            FileUtils.get_contents (file_name, out content);
        } catch (GLib.Error e) {
            Log.error ("Config file read error: %s".printf (file_name));
            read_success = false;
            return false;
        }
        read_success = true;
        try {
            var kv_re = new GLib.Regex ("^\\s*(.+?)\\s*" + GLib.Regex.escape_string (delimiter) + "\\s*(.*)$");
            var key_re = new GLib.Regex ("^\"([^\"]+)\"$|^([\\w-]+)$");
            foreach (var line in content.split ("\n")) {
                if (line == "" || !line.contains (delimiter) || line.strip ().has_prefix ("#")) {
                    continue;
                }
                MatchInfo mi;
                if (!kv_re.match (line, 0, out mi)) {
                    continue;
                }
                var kv = mi.fetch (1) ?? "";
                var vv = mi.fetch (2) ?? "";
                MatchInfo ki;
                if (!key_re.match (kv, 0, out ki)) {
                    Log.warning ("Wrong key in line '%s %s %s'".printf (kv, delimiter, vv));
                    continue;
                }
                var key = (ki.fetch (1) ?? "") + (ki.fetch (2) ?? "");
                if (vv.strip () == "") {
                    Log.warning ("No value specified in line '%s %s %s'".printf (kv, delimiter, vv));
                    continue;
                }
                var value = parse_values (vv);
                if (value == null) {
                    Log.warning ("Wrong value(s) in line '%s %s %s'".printf (kv, delimiter, vv));
                    continue;
                }
                if (has (key)) {
                    Log.warning ("Double values for one key:\n%s = %s\nand\n%s = %s\nLast one is stored."
                        .printf (key, val_of (key).to_display (), key, value.to_display ()));
                }
                set_val (key, value);
                Log.debug ("Config value read as: %s = %s".printf (key, value.to_display ()));
            }
        } catch (GLib.RegexError e) {
            Log.error ("Config parser error: %s".printf (e.message));
            read_success = false;
            return false;
        }
        Log.info ("Config read: %s".printf (file_name));
        return true;
    }

    /* Значения пишутся в существующий файл построчно: ключи, не затронутые программой, сохраняются */
    public virtual bool save () {
        string buf;
        try {
            FileUtils.get_contents (file_name, out buf);
        } catch (GLib.Error e) {
            Log.warning ("Config file access error, a new file (%s) will be created".printf (file_name));
            buf = "";
        }
        var keep = buf.length;
        while (keep > 0 && buf[keep - 1] == '\n') {
            keep--;
        }
        buf = keep > 0 ? buf.substring (0, keep) + "\n" : "";
        try {
            foreach (var key in order) {
                var value = map[key];
                string res = "";
                if (value.is_none ()) {
                    Log.debug ("Config value '%s' will be removed".printf (key));
                } else {
                    var parts = new string[] {};
                    foreach (var item in new CVal (value).flat ()) {
                        parts += encode (item);
                    }
                    res = key + delimiter + string.joinv (", ", parts) + "\n";
                    Log.debug ("Config value to save: %s".printf (res.substring (0, res.length - 1)));
                }
                var re = new GLib.Regex ("^[ \t]*\"?" + GLib.Regex.escape_string (key) + "\"?[ \t]*" +
                                         GLib.Regex.escape_string (delimiter) + ".+\n",
                                         GLib.RegexCompileFlags.MULTILINE);
                MatchInfo mi;
                if (re.match (buf, 0, out mi)) {
                    buf = re.replace_literal (buf, -1, 0, res);
                } else if (res != "") {
                    buf += res;
                }
            }
        } catch (GLib.RegexError e) {
            Log.error ("Config save error: %s".printf (e.message));
            return false;
        }
        try {
            FileUtils.set_contents (file_name, buf);
        } catch (GLib.Error e) {
            Log.error ("Config file write error: %s".printf (file_name));
            return false;
        }
        Log.info ("Config written: %s".printf (file_name));
        changed = false;
        return true;
    }
}

}
