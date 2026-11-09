// Adapted from shazamio-core 2.1.0 (effeb115499c1bd87f5a13fc5eb99ac1e0b0a578).
// See LICENSE-MIT and UPSTREAM.md for attribution.

use crate::signature_format::{Fingerprint, FrequencyBand, FrequencyPeak};
use chfft::RFft1D;
use std::collections::HashMap;
use std::f64::consts::PI;

pub(crate) const SAMPLE_RATE_HZ: u32 = 16000;

const FRAME_LENGTH: usize = 2048;
const HOP_LENGTH: usize = 128;
const BIN_COUNT: usize = FRAME_LENGTH / 2 + 1;

// Frames are kept by their index modulo this, and every lag below stays under it.
const HISTORY_LENGTH: usize = 256;

// A frame is judged this many hops after it was computed, once every later frame its
//  neighbourhood needs exists; its neighbours are read around an older reference frame.
const PEAK_LAG: usize = 45;
const REFERENCE_LAG: usize = 48;

// The neighbourhood a peak must beat. A spread value at `bin - 1` already covers bins
//  `bin - 1` to `bin + 1`, so the reference bin is the one below the candidate.
const FREQUENCY_NEIGHBOUR_DISTANCES: [usize; 4] = [2, 3, 6, 9];
const TIME_NEIGHBOUR_DISTANCES: [usize; 7] = [4, 7, 14, 21, 28, 35, 42];

// How many hops back a new frame's spread values are carried.
const SPREAD_BACK_LAGS: [usize; 3] = [1, 3, 6];

const FIRST_PEAK_BIN: usize = 10;
const LAST_PEAK_BIN: usize = 1014;
const MIN_PEAK_POWER: f32 = 1.0 / 64.0;

// `refined_bin` counts in 1/64 of a bin, and one bin is 8000 / 1024 Hz, so a
//  refined bin is 125 / 1024 Hz.
const REFINED_BIN_HZ_NUMERATOR: u32 = 125;
const REFINED_BIN_HZ_DENOMINATOR: u32 = 1024;

#[derive(Clone)]
struct Frame {
    power: [f32; BIN_COUNT],
    spread: [f32; BIN_COUNT],
}

// The slots are zeroed up front and a lag may reach one not written yet, which reads
//  as silence.
struct History {
    frames: Vec<Frame>,
    count: usize,
}

impl History {
    fn slot(&self, lag: usize) -> usize {
        (self.count + HISTORY_LENGTH - 1 - lag) % HISTORY_LENGTH
    }

    fn ago(&self, lag: usize) -> &Frame {
        &self.frames[self.slot(lag)]
    }

    fn ago_mut(&mut self, lag: usize) -> &mut Frame {
        let slot = self.slot(lag);

        &mut self.frames[slot]
    }
}

struct Spectrogram {
    fft: RFft1D<f32>,
    window: Vec<f32>,
    samples: [i16; FRAME_LENGTH],
    history: History,
    peaks: HashMap<FrequencyBand, Vec<FrequencyPeak>>,
}

impl Spectrogram {
    fn new() -> Self {
        let silence = Frame {
            power: [0.0; BIN_COUNT],
            spread: [0.0; BIN_COUNT],
        };

        Spectrogram {
            fft: RFft1D::new(FRAME_LENGTH),
            window: hann_window(),
            samples: [0; FRAME_LENGTH],
            history: History {
                frames: vec![silence; HISTORY_LENGTH],
                count: 0,
            },
            peaks: HashMap::new(),
        }
    }

    fn push_hop(&mut self, hop: &[i16]) {
        self.samples.copy_within(HOP_LENGTH.., 0);
        self.samples[FRAME_LENGTH - HOP_LENGTH..].copy_from_slice(hop);

        let power = self.power_spectrum();

        let mut spread = power;
        for (bin, triple) in power.windows(3).enumerate() {
            spread[bin] = triple[0].max(triple[1]).max(triple[2]);
        }

        self.history.count += 1;

        for lag in SPREAD_BACK_LAGS {
            let earlier = &mut self.history.ago_mut(lag).spread;

            for (earlier_value, value) in earlier.iter_mut().zip(&spread) {
                *earlier_value = earlier_value.max(*value);
            }
        }

        *self.history.ago_mut(0) = Frame { power, spread };

        if self.history.count > PEAK_LAG {
            pick_peaks(&self.history, &mut self.peaks);
        }
    }

