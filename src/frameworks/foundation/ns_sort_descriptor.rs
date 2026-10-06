/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
//! `NSSortDescriptor`.

use super::NSComparisonResult;
use crate::objc::{
    autorelease, id, msg, msg_class, nil, objc_classes, release, ClassExports, HostObject,
    NSZonePtr,
};

struct NSSortDescriptorHostObject {
    /// `NSString*`, or nil to compare the objects themselves.
    key: id,
    ascending: bool,
}
impl HostObject for NSSortDescriptorHostObject {}

pub const CLASSES: ClassExports = objc_classes! {

(env, this, _cmd);

@implementation NSSortDescriptor: NSObject

+ (id)allocWithZone:(NSZonePtr)_zone {
    let host_object = Box::new(NSSortDescriptorHostObject { key: nil, ascending: true });
    env.objc.alloc_object(this, host_object, &mut env.mem)
}

+ (id)sortDescriptorWithKey:(id)key // NSString*
                  ascending:(bool)ascending {
    let new: id = msg_class![env; NSSortDescriptor alloc];
    let new: id = msg![env; new initWithKey:key ascending:ascending];
    autorelease(env, new)
}

- (id)initWithKey:(id)key // NSString*
        ascending:(bool)ascending {
    let key: id = msg![env; key copy];
    *env.objc.borrow_mut(this) = NSSortDescriptorHostObject { key, ascending };
    this
}

- (id)key {
    env.objc.borrow::<NSSortDescriptorHostObject>(this).key
}

- (bool)ascending {
    env.objc.borrow::<NSSortDescriptorHostObject>(this).ascending
}

- (NSComparisonResult)compareObject:(id)a toObject:(id)b {
    let &NSSortDescriptorHostObject { key, ascending } = env.objc.borrow(this);
    let (a, b): (id, id) = if key == nil {
        (a, b)
    } else {
        (msg![env; a valueForKey:key], msg![env; b valueForKey:key])
    };
    let res: NSComparisonResult = msg![env; a compare:b];
    if ascending { res } else { -res }
}

- (())dealloc {
    let key = env.objc.borrow::<NSSortDescriptorHostObject>(this).key;
    release(env, key);
    env.objc.dealloc_object(this, &mut env.mem)
}

@end

};
