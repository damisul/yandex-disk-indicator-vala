/* Диалог настроек индикатора и демонов, плюс диалог списка исключаемых каталогов. */

namespace YD {

public class ExcludeDirs : Gtk.Dialog {

    private unowned DConfig dconfig;
    private string[] dirset = {};
    private Gtk.ListStore ex_list;

    public ExcludeDirs (Gtk.Window? parent, DConfig dconfig) {
        this.dconfig = dconfig;
        set_title (_("Folders that are excluded from synchronization"));
        set_transient_for (parent);
        set_modal (true);
        set_icon (Gui.logo);
        set_size_request (400, 300);

        var add_button_widget = (Gtk.Button) add_button (_("Add catalogue"), Gtk.ResponseType.APPLY);
        add_button_widget.clicked.connect (() => { add_folder (parent); });
        var remove_button_widget = (Gtk.Button) add_button (_("Remove selected"), Gtk.ResponseType.REJECT);
        remove_button_widget.clicked.connect (delete_selected);
        var close_button_widget = (Gtk.Button) add_button (_("Close"), Gtk.ResponseType.CLOSE);
        close_button_widget.clicked.connect (exit_from_dialog);

        ex_list = new Gtk.ListStore (2, typeof (bool), typeof (string));
        var view = new Gtk.TreeView.with_model (ex_list);
        var render = new Gtk.CellRendererToggle ();
        render.toggled.connect (line_toggled);
        var check_column = new Gtk.TreeViewColumn ();
        check_column.add_attribute (render, "active", 0);
        check_column.set_title (" ");
        check_column.pack_start (render, true);
        view.append_column (check_column);
        var text_column = new Gtk.TreeViewColumn ();
        var text_render = new Gtk.CellRendererText ();
        text_column.add_attribute (text_render, "text", 1);
        text_column.set_title (_("Path"));
        text_column.pack_start (text_render, true);
        view.append_column (text_column);

        var scroll = new Gtk.ScrolledWindow (null, null);
        scroll.add (view);
        get_content_area ().pack_start (scroll, true, true, 6);

        foreach (var value in dconfig.get_strings ("exclude-dirs")) {
            dirset += value;
            Gtk.TreeIter iter;
            ex_list.append (out iter);
            ex_list.set (iter, 0, false, 1, value);
        }
        show_all ();
    }

    /* Сохраняет список в свойство "exclude-dirs" конфигурации демона */
    private void exit_from_dialog () {
        if (dconfig.changed) {
            var list = new CVal ();
            foreach (var value in dirset) {
                list.add (Val.str_val (value));
            }
            dconfig.set_val ("exclude-dirs", list.get_val ());
        }
        destroy ();
    }

    private void line_toggled (string path) {
        Gtk.TreeIter iter;
        if (!ex_list.get_iter (out iter, new Gtk.TreePath.from_string (path))) {
            return;
        }
        bool active;
        ex_list.get (iter, 0, out active);
        ex_list.set (iter, 0, !active);
    }

    private void delete_selected () {
        Gtk.TreeIter iter;
        if (!ex_list.get_iter_first (out iter)) {
            return;
        }
        while (true) {
            bool active;
            string path;
            ex_list.get (iter, 0, out active, 1, out path);
            if (active) {
                dirset = Utils.strv_remove (dirset, path);
                dconfig.changed = true;
                /* remove() оставляет в iter ссылку на следующую строку */
                if (!ex_list.remove (ref iter)) {
                    break;
                }
            } else if (!ex_list.iter_next (ref iter)) {
                break;
            }
        }
    }

    private void add_folder (Gtk.Window? parent) {
        var dialog = new Gtk.FileChooserDialog (_("Select catalogue to add to list"), parent,
                                               Gtk.FileChooserAction.SELECT_FOLDER,
                                               _("Close"), Gtk.ResponseType.CANCEL,
                                               _("Select"), Gtk.ResponseType.ACCEPT);
        dialog.set_default_response (Gtk.ResponseType.CANCEL);
        dialog.set_select_multiple (true);
        var root_dir = dconfig.get_string ("dir", "");
        dialog.set_current_folder (root_dir);
        if (dialog.run () == Gtk.ResponseType.ACCEPT) {
            foreach (var path in dialog.get_filenames ()) {
                if (path.has_prefix (root_dir)) {
                    var relative = Utils.relative_path (path, root_dir);
                    if (!Utils.strv_has (dirset, relative)) {
                        Gtk.TreeIter iter;
                        ex_list.append (out iter);
                        ex_list.set (iter, 0, false, 1, relative);
                        dirset += relative;
                        dconfig.changed = true;
                    }
                }
            }
        }
        dialog.destroy ();
    }
}

public class Preferences : Gtk.Dialog {

    /* Открытые дочерние диалоги держатся здесь, чтобы Vala не освободил их раньше времени */
    private Gtk.Widget[] children = {};

    public Preferences (Gtk.MenuItem trigger) {
        foreach (var i in Indicator.get_all ()) {
            i.menu.preferences_item.set_sensitive (false);
        }
        set_title (_("Yandex.Disk-indicator and Yandex.Disks preferences"));
        set_modal (true);
        set_icon (Gui.logo);
        set_border_width (6);
        add_button (_("Close"), Gtk.ResponseType.CLOSE);

        var pref_notebook = new Gtk.Notebook ();
        get_content_area ().add (pref_notebook);

        /* --- Вкладка настроек индикатора --- */
        var preferences_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 5);
        add_app_check (preferences_box, "autostart",
                       _("Start Yandex.Disk indicator when you start your computer"));
        add_app_check (preferences_box, "notifications", _("Show on-screen notifications"));
        add_app_check (preferences_box, "theme", _("Prefer light icon theme"));
        add_app_check (preferences_box, "fmextensions", _("Activate file manager extensions"));
        pref_notebook.append_page (preferences_box, new Gtk.Label (_("Indicator settings")));

