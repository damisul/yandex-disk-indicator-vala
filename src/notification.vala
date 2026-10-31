/* Экранные уведомления: интерфейс freedesktop.org Notifications вызывается напрямую
   через D-Bus, поэтому отдельная библиотека уведомлений не требуется. */

namespace YD {

public class Notification : GLib.Object {

    private const string BUS_NAME = "org.freedesktop.Notifications";
    private const string OBJ_PATH = "/org/freedesktop/Notifications";

    private string title;
    private uint32 last_id = 0;

    public Notification (string title) { this.title = title; }

    public void send (string message) {
        Log.debug ("Message: %s | %s".printf (title, message));
        var actions = new GLib.Variant.array (new GLib.VariantType ("(ss)"), new GLib.Variant[] {});
        var hints = new GLib.Variant.array (new GLib.VariantType ("{sv}"), new GLib.Variant[] {});
        var params = new GLib.Variant.tuple ({
            new GLib.Variant.string (APPNAME),
            new GLib.Variant.uint32 (last_id),
            new GLib.Variant.string (App.logo_path),
            actions,
            hints,
            new GLib.Variant.int32 (0)
        });
        try {
            var conn = GLib.Bus.get_sync (GLib.BusType.SESSION);
            var reply = conn.call_sync (BUS_NAME, OBJ_PATH, BUS_NAME, "Notify", params,
                                       new GLib.VariantType ("(u)"), GLib.DBusCallFlags.NONE, -1, null);
            last_id = reply.get_child_value (0).get_uint32 ();
        } catch (GLib.Error e) {
            Log.error ("Message engine failure");
        }
    }
}

}
