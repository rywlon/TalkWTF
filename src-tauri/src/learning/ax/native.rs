//! Path A: native AppKit controls expose their text as the plain `AXValue`
//! attribute.

use super::{copy_string, AXUIElementRef, ATTR_VALUE};

pub(super) fn read(element: AXUIElementRef) -> Option<String> {
    // Just attempt the read. Probing the attribute list first costs an extra IPC
    // and, worse, that probe can fail on its own — which we would misread as
    // "this element is unsupported" even though AXValue would have answered.
    copy_string(element, ATTR_VALUE).filter(|text| !text.is_empty())
}