        /* --- По вкладке на каждый демон --- */
        foreach (var i in Indicator.get_all ()) {
            var options_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 5);

            var cb_start_on_start = new Gtk.CheckButton.with_label (
                _("Start Yandex.Disk daemon %swhen indicator is starting").printf (i.ID));
            cb_start_on_start.set_tooltip_text (_("When daemon was not started before."));
            cb_start_on_start.set_active (i.config.get_bool ("startonstartofindicator", true));
            cb_start_on_start.toggled.connect (() => {
                daemon_toggle (i.config, "startonstartofindicator", cb_start_on_start.get_active ());
            });
            options_box.pack_start (cb_start_on_start, false, false, 0);

            var cb_stop_on_exit = new Gtk.CheckButton.with_label (
                _("Stop Yandex.Disk daemon %son closing of indicator").printf (i.ID));
            cb_stop_on_exit.set_active (i.config.get_bool ("stoponexitfromindicator", false));
            cb_stop_on_exit.toggled.connect (() => {
                daemon_toggle (i.config, "stoponexitfromindicator", cb_stop_on_exit.get_active ());
            });
            options_box.pack_start (cb_stop_on_exit, false, false, 0);

            var frame = new Gtk.Frame (null);
            frame.set_label (_("NOTE! You have to reload daemon %sto activate following settings")
                             .printf (i.ID));
            frame.set_border_width (6);
            options_box.pack_start (frame, false, false, 0);

            var framed_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 5);
            framed_box.set_homogeneous (true);
            frame.add (framed_box);

            var cb_ro = new Gtk.CheckButton.with_label (
                _("Read-Only: Do not upload locally changed files to Yandex.Disk"));
            cb_ro.set_tooltip_text (_("Locally changed files will be renamed if a newer version of this " +
                                      "file appear in Yandex.Disk."));
            cb_ro.set_active (i.config.get_bool ("read-only", false));
            framed_box.pack_start (cb_ro, false, false, 0);

            var overwrite = new Gtk.CheckButton.with_label (
                _("Overwrite locally changed files by files" +
                  " from Yandex.Disk (in read-only mode)"));
            overwrite.set_tooltip_text (_("Locally changed files will be overwritten if a newer " +
                                          "version of this file appear in Yandex.Disk."));
            overwrite.set_active (i.config.get_bool ("overwrite", false));
            overwrite.set_sensitive (i.config.get_bool ("read-only", false));
            cb_ro.toggled.connect (() => {
                overwrite.set_sensitive (cb_ro.get_active ());
                daemon_toggle (i.config, "read-only", cb_ro.get_active ());
            });
            overwrite.toggled.connect (() => {
                daemon_toggle (i.config, "overwrite", overwrite.get_active ());
            });
            framed_box.pack_start (overwrite, false, false, 0);

            var ex_list_button = new Gtk.Button.with_label (_("Excluded folders List"));
            ex_list_button.set_tooltip_text (_("Folders in the list will not be synchronized."));
            ex_list_button.clicked.connect (() => {
                var dialog = new ExcludeDirs (this, i.config);
                children += dialog;
            });
            framed_box.pack_start (ex_list_button, false, false, 0);

            pref_notebook.append_page (options_box,
                                       new Gtk.Label (_("Daemon %soptions").printf (i.ID)));
        }

        set_resizable (false);
        show_all ();
        run ();

        if (App.conf.changed) {
            App.conf.save ();
        }
        foreach (var i in Indicator.get_all ()) {
            if (i.config.changed) {
                i.config.save ();
            }
            i.menu.preferences_item.set_sensitive (true);
        }
        destroy ();
    }

    private void add_app_check (Gtk.Box box, string key, string label) {
        var cb = new Gtk.CheckButton.with_label (label);
        cb.set_active (App.conf.get_bool (key));
        cb.toggled.connect (() => { on_app_toggled (cb, key); });
        box.pack_start (cb, false, false, 0);
    }

    private void daemon_toggle (DConfig config, string key, bool state) {
        Log.debug ("Togged: %s  val: %s".printf (key, state.to_string ()));
        config.set_bool (key, state);
        config.changed = true;
    }

    private void on_app_toggled (Gtk.CheckButton button, string key) {
        var toggle_state = button.get_active ();
        Log.debug ("Togged: %s  val: %s".printf (key, toggle_state.to_string ()));
        if (key == "theme") {
            foreach (var i in Indicator.get_all ()) {
                i.set_icon_theme (toggle_state);
                i.update_icon (i.current_status);
            }
        } else if (key == "autostart") {
            if (toggle_state) {
                Utils.copy_file (App.autostart_src, App.autostart_dst);
            } else {
                Utils.delete_file (App.autostart_dst);
            }
        } else if (key == "fmextensions") {
            /* Неудачная активация откатывает состояние кнопки; inconsistent-флаг
               помечает второй (отменяющий) вызов toggled */
            if (!button.get_inconsistent ()) {
                if (!Utils.activate_actions (toggle_state, App.inst_path)) {
                    button.set_inconsistent (true);
                    button.set_active (!toggle_state);
                    return;
                }
            } else {
                button.set_inconsistent (false);
            }
        }
        App.conf.set_bool (key, button.get_active ());
        App.conf.changed = true;
    }
}

}
