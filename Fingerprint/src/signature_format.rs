// Adapted from shazamio-core 2.1.0 (effeb115499c1bd87f5a13fc5eb99ac1e0b0a578).
// See LICENSE-MIT and UPSTREAM.md for attribution.

use std::collections::HashMap;

const HEADER_LENGTH: usize = 48;
const HEADER_MAGIC: u32 = 0xcafe_2580;
const HEADER_SECOND_MAGIC: u32 = 0x9411_9c00;
const HEADER_FIXED_VALUE: u32 = 0x007c_0000;
const SAMPLE_RATE_ID_SHIFT: u32 = 27;
const BODY_MAGIC: u32 = 0x4000_0000;
const BAND_MARKER_BASE: u32 = 0x6003_0040;

// A frame delta this large does not fit its byte, so the frame index is written whole.
const FRAME_ESCAPE: u8 = 0xff;

pub struct FrequencyPeak {
    pub frame: u32,
    pub magnitude: u16,
    // In 1/64 of an FFT bin.
    pub refined_bin: u16,
}

#[derive(Hash, Eq, PartialEq, PartialOrd, Ord, Debug, Clone, Copy)]
pub enum FrequencyBand {
    Hz250To520 = 0,
    Hz520To1450 = 1,
    Hz1450To3500 = 2,
    Hz3500To5500 = 3,
}

impl FrequencyBand {
    pub fn containing(frequency_hz: u32) -> Option<Self> {
        match frequency_hz {
            250..=519 => Some(FrequencyBand::Hz250To520),
            520..=1449 => Some(FrequencyBand::Hz520To1450),
            1450..=3499 => Some(FrequencyBand::Hz1450To3500),
            3500..=5500 => Some(FrequencyBand::Hz3500To5500),
            _ => None,
        }
    }
}

pub struct Fingerprint {
    pub sample_rate_hz: u32,
    pub sample_count: u32,
    pub peaks_by_band: HashMap<FrequencyBand, Vec<FrequencyPeak>>,
}

fn sample_rate_id(sample_rate_hz: u32) -> u32 {
    match sample_rate_hz {
        8000 => 1,
        11025 => 2,
        16000 => 3,
        32000 => 4,
        44100 => 5,
        48000 => 6,
        _ => panic!("Invalid sample rate {sample_rate_hz} for a signature"),
    }
}

fn encode_peaks(peaks: &[FrequencyPeak]) -> Vec<u8> {
    let mut encoded = Vec::with_capacity(peaks.len() * 5);
    let mut previous_frame = 0;

    for peak in peaks {
        let mut delta = peak
            .frame
            .checked_sub(previous_frame)
            .expect("the peaks of a band are in frame order");

        if delta >= u32::from(FRAME_ESCAPE) {
            encoded.push(FRAME_ESCAPE);
            encoded.extend_from_slice(&peak.frame.to_le_bytes());
            delta = 0;
        }

        encoded.push(delta as u8);
        encoded.extend_from_slice(&peak.magnitude.to_le_bytes());
        encoded.extend_from_slice(&peak.refined_bin.to_le_bytes());

        previous_frame = peak.frame;
    }

    encoded
}

impl Fingerprint {
    pub fn encode(&self) -> Vec<u8> {
        let mut bands: Vec<_> = self.peaks_by_band.iter().collect();
        bands.sort_by_key(|(band, _)| **band);

        let mut body = Vec::new();
        for (band, peaks) in bands {
            let encoded = encode_peaks(peaks);

            body.extend_from_slice(&(BAND_MARKER_BASE + *band as u32).to_le_bytes());
            body.extend_from_slice(&(encoded.len() as u32).to_le_bytes());
            body.extend_from_slice(&encoded);
            body.resize(body.len().next_multiple_of(4), 0);
        }

        // The body opens with its own magic and length, and both lengths count them.
        let body_length = (body.len() + 8) as u32;

        // The format pads the sample count by 240 ms; `* 24 / 100` is exact at every
        //  rate `sample_rate_id` accepts.
        let padded_sample_count = self.sample_count + self.sample_rate_hz * 24 / 100;

        let words = [
            HEADER_MAGIC,
            0,
            body_length,
            HEADER_SECOND_MAGIC,
            0,
            0,
            0,
            sample_rate_id(self.sample_rate_hz) << SAMPLE_RATE_ID_SHIFT,
            0,
            0,
            padded_sample_count,
            HEADER_FIXED_VALUE,
            BODY_MAGIC,
            body_length,
        ];

        let mut signature = Vec::with_capacity(HEADER_LENGTH + body_length as usize);
        for word in words {
            signature.extend_from_slice(&word.to_le_bytes());
        }
        signature.extend_from_slice(&body);

        let checksum = crc32fast::hash(&signature[8..]);
        signature[4..8].copy_from_slice(&checksum.to_le_bytes());

        signature
    }
}
