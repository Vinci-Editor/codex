use std::ffi::CStr;
use std::os::raw::c_char;
use std::ptr;
use std::slice;

/// Heap-owned byte buffer returned across the C ABI.
///
/// The buffer is not null-terminated. Swift callers must copy `len` bytes and
/// then call `codex_mobile_buffer_free`.
#[repr(C)]
pub struct CodexMobileBuffer {
    pub ptr: *mut u8,
    pub len: usize,
}

impl CodexMobileBuffer {
    fn empty() -> Self {
        Self {
            ptr: ptr::null_mut(),
            len: 0,
        }
    }

    fn from_string(value: String) -> Self {
        let mut bytes = value.into_bytes().into_boxed_slice();
        let buffer = Self {
            ptr: bytes.as_mut_ptr(),
            len: bytes.len(),
        };
        let _ = Box::into_raw(bytes);
        buffer
    }
}

fn ok(value: String) -> CodexMobileBuffer {
    CodexMobileBuffer::from_string(value)
}

fn err(message: impl ToString) -> CodexMobileBuffer {
    CodexMobileBuffer::from_string(
        serde_json::json!({
            "ok": false,
            "error": message.to_string(),
        })
        .to_string(),
    )
}

fn read_c_string(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("input pointer is null".to_string());
    }
    let c_str = unsafe { CStr::from_ptr(ptr) };
    c_str
        .to_str()
        .map(str::to_string)
        .map_err(|error| format!("input is not utf-8: {error}"))
}

fn call_json(
    input: *const c_char,
    action: impl FnOnce(&str) -> Result<String, String>,
) -> CodexMobileBuffer {
    match read_c_string(input).and_then(|input| action(&input)) {
        Ok(value) => ok(value),
        Err(error) => err(error),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_buffer_free(buffer: CodexMobileBuffer) {
    if buffer.ptr.is_null() || buffer.len == 0 {
        return;
    }
    unsafe {
        let _ = Box::from_raw(ptr::slice_from_raw_parts_mut(buffer.ptr, buffer.len));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_core_version_json() -> CodexMobileBuffer {
    ok(crate::version_json())
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_provider_defaults_json() -> CodexMobileBuffer {
    ok(crate::provider_defaults_json())
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_builtin_tools_json() -> CodexMobileBuffer {
    ok(crate::builtin_tools_json())
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_build_responses_request_json(
    input: *const c_char,
) -> CodexMobileBuffer {
    call_json(input, |input| {
        crate::build_responses_request_json(input).map_err(|error| error.to_string())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_parse_sse_event_json(input: *const c_char) -> CodexMobileBuffer {
    call_json(input, |input| {
        crate::parse_sse_event_json(input).map_err(|error| error.to_string())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_tool_output_json(input: *const c_char) -> CodexMobileBuffer {
    call_json(input, |input| {
        crate::tool_output_json(input).map_err(|error| error.to_string())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_emulate_shell_json(input: *const c_char) -> CodexMobileBuffer {
    call_json(input, |input| {
        crate::emulate_shell_json(input).map_err(|error| error.to_string())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_apply_patch_json(input: *const c_char) -> CodexMobileBuffer {
    call_json(input, |input| {
        crate::apply_patch_json(input).map_err(|error| error.to_string())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_device_code_request_json(input: *const c_char) -> CodexMobileBuffer {
    call_json(input, |input| {
        crate::device_code_request_json(input).map_err(|error| error.to_string())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_refresh_token_request_json(
    input: *const c_char,
) -> CodexMobileBuffer {
    call_json(input, |input| {
        crate::refresh_token_request_json(input).map_err(|error| error.to_string())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_authorization_url_json(input: *const c_char) -> CodexMobileBuffer {
    call_json(input, |input| {
        crate::authorization_url_json(input).map_err(|error| error.to_string())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_authorization_code_token_request_json(
    input: *const c_char,
) -> CodexMobileBuffer {
    call_json(input, |input| {
        crate::authorization_code_token_request_json(input).map_err(|error| error.to_string())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_parse_chatgpt_token_claims_json(
    input: *const c_char,
) -> CodexMobileBuffer {
    call_json(input, |input| {
        crate::parse_chatgpt_token_claims_json(input).map_err(|error| error.to_string())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_buffer_empty() -> CodexMobileBuffer {
    CodexMobileBuffer::empty()
}

#[allow(dead_code)]
pub(crate) fn buffer_bytes(buffer: &CodexMobileBuffer) -> &[u8] {
    if buffer.ptr.is_null() || buffer.len == 0 {
        return &[];
    }
    unsafe { slice::from_raw_parts(buffer.ptr, buffer.len) }
}
