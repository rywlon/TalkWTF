//! Accessibility API access: FFI, the focused element, exclusions, and the two
//! ways to read its text.
//!
//! Attribute names are built from their stable public strings instead of linking
//! the `kAX*` constants: those are Carbon-era enum members whose linkage varies
//! across SDKs, and the names returned by `AXUIElementCopyAttributeNames` are
//! exactly these short strings (which is also how Typeless's helper works — its
//! dylib imports no `kAX*` symbol at all).

mod native;
mod web;

use std::ffi::c_void;

use log::debug;
use objc2::rc::Retained;
use objc2_foundation::NSString;

pub(crate) type AXUIElementRef = *mut c_void;
pub(crate) type CFTypeRef = *const c_void;
type CFArrayRef = *const c_void;
type CFIndex = isize;
type AXError = i32;
type Boolean = u8;

const SUCCESS: AXError = 0;
/// AX calls block while the target app is busy. Without this a stuck app would
/// pile up our 700ms polls.
const MESSAGING_TIMEOUT_SECONDS: f32 = 0.5;

pub(crate) const ATTR_ROLE: &str = "AXRole";
const ATTR_SUBROLE: &str = "AXSubrole";
pub(crate) const ATTR_VALUE: &str = "AXValue";
const ATTR_CHILDREN: &str = "AXChildren";
const ATTR_PARENT: &str = "AXParent";
pub(crate) const PARAM_TEXT_MARKER_RANGE_FOR_ELEMENT: &str = "AXTextMarkerRangeForUIElement";
pub(crate) const PARAM_STRING_FOR_TEXT_MARKER_RANGE: &str = "AXStringForTextMarkerRange";

const SUBROLE_SECURE_TEXT_FIELD: &str = "AXSecureTextField";
/// Apps whose text fields are never worth reading.
const BLOCKED_BUNDLE_IDS: [&str; 6] = [
    "com.1password.1password",
    "com.agilebits.onepassword7",
    "com.bitwarden.desktop",
    "com.apple.keychainaccess",
    "com.lastpass.LastPass",
    "com.dashlane.Dashlane",
];
/// How far up we look for a text-marker-capable ancestor (web views nest a few
/// levels above the editable region).
const MAX_ANCESTOR_HOPS: usize = 6;
/// Cap on children inspected when the focused element itself is not readable.
const MAX_CHILDREN: usize = 40;

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXUIElementCreateSystemWide() -> AXUIElementRef;
    fn AXUIElementCopyAttributeValue(
        element: AXUIElementRef,
        attribute: CFTypeRef,
        value: *mut CFTypeRef,
    ) -> AXError;
    fn AXUIElementCopyAttributeNames(element: AXUIElementRef, names: *mut CFArrayRef) -> AXError;
    fn AXUIElementCopyParameterizedAttributeValue(
        element: AXUIElementRef,
        attribute: CFTypeRef,
        parameter: CFTypeRef,
        result: *mut CFTypeRef,
    ) -> AXError;
    fn AXUIElementCopyParameterizedAttributeNames(
        element: AXUIElementRef,
        names: *mut CFArrayRef,
    ) -> AXError;
    fn AXUIElementSetMessagingTimeout(element: AXUIElementRef, timeout: f32) -> AXError;
    fn AXValueGetValue(value: CFTypeRef, the_type: u32, value_ptr: *mut c_void) -> Boolean;
    fn AXValueGetTypeID() -> usize;
    fn AXIsProcessTrusted() -> Boolean;
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRelease(value: CFTypeRef);
    fn CFGetTypeID(value: CFTypeRef) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFArrayGetCount(array: CFArrayRef) -> CFIndex;
    fn CFArrayGetValueAtIndex(array: CFArrayRef, index: CFIndex) -> *const c_void;
}

/// Owned AX element. CFType objects are reference counted, so every value we
/// copy has to be released exactly once — this makes that automatic.
pub(crate) struct AxElement(AXUIElementRef);

impl AxElement {
    fn new(raw: AXUIElementRef) -> Option<Self> {
        (!raw.is_null()).then_some(Self(raw))
    }

    pub(crate) fn raw(&self) -> AXUIElementRef {
        self.0
    }
}

impl Drop for AxElement {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0 as CFTypeRef) }
    }
}

/// Owned CF value (string, array, range, ...).
pub(crate) struct CfOwned(pub(crate) CFTypeRef);

impl CfOwned {
    pub(crate) fn new(raw: CFTypeRef) -> Option<Self> {
        (!raw.is_null()).then_some(Self(raw))
    }

