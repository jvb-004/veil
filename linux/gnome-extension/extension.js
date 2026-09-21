// The overlay lives inside GNOME Shell rather than in a window of its own.
//
// This is not a workaround, it is the correct architecture on GNOME. Wayland
// has no layer-shell on Mutter, so a normal GTK window cannot reliably sit
// above a fullscreen Zoom, and anything that can will fight the focus stack.
// A shell widget is drawn by the compositor itself: always on top, never
// focusable, absent from the window switcher and from Mission Control.
//
// It knows nothing about audio or models. It renders what the daemon says.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const IFACE = `
<node>
  <interface name="dev.veil.Daemon1">
    <method name="Ping"><arg type="s" direction="out"/></method>
    <signal name="Answer">
      <arg type="s" name="question"/>
      <arg type="s" name="body"/>
      <arg type="b" name="speculative"/>
    </signal>
    <signal name="Status"><arg type="s" name="text"/></signal>
    <signal name="Sharing">
      <arg type="b" name="sharing"/>
      <arg type="as" name="scope"/>
    </signal>
  </interface>
</node>`;

const Proxy = Gio.DBusProxy.makeProxyWrapper(IFACE);

export default class VeilExtension extends Extension {
    enable() {
        this._hiddenByShare = false;

        this._box = new St.BoxLayout({
            style_class: 'veil-overlay',
            vertical: true,
            reactive: false,
            can_focus: false,
            track_hover: false,
        });

        this._question = new St.Label({style_class: 'veil-question', text: 'veil'});
        this._question.clutter_text.line_wrap = true;
        this._body = new St.Label({style_class: 'veil-body', text: ''});
        this._body.clutter_text.line_wrap = true;
        this._status = new St.Label({style_class: 'veil-status', text: 'waiting for daemon'});

        this._box.add_child(this._question);
        this._box.add_child(this._body);
        this._box.add_child(this._status);

        // uiGroup is above every application window, including fullscreen ones.
        Main.layoutManager.uiGroup.add_child(this._box);
        this._reposition();
        this._monitorsId = Main.layoutManager.connect('monitors-changed',
            () => this._reposition());

        this._connect();
    }

    // Top centre, under the notch or the camera. Reading from there keeps the
    // user's eyes closest to the lens, which is the part no API can fix.
    _reposition() {
        const work = Main.layoutManager.primaryMonitor;
        if (!work)
            return;
        this._box.set_width(Math.min(560, Math.floor(work.width * 0.5)));
        this._box.set_position(
            work.x + Math.floor((work.width - this._box.width) / 2),
            work.y + 12);
    }

    _connect() {
        try {
            this._proxy = new Proxy(Gio.DBus.session, 'dev.veil.Daemon', '/dev/veil/Daemon');
        } catch (e) {
            this._status.set_text('daemon not running');
            this._retry();
            return;
        }

        this._answerId = this._proxy.connectSignal('Answer', (_p, _s, [question, body, speculative]) => {
            this._question.set_text(question);
            this._body.set_text(body);
            this._box.set_style_class_name(
                speculative ? 'veil-overlay veil-speculative' : 'veil-overlay');
            this._reposition();
        });

        this._statusId = this._proxy.connectSignal('Status', (_p, _s, [text]) => {
            this._status.set_text(text);
        });

        // The whole point. The daemon sees the PipeWire graph, we react to it.
        this._sharingId = this._proxy.connectSignal('Sharing', (_p, _s, [sharing, scope]) => {
            if (sharing) {
                this._hiddenByShare = true;
                this._box.hide();
                log(`veil: screen capture active (${scope.join(', ')}), overlay hidden`);
            } else if (this._hiddenByShare) {
                this._hiddenByShare = false;
                this._box.show();
            }
        });

        this._proxy.PingRemote((result, error) => {
            this._status.set_text(error ? 'daemon not running' : `daemon ${result[0]}`);
        });
    }

    _retry() {
        this._retryId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 3, () => {
            this._retryId = null;
            this._connect();
            return GLib.SOURCE_REMOVE;
        });
    }

    disable() {
        if (this._retryId) {
            GLib.source_remove(this._retryId);
            this._retryId = null;
        }
        if (this._monitorsId) {
            Main.layoutManager.disconnect(this._monitorsId);
            this._monitorsId = null;
        }
        for (const id of ['_answerId', '_statusId', '_sharingId']) {
            if (this[id] && this._proxy) {
                this._proxy.disconnectSignal(this[id]);
                this[id] = null;
            }
        }
        this._proxy = null;
        this._box?.destroy();
        this._box = null;
    }
}