    fn power_spectrum(&mut self) -> [f32; BIN_COUNT] {
        let windowed: Vec<f32> = self
            .samples
            .iter()
            .zip(&self.window)
            .map(|(&sample, weight)| sample as f32 * weight)
            .collect();

        let mut power = [0.0; BIN_COUNT];
        for (value, coefficient) in power.iter_mut().zip(self.fft.forward(&windowed)) {
            *value = (coefficient.norm_sqr() / 131072.0).max(1e-10);
        }

        power
    }
}

fn pick_peaks(history: &History, peaks: &mut HashMap<FrequencyBand, Vec<FrequencyPeak>>) {
    let frame_index = (history.count - 1 - PEAK_LAG) as u32;
    let candidate = &history.ago(PEAK_LAG).power;
    let reference = &history.ago(REFERENCE_LAG).spread;

    let time_neighbours: Vec<&[f32; BIN_COUNT]> = TIME_NEIGHBOUR_DISTANCES
        .iter()
        .flat_map(|distance| [REFERENCE_LAG - distance, REFERENCE_LAG + distance])
        .map(|lag| &history.ago(lag).spread)
        .collect();

    for bin in FIRST_PEAK_BIN..=LAST_PEAK_BIN {
        let power = candidate[bin];
        let below = bin - 1;

        if power < MIN_PEAK_POWER || power < reference[below] {
            continue;
        }

        let beats_frequency_neighbours = FREQUENCY_NEIGHBOUR_DISTANCES.iter().all(|distance| {
            power > reference[below - distance] && power > reference[below + distance]
        });
        let beats_time_neighbours = time_neighbours.iter().all(|frame| power > frame[below]);

        if !beats_frequency_neighbours || !beats_time_neighbours {
            continue;
        }

        let magnitude = log_magnitude(power);
        let refined_bin = refine_bin(
            bin,
            log_magnitude(candidate[bin - 1]),
            magnitude,
            log_magnitude(candidate[bin + 1]),
        );
        let frequency_hz =
            u32::from(refined_bin) * REFINED_BIN_HZ_NUMERATOR / REFINED_BIN_HZ_DENOMINATOR;

        let Some(band) = FrequencyBand::containing(frequency_hz) else {
            continue;
        };

        peaks.entry(band).or_default().push(FrequencyPeak {
            frame: frame_index,
            magnitude: magnitude as u16,
            refined_bin,
        });
    }
}

// `numpy.hanning(FRAME_LENGTH + 2)[1:-1]`: a Hann window whose zero ends fall just
//  outside the frame, so no sample inside it is weighted to nothing.
fn hann_window() -> Vec<f32> {
    let period = (FRAME_LENGTH + 1) as f64;

    (1..=FRAME_LENGTH)
        .map(|position| (PI * position as f64 / period).sin().powi(2) as f32)
        .collect()
}

// The scale the signature format stores a peak's magnitude in.
fn log_magnitude(power: f32) -> f32 {
    power.ln().max(1.0 / 64.0) * 1477.3 + 6144.0
}

// Fits a parabola through the peak and its two neighbours and returns its vertex, in
//  1/64 of a bin.
fn refine_bin(bin: usize, below: f32, peak: f32, above: f32) -> u16 {
    let curvature = peak * 2.0 - below - above;
    let vertex_offset = (above - below) * 32.0 / curvature;

    (bin as i32 * 64 + vertex_offset as i32) as u16
}

// A trailing part of a hop is dropped, as the frames advance a whole hop at a time.
pub fn fingerprint_samples(samples: &[i16]) -> Fingerprint {
    let mut spectrogram = Spectrogram::new();

    for hop in samples.chunks_exact(HOP_LENGTH) {
        spectrogram.push_hop(hop);
    }

    Fingerprint {
        sample_rate_hz: SAMPLE_RATE_HZ,
        sample_count: samples.len() as u32,
        peaks_by_band: spectrogram.peaks,
    }
}