    pub(crate) fn raw(&self) -> CFTypeRef {
        self.0
    }
}

impl Drop for CfOwned {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0) }
    }
}

/// Where a read came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextSource {
    /// Plain `AXValue` attribute — native AppKit controls.
    Native,
    /// Text markers — web content inside a browser or Electron app.
    Web,
}

pub struct FocusedText {
    pub text: String,
    pub source: TextSource,
    /// Which step of the search produced this text, for diagnostics.
    pub strategy: &'static str,
}

/// Whether this process may use the Accessibility API at all.
pub fn is_trusted() -> bool {
    unsafe { AXIsProcessTrusted() != 0 }
}

/// Bundle id of the frontmost application: used to notice that the user moved on
/// and to skip password managers.
pub fn frontmost_bundle_id() -> Option<String> {
    let workspace = objc2_app_kit::NSWorkspace::sharedWorkspace();
    let application = workspace.frontmostApplication()?;
    Some(application.bundleIdentifier()?.to_string())
}

pub fn is_blocked_app(bundle_id: Option<&str>) -> bool {
    bundle_id.is_some_and(|id| BLOCKED_BUNDLE_IDS.contains(&id))
}

/// Read the text of whatever text field currently has focus, trying both
/// mechanisms. `None` means "nothing readable here" — never an error.
pub fn read_focused_text(verbose: bool) -> Option<FocusedText> {
    if !is_trusted() {
        debug!("Accessibility permission is not granted");
        return None;
    }
    if crate::secure_input::is_enabled_now() {
        return None;
    }
    if is_blocked_app(frontmost_bundle_id().as_deref()) {
        return None;
    }

    let Some(system_wide) = (unsafe { AxElement::new(AXUIElementCreateSystemWide()) }) else {
        debug!("Could not create the system-wide accessibility element");
        return None;
    };
    set_timeout(system_wide.raw());

    let Some(focused) = copy_element(system_wide.raw(), "AXFocusedUIElement") else {
        debug!("No focused accessibility element");
        return None;
    };
    set_timeout(focused.raw());

    let result = read_element(focused.raw())
        .or_else(|| read_ancestor(focused.raw()))
        .or_else(|| read_child(focused.raw()));

    if result.is_none() && verbose {
        debug!(
            "The focused element has no readable text right now ({})",
            describe_capabilities(focused.raw())
        );
    }

    result
}

/// The two mechanisms, in order: plain value first (cheap, native controls),
/// then text markers (web content).
fn read_element(element: AXUIElementRef) -> Option<FocusedText> {
    if is_secure_text_field(element) {
        return None;
    }

    if let Some(text) = native::read(element) {
        return Some(FocusedText {
            text,
            source: TextSource::Native,
            strategy: "focused element, AXValue",
        });
    }

    web::read(element).map(|text| FocusedText {
        text,
        source: TextSource::Web,
        strategy: "focused element, text markers",
    })
}

/// Web views often put focus on a container rather than the editable region, so
/// walk up looking for something text-marker capable.
fn read_ancestor(element: AXUIElementRef) -> Option<FocusedText> {
    let mut owned: Option<AxElement> = None;

    for _ in 0..MAX_ANCESTOR_HOPS {
        let current = owned.as_ref().map_or(element, |hop| hop.raw());
        let parent = copy_element(current, ATTR_PARENT)?;
        set_timeout(parent.raw());

        if let Some(text) = web::read(parent.raw()) {
            return Some(FocusedText {
                text,
                source: TextSource::Web,
                strategy: "ancestor, text markers",
            });
        }

        // Keeps the new hop alive; drops (releases) the previous one.
        owned = Some(parent);
    }

    None
}

/// Last resort: a direct child that advertises a readable value.
fn read_child(element: AXUIElementRef) -> Option<FocusedText> {
    let children = copy_array(element, ATTR_CHILDREN)?;
    let count = unsafe { CFArrayGetCount(children.raw()) }.min(MAX_CHILDREN as CFIndex);

    for index in 0..count {
        let child = unsafe { CFArrayGetValueAtIndex(children.raw(), index) } as AXUIElementRef;
        if child.is_null() {
            continue;
        }
        set_timeout(child);

        if let Some(text) = native::read(child) {
            return Some(FocusedText {
                text,
                source: TextSource::Native,
                strategy: "child element, AXValue",
            });
        }
    }

    None
}

fn is_secure_text_field(element: AXUIElementRef) -> bool {
    copy_string(element, ATTR_SUBROLE).as_deref() == Some(SUBROLE_SECURE_TEXT_FIELD)
}

