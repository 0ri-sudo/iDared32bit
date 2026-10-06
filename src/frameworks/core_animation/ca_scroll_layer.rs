/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
//! `CAScrollLayer`. Scrolling moves the origin of the layer's bounds, which
//! moves its sublayers. Only the default scroll mode, both directions, is
//! supported.

use crate::frameworks::core_graphics::{CGPoint, CGRect};
use crate::objc::{id, msg, objc_classes, ClassExports};

pub const CLASSES: ClassExports = objc_classes! {

(env, this, _cmd);

@implementation CAScrollLayer: CALayer

- (())scrollToPoint:(CGPoint)point {
    let mut bounds: CGRect = msg![env; this bounds];
    bounds.origin = point;
    () = msg![env; this setBounds:bounds];
}

- (())scrollToRect:(CGRect)rect {
    // Scroll as little as possible to make the rect visible.
    let bounds: CGRect = msg![env; this bounds];
    let scroll = |start: f32, size: f32, visible_start: f32, visible_size: f32| {
        if start < visible_start {
            start
        } else if start + size > visible_start + visible_size {
            start + size - visible_size
        } else {
            visible_start
        }
    };
    let point = CGPoint {
        x: scroll(rect.origin.x, rect.size.width, bounds.origin.x, bounds.size.width),
        y: scroll(rect.origin.y, rect.size.height, bounds.origin.y, bounds.size.height),
    };
    () = msg![env; this scrollToPoint:point];
}

- (id)scrollMode {
    crate::frameworks::foundation::ns_string::get_static_str(env, "both")
}

- (())setScrollMode:(id)mode { // NSString*
    let mode = crate::frameworks::foundation::ns_string::to_rust_string(env, mode);
    if mode != "both" {
        log!("TODO: [(CAScrollLayer*){:?} setScrollMode:{:?}] (only \"both\" is supported)", this, mode);
    }
}

@end

};
