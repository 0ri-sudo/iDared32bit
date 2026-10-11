/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Parts of this file are derived from SDL 2's Android project template, which
 * has a different license. Please see vendor/SDL/LICENSE.txt for details.
 */
package org.alexmartin.idared32bit;

import android.content.BroadcastReceiver;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;

import org.libsdl.app.SDLActivity;

/**
 * A wrapper class over SDLActivity
 */

public class MainActivity extends SDLActivity {
    @Override
    protected String[] getLibraries() {
        return new String[]{
            "SDL2",
            "touchHLE"
        };
    }

    /**
     * SDL's HIDDeviceManager registers a receiver for its own USB permission
     * broadcast without saying whether other apps may send to it. Since
     * Android 14, for apps targeting it, that throws, and the app would crash
     * at launch. This SDL version predates SDL's own fix, so this does it.
     */
    @Override
    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter) {
        if (Build.VERSION.SDK_INT >= 33) {
            // USB broadcasts come from the system, so it must be exported.
            return super.registerReceiver(receiver, filter, RECEIVER_EXPORTED);
        }
        return super.registerReceiver(receiver, filter);
    }
}