fn set_timeout(element: AXUIElementRef) {
    unsafe { AXUIElementSetMessagingTimeout(element, MESSAGING_TIMEOUT_SECONDS) };
}

/// Build a CFString from a Rust literal. The returned value must outlive the FFI
/// call that consumes it.
fn attribute(name: &str) -> Retained<NSString> {
    NSString::from_str(name)
}

pub(crate) fn copy_string(element: AXUIElementRef, name: &str) -> Option<String> {
    copy_string_status(element, name).0
}

/// Same read, but the AX error code is kept, so a transient failure (the app is
/// busy, or an input-method composition window owns focus) can be told apart from
/// a genuinely unsupported attribute.
fn copy_string_status(element: AXUIElementRef, name: &str) -> (Option<String>, AXError) {
    let attribute = attribute(name);
    let mut value: CFTypeRef = std::ptr::null();

    let status = unsafe {
        AXUIElementCopyAttributeValue(
            element,
            Retained::as_ptr(&attribute) as CFTypeRef,
            &mut value,
        )
    };
    if status != SUCCESS {
        return (None, status);
    }

    (cfstring_to_string(value), status)
}

fn copy_element(element: AXUIElementRef, name: &str) -> Option<AxElement> {
    let attribute = attribute(name);
    let mut value: CFTypeRef = std::ptr::null();

    let status = unsafe {
        AXUIElementCopyAttributeValue(
            element,
            Retained::as_ptr(&attribute) as CFTypeRef,
            &mut value,
        )
    };
    if status != SUCCESS {
        return None;
    }

    AxElement::new(value as AXUIElementRef)
}

fn copy_array(element: AXUIElementRef, name: &str) -> Option<CfOwned> {
    let attribute = attribute(name);
    let mut value: CFTypeRef = std::ptr::null();

    let status = unsafe {
        AXUIElementCopyAttributeValue(
            element,
            Retained::as_ptr(&attribute) as CFTypeRef,
            &mut value,
        )
    };
    if status != SUCCESS {
        return None;
    }

    CfOwned::new(value)
}

/// Names of the attributes (or parameterized attributes) an element supports.
/// This is how we decide which read path applies instead of guessing from errors.
fn supported_names(element: AXUIElementRef, parameterized: bool) -> Vec<String> {
    let mut names: CFArrayRef = std::ptr::null();
    let status = unsafe {
        if parameterized {
            AXUIElementCopyParameterizedAttributeNames(element, &mut names)
        } else {
            AXUIElementCopyAttributeNames(element, &mut names)
        }
    };

    let Some(names) = CfOwned::new(names as CFTypeRef) else {
        return Vec::new();
    };
    if status != SUCCESS {
        return Vec::new();
    }

    let count = unsafe { CFArrayGetCount(names.raw() as CFArrayRef) };
    let mut collected = Vec::new();
    for index in 0..count {
        let entry =
            unsafe { CFArrayGetValueAtIndex(names.raw() as CFArrayRef, index) } as CFTypeRef;
        if let Some(name) = cfstring_to_string(entry) {
            collected.push(name);
        }
    }
    collected
}

/// What an element offers, for the failure diagnostic. Never used as a gate: a
/// failed probe must not look like an unsupported element.
fn describe_capabilities(element: AXUIElementRef) -> String {
    let attributes = supported_names(element, false);
    let parameterized = supported_names(element, true);
    let (value, value_status) = copy_string_status(element, ATTR_VALUE);

    format!(
        "role {:?}, {} attribute(s) [lists AXValue: {}, AXChildren: {}], \
         {} parameterized [lists string-for-range: {}], AXValue read: {:?} (AXError {})",
        copy_string(element, ATTR_ROLE),
        attributes.len(),
        attributes.iter().any(|name| name == ATTR_VALUE),
        attributes.iter().any(|name| name == ATTR_CHILDREN),
        parameterized.len(),
        parameterized
            .iter()
            .any(|name| name == PARAM_STRING_FOR_TEXT_MARKER_RANGE),
        value.map(|text| text.chars().count()),
        value_status,
    )
}

/// CFString and NSString are toll-free bridged, so a CF value can be read
/// through objc2's NSString and copied into a Rust String.
fn cfstring_to_string(value: CFTypeRef) -> Option<String> {
    if value.is_null() || unsafe { CFGetTypeID(value) != CFStringGetTypeID() } {
        return None;
    }

    let string: &NSString = unsafe { &*(value as *const NSString) };
    Some(string.to_string())
}

