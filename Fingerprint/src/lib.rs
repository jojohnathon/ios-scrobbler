mod algorithm;
mod signature_format;

const WINDOW_SAMPLES: usize = algorithm::SAMPLE_RATE_HZ as usize * 12;

#[repr(C)]
pub struct FingerprintBytes {
    pub data: *mut u8,
    pub length: usize,
}

/// # Safety
/// The caller provides a readable array of `sample_count` samples for this call.
#[no_mangle]
pub unsafe extern "C" fn scrobbler_fingerprint(
    samples: *const i16,
    sample_count: usize,
) -> FingerprintBytes {
    if samples.is_null() || sample_count != WINDOW_SAMPLES {
        return FingerprintBytes {
            data: std::ptr::null_mut(),
            length: 0,
        };
    }

    let samples = unsafe { std::slice::from_raw_parts(samples, sample_count) };
    let bytes = algorithm::fingerprint_samples(samples)
        .encode()
        .into_boxed_slice();
    let length = bytes.len();
    let data = Box::into_raw(bytes).cast::<u8>();
    FingerprintBytes { data, length }
}

/// # Safety
/// Pass the original result of `scrobbler_fingerprint` exactly once.
#[no_mangle]
pub unsafe extern "C" fn scrobbler_free_fingerprint(bytes: FingerprintBytes) {
    if !bytes.data.is_null() {
        let slice = std::ptr::slice_from_raw_parts_mut(bytes.data, bytes.length);
        drop(unsafe { Box::from_raw(slice) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_encodes_valid_input_and_rejects_partial_windows() {
        let samples = vec![0; WINDOW_SAMPLES];
        let invalid = unsafe { scrobbler_fingerprint(samples.as_ptr(), WINDOW_SAMPLES - 1) };
        assert!(invalid.data.is_null());
        assert_eq!(invalid.length, 0);

        let result = unsafe { scrobbler_fingerprint(samples.as_ptr(), samples.len()) };
        assert!(!result.data.is_null());
        assert_eq!(result.length, 56);
        let bytes = unsafe { std::slice::from_raw_parts(result.data, result.length) };
        assert_eq!(&bytes[0..4], &0xcafe_2580_u32.to_le_bytes());
        assert_eq!(&bytes[4..8], &crc32fast::hash(&bytes[8..]).to_le_bytes());
        assert_eq!(
            &bytes[40..44],
            &(WINDOW_SAMPLES as u32 + 3840).to_le_bytes()
        );
        unsafe { scrobbler_free_fingerprint(result) };
    }
}
