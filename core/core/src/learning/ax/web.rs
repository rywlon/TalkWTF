//! Path B: web content (browsers, Electron apps) does not expose `AXValue`.
//! Its text is addressed with text markers — first the element's whole range,
//! then the string for that range.

use super::{
    cf_to_string, copy_parameterized, AXUIElementRef, CFTypeRef,
    PARAM_STRING_FOR_TEXT_MARKER_RANGE, PARAM_TEXT_MARKER_RANGE_FOR_ELEMENT,
};

pub(super) fn read(element: AXUIElementRef) -> Option<String> {
    // Attempt the read rather than probing first: the probe is another IPC that
    // can fail independently, and a failed probe looks exactly like an
    // unsupported element.
    let range = copy_parameterized(
        element,
        PARAM_TEXT_MARKER_RANGE_FOR_ELEMENT,
        std::ptr::null(),
    )?;

    string_for_range(element, range.raw()).filter(|text| !text.is_empty())
}

fn string_for_range(element: AXUIElementRef, range: CFTypeRef) -> Option<String> {
    let value = copy_parameterized(element, PARAM_STRING_FOR_TEXT_MARKER_RANGE, range)?;
    cf_to_string(value.raw())
}