/// Read a parameterized attribute, e.g. the string for a text-marker range.
pub(crate) fn copy_parameterized(
    element: AXUIElementRef,
    name: &str,
    parameter: CFTypeRef,
) -> Option<CfOwned> {
    let attribute = attribute(name);
    let mut result: CFTypeRef = std::ptr::null();

    let status = unsafe {
        AXUIElementCopyParameterizedAttributeValue(
            element,
            Retained::as_ptr(&attribute) as CFTypeRef,
            parameter,
            &mut result,
        )
    };
    if status != SUCCESS {
        return None;
    }

    CfOwned::new(result)
}

/// Read a CFString into a Rust String (used by the web path for marker payloads).
pub(crate) fn cf_to_string(value: CFTypeRef) -> Option<String> {
    cfstring_to_string(value)
}

/// `AXValue` type codes for the geometry attributes.
const AX_VALUE_CGPOINT: u32 = 1;
const AX_VALUE_CGSIZE: u32 = 2;

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct CGPoint {
    x: f64,
    y: f64,
}

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct CGSize {
    width: f64,
    height: f64,
}

fn copy_value(element: AXUIElementRef, name: &str) -> Option<CfOwned> {
    let attribute = attribute(name);
    let mut value: CFTypeRef = std::ptr::null();

    let status = unsafe {
        AXUIElementCopyAttributeValue(
            element,
            Retained::as_ptr(&attribute) as CFTypeRef,
            &mut value,
        )
    };
    if status != SUCCESS {
        return None;
    }

    CfOwned::new(value)
}

/// Screen frame `(x, y, width, height)` of the focused element, in the top-left
/// origin coordinate space the overlay window is positioned in. Used to put the
/// "added to dictionary" notice next to the field the user was typing in, the way
/// Typeless does, instead of at a screen edge.
pub fn focused_element_frame() -> Option<(f64, f64, f64, f64)> {
    if !is_trusted() {
        return None;
    }

    let system_wide = unsafe { AxElement::new(AXUIElementCreateSystemWide()) }?;
    let focused = copy_element(system_wide.raw(), "AXFocusedUIElement")?;

    let position = copy_value(focused.raw(), "AXPosition")?;
    let size = copy_value(focused.raw(), "AXSize")?;

    if unsafe { CFGetTypeID(position.raw()) != AXValueGetTypeID() }
        || unsafe { CFGetTypeID(size.raw()) != AXValueGetTypeID() }
    {
        return None;
    }

    let mut point = CGPoint::default();
    let mut extent = CGSize::default();

    let point_ok = unsafe {
        AXValueGetValue(
            position.raw(),
            AX_VALUE_CGPOINT,
            &mut point as *mut CGPoint as *mut c_void,
        ) != 0
    };
    let size_ok = unsafe {
        AXValueGetValue(
            size.raw(),
            AX_VALUE_CGSIZE,
            &mut extent as *mut CGSize as *mut c_void,
        ) != 0
    };

    if !point_ok || !size_ok || extent.width <= 0.0 || extent.height <= 0.0 {
        return None;
    }

    Some((point.x, point.y, extent.width, extent.height))
}

/// One-shot report of what the accessibility layer can see right now. Rendered in
/// the settings UI so this never has to be diagnosed from a log file.
pub fn diagnose() -> Vec<String> {
    let mut lines = Vec::new();

    lines.push(format!("accessibility trusted: {}", is_trusted()));
    lines.push(format!(
        "secure input active: {}",
        crate::secure_input::is_enabled_now()
    ));

    let bundle = frontmost_bundle_id();
    lines.push(format!("frontmost bundle id: {bundle:?}"));
    lines.push(format!(
        "blocked (password manager): {}",
        is_blocked_app(bundle.as_deref())
    ));

    if !is_trusted() {
        return lines;
    }

    let Some(system_wide) = (unsafe { AxElement::new(AXUIElementCreateSystemWide()) }) else {
        lines.push("could not create the system-wide element".to_string());
        return lines;
    };
    set_timeout(system_wide.raw());

    let Some(focused) = copy_element(system_wide.raw(), "AXFocusedUIElement") else {
        lines.push("no focused accessibility element".to_string());
        return lines;
    };
    set_timeout(focused.raw());

    lines.push(format!(
        "focused element: {}",
        describe_capabilities(focused.raw())
    ));

    match read_focused_text(false) {
        Some(read) => {
            lines.push(format!(
                "READ OK via {} ({:?}): {} chars",
                read.strategy,
                read.source,
                read.text.chars().count()
            ));
            let preview: String = read.text.chars().take(120).collect();
            lines.push(format!("text: {preview}"));
        }
        None => lines.push("READ FAILED (nothing readable on this element)".to_string()),
    }

    lines
}
