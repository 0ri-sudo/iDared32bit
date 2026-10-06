/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
//! `NSStream`, `NSInputStream` and `NSOutputStream`. Only streams of files are
//! supported, and there are no run loop events.

use super::{ns_string, NSInteger, NSUInteger};
use crate::libc::posix_io;
use crate::mem::{ConstPtr, ConstVoidPtr, MutVoidPtr};
use crate::objc::{
    autorelease, id, msg, msg_class, nil, objc_classes, release, retain, ClassExports, HostObject,
    NSZonePtr,
};
use crate::Environment;

type NSStreamStatus = NSUInteger;
const NSStreamStatusNotOpen: NSStreamStatus = 0;
const NSStreamStatusOpen: NSStreamStatus = 2;
const NSStreamStatusAtEnd: NSStreamStatus = 5;
const NSStreamStatusClosed: NSStreamStatus = 6;
const NSStreamStatusError: NSStreamStatus = 7;

#[derive(Default)]
struct NSStreamHostObject {
    /// `NSString*` of the file's path.
    path: id,
    /// The flags to `open()` it with.
    open_flags: i32,
    fd: Option<posix_io::FileDescriptor>,
    status: NSStreamStatus,
}
impl HostObject for NSStreamHostObject {}

fn init_with_path(env: &mut Environment, this: id, path: id, open_flags: i32) -> id {
    retain(env, path);
    let host_object = env.objc.borrow_mut::<NSStreamHostObject>(this);
    host_object.path = path;
    host_object.open_flags = open_flags;
    this
}

fn open_fd(env: &mut Environment, this: id) -> Option<posix_io::FileDescriptor> {
    let host_object = env.objc.borrow::<NSStreamHostObject>(this);
    (host_object.status == NSStreamStatusOpen).then_some(host_object.fd?)
}

fn bytes_left(env: &mut Environment, fd: posix_io::FileDescriptor) -> NSUInteger {
    let pos = posix_io::lseek(env, fd, 0, posix_io::SEEK_CUR);
    let end = posix_io::lseek(env, fd, 0, posix_io::SEEK_END);
    posix_io::lseek(env, fd, pos, posix_io::SEEK_SET);
    (end - pos).clamp(0, NSUInteger::MAX.into()) as NSUInteger
}

pub const CLASSES: ClassExports = objc_classes! {

(env, this, _cmd);

@implementation NSStream: NSObject

+ (id)allocWithZone:(NSZonePtr)_zone {
    let host_object = Box::<NSStreamHostObject>::default();
    env.objc.alloc_object(this, host_object, &mut env.mem)
}

- (())open {
    let &NSStreamHostObject { path, open_flags, status, .. } = env.objc.borrow(this);
    if status != NSStreamStatusNotOpen {
        return;
    }
    let path_str: ConstPtr<u8> = msg![env; path UTF8String];
    let fd = posix_io::open_direct(env, path_str, open_flags);
    log_dbg!("[(NSStream*){:?} open] {:?} => fd {}", this, ns_string::to_rust_string(env, path), fd);
    let host_object = env.objc.borrow_mut::<NSStreamHostObject>(this);
    if fd == -1 {
        host_object.status = NSStreamStatusError;
    } else {
        host_object.fd = Some(fd);
        host_object.status = NSStreamStatusOpen;
    }
}

- (())close {
    let host_object = env.objc.borrow_mut::<NSStreamHostObject>(this);
    let fd = host_object.fd.take();
    host_object.status = NSStreamStatusClosed;
    if let Some(fd) = fd {
        posix_io::close(env, fd);
    }
}

- (NSStreamStatus)streamStatus {
    env.objc.borrow::<NSStreamHostObject>(this).status
}

- (id)streamError {
    nil
}

- (())dealloc {
    let host_object = env.objc.borrow_mut::<NSStreamHostObject>(this);
    let (path, fd) = (host_object.path, host_object.fd.take());
    if let Some(fd) = fd {
        posix_io::close(env, fd);
    }
    release(env, path);
    env.objc.dealloc_object(this, &mut env.mem)
}

@end

@implementation NSInputStream: NSStream

+ (id)inputStreamWithFileAtPath:(id)path { // NSString*
    let new: id = msg_class![env; NSInputStream alloc];
    let new: id = msg![env; new initWithFileAtPath:path];
    autorelease(env, new)
}

- (id)initWithFileAtPath:(id)path { // NSString*
    init_with_path(env, this, path, posix_io::O_RDONLY)
}

- (NSInteger)read:(MutVoidPtr)buffer maxLength:(NSUInteger)max_length {
    let Some(fd) = open_fd(env, this) else {
        return if env.objc.borrow::<NSStreamHostObject>(this).status == NSStreamStatusAtEnd {
            0
        } else {
            -1
        };
    };
    // Asking for more than is left is normal for a stream, but read() would
    // warn about it.
    let length = max_length.min(bytes_left(env, fd));
    if length == 0 {
        env.objc.borrow_mut::<NSStreamHostObject>(this).status = NSStreamStatusAtEnd;
        return 0;
    }
    posix_io::read(env, fd, buffer, length)
}

- (bool)hasBytesAvailable {
    open_fd(env, this).is_some_and(|fd| bytes_left(env, fd) > 0)
}

@end

@implementation NSOutputStream: NSStream

+ (id)outputStreamToFileAtPath:(id)path // NSString*
                        append:(bool)append {
    let new: id = msg_class![env; NSOutputStream alloc];
    let new: id = msg![env; new initToFileAtPath:path append:append];
    autorelease(env, new)
}

- (id)initToFileAtPath:(id)path // NSString*
                append:(bool)append {
    let flags = posix_io::O_WRONLY
        | posix_io::O_CREAT
        | if append { posix_io::O_APPEND } else { posix_io::O_TRUNC };
    init_with_path(env, this, path, flags)
}

- (NSInteger)write:(ConstVoidPtr)buffer maxLength:(NSUInteger)max_length {
    match open_fd(env, this) {
        Some(fd) => posix_io::write(env, fd, buffer, max_length),
        None => -1,
    }
}

- (bool)hasSpaceAvailable {
    open_fd(env, this).is_some()
}

@end

};
