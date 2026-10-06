/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
//! `CATransform3D`. Layers only have 2D transforms here, so only the affine
//! part of one is used.

use crate::abi::{impl_GuestRet_for_large_struct, GuestArg};
use crate::dyld::{export_c_func, FunctionExports};
use crate::frameworks::core_graphics::cg_affine_transform::CGAffineTransform;
use crate::frameworks::core_graphics::CGFloat;
use crate::mem::SafeRead;
use crate::Environment;

#[derive(Copy, Clone, Debug, PartialEq)]
#[repr(C, packed)]
pub struct CATransform3D {
    pub m: [CGFloat; 16],
}
unsafe impl SafeRead for CATransform3D {}
impl GuestArg for CATransform3D {
    const REG_COUNT: usize = 16;

    fn from_regs(regs: &[u32]) -> Self {
        CATransform3D {
            m: std::array::from_fn(|i| GuestArg::from_regs(&regs[i..i + 1])),
        }
    }
    fn to_regs(self, regs: &mut [u32]) {
        let m = self.m;
        for (i, value) in m.into_iter().enumerate() {
            value.to_regs(&mut regs[i..i + 1]);
        }
    }
}
impl_GuestRet_for_large_struct!(CATransform3D);

impl From<CGAffineTransform> for CATransform3D {
    fn from(t: CGAffineTransform) -> Self {
        #[rustfmt::skip]
        let m = [
            t.a,  t.b,  0.0, 0.0,
            t.c,  t.d,  0.0, 0.0,
            0.0,  0.0,  1.0, 0.0,
            t.tx, t.ty, 0.0, 1.0,
        ];
        CATransform3D { m }
    }
}

impl CATransform3D {
    pub fn is_affine(&self) -> bool {
        let m = self.m;
        m[2] == 0.0
            && m[3] == 0.0
            && m[6] == 0.0
            && m[7] == 0.0
            && m[8] == 0.0
            && m[9] == 0.0
            && m[10] == 1.0
            && m[11] == 0.0
            && m[14] == 0.0
            && m[15] == 1.0
    }

    pub fn affine_part(&self) -> CGAffineTransform {
        let m = self.m;
        CGAffineTransform {
            a: m[0],
            b: m[1],
            c: m[4],
            d: m[5],
            tx: m[12],
            ty: m[13],
        }
    }
}

fn CATransform3DMakeAffineTransform(_env: &mut Environment, t: CGAffineTransform) -> CATransform3D {
    t.into()
}

fn CATransform3DIsAffine(_env: &mut Environment, t: CATransform3D) -> bool {
    t.is_affine()
}

fn CATransform3DGetAffineTransform(_env: &mut Environment, t: CATransform3D) -> CGAffineTransform {
    t.affine_part()
}

pub const FUNCTIONS: FunctionExports = &[
    export_c_func!(CATransform3DMakeAffineTransform(_)),
    export_c_func!(CATransform3DIsAffine(_)),
    export_c_func!(CATransform3DGetAffineTransform(_)),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn affine_round_trip() {
        let affine = CGAffineTransform {
            a: 0.5,
            b: -0.25,
            c: 0.25,
            d: 0.5,
            tx: 10.0,
            ty: 20.0,
        };
        let transform = CATransform3D::from(affine);
        assert!(transform.is_affine());
        assert_eq!(transform.affine_part(), affine);
        let mut perspective = transform;
        perspective.m[11] = -0.002;
        assert!(!perspective.is_affine());
    }
}
